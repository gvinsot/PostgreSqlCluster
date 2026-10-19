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
PG_DEFAULT_DB="${PG_DEFAULT_DB:-postgres}"
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicator}"
PG_REPLICATION_PASSWORD="${PG_REPLICATION_PASSWORD:-replicator123}"
PG_IMAGE="${PG_IMAGE:-timescale/timescaledb:2.25.2-pg18}"
STACK_NAME="${DEPLOY_STACK_NAME:-${STACK_NAME:-postgresqlcluster}}"
PG_NETWORK_NAME="${PG_NETWORK_NAME:-${STACK_NAME}_internal}"

# Target placement (defaults must match docker-compose.swarm.yml)
PG_PRIMARY_NODE="${PG_PRIMARY_NODE:-server-d}"
PG_STANDBY1_NODE="${PG_STANDBY1_NODE:-server-c}"
PG_STANDBY2_NODE="${PG_STANDBY2_NODE:-server-b}"
# Seconds to wait for the promoted standby to replay the last WAL of the old primary
PG_SWITCHOVER_CATCHUP_TIMEOUT="${PG_SWITCHOVER_CATCHUP_TIMEOUT:-120}"

COMPOSE_FILE="$(dirname "$0")/docker-compose.swarm.yml"

# Check for required nodes
echo -e "${BLUE}Checking required nodes...${NC}"
echo "Using PostgreSQL image: ${PG_IMAGE}"
echo "Using Docker network: ${PG_NETWORK_NAME}"
echo "Target placement: pg-primary=${PG_PRIMARY_NODE} pg-standby1=${PG_STANDBY1_NODE} pg-standby2=${PG_STANDBY2_NODE}"

REQUIRED_NODES="$PG_PRIMARY_NODE $PG_STANDBY1_NODE $PG_STANDBY2_NODE"
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

if [ "$(printf '%s\n' $REQUIRED_NODES | sort -u | wc -l)" -ne 3 ]; then
    echo -e "${RED}ERROR: PG_PRIMARY_NODE, PG_STANDBY1_NODE and PG_STANDBY2_NODE must be three different nodes${NC}"
    exit 1
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
    docker service ps "${STACK_NAME}_pg-primary" --filter "desired-state=running" --format "{{.Node}}" 2>/dev/null | head -1
}

# Function to check if pg-primary service is running
is_service_running() {
    local replicas
    replicas=$(docker service ls --filter "name=${STACK_NAME}_pg-primary" --format "{{.Replicas}}" 2>/dev/null)
    [[ "$replicas" == "1/1" ]]
    return $?
}

# Function to execute a psql command through a temporary container on the cluster network
# Usage: exec_psql_on <host> <sql> [database]
exec_psql_on() {
    local host="$1"
    local sql_cmd="$2"
    local database="${3:-postgres}"

    # -e PGPASSWORD forwards the value from this environment (not visible in ps)
    PGPASSWORD="$PG_ADMIN_PASSWORD" docker run --rm --network "$PG_NETWORK_NAME" -e PGPASSWORD "$PG_IMAGE" \
        psql -v ON_ERROR_STOP=1 -h "$host" -U "$PG_ADMIN_USER" -d "$database" -t -A -c "$sql_cmd" 2>/dev/null
}

# Function to execute psql command on the primary via temporary container
exec_psql() {
    exec_psql_on pg-primary "$1" "${2:-postgres}"
}

# Function to check if replication is active
is_replication_active() {
    local count
    count=$(exec_psql "SELECT count(*) FROM pg_stat_replication;" "postgres")
    [[ "$count" -gt 0 ]] 2>/dev/null
    return $?
}

# Function to check if TimescaleDB is enabled on the default database
is_timescaledb_enabled() {
    local enabled
    enabled=$(exec_psql "SELECT 1 FROM pg_extension WHERE extname = 'timescaledb';" "$PG_DEFAULT_DB")
    [[ "$enabled" == "1" ]]
    return $?
}

# ============================================================================
# Switchover: move the primary role to another node
# ============================================================================
# Volumes are local to each node, so changing the placement constraints alone
# would start the primary on an empty volume. When PG_PRIMARY_NODE differs from
# the node the primary is deployed on, and a standby runs on PG_PRIMARY_NODE:
#   1. stop the old primary cleanly (shutdown checkpoint streamed to standbys)
#   2. wait for that standby to replay the shutdown checkpoint
#   3. promote it, then stop it cleanly
#   4. copy its data into the pg_primary_data volume of PG_PRIMARY_NODE
#   5. fence the retired volumes (old primary, promoted standby) so that a
#      rollback to the previous compose cannot start them
#   6. empty the volumes of standbys moving to another node: they start with
#      a fresh pg_basebackup from the new primary
# docker stack deploy then applies the new placement. Up to step 3 every
# failure restarts the old primary and aborts the deployment.

# Node in the "node.hostname == X" placement constraint of a stack service
service_node() {
    docker service inspect "${STACK_NAME}_$1" \
        --format '{{range .Spec.TaskTemplate.Placement.Constraints}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n 's/^node\.hostname *== *//p' | head -1
}

target_node() {
    case "$1" in
        pg-primary) echo "$PG_PRIMARY_NODE" ;;
        pg-standby1) echo "$PG_STANDBY1_NODE" ;;
        pg-standby2) echo "$PG_STANDBY2_NODE" ;;
    esac
}

volume_of() {
    case "$1" in
        pg-primary) echo "${STACK_NAME}_pg_primary_data" ;;
        pg-standby1) echo "${STACK_NAME}_pg_standby1_data" ;;
        pg-standby2) echo "${STACK_NAME}_pg_standby2_data" ;;
    esac
}

scale_service() {
    docker service scale --detach=false "${STACK_NAME}_$1=$2" >/dev/null 2>&1
}

# Run a bash script as a one-shot swarm job on a given node, with node-local
# volumes mounted. Usage: run_node_job <node> <label> <script> <volume>:<path>...
# The job output is printed and kept in $JOB_OUTPUT.
JOB_OUTPUT=""
run_node_job() {
    local node="$1" label="$2" script="$3"
    shift 3
    local name="pgswitch-${label}-$(date +%s)"
    local mounts=() m state="" i

    for m in "$@"; do
        mounts+=(--mount "type=volume,source=${m%%:*},target=${m#*:}")
    done

    if ! docker service create --detach --quiet --name "$name" \
        --mode replicated-job --restart-condition none \
        --constraint "node.hostname==${node}" \
        "${mounts[@]}" --entrypoint bash "$PG_IMAGE" -c "$script" >/dev/null; then
        echo -e "${RED}Could not create job ${name} on ${node}${NC}"
        return 1
    fi

    for i in $(seq 1 360); do
        state=$(docker service ps "$name" --format '{{.CurrentState}}' 2>/dev/null | head -1)
        case "$state" in Complete*|Failed*|Rejected*) break ;; esac
        sleep 5
    done

    JOB_OUTPUT=$(docker service logs --raw "$name" 2>&1)
    printf '%s\n' "$JOB_OUTPUT" | sed "s/^/    [${node}] /"
    docker service rm "$name" >/dev/null 2>&1

    if [[ "$state" != Complete* ]]; then
        echo -e "${RED}Job ${label} on ${node} did not complete (state: ${state:-unknown})${NC}"
        return 1
    fi
}

# Restart the old primary and abort the deployment (only valid before promotion)
abort_switchover() {
    echo -e "${RED}Switchover aborted: $1${NC}"
    echo "Restarting the old primary on ${OLD_PRIMARY_NODE}..."
    scale_service pg-primary 1
    exit 1
}

# Data directory of a volume mounted on /v, relative to the image PGDATA
JOB_PGDATA='D=/v${PGDATA#/var/lib/postgresql}'

FENCE_TEXT="This volume was retired by a PostgreSQL switchover on $(date -u '+%Y-%m-%dT%H:%M:%SZ'): its data is stale.
The cluster now runs with pg-primary on ${PG_PRIMARY_NODE}. PG_VERSION was renamed PG_VERSION.fenced
so that no PostgreSQL instance can start on it. Remove the volume once it is no longer needed as a backup."

switchover() {
    OLD_PRIMARY_NODE="$1"
    local new_node="$PG_PRIMARY_NODE"
    local src="" s ckpt state promoted moved

    echo ""
    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}Switchover: pg-primary ${OLD_PRIMARY_NODE} -> ${new_node}${NC}"
    echo -e "${BLUE}=============================================${NC}"

    # --- Pre-flight checks (nothing changed yet) ---
    for s in pg-standby1 pg-standby2; do
        [ "$(service_node "$s")" = "$new_node" ] && src="$s"
    done
    if [ -z "$src" ]; then
        echo -e "${RED}ERROR: no standby is deployed on ${new_node}: the new primary node must currently host a standby${NC}"
        exit 1
    fi
    echo "Standby to promote: ${src} (on ${new_node})"

    if [ "$(get_primary_node)" != "$OLD_PRIMARY_NODE" ] || ! is_service_running; then
        echo -e "${RED}ERROR: pg-primary is not running on ${OLD_PRIMARY_NODE}, refusing to switch over${NC}"
        exit 1
    fi
    if [ "$(exec_psql "SELECT pg_is_in_recovery();")" != "f" ]; then
        echo -e "${RED}ERROR: pg-primary is not reachable or not a primary${NC}"
        exit 1
    fi
    if [ "$(exec_psql_on "$src" "SELECT status FROM pg_stat_wal_receiver;")" != "streaming" ]; then
        echo -e "${RED}ERROR: ${src} is not streaming from the primary${NC}"
        exit 1
    fi
    echo -e "${GREEN}Primary is up and ${src} is streaming${NC}"

    # --- 1. Stop the old primary cleanly ---
    echo "Checkpoint on the primary (shortens the shutdown checkpoint)..."
    exec_psql "CHECKPOINT;" >/dev/null
    echo "Stopping pg-primary on ${OLD_PRIMARY_NODE} (applications are disconnected from now on)..."
    if ! scale_service pg-primary 0; then
        abort_switchover "could not stop pg-primary"
    fi

    run_node_job "$OLD_PRIMARY_NODE" controldata \
        "$JOB_PGDATA; pg_controldata \"\$D\"" \
        "$(volume_of pg-primary):/v" \
        || abort_switchover "could not read pg_control of the old primary"
    state=$(printf '%s\n' "$JOB_OUTPUT" | sed -n 's/^Database cluster state: *//p')
    ckpt=$(printf '%s\n' "$JOB_OUTPUT" | sed -n 's/^Latest checkpoint location: *//p')
    if [ "$state" != "shut down" ] || [ -z "$ckpt" ]; then
        abort_switchover "old primary did not shut down cleanly (state: ${state:-unknown})"
    fi
    echo "Old primary shut down cleanly, shutdown checkpoint at ${ckpt}"

    # --- 2. Wait for the standby to replay the shutdown checkpoint ---
    local caught_up=""
    for i in $(seq 1 $((PG_SWITCHOVER_CATCHUP_TIMEOUT / 5))); do
        caught_up=$(exec_psql_on "$src" "SELECT pg_last_wal_replay_lsn() > '${ckpt}'::pg_lsn;")
        [ "$caught_up" = "t" ] && break
        sleep 5
    done
    if [ "$caught_up" != "t" ]; then
        abort_switchover "${src} did not replay up to ${ckpt} within ${PG_SWITCHOVER_CATCHUP_TIMEOUT}s"
    fi
    echo -e "${GREEN}${src} has replayed all the WAL of the old primary${NC}"

    for s in pg-standby1 pg-standby2; do
        [ "$s" = "$src" ] && continue
        if [ "$(exec_psql_on "$s" "SELECT pg_last_wal_receive_lsn() > '${ckpt}'::pg_lsn;")" = "t" ]; then
            echo "${s} received all the WAL of the old primary (it will follow the new timeline)"
        else
            echo -e "${YELLOW}${s} is behind the old primary: it will catch up from the new primary${NC}"
        fi
    done

    # --- 3. Promote the standby, then stop it cleanly ---
    promoted=$(exec_psql_on "$src" "SELECT pg_promote(true, 60);")
    if [ "$promoted" != "t" ]; then
        abort_switchover "pg_promote() failed on ${src}"
    fi
    # Point of no return: the old primary must not be restarted any more
    echo -e "${GREEN}${src} promoted (new timeline)${NC}"
    exec_psql_on "$src" "CHECKPOINT;" >/dev/null
    if ! scale_service "$src" 0; then
        echo -e "${RED}ERROR: could not stop ${src} after its promotion.${NC}"
        echo "The cluster is down. The current data lives in volume $(volume_of "$src") on ${new_node}."
        exit 1
    fi

    # --- 4. Copy the promoted data into the primary volume of the new node ---
    echo "Copying the promoted data into $(volume_of pg-primary) on ${new_node}..."
    if ! run_node_job "$new_node" copy "set -e
S=/src\${PGDATA#/var/lib/postgresql}
D=/dst\${PGDATA#/var/lib/postgresql}
[ -s \"\$S/PG_VERSION\" ] || { echo \"ERROR: no cluster in \$S\"; exit 1; }
state=\$(pg_controldata \"\$S\" | sed -n 's/^Database cluster state: *//p')
[ \"\$state\" = 'shut down' ] || { echo \"ERROR: source state is '\$state', expected 'shut down'\"; exit 1; }
find /dst -mindepth 1 -delete
cp -a /src/. /dst/
rm -f \"\$D/standby.signal\" \"\$D/recovery.signal\"
sed -i -e '/^primary_conninfo/d' -e '/^primary_slot_name/d' \"\$D/postgresql.auto.conf\"
mv \"\$S/PG_VERSION\" \"\$S/PG_VERSION.fenced\"
cat > \"\$S/SWITCHOVER_FENCED\" <<'EOF'
${FENCE_TEXT}
EOF
echo \"Copied \$(du -sh /dst | cut -f1), source volume fenced\"" \
        "$(volume_of "$src"):/src" "$(volume_of pg-primary):/dst"; then
        echo -e "${RED}ERROR: copy failed. The cluster is down.${NC}"
        echo "The current data lives in volume $(volume_of "$src") on ${new_node} (promoted, cleanly shut down)."
        echo "Fix the issue and redeploy: the switchover resumes at this copy step only manually (see MANAGE.md)."
        exit 1
    fi

    # --- 5. Fence the old primary volume ---
    if ! run_node_job "$OLD_PRIMARY_NODE" fence "$JOB_PGDATA
[ -e \"\$D/PG_VERSION\" ] && mv \"\$D/PG_VERSION\" \"\$D/PG_VERSION.fenced\"
cat > \"\$D/SWITCHOVER_FENCED\" <<'EOF'
${FENCE_TEXT}
EOF
echo 'Old primary volume fenced'" "$(volume_of pg-primary):/v"; then
        echo -e "${YELLOW}Warning: could not fence $(volume_of pg-primary) on ${OLD_PRIMARY_NODE}.${NC}"
        echo -e "${YELLOW}Do NOT roll back to a previous version before fencing or removing it.${NC}"
    fi

    echo -e "${GREEN}Switchover data move complete: pg-primary will start on ${new_node}${NC}"
    echo "Retired volumes kept as a backup (remove them once the new cluster is validated):"
    echo "  ${OLD_PRIMARY_NODE}: docker volume rm $(volume_of pg-primary)"
    echo "  ${new_node}: docker volume rm $(volume_of "$src")"
    SWITCHOVER_DONE=true
}

# Standbys moving to another node start from an empty volume (pg_basebackup):
# empty any stale volume left on the target node by an earlier placement.
reset_moving_standbys() {
    local s cur tgt
    for s in pg-standby1 pg-standby2; do
        cur=$(service_node "$s")
        tgt=$(target_node "$s")
        [ -z "$cur" ] || [ "$cur" = "$tgt" ] && continue
        echo "${s} moves ${cur} -> ${tgt}: emptying $(volume_of "$s") on ${tgt} for a fresh base backup..."
        if ! run_node_job "$tgt" reset \
            "find /v -mindepth 1 -delete; echo 'Volume emptied'" "$(volume_of "$s"):/v"; then
            echo -e "${RED}ERROR: could not empty $(volume_of "$s") on ${tgt}${NC}"
            exit 1
        fi
        # The volume left on the old node is no longer used
        [ "$s" != "$SWITCHOVER_SOURCE" ] && echo "  Old volume left on ${cur}: docker volume rm $(volume_of "$s")"
    done
}

SWITCHOVER_DONE=false
SWITCHOVER_SOURCE=""
if docker service inspect "${STACK_NAME}_pg-primary" >/dev/null 2>&1; then
    CURRENT_PRIMARY_NODE=$(service_node pg-primary)
    if [ -n "$CURRENT_PRIMARY_NODE" ] && [ "$CURRENT_PRIMARY_NODE" != "$PG_PRIMARY_NODE" ]; then
        for s in pg-standby1 pg-standby2; do
            [ "$(service_node "$s")" = "$PG_PRIMARY_NODE" ] && SWITCHOVER_SOURCE="$s"
        done
        if is_service_running; then
            switchover "$CURRENT_PRIMARY_NODE"
        else
            # Primary down: resume only if an earlier switchover already moved
            # the data (e.g. the deployment was rolled back after the copy)
            echo "pg-primary is not running: checking $(volume_of pg-primary) on ${PG_PRIMARY_NODE}..."
            if run_node_job "$PG_PRIMARY_NODE" probe "$JOB_PGDATA
[ -s \"\$D/PG_VERSION\" ] && [ ! -e \"\$D/SWITCHOVER_FENCED\" ] && [ ! -e \"\$D/standby.signal\" ] \
    && echo 'Primary data present' || { echo 'No usable primary data'; exit 1; }" \
                "$(volume_of pg-primary):/v"; then
                echo -e "${GREEN}${PG_PRIMARY_NODE} already holds the primary data: deploying the new placement${NC}"
            else
                echo -e "${RED}ERROR: pg-primary is down and ${PG_PRIMARY_NODE} holds no primary data: cannot switch over safely${NC}"
                exit 1
            fi
        fi
    fi
    reset_moving_standbys
fi

# Main logic: Check cluster status
echo ""
echo -e "${BLUE}Checking cluster status...${NC}"

if [ "$SWITCHOVER_DONE" = "true" ]; then
    echo "Switchover in progress: pg-primary will start on ${PG_PRIMARY_NODE} with this deployment."
    echo "docker-compose.post.sh checks the new topology once the stack is deployed."
elif is_service_running; then
    PRIMARY_NODE=$(get_primary_node)
    echo "PostgreSQL primary is running on node: ${PRIMARY_NODE}"

    # Check if we can connect
    if exec_psql "SELECT 1;" "postgres" | grep -q "1"; then
        echo -e "${GREEN}PostgreSQL primary is accessible${NC}"

        # Check replication status
        if is_replication_active; then
            echo -e "${GREEN}Streaming replication is active${NC}"

            echo ""
            echo "Replication status:"
            PGPASSWORD="$PG_ADMIN_PASSWORD" docker run --rm --network "$PG_NETWORK_NAME" -e PGPASSWORD "$PG_IMAGE" \
                psql -v ON_ERROR_STOP=1 -h pg-primary -U "$PG_ADMIN_USER" -d postgres -c \
                "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;" 2>/dev/null
        else
            echo -e "${YELLOW}No active replication connections yet${NC}"
            echo "Standbys may still be initializing (pg_basebackup in progress)."
        fi

        echo ""
        if is_timescaledb_enabled; then
            echo -e "${GREEN}TimescaleDB extension is enabled on database '${PG_DEFAULT_DB}'${NC}"
        else
            echo -e "${YELLOW}TimescaleDB extension is not enabled yet on database '${PG_DEFAULT_DB}'${NC}"
            echo "It will be created automatically by the pg-init service after deployment."
        fi

        echo ""
        echo -e "${GREEN}=============================================${NC}"
        echo -e "${GREEN}PostgreSQL cluster is running${NC}"
        echo -e "${GREEN}=============================================${NC}"
        echo ""
        # The output lands in the PulsarCD deploy logs: never print the password
        echo "Admin credentials (from .env or defaults):"
        echo "  Admin user:       ${PG_ADMIN_USER}"
        echo "  Admin password:   PG_ADMIN_PASSWORD in devops/.env"
        echo "  Default database: ${PG_DEFAULT_DB}"
        echo ""
        echo "Connection string:"
        echo "  postgresql://${PG_ADMIN_USER}:<PG_ADMIN_PASSWORD>@pg-primary:5432/${PG_DEFAULT_DB}"
        echo ""
        echo -e "${YELLOW}To create application users, run:${NC}"
        echo "  ./devops/create-app-user.sh <database> <username> <password> [role]"
        echo ""
    else
        echo -e "${YELLOW}Cannot connect to PostgreSQL yet. Waiting for services to start.${NC}"
    fi
else
    # Check if the stack exists at all
    if docker service ls --filter "name=${STACK_NAME}" --format "{{.Name}}" 2>/dev/null | grep -q "${STACK_NAME}"; then
        echo -e "${YELLOW}PostgreSQL services exist but primary is not running (0/1 replicas)${NC}"
        echo "Check service status: docker service ps ${STACK_NAME}_pg-primary --no-trunc"
    else
        echo "PostgreSQL cluster not deployed yet (first deployment)"
    fi
fi

echo ""
echo -e "${GREEN}Pre-deployment checks complete${NC}"
