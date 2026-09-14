#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Every probe in the clamshell chain answers 0 (yes) or 1 (no); anything else
# means it could not tell. The chain polls every two seconds while docked, and
# a package transaction can leave busctl or hyprctl unable to start for a
# moment. That moment must not read as an open lid or a missing monitor: the
# panel would come back behind the closed lid and take the workspaces with it.

require_command jq

laptop_closed="$ROOT/bin/omarchy-hw-laptop-closed"
hw_clamshell="$ROOT/bin/omarchy-hw-clamshell"
external_active="$ROOT/bin/omarchy-hyprland-monitor-external-active"
clamshell="$ROOT/bin/omarchy-hyprland-monitor-clamshell"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mock_bin="$tmpdir/bin"
mkdir -p "$mock_bin"

# A stub's body comes on stdin, so JSON and quotes need no escaping.
stub() {
  { printf '#!/bin/bash\n'; cat; } >"$mock_bin/$1"
  chmod +x "$mock_bin/$1"
}

status_of() {
  local status=0
  PATH="$mock_bin:$PATH" "$@" >/dev/null 2>&1 || status=$?
  printf '%s\n' "$status"
}

expect_status() {
  local expected="$1" description="$2"
  shift 2
  local actual
  actual=$(status_of "$@")
  [[ $actual == "$expected" ]] || fail "$description" "expected exit $expected, got $actual"
  pass "$description"
}

expect_unanswered() {
  local description="$1"
  shift
  local actual
  actual=$(status_of "$@")
  [[ $actual != 0 && $actual != 1 ]] || fail "$description" "expected neither 0 nor 1, got $actual"
  pass "$description"
}

# The lid probe: ACPI answers alone where it reads open or closed; otherwise
# logind answers, and only its two answers count.
no_acpi="$tmpdir/no-acpi"
acpi="$tmpdir/acpi"
mkdir -p "$no_acpi" "$acpi/LID0"

stub busctl <<'SH'
exit 1
SH
OMARCHY_ACPI_LID_DIR=$no_acpi expect_status 2 "lid probe answers 2 when logind cannot be asked" "$laptop_closed"

stub busctl <<'SH'
echo "b true"
SH
OMARCHY_ACPI_LID_DIR=$no_acpi expect_status 0 "lid probe answers 0 when logind says closed" "$laptop_closed"

stub busctl <<'SH'
echo "b false"
SH
OMARCHY_ACPI_LID_DIR=$no_acpi expect_status 1 "lid probe answers 1 when logind says open" "$laptop_closed"

stub busctl <<'SH'
echo "s maybe"
SH
OMARCHY_ACPI_LID_DIR=$no_acpi expect_status 2 "lid probe answers 2 on a logind reply it does not recognize" "$laptop_closed"

stub busctl <<'SH'
exit 0
SH
OMARCHY_ACPI_LID_DIR=$no_acpi expect_status 2 "lid probe answers 2 on an empty logind reply" "$laptop_closed"

stub busctl <<'SH'
echo "b false"
exit 1
SH
OMARCHY_ACPI_LID_DIR=$no_acpi expect_status 2 "lid probe answers 2 when logind prints an answer but the query failed" "$laptop_closed"

stub busctl <<'SH'
exit 1
SH
echo "state:      closed" >"$acpi/LID0/state"
OMARCHY_ACPI_LID_DIR=$acpi expect_status 0 "ACPI answers closed without asking logind" "$laptop_closed"
echo "state:      open" >"$acpi/LID0/state"
OMARCHY_ACPI_LID_DIR=$acpi expect_status 1 "ACPI answers open without asking logind" "$laptop_closed"

stub busctl <<'SH'
echo "b true"
SH
echo "state:      unknown" >"$acpi/LID0/state"
OMARCHY_ACPI_LID_DIR=$acpi expect_status 2 "an ACPI lid that reads neither way is no answer, whatever logind says" "$laptop_closed"
echo "state:      not closed" >"$acpi/LID0/state"
OMARCHY_ACPI_LID_DIR=$acpi expect_status 2 "an ACPI reading is matched whole, not by substring" "$laptop_closed"
echo "state:      open" >"$acpi/LID0/state"
chmod 000 "$acpi/LID0/state"
OMARCHY_ACPI_LID_DIR=$acpi expect_status 2 "an ACPI lid that cannot be read is no answer, whatever logind says" "$laptop_closed"
chmod 644 "$acpi/LID0/state"

# Two ACPI lids: closed wins, open needs both, one that reads neither way spoils open.
mkdir -p "$acpi/LID1"
echo "state:      open" >"$acpi/LID0/state"
echo "state:      unknown" >"$acpi/LID1/state"
OMARCHY_ACPI_LID_DIR=$acpi expect_status 2 "an open ACPI lid does not answer for one that reads neither way" "$laptop_closed"
echo "state:      unknown" >"$acpi/LID0/state"
echo "state:      open" >"$acpi/LID1/state"
OMARCHY_ACPI_LID_DIR=$acpi expect_status 2 "an ACPI lid that reads neither way is not outvoted by a later open one" "$laptop_closed"
echo "state:      closed" >"$acpi/LID0/state"
OMARCHY_ACPI_LID_DIR=$acpi expect_status 0 "a closed ACPI lid answers beside one that reads neither way" "$laptop_closed"
echo "state:      open" >"$acpi/LID0/state"
OMARCHY_ACPI_LID_DIR=$acpi expect_status 1 "two open ACPI lids answer open" "$laptop_closed"
rm -r "$acpi/LID1"

# Clamshell: the sysfs monitor check settles "no" alone; an unreadable lid
# passes through only when a monitor makes the lid matter, and a helper that
# could not start is no answer either.
stub omarchy-hw-external-monitors <<'SH'
exit 1
SH
stub omarchy-hw-laptop-closed <<'SH'
exit 2
SH
expect_status 1 "no external monitor is never clamshell, whatever the lid probe says" "$hw_clamshell"

stub omarchy-hw-external-monitors <<'SH'
exit 0
SH
expect_status 2 "an unreadable lid beside an external monitor is unknown, not open" "$hw_clamshell"
OMARCHY_LID=closed expect_status 0 "the bind's closed transition outranks an unreadable lid" "$hw_clamshell"

stub omarchy-hw-laptop-closed <<'SH'
exit 0
SH
expect_status 0 "a closed lid beside an external monitor is clamshell" "$hw_clamshell"
OMARCHY_LID=open expect_status 1 "the bind's open transition outranks a lid still read as closed" "$hw_clamshell"

stub omarchy-hw-laptop-closed <<'SH'
exit 1
SH
expect_status 1 "an open lid beside an external monitor is not clamshell" "$hw_clamshell"

stub omarchy-hw-laptop-closed <<'SH'
exit 127
SH
expect_unanswered "a lid helper that could not start is not an answer" "$hw_clamshell"

stub omarchy-hw-external-monitors <<'SH'
exit 127
SH
expect_status 2 "a monitor helper that could not start is not an answer" "$hw_clamshell"

# The active-external probe: a compositor that fails, or a reply the decision
# cannot rest on, is unknown; a well-formed list without an enabled external is
# a real "no".
stub hyprctl <<'SH'
exit 1
SH
expect_status 2 "external-active answers 2 when hyprctl fails" "$external_active"

stub hyprctl <<'SH'
echo "Couldn't connect to Hyprland"
SH
expect_status 2 "external-active answers 2 when hyprctl returns no monitor list" "$external_active"

stub hyprctl <<'SH'
echo '{"name":"DP-1","disabled":false}'
SH
expect_status 2 "external-active answers 2 when the reply is not a list" "$external_active"

stub hyprctl <<'SH'
echo '[{"name":"DP-1"}]'
SH
expect_status 2 "external-active answers 2 when a monitor carries no enabled state" "$external_active"

stub hyprctl <<'SH'
echo '[{"name":"DP-1","disabled":false}] []'
SH
expect_status 2 "external-active answers 2 when the reply holds more than one document" "$external_active"

stub hyprctl <<'SH'
echo '{} []'
SH
expect_status 2 "external-active answers 2 when a later document would hide an invalid first" "$external_active"

stub hyprctl <<'SH'
exit 0
SH
expect_status 2 "external-active answers 2 on an empty reply" "$external_active"

stub hyprctl <<'SH'
echo '[]'
SH
expect_status 1 "external-active answers 1 for an empty list" "$external_active"

stub hyprctl <<'SH'
echo '[{"name":"eDP-1","disabled":false}]'
SH
expect_status 1 "external-active answers 1 with only the internal panel" "$external_active"

stub hyprctl <<'SH'
printf '\n  [{"name":"eDP-1","disabled":true},{"name":"DP-1","disabled":false}]\n'
SH
expect_status 0 "external-active answers 0 with an enabled external, whatever surrounds the list" "$external_active"

stub hyprctl <<'SH'
echo '[{"name":"eDP-1","disabled":false},{"name":"DP-1","disabled":true}]'
SH
expect_status 1 "external-active answers 1 with the external disabled on purpose" "$external_active"

# The reconciler, run with the real recovery helpers and toggle helpers under a
# scratch HOME. hyprctl records every call that is not a query, so a hold can
# be shown to touch nothing.
home="$tmpdir/home"
toggles="$home/.local/state/omarchy/toggles/hypr"
flag="$toggles/internal-monitor-clamshell.lua"
manual_flag="$toggles/internal-monitor-disable.lua"
hyprctl_log="$tmpdir/hyprctl.log"
monitors_json="$tmpdir/monitors.json"
disable_rule='hl.monitor({ output = "eDP-1", disabled = true })'
mkdir -p "$toggles" "$home/.config/hypr"
: >"$home/.config/hypr/monitors.lua"

stub omarchy-hyprland-monitor-laptop <<'SH'
echo eDP-1
SH
stub omarchy-notification-send <<'SH'
exit 0
SH
stub hyprctl <<'SH'
case $1 in
  monitors) cat "$MONITORS_JSON" ;;
  reload)
    echo "$*" >>"$HYPRCTL_LOG"
    exit "${RELOAD_STATUS:-0}"
    ;;
  *) echo "$*" >>"$HYPRCTL_LOG" ;;
esac
SH
stub omarchy-hyprland-reload-guard <<'SH'
[[ $1 == "paused" && ${GUARD_PAUSED:-0} == 1 ]]
SH

panel_on='[{"name":"eDP-1","disabled":false,"scale":2},{"name":"DP-1","disabled":false,"scale":1.25}]'
panel_off='[{"name":"eDP-1","disabled":true,"scale":0},{"name":"DP-1","disabled":false,"scale":1.25}]'

# run_reconciler <clamshell status> <external status> <monitors json>
run_reconciler() {
  stub omarchy-hw-clamshell <<SH
exit $1
SH
  stub omarchy-hyprland-monitor-external-active <<SH
exit $2
SH
  printf '%s\n' "$3" >"$monitors_json"
  : >"$hyprctl_log"
  local status=0
  HOME="$home" OMARCHY_PATH="$ROOT" MONITORS_JSON="$monitors_json" HYPRCTL_LOG="$hyprctl_log" \
    RELOAD_STATUS="${RELOAD_STATUS:-0}" GUARD_PAUSED="${GUARD_PAUSED:-0}" \
    PATH="$mock_bin:$PATH" "$clamshell" >/dev/null 2>&1 || status=$?
  printf '%s\n' "$status"
}

toggle_state() {
  find "$toggles" -type f | sort | xargs -r md5sum
}

# Every pairing with an unanswered probe, with the clamshell flag present and
# absent and each manual toggle off and on: exit 0 and the clamshell flag as it
# was. An unanswered compositor changes nothing at all. An unanswered lid beside
# an answered "no external" still lets recovery hand a manually disabled or
# mirrored panel back: that decision rests on the external answer alone.
mirror_flag="$toggles/internal-monitor-mirror.lua"
for clamshell_status in 0 1 2 127; do
  for external_status in 0 1 2 127; do
    (( clamshell_status > 1 || external_status > 1 )) || continue
    for flag_state in present absent; do
      for manual in none disable mirror; do
        case $manual in
          none) rm -f "$manual_flag" "$mirror_flag" ;;
          disable) printf '%s\n' "$disable_rule" >"$manual_flag"; rm -f "$mirror_flag" ;;
          mirror) printf 'hl.monitor({ output = "DP-1", mirror = "eDP-1" })\n' >"$mirror_flag"; rm -f "$manual_flag" ;;
        esac
        if [[ $flag_state == present ]]; then
          printf '%s\n' "$disable_rule" >"$flag"
        else
          rm -f "$flag"
        fi
        before=$(toggle_state)
        case="$clamshell_status/$external_status, flag $flag_state, manual $manual"
        status=$(run_reconciler "$clamshell_status" "$external_status" "$panel_on")
        [[ $status == 0 ]] || fail "reconciler exits 0 on hold ($case)" "exit $status"
        if [[ $flag_state == present ]]; then
          [[ -f $flag && $(< "$flag") == "$disable_rule" ]] || fail "reconciler keeps the clamshell flag on hold ($case)"
        else
          [[ ! -f $flag ]] || fail "reconciler writes no clamshell flag on hold ($case)"
        fi
        if (( external_status == 1 )) && [[ $manual != none ]]; then
          [[ ! -f $manual_flag && ! -f $mirror_flag ]] || fail "recovery hands the panel back on an answered missing external ($case)"
        else
          [[ $(toggle_state) == "$before" ]] || fail "reconciler touches no toggle on hold ($case)" "$(toggle_state)"
          [[ ! -s $hyprctl_log ]] || fail "reconciler changes nothing in Hyprland on hold ($case)" "$(cat "$hyprctl_log")"
        fi
      done
    done
  done
done
rm -f "$manual_flag" "$mirror_flag"
pass "reconciler holds on every unanswered probe, with or without a manual toggle"

# Answered probes keep switching the panel.
rm -f "$flag"
run_reconciler 0 0 "$panel_on" >/dev/null
[[ -f $flag && $(< "$flag") == "$disable_rule" ]] || fail "an answered clamshell writes the disable flag" "$(cat "$flag" 2>/dev/null)"
grep -qx 'reload' "$hyprctl_log" || fail "an answered clamshell reloads Hyprland" "$(cat "$hyprctl_log")"
pass "an answered clamshell disables the panel"

run_reconciler 0 0 "$panel_off" >/dev/null
[[ ! -s $hyprctl_log ]] || fail "a clamshell already applied is left alone" "$(cat "$hyprctl_log")"
pass "a clamshell already applied is left alone"

for pair in "1 0" "0 1" "1 1"; do
  printf '%s\n' "$disable_rule" >"$flag"
  run_reconciler $pair "$panel_off" >/dev/null
  [[ ! -f $flag ]] || fail "an answered non-clamshell ($pair) removes the flag"
  grep -qx 'reload' "$hyprctl_log" || fail "an answered non-clamshell ($pair) reloads Hyprland" "$(cat "$hyprctl_log")"
done
pass "an answered open lid or missing external re-enables the panel"

# A reload that failed, or was paused for a package transaction, leaves the
# panel on with the flag in place; the next answered poll reloads again.
rm -f "$flag"
RELOAD_STATUS=1 run_reconciler 0 0 "$panel_on" >/dev/null
[[ -f $flag ]] || fail "a failed reload keeps the written flag"
run_reconciler 0 0 "$panel_on" >/dev/null
grep -qx 'reload' "$hyprctl_log" || fail "a panel still on behind an unchanged flag is reloaded again" "$(cat "$hyprctl_log")"
pass "a failed reload is retried while the panel is still on"

rm -f "$flag"
GUARD_PAUSED=1 run_reconciler 0 0 "$panel_on" >/dev/null
[[ -f $flag ]] || fail "a paused reload still records the clamshell flag"
[[ ! -s $hyprctl_log ]] || fail "a paused reload does not reload into a package transaction" "$(cat "$hyprctl_log")"
pass "a package transaction defers the reload and keeps the flag for its resume"

printf '%s\n' "$disable_rule" >"$flag"
GUARD_PAUSED=1 run_reconciler 1 0 "$panel_off" >/dev/null
[[ ! -f $flag ]] || fail "a paused reload still removes the clamshell flag on an open lid"
! grep -qx 'reload' "$hyprctl_log" || fail "an open lid does not reload into a package transaction" "$(cat "$hyprctl_log")"
pass "an open lid during a package transaction drops the flag without reloading"

# Recovery with answered probes: a manually disabled or mirrored panel comes
# back when the external is answered gone, and stays put while it is active.
rm -f "$flag"
printf '%s\n' "$disable_rule" >"$manual_flag"
run_reconciler 1 1 "$panel_off" >/dev/null
[[ ! -f $manual_flag ]] || fail "recovery hands a manually disabled panel back when no external is left"
printf 'hl.monitor({ output = "DP-1", mirror = "eDP-1" })\n' >"$mirror_flag"
run_reconciler 1 1 "$panel_off" >/dev/null
[[ ! -f $mirror_flag ]] || fail "recovery ends mirroring when no external is left"
pass "recovery hands a manually disabled or mirrored panel back on an answered missing external"

printf '%s\n' "$disable_rule" >"$manual_flag"
run_reconciler 0 0 "$panel_off" >/dev/null
[[ -f $manual_flag ]] || fail "recovery leaves a manually disabled panel alone while an external is active"
pass "recovery leaves a manually disabled panel alone while an external is active"
rm -f "$manual_flag"

# The compositor's answer can change between recovery and the decision; the
# decision must rest on the later answer, never on one recovery already
# superseded. The stub answers from a queue, one status per call.
answers="$tmpdir/answers"
stub omarchy-hyprland-monitor-external-active <<'SH'
status=$(head -n 1 "$ANSWERS")
sed -i '1d' "$ANSWERS"
exit "${status:-2}"
SH
stub omarchy-hw-clamshell <<'SH'
exit 0
SH
run_queued() {
  printf '%s\n' "$@" >"$answers"
  : >"$hyprctl_log"
  HOME="$home" OMARCHY_PATH="$ROOT" MONITORS_JSON="$monitors_json" HYPRCTL_LOG="$hyprctl_log" \
    ANSWERS="$answers" PATH="$mock_bin:$PATH" "$clamshell" >/dev/null 2>&1 || true
}
printf '%s\n' "$panel_off" >"$monitors_json"
printf '%s\n' "$disable_rule" >"$manual_flag"
rm -f "$flag"
# Recovery sees no external (1, 1 for the two helpers); the decision then sees
# it active again (0): the toggle is handed back, and the fresher answer
# beside a closed lid restores clamshell.
run_queued 1 1 0
[[ ! -f $manual_flag ]] || fail "recovery acts on its own answered missing external"
[[ -f $flag ]] || fail "a later answered active external decides clamshell after recovery"
pass "the clamshell decision rests on an answer taken after recovery"
# Recovery sees the external active (0, 0) and leaves the toggle; the decision
# then sees it gone (1) and re-enables the panel rather than disabling it on
# the earlier answer.
printf '%s\n' "$disable_rule" >"$manual_flag"
printf '%s\n' "$disable_rule" >"$flag"
run_queued 0 0 1
[[ -f $manual_flag ]] || fail "recovery leaves the toggle on its own answered active external"
[[ ! -f $flag ]] || fail "a later answered missing external never disables the panel on an earlier answer"
pass "an external answered gone after recovery re-enables the panel"
rm -f "$manual_flag" "$flag"
