#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The watcher's docked poll, run for real against a stand-in event socket. The
# compositor's answer comes from a file the test rewrites; a stub sleep logs
# its argument and its caller, and the poll is the only caller of "sleep 2",
# so the poll is alive exactly while those lines keep coming; the reconciler
# stub logs the answer it would have seen.

require_command socat
require_command flock

monitor_watch="$ROOT/bin/omarchy-hyprland-monitor-watch"

tmpdir=$(mktemp -d)
run="$tmpdir/run"
signature="test"
hypr_dir="$run/hypr/$signature"
socket="$hypr_dir/.socket2.sock"
events="$tmpdir/events"
mock_bin="$tmpdir/bin"
sleep_log="$tmpdir/sleep.log"
reconcile_log="$tmpdir/reconcile.log"
external_status="$tmpdir/external-status"
mkdir -p "$hypr_dir" "$mock_bin"
mkfifo "$events"
: >"$sleep_log"
: >"$reconcile_log"

watch_pid=""
server_pid=""
feeder_pid=""
cleanup() {
  [[ -n $feeder_pid ]] && kill "$feeder_pid" 2>/dev/null
  [[ -n $watch_pid ]] && kill -- "-$watch_pid" 2>/dev/null
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null
  exec 3>&- 2>/dev/null
  rm -rf "$tmpdir"
}
trap cleanup EXIT

stub() {
  { printf '#!/bin/bash\n'; cat; } >"$mock_bin/$1"
  chmod +x "$mock_bin/$1"
}

stub sleep <<'SH'
printf 'sleep %s %s\n' "$1" "$PPID" >>"$SLEEP_LOG"
exec /usr/bin/sleep "$@"
SH
stub omarchy-hyprland-monitor-external-active <<'SH'
exit "$(< "$EXTERNAL_STATUS")"
SH
stub omarchy-hw-laptop <<'SH'
exit 0
SH
stub omarchy-hyprland-monitor-clamshell <<'SH'
printf 'reconcile %s\n' "$(< "$EXTERNAL_STATUS")" >>"$RECONCILE_LOG"
SH
stub omarchy-hyprland-monitor-modeless <<'SH'
exit 1
SH
stub omarchy-hyprland-reload-guard <<'SH'
exit 1
SH

poll_passes() {
  grep -c '^sleep 2 ' "$sleep_log" || true
}

poll_owner() {
  grep '^sleep 2 ' "$sleep_log" | tail -n 1 | cut -d ' ' -f 3
}

answered_reconciliations() {
  grep -c '^reconcile 1$' "$reconcile_log" || true
}

emit() {
  printf '%s\n' "$1" >&3
}

# Hold the FIFO open at both ends so the server never sees EOF, then serve it
# to the one client the watcher will connect.
exec 3<>"$events"
socat -u OPEN:"$events",rdonly UNIX-LISTEN:"$socket" 2>/dev/null &
server_pid=$!
for _ in $(seq 50); do
  [[ -S $socket ]] && break
  /usr/bin/sleep 0.1
done
[[ -S $socket ]] || fail "stand-in event socket is listening"

# Startup with a compositor that cannot be asked.
echo 2 >"$external_status"
XDG_RUNTIME_DIR="$run" HYPRLAND_INSTANCE_SIGNATURE="$signature" SLEEP_LOG="$sleep_log" \
  RECONCILE_LOG="$reconcile_log" EXTERNAL_STATUS="$external_status" PATH="$mock_bin:$PATH" \
  setsid bash "$monitor_watch" >/dev/null 2>&1 &
watch_pid=$!

/usr/bin/sleep 4.5
kill -0 "$watch_pid" 2>/dev/null || fail "watcher is running"
(( $(poll_passes) >= 2 )) || fail "an unanswered compositor at startup starts the poll" "passes: $(poll_passes)"
pass "an unanswered compositor at startup starts the poll"

# The answer becomes "undocked" with no monitor event, under a stream of
# unrelated events too quick for the read to ever time out: the main loop's
# own recheck still stops the poll, and the panel is reconciled on the answer
# that ended the wait.
(
  while true; do
    printf 'activewindow>>foot,shell\n' >&3
    /usr/bin/sleep 0.25
  done
) &
feeder_pid=$!
echo 1 >"$external_status"
/usr/bin/sleep 4.5
before=$(poll_passes)
/usr/bin/sleep 4.5
(( $(poll_passes) == before )) || fail "an answered undocked stops the poll without a monitor event" "passes: $before -> $(poll_passes)"
pass "an answered undocked stops the poll without a monitor event, whatever else the compositor says"
(( $(answered_reconciliations) >= 1 )) || fail "the answer that ends an unknown period is reconciled on" "$(cat "$reconcile_log")"
pass "the answer that ends an unknown period is reconciled on"
kill "$feeder_pid" 2>/dev/null
feeder_pid=""

# A dock event restarts it, even when the line arrives in two pieces around
# the read timeout.
echo 0 >"$external_status"
printf 'monitoraddedv2>' >&3
/usr/bin/sleep 2.5
printf '>1,DP-1,LG\n' >&3
/usr/bin/sleep 4.5
(( $(poll_passes) > before )) || fail "a dock event split across the read timeout restarts the poll" "passes: $before -> $(poll_passes)"
pass "a dock event split across the read timeout restarts the poll"

# A poll that died is replaced on the next event, an unanswered one included.
owner=$(poll_owner)
[[ -n $owner ]] || fail "the poll's process is known" "$(tail -n 3 "$sleep_log")"
kill "$owner"
/usr/bin/sleep 1
echo 2 >"$external_status"
emit 'monitorremovedv2>>1,DP-1,LG'
/usr/bin/sleep 4.5
[[ $(poll_owner) != "$owner" ]] || fail "a dead poll is replaced on an unanswered event" "owner still $owner"
(( $(poll_passes) >= 2 )) || fail "the replacement poll runs" "passes: $(poll_passes)"
pass "a dead poll is replaced on an unanswered event"

kill -0 "$watch_pid" 2>/dev/null || fail "watcher survives the whole run"
pass "watcher survives the whole run"
