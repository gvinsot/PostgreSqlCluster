#!/bin/bash

# ============================================================================
# Create PostgreSQL Application User
# ============================================================================
# Usage: ./create-app-user.sh <database> <username> <password> [role]
#
# Examples:
#   ./create-app-user.sh myapp appuser secretpass
#   ./create-app-user.sh myapp appuser secretpass readwrite
#   ./create-app-user.sh myapp readonly_user secretpass readonly
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load .env file if it exists (for admin credentials)
if [ -f "$(dirname "$0")/.env" ]; then
    source "$(dirname "$0")/.env"
elif [ -f "$(dirname "$0")/../.env" ]; then
    source "$(dirname "$0")/../.env"
elif [ -f ".env" ]; then
    source ".env"
fi

# Admin credentials for authentication
PG_ADMIN_USER="${PG_ADMIN_USER:-postgres}"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-postgres123}"

# Parse arguments
DATABASE="$1"
USERNAME="$2"
PASSWORD="$3"
ROLE="${4:-owner}"

# Validate arguments
if [ -z "$DATABASE" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo ""
    echo "Usage: $0 <database> <username> <password> [role]"
    echo ""
    echo "Arguments:"
    echo "  database    The PostgreSQL database name"
    echo "  username    The username to create"
    echo "  password    The password for the user"
    echo "  role        Optional role (default: readwrite)"
    echo ""
    echo "Available roles:"
    echo "  readonly    SELECT only"
    echo "  readwrite   SELECT, INSERT, UPDATE, DELETE (default)"
    echo "  admin       ALL PRIVILEGES on the database"
    echo "  owner       Database owner"
    echo ""
    echo "Examples:"
    echo "  $0 myapp appuser mypassword"
    echo "  $0 analytics reader readpass readonly"
    exit 1
fi

# Validate role
case "$ROLE" in
    readonly|readwrite|admin|owner)
        ;;
    *)
        echo -e "${RED}Error: Invalid role '${ROLE}'${NC}"
        echo "Available roles: readonly, readwrite, admin, owner"
        exit 1
        ;;
esac

# Check if pg-primary service is running
if ! docker service ls --filter "name=postgresqlcluster_pg-primary" --format "{{.Replicas}}" 2>/dev/null | grep -q "1/1"; then
    echo -e "${RED}Error: PostgreSQL primary service is not running${NC}"
    echo "Make sure the PostgreSQL cluster is deployed and running."
    echo ""
    echo "Check status: docker service ls --filter name=postgresqlcluster"
    exit 1
fi

# Check if the overlay network exists
if ! docker network ls --filter "name=postgresqlcluster_internal" --format "{{.Name}}" 2>/dev/null | grep -q "postgresqlcluster_internal"; then
    echo -e "${RED}Error: PostgreSQL network 'postgresqlcluster_internal' not found${NC}"
    echo "Make sure the PostgreSQL cluster is deployed."
    exit 1
fi

echo -e "${BLUE}Creating user '${USERNAME}' on database '${DATABASE}' with role '${ROLE}'...${NC}"

# Helper function to run psql via temporary container
run_psql() {
    PGPASSWORD="$PG_ADMIN_PASSWORD" docker run --rm --network postgresqlcluster_internal postgres:18 \
        psql -h pg-primary -U "$PG_ADMIN_USER" -d "$1" -t -A -c "$2" 2>&1
}

run_psql_verbose() {
    PGPASSWORD="$PG_ADMIN_PASSWORD" docker run --rm --network postgresqlcluster_internal postgres:18 \
        psql -h pg-primary -U "$PG_ADMIN_USER" -d "$1" -c "$2" 2>&1
}

# Step 1: Create the database if it doesn't exist
DB_EXISTS=$(run_psql "postgres" "SELECT 1 FROM pg_database WHERE datname = '${DATABASE}'")
if [ "$DB_EXISTS" != "1" ]; then
    RESULT=$(run_psql "postgres" "CREATE DATABASE ${DATABASE}")
    if echo "$RESULT" | grep -qi "error"; then
        echo -e "${RED}Failed to create database: $RESULT${NC}"
        exit 1
    fi
    echo -e "${GREEN}Database '${DATABASE}' created${NC}"
else
    echo "Database '${DATABASE}' already exists"
fi

# Step 2: Create the user if it doesn't exist
USER_EXISTS=$(run_psql "postgres" "SELECT 1 FROM pg_roles WHERE rolname = '${USERNAME}'")
if [ "$USER_EXISTS" = "1" ]; then
    echo -e "${YELLOW}User '${USERNAME}' already exists${NC}"
    echo ""
    echo "Connection string:"
    echo "  postgresql://${USERNAME}:<password>@pg-primary:5432/${DATABASE}"
    echo ""
    echo "With all hosts (failover):"
    echo "  postgresql://${USERNAME}:<password>@pg-primary:5432,pg-standby1:5432,pg-standby2:5432/${DATABASE}?target_session_attrs=read-write"
    exit 0
fi

RESULT=$(run_psql "postgres" "CREATE ROLE ${USERNAME} WITH LOGIN PASSWORD '${PASSWORD}'")
if echo "$RESULT" | grep -qi "error"; then
    echo -e "${RED}Failed to create user: $RESULT${NC}"
    exit 1
fi
echo -e "${GREEN}User '${USERNAME}' created${NC}"

# Step 3: Grant privileges based on role
case "$ROLE" in
    readonly)
        run_psql "$DATABASE" "GRANT CONNECT ON DATABASE ${DATABASE} TO ${USERNAME};"
        run_psql "$DATABASE" "GRANT USAGE ON SCHEMA public TO ${USERNAME};"
        run_psql "$DATABASE" "GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${USERNAME};"
        run_psql "$DATABASE" "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${USERNAME};"
        echo -e "${GREEN}Granted read-only access${NC}"
        ;;
    readwrite)
        run_psql "$DATABASE" "GRANT CONNECT ON DATABASE ${DATABASE} TO ${USERNAME};"
        run_psql "$DATABASE" "GRANT USAGE, CREATE ON SCHEMA public TO ${USERNAME};"
        run_psql "$DATABASE" "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${USERNAME};"
        run_psql "$DATABASE" "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${USERNAME};"
        run_psql "$DATABASE" "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${USERNAME};"
        run_psql "$DATABASE" "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${USERNAME};"
        echo -e "${GREEN}Granted read-write access${NC}"
        ;;
    admin)
        run_psql "$DATABASE" "GRANT ALL PRIVILEGES ON DATABASE ${DATABASE} TO ${USERNAME};"
        run_psql "$DATABASE" "GRANT ALL PRIVILEGES ON SCHEMA public TO ${USERNAME};"
        run_psql "$DATABASE" "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${USERNAME};"
        run_psql "$DATABASE" "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${USERNAME};"
        run_psql "$DATABASE" "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO ${USERNAME};"
        run_psql "$DATABASE" "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO ${USERNAME};"
        echo -e "${GREEN}Granted admin access${NC}"
        ;;
    owner)
        run_psql "postgres" "ALTER DATABASE ${DATABASE} OWNER TO ${USERNAME};"
        echo -e "${GREEN}Granted database ownership${NC}"
        ;;
esac

echo ""
echo "User details:"
echo "  Database: ${DATABASE}"
echo "  Username: ${USERNAME}"
echo "  Role:     ${ROLE}"
echo ""
echo "Connection string:"
echo -e "  ${GREEN}postgresql://${USERNAME}:${PASSWORD}@pg-primary:5432/${DATABASE}${NC}"
echo ""
echo "With all hosts (automatic failover):"
echo -e "  ${GREEN}postgresql://${USERNAME}:${PASSWORD}@pg-primary:5432,pg-standby1:5432,pg-standby2:5432/${DATABASE}?target_session_attrs=read-write${NC}"
echo ""
echo "Read-only connection (uses standbys):"
echo -e "  ${GREEN}postgresql://${USERNAME}:${PASSWORD}@pg-standby1:5432,pg-standby2:5432/${DATABASE}?target_session_attrs=any${NC}"
echo ""
