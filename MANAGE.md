# PostgreSqlCluster Management

This document covers the **deployment, architecture, and management** of the PostgreSQL streaming replication cluster.

> For connection instructions, see [README.md](README.md).

## Architecture

```
┌─────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   server-b  │    │    server-c     │    │    server-d     │
│   PRIMARY   │───►│    STANDBY 1    │    │    STANDBY 2    │
│ TimescaleDB │───►│   TimescaleDB   │    │   TimescaleDB   │
└─────────────┘    └─────────────────┘    └─────────────────┘
       │                                          ▲
       └──────────────────────────────────────────┘
              Streaming Replication (WAL)
           Network: pgcluster_internal
```

| Component | Node | Description |
|-----------|------|-------------|
| pg-primary | server-b | Primary node (read/write) |
| pg-standby1 | server-c | Hot standby replica (read-only) |
| pg-standby2 | server-d | Hot standby replica (read-only) |
| pg-init | server-a | Initialization container (runs once) |
| adminer | any manager | Web admin UI (Adminer) |

## Prerequisites

- Docker Swarm initialized with nodes: `server-a`, `server-b`, `server-c`, `server-d`
- `PG_IMAGE` image pulled on `server-b`, `server-c`, `server-d` (default: `timescale/timescaledb:2.25.2-pg18`)
- Overlay network connectivity between all nodes


## Environment Variables

Create a `.env` file in the `devops/` directory:

```bash
# PostgreSQL Admin User (superuser)
PG_ADMIN_USER=postgres
PG_ADMIN_PASSWORD=ChangeThisSecurePassword123!
PG_DEFAULT_DB=postgres

# PostgreSQL Replication User
PG_REPLICATION_USER=replicator
PG_REPLICATION_PASSWORD=ChangeThisReplicationPassword456!

# Docker Swarm stack settings
STACK_NAME=pgcluster

# PostgreSQL image with TimescaleDB support
PG_IMAGE=timescale/timescaledb:2.25.2-pg18
```

| Variable | Description | Default |
|----------|-------------|---------|
| `PG_ADMIN_USER` | Superuser username | `postgres` |
| `PG_ADMIN_PASSWORD` | Superuser password | `postgres123` |
| `PG_DEFAULT_DB` | Default database | `postgres` |
| `PG_REPLICATION_USER` | Replication user | `replicator` |
| `PG_REPLICATION_PASSWORD` | Replication password | `replicator123` |
| `STACK_NAME` | Docker stack name used by helper scripts | `pgcluster` |
| `PG_IMAGE` | PostgreSQL image with TimescaleDB support | `timescale/timescaledb:2.25.2-pg18` |

## Deployment

### Phase 1: Initial Deployment

The first deployment starts the cluster. The primary initializes with replication support, and standbys perform `pg_basebackup` automatically.

```bash
# Deploy the stack
docker stack deploy -c devops/docker-compose.swarm.yml pgcluster

# Watch the initialization
docker service logs -f pgcluster_pg-init
# Wait until you see "PostgreSQL cluster is ready!"
# Then press Ctrl+C
```

### Phase 2: Verify Replication

The second deployment (or re-run) checks that replication is active.

```bash
# Run deployment again (pre.sh will report status)
docker stack deploy -c devops/docker-compose.swarm.yml pgcluster
```

The `pre.sh` script will output the connection string with credentials.

### Verify Deployment

```bash
# Check all services are running
docker stack services pgcluster

# Expected output:
# NAME                     REPLICAS   IMAGE
# pgcluster_pg-primary     1/1        timescale/timescaledb:2.25.2-pg18
# pgcluster_pg-standby1    1/1        timescale/timescaledb:2.25.2-pg18
# pgcluster_pg-standby2    1/1        timescale/timescaledb:2.25.2-pg18
# pgcluster_pg-init        1/1        timescale/timescaledb:2.25.2-pg18
# pgcluster_adminer        1/1        adminer:latest

# Check replication status
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c \
  "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
```

## Authentication

### How It Works

1. PostgreSQL uses **scram-sha-256** for password authentication
2. The replication user authenticates via `pg_hba.conf` rules
3. User credentials are stored in the `pg_catalog.pg_authid` system catalog

### Superuser

The superuser is created automatically on first deployment:

| User | Database | Role | Source |
|------|----------|------|--------|
| `postgres` (default) | all | superuser | `PG_ADMIN_USER` / `PG_ADMIN_PASSWORD` from `.env` |

### Replication User

The replication user is created by the init script:

| User | Purpose | Source |
|------|---------|--------|
| `replicator` (default) | Streaming replication | `PG_REPLICATION_USER` / `PG_REPLICATION_PASSWORD` from `.env` |

### Create Application Users

Use the dedicated script to create users for each project:

```bash
./devops/create-app-user.sh <database> <username> <password> [role]
```

**Examples:**

```bash
# Create a read/write user for "myapp" database
./devops/create-app-user.sh myapp appuser secretpassword

# Create a read-only user for analytics
./devops/create-app-user.sh analytics reader readpass readonly

# Create a database admin
./devops/create-app-user.sh myapp dbadmin adminpass admin
```

**Available roles:**

| Role | Description |
|------|-------------|
| `readonly` | SELECT only |
| `readwrite` | SELECT, INSERT, UPDATE, DELETE (default) |
| `admin` | ALL PRIVILEGES on the database |
| `owner` | Database owner |

The script outputs the connection string for the created user.

### Manual User Creation

Alternatively, connect to PostgreSQL directly:

```bash
docker run --rm -it --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres
```

```sql
CREATE DATABASE myproject;
CREATE ROLE projectuser WITH LOGIN PASSWORD 'projectpassword';
GRANT CONNECT ON DATABASE myproject TO projectuser;
GRANT USAGE, CREATE ON SCHEMA public TO projectuser;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO projectuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO projectuser;
```

## Adminer (Admin UI)

A lightweight web-based PostgreSQL admin interface is included.

| Setting | Value |
|---------|-------|
| URL | https://adminer.methodinfo.fr |
| Access | Local IPs only (192.168.x.x, 10.x.x.x, 172.16-31.x.x) |

### Connexion

Adminer n'a pas de pré-configuration. À l'ouverture, remplissez :

1. **System**: PostgreSQL
2. **Server**: `pg-primary`
3. **Username**: valeur de `PG_ADMIN_USER`
4. **Password**: valeur de `PG_ADMIN_PASSWORD`
5. **Database**: (optionnel) nom de la base ou laisser vide pour voir toutes les bases

### Sécurité

L'interface est protégée par :
1. Authentification PostgreSQL (pas de compte Adminer séparé)
2. Whitelist IP (réseaux locaux uniquement)
3. HTTPS via Traefik

## Data Persistence

Data is stored in Docker volumes on each node:

| Volume | Node | Container Path |
|--------|------|----------------|
| `pgcluster_pg_primary_data` | server-b | /var/lib/postgresql |
| `pgcluster_pg_standby1_data` | server-c | /var/lib/postgresql |
| `pgcluster_pg_standby2_data` | server-d | /var/lib/postgresql |

### Backup

```bash
# Backup from primary (all databases)
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  pg_dumpall -h pg-primary -U postgres | gzip > backup-$(date +%Y%m%d).sql.gz

# Backup a specific database
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  pg_dump -h pg-primary -U postgres -Fc myapp > myapp-$(date +%Y%m%d).dump
```

### Restore

```bash
# Restore all databases
gunzip -c backup-20240120.sql.gz | \
  docker run --rm -i --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres

# Restore a specific database
docker run --rm -i --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  pg_restore -h pg-primary -U postgres -d myapp < myapp-20240120.dump
```

## Troubleshooting

### Service Won't Start

```bash
# Check detailed status
docker service ps pgcluster_pg-primary --no-trunc

# Common issues:
# - "no suitable node" -> Node constraint not met
# - "image not found" -> Pull image on target node
# - "read-only file system" -> Disk issue on node
```

### Image Not Found on Node

```bash
# SSH to the node and pull
docker pull timescale/timescaledb:2.25.2-pg18
```

### Standby Not Replicating

```bash
# Check standby logs
docker service logs pgcluster_pg-standby1

# Check replication status from primary
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c \
  "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"

# Check standby status
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-standby1 -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
```

### Authentication Errors

```bash
# Test connection without password (should fail if auth is properly configured)
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c "SELECT 1;"

# Test with password
docker run --rm --network pgcluster_internal -e PGPASSWORD=yourpassword timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c "SELECT 1;"
```

### Network Issues

```bash
# Test connectivity from a container
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  pg_isready -h pg-primary -p 5432

# Check overlay network
docker network inspect pgcluster_internal
```

### Check Cluster Health

```bash
# Replication status
docker run --rm --network pgcluster_internal -e PGPASSWORD=yourpassword timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c \
  "SELECT client_addr, state, sent_lsn, replay_lsn,
   pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replication_lag_bytes
   FROM pg_stat_replication;"

# Check if a node is primary or standby
docker run --rm --network pgcluster_internal -e PGPASSWORD=yourpassword timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c "SELECT pg_is_in_recovery();"
# Returns 'f' for primary, 't' for standby
```

## Scaling and Maintenance

### Remove the Stack

```bash
docker stack rm pgcluster

# Wait for removal
sleep 15

# Verify
docker stack ps pgcluster
```

### Update PostgreSQL Version

1. Update `PG_IMAGE` in your `.env` file or the image tag in `docker-compose.swarm.yml`
2. Pull the new image on all nodes
3. Redeploy the stack

```bash
# On each node
docker pull timescale/timescaledb:2.25.2-pg18

# Redeploy
docker stack deploy -c devops/docker-compose.swarm.yml pgcluster
```

> **Warning:** Major version upgrades (e.g., 17 to 18) may require `pg_upgrade`. Test in a staging environment first.

### Force Restart a Service

```bash
docker service update --force pgcluster_pg-primary
```

### Recreate a Standby

If a standby is corrupted or out of sync:

```bash
# Remove the standby's data volume
docker service scale pgcluster_pg-standby1=0
sleep 10
docker volume rm pgcluster_pg_standby1_data
docker service scale pgcluster_pg-standby1=1
# The standby will automatically perform a fresh pg_basebackup
```

## TimescaleDB

The cluster now starts PostgreSQL with `shared_preload_libraries=timescaledb` on the primary and both standbys.

How the extension is enabled:

1. `pg-init` runs `CREATE EXTENSION IF NOT EXISTS timescaledb;` on `PG_DEFAULT_DB`
2. databases created through `./devops/create-app-user.sh` enable TimescaleDB automatically
3. existing databases created before this change must be updated once manually:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
```

To verify the extension on the primary:

```bash
docker run --rm --network pgcluster_internal -e PGPASSWORD=yourpassword timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';"
```

## Replication Configuration

The primary is configured with these replication parameters:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `wal_level` | `replica` | Enable WAL for streaming replication |
| `max_wal_senders` | `10` | Maximum concurrent replication connections |
| `max_replication_slots` | `10` | Maximum replication slots |
| `hot_standby` | `on` | Allow read queries on standbys |
| `wal_keep_size` | `1GB` | WAL segments to retain for standbys |

## Network Ports

| Port | Protocol | Purpose |
|------|----------|---------------|
| 5432 | TCP | PostgreSQL (internal only) |
| 8080 | TCP | Adminer (via Traefik) |

No ports are exposed externally. All PostgreSQL access is through the overlay network.
