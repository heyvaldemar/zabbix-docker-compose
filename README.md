# Zabbix on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/zabbix-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/zabbix-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This repository deploys a full Zabbix 7.0 LTS monitoring stack (server, nginx web frontend, agent2, PostgreSQL, and a scheduled backup container) with the web UI published directly on port 80. It is the no-reverse-proxy sibling of [zabbix-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/zabbix-traefik-letsencrypt-docker-compose); use that variant when you want automatic HTTPS with Let's Encrypt.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-zabbix-using-docker-compose/](https://www.heyvaldemar.com/install-zabbix-using-docker-compose/).

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/zabbix-docker-compose
cd zabbix-docker-compose

# 2. Create the Docker network the stack expects
docker network create zabbix-network

# 3. Copy the environment template and set the database password
cp .env.example .env
$EDITOR .env
# ^ Required: ZABBIX_DB_PASSWORD. Everything else has defaults.

# 4. Deploy
docker compose -f zabbix-docker-compose.yml -p zabbix up -d
```

The dashboard appears on `http://your-server/` within a couple of minutes (first boot creates the database schema). Default frontend credentials are Zabbix's stock `Admin` / `zabbix`: change them immediately. Agent traffic arrives on ports 10051 (server) as published by the compose file.

### What success looks like

```bash
docker compose -f zabbix-docker-compose.yml -p zabbix ps
curl -fsS -X POST "http://localhost/api_jsonrpc.php" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}'
# Expected: {"jsonrpc":"2.0","result":"7.0.30","id":1}
```

## Updating

`./update.sh` moves this checkout to the latest release tag — a combination this repository's CI has booted, upgraded from the previous release on the same volumes, and smoke-tested — and then runs `docker compose up -d`. It refuses to cross a major version unattended, refuses to run over local changes, and names any variable that became required since your version before anything has moved. `./update.sh --dry-run` says what would happen. Every release cut by fleet triage also carries what upstream changed, read from its release notes against this compose file.

## Supply chain trust

Four upstream images ([`zabbix/zabbix-server-pgsql`](https://hub.docker.com/r/zabbix/zabbix-server-pgsql), [`zabbix/zabbix-web-nginx-pgsql`](https://hub.docker.com/r/zabbix/zabbix-web-nginx-pgsql), [`zabbix/zabbix-agent2`](https://hub.docker.com/r/zabbix/zabbix-agent2), [`postgres`](https://hub.docker.com/_/postgres)), all pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block: `git pull` alone delivers the version combination this repository has tested; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

Two override levels exist per image. `<PREFIX>_IMAGE_VERSION` in `.env` swaps only the version of that image (Compose then pulls the tag, without a digest) and leaves every other pin as tested; `<PREFIX>_IMAGE_TAG` replaces the whole reference, digest included. The variable names are listed in `.env.example`. Nested defaults need Docker Compose v2.5 or newer (2022); v2.0 to v2.4 leave the inner `${...}` unexpanded and `docker compose up` fails with an invalid reference instead of deploying something unexpected.

The daily `check-pin-freshness` CI job re-resolves each pinned tag against its registry and compares the pinned Zabbix version against the latest patch of its LTS line via endoflife.date, failing loudly if the line itself goes end-of-life. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults: the same values CI boots the stack under. Override any of them in `.env` (the knobs and their defaults are listed in `.env.example`, e.g. `TRAEFIK_MEMORY_LIMIT=512m`) and the override survives every `git pull`. If a service is OOM-killed under real load, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so; raise its `_MEMORY_LIMIT` and recreate.

## Container hardening

Every service runs with `security_opt: no-new-privileges:true`, so a process cannot gain privileges through setuid binaries even if it escapes its initial capability set. Infrastructure containers (the reverse proxy, databases, caches, backups) run with `cap_drop: [ALL]` and add back only what their entrypoints need: `NET_BIND_SERVICE` for Traefik to bind :80/:443, `CHOWN`/`SETUID`/`SETGID` (and friends) for database images to own their data directory and drop to their service user. Application containers keep the default capability set on purpose: upstream images assume it, and a wrong guess there is a boot loop in production rather than a hardening win. CI boots the stack under exactly these settings on every push, so what ships is what was tested.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/zabbix-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck + actionlint, Trivy scans of all four pinned images, the weekly freshness check, and a deploy-and-test job that boots the full stack with ephemeral credentials, waits for the zabbix-server healthcheck, and requires the web API (`apiinfo.version`) to answer. The shipped configuration must produce a working Zabbix, not just started containers.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the HTTPS smoke. The scenario that matters most is the restore roundtrip: insert a marker row, restore the earliest backup, assert the marker is gone. A backup that cannot be restored fails the build. Run it yourself against a running deployment with short intervals in `.env` (`BACKUP_INIT_SLEEP=15s`, `BACKUP_INTERVAL=60s`):

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

It stops the database container briefly to prove failure detection: run it on a staging copy, not on production.

## Backups and restore

The `backups` container runs a `pg_dump | gzip` → prune → sleep loop (defaults: 30-minute warm-up, 24-hour interval, 7-day retention, tune via `.env`). Restore with the interactive script:

```bash
chmod +x zabbix-restore-database.sh
./zabbix-restore-database.sh
```

## Security notes

- Change the stock `Admin`/`zabbix` frontend login on first use.
- `.env` is gitignored; compose fails fast when `ZABBIX_DB_PASSWORD` is unset. Pre-rotation advisory: releases before v1.0.0 (2026-08-31) shipped a tracked `.env` with a generated-looking database password: rotate it if reused.
- The web UI is plain HTTP on port 80: front it with TLS (or use the [Traefik variant](https://github.com/heyvaldemar/zabbix-traefik-letsencrypt-docker-compose)) before exposing it beyond a trusted network.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
