# PostgreSqlCluster

A PostgreSQL Streaming Replication Cluster for Docker Swarm. This document explains how to **connect your services** to the cluster.

> For deployment and management instructions, see [MANAGE.md](MANAGE.md).

## Naming Conventions

### Database Names

Use the format: `<project>_<environment>`

| Environment | Example |
|-------------|---------|
| Development | `myapp_dev` |
| Staging | `myapp_staging` |
| Production | `myapp_prod` |
| Testing | `myapp_test` |

**Rules:**
- Use lowercase letters, numbers, and underscores only
- Start with the project name
- End with the environment suffix
- Maximum 63 characters

### Table Names

Use the format: `<entity>` (singular or plural, be consistent)

| Good | Bad |
|------|-----|
| `users` | `Users` |
| `order_items` | `OrderItems` |
| `audit_logs` | `audit-logs` |

**Rules:**
- Use lowercase with underscores (snake_case)
- No hyphens, spaces, or special characters
- Be consistent: either all singular or all plural
- Prefix with module name for large projects: `auth_users`, `billing_invoices`

### User Names

Use the format: `<project>_<environment>_<role>`

| Example | Description |
|---------|-------------|
| `myapp_prod_app` | Production application user |
| `myapp_dev_app` | Development application user |
| `myapp_prod_readonly` | Read-only user for reporting |

### Examples

```bash
# Create users for different environments
./devops/create-app-user.sh myapp_dev devuser devpass123
./devops/create-app-user.sh myapp_staging staginguser stagingpass123
./devops/create-app-user.sh myapp_prod produser prodpass123!

# Create a read-only user for analytics
./devops/create-app-user.sh myapp_prod analytics_reader readpass readonly
```

## Quick Start

### 1. Add the Network

Your service must join the `pgcluster_internal` overlay network:

```yaml
services:
  your-service:
    image: your-image
    networks:
      - pgcluster_internal

networks:
  pgcluster_internal:
    external: true
```

### 2. Use the Connection String

Ask the cluster admin to create a user for your project:

```bash
# Admin runs this command
./devops/create-app-user.sh myapp appuser secretpass
```

Then use the credentials in your service:

```yaml
environment:
  - DATABASE_URL=postgresql://appuser:secretpass@pg-primary:5432/myapp
```

## TimescaleDB

The cluster now ships with TimescaleDB enabled.

- PostgreSQL services use a TimescaleDB-capable image (`PG_IMAGE`, default: `timescale/timescaledb:2.25.2-pg18`)
- `shared_preload_libraries=timescaledb` is enabled on the primary and both standbys
- the `pg-init` service creates `timescaledb` automatically on `PG_DEFAULT_DB`
- databases created with `./devops/create-app-user.sh` enable the extension automatically

For a database created before this change, run once on the primary:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
```

You can verify the extension with:

```bash
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';"
```

## Connection Options

| Option | Description | Example |
|--------|-------------|---------|
| `target_session_attrs` | Route to read-write or any node | `target_session_attrs=read-write` |
| `sslmode` | SSL connection mode | `sslmode=prefer` |
| `connect_timeout` | Connection timeout in seconds | `connect_timeout=10` |
| `application_name` | Identify the application | `application_name=myapp` |

### Production-Ready Connection String

```
postgresql://user:pass@pg-primary:5432,pg-standby1:5432,pg-standby2:5432/mydb?target_session_attrs=read-write&connect_timeout=10&application_name=myapp
```

### Read-Only Connection (uses standbys)

```
postgresql://user:pass@pg-standby1:5432,pg-standby2:5432/mydb?target_session_attrs=any
```

## Service Hostnames

| Hostname | Role | Description |
|----------|------|-------------|
| `pg-primary` | Primary | Read/write operations |
| `pg-standby1` | Standby | Read replica (hot standby) |
| `pg-standby2` | Standby | Read replica (hot standby) |

## Session Attributes

| Value | Description |
|-------|-------------|
| `read-write` | Connect only to a primary (read/write) node |
| `read-only` | Connect only to a standby (read-only) node |
| `any` | Connect to any available node |
| `prefer-standby` | Prefer standby, fallback to primary |

## Testing Connection

Test from any container on the network:

```bash
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  pg_isready -h pg-primary -p 5432 -U postgres
```

```bash
docker run --rm --network pgcluster_internal timescale/timescaledb:2.25.2-pg18 \
  psql -h pg-primary -U postgres -d postgres -c "SELECT version();"
```

## Ports

PostgreSQL uses port `5432` internally. No ports are exposed externally - all connections go through the Docker overlay network.