#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load .env file if it exists
if [ -f "$(dirname "$0")/../.env" ]; then
    source "$(dirname "$0")/../.env"
elif [ -f "$(dirname "$0")/.env" ]; then
    source "$(dirname "$0")/.env"
elif [ -f ".env" ]; then
    source ".env"
fi

# Default credentials if not set in .env
PG_ADMIN_USER="${PG_ADMIN_USER:-postgres}"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-postgres123}"
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicator}"
PG_REPLICATION_PASSWORD="${PG_REPLICATION_PASSWORD:-replicator123}"

COMPOSE_FILE="$(dirname "$0")/docker-compose.swarm.yml"

# Check for required nodes
echo -e "${BLUE}Checking required nodes...${NC}"
REQUIRED_NODES="server-b server-c server-d"
MISSING_NODES=""
for node in $REQUIRED_NODES; do
    if ! docker node ls --format "{{.Hostname}}" 2>/dev/null | grep -q "^${node}$"; then
        MISSING_NODES="$MISSING_NODES $node"
    fi
done

if [ -n "$MISSING_NODES" ]; then
    echo -e "${YELLOW}Warning: Missing nodes:${MISSING_NODES}${NC}"
    echo "Services will fail to start on missing nodes."
    echo ""
fi

# Setup PostgreSQL init replication script as Docker config
echo -e "${BLUE}Setting up PostgreSQL replication init script...${NC}"

if ! docker config ls 2>/dev/null | grep -q "pg_init_replication"; then
    echo "Creating pg_init_replication Docker config..."

    cat > /tmp/pg-init-replication.sh << 'INITEOF'
#!/bin/bash
set -e

echo "Setting up PostgreSQL replication..."

# Create replication user (idempotent)
psql -v ON_ERROR_STOP=0 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
DO \$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$REPLICATION_USER') THEN
      EXECUTE format('CREATE ROLE %I WITH REPLICATION LOGIN PASSWORD %L', '$REPLICATION_USER', '$REPLICATION_PASSWORD');
      RAISE NOTICE 'Created replication user: %', '$REPLICATION_USER';
   ELSE
      RAISE NOTICE 'Replication user already exists: %', '$REPLICATION_USER';
   END IF;
END
\$do\$;
EOSQL

# Add replication access rule if not already present
if ! grep -q "host replication ${REPLICATION_USER} all" "$PGDATA/pg_hba.conf"; then
    echo "host replication ${REPLICATION_USER} all scram-sha-256" >> "$PGDATA/pg_hba.conf"
    echo "Added replication rule to pg_hba.conf"
fi

# Reload configuration to apply pg_hba.conf changes
pg_ctl reload -D "$PGDATA"

echo "Replication setup complete"
INITEOF

    docker config create pg_init_replication /tmp/pg-init-replication.sh
    rm /tmp/pg-init-replication.sh
    echo -e "${GREEN}pg_init_replication Docker config created${NC}"
else
    echo "pg_init_replication Docker config already exists"
fi

# Function to get the node where pg-primary is running
get_primary_node() {
    docker service ps pgcluster_pg-primary --filter "desired-state=running" --format "{{.Node}}" 2>/dev/null | head -1
}

# Function to check if pg-primary service is running
is_service_running() {
    local replicas=$(docker service ls --filter "name=pgcluster_pg-primary" --format "{{.Replicas}}" 2>/dev/null)
    [[ "$replicas" == "1/1" ]]
    return $?
}

# Function to execute psql command on the primary via temporary container
exec_psql() {
    local sql_cmd="$1"
    PGPASSWORD="$PG_ADMIN_PASSWORD" docker run --rm --network pgcluster_internal postgres:18 \
        psql -h pg-primary -U "$PG_ADMIN_USER" -d postgres -t -A -c "$sql_cmd" 2>/dev/null
}

# Function to check if replication is active
is_replication_active() {
    local count=$(exec_psql "SELECT count(*) FROM pg_stat_replication;")
    [[ "$count" -gt 0 ]] 2>/dev/null
    return $?
}

# Main logic: Check cluster status
echo ""
echo -e "${BLUE}Checking cluster status...${NC}"

if is_service_running; then
    PRIMARY_NODE=$(get_primary_node)
    echo "PostgreSQL primary is running on node: ${PRIMARY_NODE}"

    # Check if we can connect
    if exec_psql "SELECT 1;" | grep -q "1"; then
        echo -e "${GREEN}PostgreSQL primary is accessible${NC}"

        # Check replication status
        if is_replication_active; then
            echo -e "${GREEN}Streaming replication is active${NC}"

            echo ""
            echo "Replication status:"
            PGPASSWORD="$PG_ADMIN_PASSWORD" docker run --rm --network pgcluster_internal postgres:18 \
                psql -h pg-primary -U "$PG_ADMIN_USER" -d postgres -c \
                "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;" 2>/dev/null
        else
            echo -e "${YELLOW}No active replication connections yet${NC}"
            echo "Standbys may still be initializing (pg_basebackup in progress)."
        fi

        echo ""
        echo -e "${GREEN}=============================================${NC}"
        echo -e "${GREEN}PostgreSQL cluster is running${NC}"
        echo -e "${GREEN}=============================================${NC}"
        echo ""
        echo "Admin credentials (from .env or defaults):"
        echo "  Admin user:       ${PG_ADMIN_USER}"
        echo "  Admin password:   ${PG_ADMIN_PASSWORD}"
        echo ""
        echo "Connection string:"
        echo "  postgresql://${PG_ADMIN_USER}:${PG_ADMIN_PASSWORD}@pg-primary:5432/postgres"
        echo ""
        echo -e "${YELLOW}To create application users, run:${NC}"
        echo "  ./devops/create-app-user.sh <database> <username> <password>"
        echo ""
    else
        echo -e "${YELLOW}Cannot connect to PostgreSQL yet. Waiting for services to start.${NC}"
    fi
else
    # Check if the stack exists at all
    if docker service ls --filter "name=pgcluster" --format "{{.Name}}" 2>/dev/null | grep -q "pgcluster"; then
        echo -e "${YELLOW}PostgreSQL services exist but primary is not running (0/1 replicas)${NC}"
        echo "Check service status: docker service ps pgcluster_pg-primary --no-trunc"
    else
        echo "PostgreSQL cluster not deployed yet (first deployment)"
    fi
fi

echo ""
echo -e "${GREEN}Pre-deployment checks complete${NC}"
