# PostgreSqlCluster Management

This document covers the **deployment, architecture, and management** of the PostgreSQL streaming replication cluster.

> For connection instructions, see [README.md](README.md).

## Architecture

```
┌─────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   server-d  │    │    server-c     │    │    server-b     │
│   PRIMARY   │───►│    STANDBY 1    │    │    STANDBY 2    │
│ TimescaleDB │───►│   TimescaleDB   │    │   TimescaleDB   │
└─────────────┘    └─────────────────┘    └─────────────────┘
       │                                          ▲
       └──────────────────────────────────────────┘
              Streaming Replication (WAL)
           Network: postgresqlcluster_internal
```

| Component | Node | Description |
|-----------|------|-------------|
| pg-primary | server-d (`PG_PRIMARY_NODE`) | Primary node (read/write) |
| pg-standby1 | server-c (`PG_STANDBY1_NODE`) | Hot standby replica (read-only) |
| pg-standby2 | server-b (`PG_STANDBY2_NODE`) | Hot standby replica (read-only) |
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
STACK_NAME=postgresqlcluster

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
| `STACK_NAME` | Docker stack name used by helper scripts | `postgresqlcluster` |
| `PG_PRIMARY_NODE` | Node of `pg-primary` (see [Switchover](#switchover)) | `server-d` |
| `PG_STANDBY1_NODE` | Node of `pg-standby1` | `server-c` |
| `PG_STANDBY2_NODE` | Node of `pg-standby2` | `server-b` |
| `PG_IMAGE` | PostgreSQL image with TimescaleDB support | `timescale/timescaledb:2.25.2-pg18` |

## Deployment

### Phase 1: Initial Deployment

The first deployment starts the cluster. The primary initializes with replication support, and standbys perform `pg_basebackup` automatically.

```bash
# Deploy the stack
docker stack deploy -c devops/docker-compose.swarm.yml postgresqlcluster

# Watch the initialization
docker service logs -f postgresqlcluster_pg-init
# Wait until you see "PostgreSQL cluster is ready!"
# Then press Ctrl+C
```

### Phase 2: Verify Replication

The second deployment (or re-run) checks that replication is active.

```bash
# Run deployment again (pre.sh will report status)
docker stack deploy -c devops/docker-compose.swarm.yml postgresqlcluster
```

The `pre.sh` script will output the connection string (the password is masked: it comes from `PG_ADMIN_PASSWORD` in `devops/.env`).

### Verify Deployment

```bash
# Check all services are running
docker stack services postgresqlcluster

# Expected output:
# NAME                     REPLICAS   IMAGE
# postgresqlcluster_pg-primary     1/1        timescale/timescaledb:2.25.2-pg18
# postgresqlcluster_pg-standby1    1/1        timescale/timescaledb:2.25.2-pg18
# postgresqlcluster_pg-standby2    1/1        timescale/timescaledb:2.25.2-pg18
# postgresqlcluster_pg-init        1/1        timescale/timescaledb:2.25.2-pg18
# postgresqlcluster_adminer        1/1        adminer:latest

# Check replication status
docker run --rm --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
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
docker run --rm -it --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
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
| `postgresqlcluster_pg_primary_data` | server-d | /var/lib/postgresql |
| `postgresqlcluster_pg_standby1_data` | server-c | /var/lib/postgresql |
| `postgresqlcluster_pg_standby2_data` | server-b | /var/lib/postgresql |

Volumes are local to their node: a volume of the same name on another node is a different (stale or empty) volume.

### Backup

```bash
# Backup from primary (all databases)
docker run --rm --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
  pg_dumpall -h pg-primary -U postgres | gzip > backup-$(date +%Y%m%d).sql.gz

# Backup a specific database
docker run --rm --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
  pg_dump -h pg-primary -U postgres -Fc myapp > myapp-$(date +%Y%m%d).dump
```

### Restore

```bash
# Restore all databases
gunzip -c backup-20240120.sql.gz | \
  docker run --rm -i --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres

# Restore a specific database
docker run --rm -i --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
  pg_restore -h pg-primary -U postgres -d myapp < myapp-20240120.dump
```

## Troubleshooting

### Service Won't Start

```bash
# Check detailed status
docker service ps postgresqlcluster_pg-primary --no-trunc

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
docker service logs postgresqlcluster_pg-standby1

# Check replication status from primary
docker run --rm --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c \
  "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"

# Check standby status
docker run --rm --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-standby1 -U postgres -d postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
```

### Authentication Errors

```bash
# Test connection without password (should fail if auth is properly configured)
docker run --rm --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c "SELECT 1;"

# Test with password
docker run --rm --network postgresqlcluster_internal -e PGPASSWORD=yourpassword timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c "SELECT 1;"
```

### Network Issues

```bash
# Test connectivity from a container
docker run --rm --network postgresqlcluster_internal timescale/timescaledb:2.25.2-pg18 \
  pg_isready -h pg-primary -p 5432

# Check overlay network
docker network inspect postgresqlcluster_internal
```

### Check Cluster Health

```bash
# Replication status
docker run --rm --network postgresqlcluster_internal -e PGPASSWORD=yourpassword timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c \
  "SELECT client_addr, state, sent_lsn, replay_lsn,
   pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replication_lag_bytes
   FROM pg_stat_replication;"

# Check if a node is primary or standby
docker run --rm --network postgresqlcluster_internal -e PGPASSWORD=yourpassword timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c "SELECT pg_is_in_recovery();"
# Returns 'f' for primary, 't' for standby
```

## Scaling and Maintenance

### Remove the Stack

```bash
docker stack rm postgresqlcluster

# Wait for removal
sleep 15

# Verify
docker stack ps postgresqlcluster
```

### Update PostgreSQL Version

1. Update `PG_IMAGE` in your `.env` file or the image tag in `docker-compose.swarm.yml`
2. Pull the new image on all nodes
3. Redeploy the stack

```bash
# On each node
docker pull timescale/timescaledb:2.25.2-pg18

# Redeploy
docker stack deploy -c devops/docker-compose.swarm.yml postgresqlcluster
```

> **Warning:** Major version upgrades (e.g., 17 to 18) may require `pg_upgrade`. Test in a staging environment first.

### Force Restart a Service

```bash
docker service update --force postgresqlcluster_pg-primary
```

### Switchover

The primary role moves to another node through a regular deployment: set `PG_PRIMARY_NODE` to the node of one of the standbys (and give the old primary node to that standby), then deploy with PulsarCD. **Never do it with a manual `docker stack deploy`**: the primary would start on the empty volume of its new node.

`docker-compose.pre.sh` detects that `PG_PRIMARY_NODE` differs from the deployed placement and, before the stack is deployed:

1. checks that the primary is up and that the standby on the target node is streaming;
2. runs `CHECKPOINT`, then stops `pg-primary` (clean shutdown: the shutdown checkpoint is streamed to the standbys) and reads its `pg_control` to get the checkpoint location;
3. waits for the standby to replay past that checkpoint (`PG_SWITCHOVER_CATCHUP_TIMEOUT`, 120 s);
4. promotes it (`pg_promote()`), then stops it;
5. copies its data into `pg_primary_data` on the target node, removing `standby.signal` and `primary_conninfo`;
6. fences the retired volumes (old primary, promoted standby): `PG_VERSION` is renamed `PG_VERSION.fenced` and a `SWITCHOVER_FENCED` file explains why, so neither the current compose nor a rollback to a previous version can start PostgreSQL on stale data;
7. empties the volume of the standby moving to the old primary node, which then performs a fresh `pg_basebackup`.

Node-local work runs as one-shot swarm jobs (`pgswitch-*`, `--mode replicated-job`) pinned to the node. Until step 4, any failure restarts the old primary and aborts the deployment; after it, the script stops with the location of the current data. `docker-compose.post.sh` then waits (`PG_POST_CHECK_TIMEOUT`, 600 s) for the primary to accept writes on its node and for both standbys to stream from it. The other standby follows the new timeline on its own.

Applications are disconnected from the stop of the old primary until the new one starts (a few minutes, mostly the copy of the data). Once the cluster is validated, remove the retired volumes printed by `pre.sh`:

```bash
# on the old primary node
docker volume rm postgresqlcluster_pg_primary_data
# on the new primary node (the standby volume that was promoted)
docker volume rm postgresqlcluster_pg_standby2_data
```

### Recreate a Standby

If a standby is corrupted or out of sync:

```bash
# Remove the standby's data volume
docker service scale postgresqlcluster_pg-standby1=0
sleep 10
docker volume rm postgresqlcluster_pg_standby1_data
docker service scale postgresqlcluster_pg-standby1=1
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
docker run --rm --network postgresqlcluster_internal -e PGPASSWORD=yourpassword timescale/timescaledb:2.25.2-pg18 \
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
