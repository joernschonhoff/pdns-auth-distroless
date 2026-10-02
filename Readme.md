# pdns-auth-distroless

A distroless container image for the PowerDNS Authoritative server.

## Purpose & Warning

This image is a learning project. Do not run it unattended in production environments — it lacks typical hardening, monitoring, and operational features.

This project is **not affiliated with, endorsed by, or associated with PowerDNS.com B.V.** in any form. "PowerDNS" is a trademark of PowerDNS.com B.V.; this image simply compiles and packages the official, publicly available PowerDNS Authoritative Server source releases.

## Contents

- Minimal Docker build for PowerDNS Authoritative
    - `pdns_server` is compiled with `bind`, `gmysql`, `gpgsql` and `gsqlite3` backends
    - PowerDNS tarballs are verified against official PGP signatures before building
- Example configuration and Docker Compose samples in the parent repository
- `Debug.Dockerfile` variant available (Debian 13-slim with a shell) for interactive troubleshooting

## Quickstart

### Build

The project ships a `Makefile` that wraps the `docker buildx` invocations (reads the version from `VERSION`, sets labels, tags, etc.):

```bash
# Show all available targets
make help

# Build production image
make build-prod

# Build debug image
make build-debug

# Build both
make build
```

### Running

`make build-prod` tags the image as `registry.gitlab.com/joern_schonhoff/pdns-auth-distroless:<version>` (override with `CI_REGISTRY_IMAGE=<name> make build-prod` for a local-only tag).

```bash
docker run --rm -v /path/to/pdns.conf:/etc/pdns/pdns.conf:ro registry.gitlab.com/joern_schonhoff/pdns-auth-distroless:$(cat VERSION)
```

Note: Runtime configuration (volumes, environment variables, networks) depends on your setup. Use the repository's `docker-compose.yml` examples as a starting point.

## Examples

The `examples/` directory contains complete Docker Compose setups for different backends:

- **SQLite**: `examples/sqlite/` - Lightweight, file-based backend
- **MySQL**: `examples/mysql/` - MariaDB backend
- **PostgreSQL**: `examples/pgsql/` - PostgreSQL backend

To use an example:

1. Copy the `.env.example` to `.env` in the example directory:
   ```bash
   cd examples/sqlite  # or mysql, or pgsql
   cp .env.example .env
   ```

2. Edit `.env` to customize settings (API keys, passwords, etc.)

3. Start the stack:
   ```bash
   docker compose up
   ```

## Configuration

PowerDNS typically reads its configuration from `/etc/pdns/pdns.conf`. Adjust the configuration for your database/backend (MySQL, PostgreSQL, SQLite, etc.).

## Version Management

The PowerDNS version is stored in the `VERSION` file. When a new version is released:

1. Update the `VERSION` file with the new version number
2. Build and test the image: `make build && make verify`
3. Commit the change

**Automated Updates:** The project is configured for Renovate bot, which will:
- Monitor https://downloads.powerdns.com/releases/ for new PowerDNS releases
- Automatically create PRs when new stable versions (e.g., `pdns-5.0.2.tar.bz2`) are detected
- Extract the version number and update the `VERSION` file

## Health Checks

The production image includes an embedded DNS health check utility for reliable container monitoring.

**Docker Compose:**
```yaml
services:
  pdns-auth:
    # ... other config ...
    healthcheck:
      test: ["CMD", "/usr/bin/dns-healthcheck", "--check-udp", "--check-tcp"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s
```

**Kubernetes:**
```yaml
livenessProbe:
  tcpSocket:
    port: 53
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  tcpSocket:
    port: 53
  initialDelaySeconds: 5
  periodSeconds: 5
```

For the debug image (which uses full Debian), health checks must be implemented at the orchestration level:

**Docker Compose (Debug):**
```yaml
services:
  pdns-auth:
    # ... other config ...
    healthcheck:
      test: ["CMD", "true"]  # Minimal check - container is running
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 30s
```

## License

GPL-2.0 (GNU General Public License v2)

This project bundles PowerDNS, which is licensed under GPL-2.0. See the LICENSE file for the full text.