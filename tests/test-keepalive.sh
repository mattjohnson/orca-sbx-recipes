#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"

NAME="orca-p-abc123def456"
PIDFILE="$HOME/.orca-sbx/$NAME/keepalive.pid"
mkdir -p "$HOME/.orca-sbx/$NAME"
# the stub holds its keepalive sessions open (recording each pid), so a spawned
# keepalive is a real live process for the liveness checks below. Bounded, so a
# failing assertion can leave nothing behind.
export STUB_KEEPALIVE_HOLD="$TESTTMP/keepalive.pids" STUB_KEEPALIVE_SECS=30

common() { sh -c "$(cat scripts/lifecycle/common.sh); $1"; }
# an unrelated live process: stands in for the PID the OS recycled onto someone
# else after the keepalive died. The subshell keeps job-control noise off stderr.
spawn_bystander() { (sleep 30 & echo $! > "$TESTTMP/bystander.pid") 2>/dev/null; }

# ensure_keepalive: a recycled PID is not our keepalive → respawn anyway
spawn_bystander
BYSTANDER="$(cat "$TESTTMP/bystander.pid")"
printf '%s' "$BYSTANDER" > "$PIDFILE"
common "ensure_keepalive $NAME"
wait_for_log "exec $NAME -- sleep 2147483647" 30 "respawned over a recycled pid" || true
[ "$(cat "$PIDFILE")" != "$BYSTANDER" ] || { echo "FAIL pidfile still points at the recycled pid"; FAILURES=$((FAILURES+1)); }
pid_alive "$BYSTANDER" || { echo "FAIL ensure_keepalive killed an unrelated process"; FAILURES=$((FAILURES+1)); }
kill "$(cat "$PIDFILE")" 2>/dev/null || true

# stop_keepalive: a recycled PID must not be signalled, but the pidfile goes
printf '%s' "$BYSTANDER" > "$PIDFILE"
common "stop_keepalive $NAME"
pid_alive "$BYSTANDER" || { echo "FAIL stop_keepalive killed an unrelated process"; FAILURES=$((FAILURES+1)); }
[ ! -f "$PIDFILE" ] || { echo "FAIL stale pidfile kept"; FAILURES=$((FAILURES+1)); }
kill "$BYSTANDER" 2>/dev/null || true

# ensure_keepalive: a live keepalive is left alone (no duplicate session)
: > "$SBX_LOG"; rm -f "$PIDFILE"
common "ensure_keepalive $NAME"
wait_for_log "exec $NAME -- sleep 2147483647" 30 "first keepalive spawned" || true
KEEPALIVE="$(cat "$PIDFILE")"
common "ensure_keepalive $NAME"
assert_eq "$(cat "$PIDFILE")" "$KEEPALIVE" "live keepalive reused"

# stop_keepalive: the real keepalive is signalled and the pidfile removed
common "stop_keepalive $NAME"
wait_pid_gone "$KEEPALIVE" 30 "keepalive stopped"
[ ! -f "$PIDFILE" ] || { echo "FAIL pidfile kept after stop"; FAILURES=$((FAILURES+1)); }

# a junk pidfile is not a live keepalive: respawn, and stop cleans up quietly
: > "$SBX_LOG"
printf 'not-a-pid' > "$PIDFILE"
common "ensure_keepalive $NAME"
wait_for_log "exec $NAME -- sleep 2147483647" 30 "respawned over a junk pidfile" || true
kill "$(cat "$PIDFILE")" 2>/dev/null || true
printf 'not-a-pid' > "$PIDFILE"
common "stop_keepalive $NAME" || { echo "FAIL stop_keepalive rc on junk pidfile"; FAILURES=$((FAILURES+1)); }
[ ! -f "$PIDFILE" ] || { echo "FAIL junk pidfile kept"; FAILURES=$((FAILURES+1)); }

finish
