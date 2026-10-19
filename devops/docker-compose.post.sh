#!/bin/bash
#
# Post-deployment checks: the primary runs where PG_PRIMARY_NODE says and
# accepts writes, and every standby streams from it. After a switchover the
# standby moved to a new node needs a full pg_basebackup first, hence the wait.

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

PG_ADMIN_USER="${PG_ADMIN_USER:-postgres}"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-postgres123}"
PG_IMAGE="${PG_IMAGE:-timescale/timescaledb:2.25.2-pg18}"
STACK_NAME="${DEPLOY_STACK_NAME:-${STACK_NAME:-postgresqlcluster}}"
PG_NETWORK_NAME="${PG_NETWORK_NAME:-${STACK_NAME}_internal}"
# Target placement (defaults must match docker-compose.swarm.yml)
PG_PRIMARY_NODE="${PG_PRIMARY_NODE:-server-d}"
PG_STANDBY1_NODE="${PG_STANDBY1_NODE:-server-c}"
PG_STANDBY2_NODE="${PG_STANDBY2_NODE:-server-b}"
# Seconds to wait for the cluster to reach the expected topology
PG_POST_CHECK_TIMEOUT="${PG_POST_CHECK_TIMEOUT:-600}"

exec_psql_on() {
    PGPASSWORD="$PG_ADMIN_PASSWORD" docker run --rm --network "$PG_NETWORK_NAME" -e PGPASSWORD "$PG_IMAGE" \
        psql -v ON_ERROR_STOP=1 -h "$1" -U "$PG_ADMIN_USER" -d postgres -t -A -c "$2" 2>/dev/null
}

running_node() {
    docker service ps "${STACK_NAME}_$1" --filter "desired-state=running" \
        --format '{{.Node}}|{{.CurrentState}}' 2>/dev/null | awk -F'|' '$2 ~ /^Running/ {print $1; exit}'
}

# Prints the problems still preventing the expected topology (empty = all good)
check_topology() {
    local svc node expected
    for svc in pg-primary pg-standby1 pg-standby2; do
        case "$svc" in
            pg-primary) expected="$PG_PRIMARY_NODE" ;;
            pg-standby1) expected="$PG_STANDBY1_NODE" ;;
            pg-standby2) expected="$PG_STANDBY2_NODE" ;;
        esac
        node=$(running_node "$svc")
        if [ "$node" != "$expected" ]; then
            echo "${svc}: running on '${node:-nowhere}', expected ${expected}"
        fi
    done

    if [ "$(exec_psql_on pg-primary "SELECT pg_is_in_recovery();")" != "f" ]; then
        echo "pg-primary: not reachable or still in recovery"
    fi
    for svc in pg-standby1 pg-standby2; do
        if [ "$(exec_psql_on "$svc" "SELECT status FROM pg_stat_wal_receiver;")" != "streaming" ]; then
            echo "${svc}: not streaming from pg-primary yet"
        fi
    done
}

echo -e "${BLUE}Checking PostgreSQL topology (primary on ${PG_PRIMARY_NODE})...${NC}"

problems=""
deadline=$(( $(date +%s) + PG_POST_CHECK_TIMEOUT ))
while :; do
    problems=$(check_topology)
    [ -z "$problems" ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then
        break
    fi
    echo "$problems" | sed 's/^/  waiting: /'
    sleep 15
done

echo ""
echo "Replication status (from pg-primary):"
PGPASSWORD="$PG_ADMIN_PASSWORD" docker run --rm --network "$PG_NETWORK_NAME" -e PGPASSWORD "$PG_IMAGE" \
    psql -h pg-primary -U "$PG_ADMIN_USER" -d postgres -c \
    "SELECT application_name, client_addr, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;" \
    2>/dev/null
echo "Timeline: $(exec_psql_on pg-primary "SELECT timeline_id FROM pg_control_checkpoint();")"

if [ -n "$problems" ]; then
    echo -e "${RED}Cluster did not reach the expected topology within ${PG_POST_CHECK_TIMEOUT}s:${NC}"
    echo "$problems" | sed 's/^/  - /'
    echo "Check: docker service logs ${STACK_NAME}_<service>"
    exit 1
fi

echo -e "${GREEN}PostgreSQL cluster OK: primary on ${PG_PRIMARY_NODE}, standbys on ${PG_STANDBY1_NODE} and ${PG_STANDBY2_NODE} streaming${NC}"
