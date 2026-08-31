# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

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

[Unreleased]: https://github.com/heyvaldemar/zabbix-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/zabbix-docker-compose/releases/tag/v1.0.0
