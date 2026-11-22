#!/usr/bin/env bash
# podman-healthchecks.sh [interval-seconds | --once]
#
# Runs the container health checks that podman does not run by itself on a
# host without systemd.
#
#   ./podman-healthchecks.sh          every 10 seconds, until stopped
#   ./podman-healthchecks.sh 30       every 30 seconds
#   ./podman-healthchecks.sh --once   one round and exit, for cron
#
# PODMAN SCHEDULES HEALTH CHECKS WITH SYSTEMD TIMERS, AND ONLY WITH THEM. A
# podman built without systemd, which is what Alpine and the other OpenRC
# systems ship, creates no timer at all (libpod/healthcheck_nosystemd_linux.go
# is a function that returns nil). Every health status then stays "starting"
# for good, and podman-compose, which waits for `condition: service_healthy`
# with `podman wait --condition=healthy`, waits forever: PostgreSQL up, every
# other container "Created" (issue #14). Docker runs the checks in its daemon,
# and podman on a host with systemd runs them from its timers; neither needs
# this.
#
# Start it before `podman-compose up`, or while `up` is already waiting: `up`
# carries on at the next round. It runs the check of every running container
# that has one, so other stacks on the same host get theirs too. A failed check
# is the container's health, recorded by podman as usual, not an error here.
set -uo pipefail

ONCE=false
INTERVAL=10
case "${1:-}" in
  "") ;;
  --once) ONCE=true ;;
  0 | *[!0-9]*) echo "usage: $0 [interval-seconds | --once]" >&2; exit 2 ;;
  *) INTERVAL="$1" ;;
esac

if ! command -v podman >/dev/null 2>&1; then
  echo "podman is not installed here: there are no checks to run" >&2
  exit 2
fi
if [ -d /run/systemd/system ]; then
  echo "systemd runs on this host, so podman normally schedules the checks itself; running them anyway" >&2
fi

# One round: every running container whose health is starting, healthy or
# unhealthy (podman ORs filters on the same key), each check in parallel so a
# slow one does not hold up the rest.
round() {
  local ids id
  if ! ids="$(podman ps --quiet --filter health=starting --filter health=healthy --filter health=unhealthy 2>&1)"; then
    echo "podman ps failed: $ids" >&2
    return 1
  fi
  for id in $ids; do
    podman healthcheck run "$id" >/dev/null 2>&1 &
  done
  wait
  return 0
}

if [ "$ONCE" = true ]; then
  round
  exit $?
fi

echo "running the health checks of every container that has one, every ${INTERVAL}s; stop with Ctrl-C"
while :; do
  round || true
  sleep "$INTERVAL"
done
