#!/usr/bin/env bash
# The stack under podman-compose, from `up` to an answering web API.
#
#   tests/podman-up.sh                 podman runs the health checks itself
#                                      (a host with systemd)
#   tests/podman-up.sh --no-systemd    it runs none: first prove that, then
#                                      start podman-healthchecks.sh
#
# Run from anywhere as the user that owns the podman store, with .env in the
# repository root. It creates zabbix-network if missing, refuses to start where
# the project already has containers or volumes, and removes the ones it made
# when it ends. CI runs the second form on Alpine inside the runner, the host
# of issue #14. The first passes on Ubuntu 26.04 without AppArmor; with
# AppArmor, PostgreSQL never starts under no-new-privileges (README, Podman).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILE="zabbix-docker-compose.yml"
PROJECT="zabbix"
NETWORK="zabbix-network"
NO_SYSTEMD=false
case "${1:-}" in
  "") ;;
  --no-systemd) NO_SYSTEMD=true ;;
  *) echo "usage: $0 [--no-systemd]" >&2; exit 2 ;;
esac

[ -f .env ] || { echo "error: no .env in $REPO_ROOT" >&2; exit 1; }
for tool in podman podman-compose curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is not installed" >&2; exit 1; }
done
podman version --format 'podman {{.Client.Version}}'
podman-compose version 2>/dev/null | grep -i '^podman-compose' || true

# It ends with `down -v`. A project that already has containers or volumes is
# somebody's deployment, not a test: refuse before touching anything.
existing="$(podman ps -aq --filter "label=com.docker.compose.project=$PROJECT")$(podman volume ls -q --filter "label=com.docker.compose.project=$PROJECT")"
if [ -n "$existing" ]; then
  echo "error: the $PROJECT project already has containers or volumes here; this test ends with down -v and would delete them" >&2
  exit 1
fi

LOGS="$(mktemp -d)"
UP_PID=""
HC_PID=""

compose() { podman-compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

# name state status, one line per container of the project
states() {
  podman ps -a --filter "label=io.podman.compose.project=$PROJECT" --format '{{.Names}} {{.State}} {{.Status}}'
}

finish() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "--- containers"; states || true
    echo "--- health check log"
    for c in $(podman ps -aq --filter "label=io.podman.compose.project=$PROJECT" 2>/dev/null); do
      podman inspect --format '{{.Name}}{{range .State.Health.Log}}{{"\n  "}}{{.Start}} exit {{.ExitCode}}: {{.Output}}{{end}}' "$c" 2>/dev/null || true
    done
    echo "--- podman-compose up"; tail -n 60 "$LOGS/up.log" 2>/dev/null || true
    echo "--- podman-healthchecks.sh"; tail -n 20 "$LOGS/healthchecks.log" 2>/dev/null || true
    for c in $(podman ps -aq --filter "label=io.podman.compose.project=$PROJECT" 2>/dev/null); do
      echo "--- $(podman inspect --format '{{.Name}}: log driver {{.HostConfig.LogConfig.Type}}' "$c" 2>/dev/null)"
      podman top "$c" user pid args 2>&1 | head -n 8 || true
      podman logs --tail 20 "$c" 2>&1 || true
    done
    pg="$(podman ps -q --filter "label=io.podman.compose.project=$PROJECT" --filter label=com.docker.compose.service=postgres 2>/dev/null | head -n 1)"
    if [ -n "$pg" ]; then
      echo "--- the PostgreSQL check by hand, without -q"
      podman exec "$pg" sh -c 'pg_isready -d "$POSTGRES_DB" -U "$POSTGRES_USER"; echo "exit $?"' 2>&1 || true
      command -v journalctl >/dev/null && journalctl --no-pager -n 30 "CONTAINER_ID_FULL=$(podman inspect --format '{{.Id}}' "$pg")" 2>&1 | tail -n 30
    fi
  fi
  [ -n "$UP_PID" ] && kill "$UP_PID" 2>/dev/null
  [ -n "$HC_PID" ] && kill "$HC_PID" 2>/dev/null
  # podman-compose down -v leaves the anonymous volumes zabbix-server's image
  # declares (docker compose removes them): take those by name, nothing else.
  local anon="" c v
  for c in $(podman ps -aq --filter "label=io.podman.compose.project=$PROJECT" 2>/dev/null); do
    for v in $(podman inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$c" 2>/dev/null); do
      [[ "$v" =~ ^[0-9a-f]{64}$ ]] && anon="$anon $v"
    done
  done
  compose down -v >/dev/null 2>&1 || true
  for v in $anon; do podman volume rm "$v" >/dev/null 2>&1 || true; done
  rm -rf "$LOGS"
  exit "$rc"
}
trap finish EXIT

podman network exists "$NETWORK" || podman network create "$NETWORK" >/dev/null

# `up -d` runs in the background: on a host without systemd it is exactly the
# command that never returns, and the test has to look at it while it waits.
compose up -d >"$LOGS/up.log" 2>&1 &
UP_PID=$!

echo "waiting for PostgreSQL to start (the first run pulls the images)"
pg=""
for _ in $(seq 1 120); do
  pg="$(podman ps --quiet --filter "label=io.podman.compose.project=$PROJECT" \
    --filter label=com.docker.compose.service=postgres --filter status=running)"
  [ -n "$pg" ] && break
  kill -0 "$UP_PID" 2>/dev/null || { echo "error: podman-compose up ended before PostgreSQL started" >&2; exit 1; }
  sleep 5
done
[ -n "$pg" ] || { echo "error: PostgreSQL did not start within 10 minutes" >&2; exit 1; }

# The compose file checks PostgreSQL every 10 s. Each run podman makes leaves
# an entry in the health log, during the start period too.
sleep 45
runs="$(podman inspect --format '{{len .State.Health.Log}}' "$pg")"
if [ "$NO_SYSTEMD" = true ]; then
  if [ "$runs" -ne 0 ]; then
    echo "error: podman ran $runs health checks by itself; this host schedules them and is not the case under test" >&2
    exit 1
  fi
  if ! kill -0 "$UP_PID" 2>/dev/null; then
    echo "error: podman-compose up returned while no health check had run" >&2
    exit 1
  fi
  echo "ok: 45 s after PostgreSQL started podman has run none of its health checks and up is still waiting (issue #14)"
  states
  ./podman-healthchecks.sh >"$LOGS/healthchecks.log" 2>&1 &
  HC_PID=$!
  echo "started podman-healthchecks.sh"
else
  if [ "$runs" -lt 2 ]; then
    echo "error: podman ran $runs health checks of PostgreSQL in 45 s; with systemd it schedules one every 10 s" >&2
    exit 1
  fi
  echo "ok: podman ran $runs health checks of PostgreSQL by itself in 45 s"
fi

echo "waiting for podman-compose up to return"
for _ in $(seq 1 60); do
  kill -0 "$UP_PID" 2>/dev/null || break
  sleep 5
done
if kill -0 "$UP_PID" 2>/dev/null; then
  echo "error: podman-compose up still waiting after 5 more minutes" >&2
  exit 1
fi
up_rc=0
wait "$UP_PID" || up_rc=$?
UP_PID=""
[ "$up_rc" -eq 0 ] || { echo "error: podman-compose up exited $up_rc" >&2; exit 1; }
echo "ok: podman-compose up returned 0"

# Every container running, and healthy wherever it has a check.
echo "waiting for every container to be running and healthy"
bad=""
for _ in $(seq 1 60); do
  bad="$(states | grep -vE ' running Up [^(]*(\(healthy\))?$' || true)"
  [ -z "$bad" ] && break
  sleep 5
done
states
[ -z "$bad" ] || { echo "error: not running and healthy: $bad" >&2; exit 1; }

echo "waiting for the Zabbix web API on port 80"
reply=""
for _ in $(seq 1 60); do
  reply="$(curl -fs -X POST "http://localhost:80/api_jsonrpc.php" -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' || true)"
  grep -q '"result"' <<<"$reply" && break
  sleep 5
done
grep -q '"result"' <<<"$reply" || { echo "error: the web API never answered: ${reply:-no reply}" >&2; exit 1; }
echo "ok: $reply"
