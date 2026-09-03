# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.4.0] - 2026-09-02

### Security

- **Container hardening.** Every service runs with
  `security_opt: no-new-privileges:true` (no privilege escalation via
  setuid binaries even if a process escapes its initial capability
  set). Infrastructure containers (the reverse proxy, databases,
  caches, backups) drop every Linux capability and add back only what
  their entrypoints need (bind :80/:443, chown a data directory, drop to
  the service user). Application containers keep the default capability
  set: upstream images assume it, and a wrong guess there is a boot loop
  in production, not a hardening win. CI boots the stack under these
  settings on every push.

## [1.3.0] - 2026-09-02

### Added

- **Resource limits on every service, as `.env`-overridable defaults.**
  Each service now carries memory and CPU limits plus reservations
  (`<SERVICE>_MEMORY_LIMIT`, `_CPU_LIMIT`, `_MEMORY_RESERVATION`,
  `_CPU_RESERVATION`, defaults listed in `.env.example`). Set any of
  them in `.env` and the override survives every `git pull`. The
  defaults are what CI boots the stack under, so they are known to be
  enough for a fresh install; raise a limit if a service is OOM-killed
  under your real load (`docker inspect` shows `OOMKilled=true`).

## [1.2.0] - 2026-09-02

### Added

- **`tests/e2e-backup-restore.sh`** — seven end-to-end scenarios against
  the live stack, run by CI on every push and by you locally: the
  required-variable guard fires, a backup is produced, it is a readable
  archive with real dump content (and a readable data `tar.gz` where the
  stack has one), a database outage is reported as `FAILED`, **restore
  genuinely replaces database state** (a marker row inserted after the
  baseline backup is gone after restoring it), and pruning removes only
  old files.

## [1.1.0] - 2026-09-02

### Fixed

- **A failed database dump no longer produces a silent, corrupt backup.**
  The old loop piped the dump into `gzip` and only checked `gzip`'s exit
  status, so a dump that failed halfway (database down, wrong password,
  disk full) still left a small `.gz` that looked like a backup. The loop
  now runs with `pipefail`, logs `Database backup OK: <file> (<bytes>
  bytes)` or `Database backup FAILED` per cycle, keeps a failed dump as
  `<file>.failed` for diagnosis, and prunes only its own files. Retention
  set to `0` disables pruning instead of deleting everything.

### Added

- CI now waits for the first backup cycle and proves the produced
  archive is readable and contains a real dump header (plus a readable
  `tar.gz` for the data backup where the stack has one).

## [1.0.0] - 2026-08-31

First semver release. Brings this template to the fleet standard (see
[zabbix-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/zabbix-traefik-letsencrypt-docker-compose)
for the TLS-fronted variant).

### Security

- **Zabbix bumped 6.4.6 → 7.0.30 LTS** (6.4 has been end-of-life since
  2024-12-31; 7.0 is supported until 2029). Server, web, and agent2 move
  together; the server migrates the database schema on first start —
  back up before pulling.
- **All four images pinned by `tag@sha256:digest`.**
- **Credentials untracked from git** — rotate `ZABBIX_DB_PASSWORD` if
  your deployment reused the previously tracked value.

### Changed

- **Image pins live in the compose file as interpolation defaults**
  (`x-images` block); the minimal `.env` is one password. Backup loop
  `$$`-escaped.

### Added

- **Deployment Verification workflow**: shellcheck + actionlint; Trivy
  scans of all four images; weekly `check-pin-freshness` (digest drift +
  LTS-line currency via endoflife.date); deploy-and-test that requires
  the server healthcheck and a working web API (`apiinfo.version`).

### Fixed

- Shellcheck findings in the restore script.

[Unreleased]: https://github.com/heyvaldemar/zabbix-docker-compose/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/heyvaldemar/zabbix-docker-compose/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/zabbix-docker-compose/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/zabbix-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/zabbix-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/zabbix-docker-compose/releases/tag/v1.0.0
