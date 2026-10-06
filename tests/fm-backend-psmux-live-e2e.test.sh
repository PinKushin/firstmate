#!/usr/bin/env bash
# tests/fm-backend-psmux-live-e2e.test.sh - a REAL psmux driven through the tmux
# adapter, end to end, under Git Bash on Windows.
#
# tests/fm-psmux.test.sh pins the psmux-aware logic against a PATH fake that
# answers the way psmux's source says it should. This guard is the other half
# every harness-dependent check needs (firstmate-coding-guidelines "Harness-
# dependent checks"): it runs the same public backend functions against the real
# multiplexer, so a psmux release that changes a process name, a path flavor, an
# error string, or a flag fails here naming the version. It is the proof behind
# .github/workflows/windows-psmux.yml and the dated record in
# docs/verification/runtime-backends.md "psmux".
#
# It spends no model tokens, so it is default-on wherever `psmux` is installed
# and skips with `skip: live: psmux absent` everywhere else (Linux and macOS CI
# lanes). FM_PSMUX_LIVE=1 makes an absent psmux a failure; =0 turns it off.
#
# Every `tmux` call goes through a shim that pins a private psmux namespace
# (`-L`), so a developer's own psmux sessions are never touched. The adapter
# under test still sees a plain `tmux` on PATH, exactly as in production.
#
# A failed check does not stop the run: every case prints `ok -` or `not ok -`,
# and `MEASUREMENT: <fact> | <value>` lines record the observed value of each
# psmux fact the adapter depends on, so one run documents the whole surface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PSMUX_LIVE psmux

REAL_PSMUX=$(command -v psmux)
TMP_ROOT=$(fm_test_tmproot fm-psmux-live)
SOCKET="fm-psmux-live-$$"
FAILS=0

check() {  # <name> <status 0|nonzero> [detail]
  if [ "$2" = 0 ]; then
    pass "$1"
  else
    printf 'not ok - %s%s\n' "$1" "${3:+: $3}" >&2
    FAILS=$((FAILS + 1))
  fi
}

# check_eq <name> <got> <want>: pass when the two are the same string.
check_eq() {
  [ "$2" = "$3" ]
  check "$1" $? "got '$2', want '$3'"
}

# check_fails <name> <status>: pass when the command under test failed.
check_fails() {
  [ "$2" -ne 0 ]
  check "$1" $? "the command unexpectedly succeeded"
}

# check_status <name> <status> <want>: pass when the status is exactly <want>.
check_status() {
  [ "$2" -eq "$3" ]
  check "$1" $? "status $2, want $3"
}

measure() {  # <fact> <value>
  printf 'MEASUREMENT: %s | %s\n' "$1" "$2"
}

# A value with its control characters made visible, so a stray CR is recorded
# rather than eaten by the terminal.
visible() {  # <value>
  printf '%s' "$1" | od -An -c | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'
}

cleanup_all() {
  [ -n "${REAL_PSMUX:-}" ] && "$REAL_PSMUX" -L "$SOCKET" kill-server >/dev/null 2>&1
  fm_test_cleanup
  return 0
}
trap cleanup_all EXIT

# --- environment under test --------------------------------------------------

unset TMUX PSMUX_SESSION FM_TMUX_FLAVOR FM_PSMUX_PROBED FM_PSMUX_HOST FM_PSMUX_BASH
measure 'host' "$(uname -s) / OSTYPE=${OSTYPE:-} / bash ${BASH_VERSION:-}"
measure 'psmux binary' "$REAL_PSMUX"

SHIM_DIR="$TMP_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_PSMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

PROJ="$TMP_ROOT/proj dir"
AGENT_DIR="$TMP_ROOT/agents"
mkdir -p "$PROJ" "$AGENT_DIR"

# win_agent_count: how many live Windows processes run an image under
# $AGENT_DIR. A Windows-side census, so it sees exactly what a Git Bash `ps`
# cannot: the processes psmux started. It matches the unique leaf of the temp
# root, case-insensitively (PowerShell -like), rather than a full path, because
# the image path Windows reports can differ from `cygpath -w` in case and in
# 8.3 short-name spelling of the parent directories.
win_agent_count() {
  local leaf out
  leaf=$(basename "$TMP_ROOT")
  # shellcheck disable=SC2016 # $_ and $env: are PowerShell syntax, not bash.
  out=$(LEAF=$leaf powershell.exe -NoProfile -NonInteractive -Command \
    '@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like ("*" + $env:LEAF + "*") }).Count' 2>/dev/null) || out=
  printf '%s' "${out//[$'\r\n ']/}"
}

wait_for() {  # <seconds> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt $((limit * 5)) ]; do
    if "$@"; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || { printf 'not ok - fm_backend_source tmux failed\n' >&2; exit 1; }

# --- 1. version and detection --------------------------------------------------

version_out=$(LC_ALL=C command tmux -V 2>&1)
version_rc=$?
measure 'tmux -V' "rc=$version_rc $(visible "$version_out")"
first_line=${version_out%%$'\n'*}
second_line=
case "$version_out" in
  *$'\n'*) second_line=${version_out#*$'\n'}; second_line=${second_line%%$'\n'*} ;;
esac
case "$first_line" in tmux\ [0-9]*) rc=0 ;; *) rc=1 ;; esac
check 'psmux -V first line is "tmux <version>"' "$rc" "$first_line"
case "${second_line%$'\r'}" in psmux\ [0-9]*) rc=0 ;; *) rc=1 ;; esac
check 'psmux -V second line is "psmux <version> (<build>)"' "$rc" "$second_line"
fm_psmux_active
check 'fm_psmux_active detects the real psmux from tmux -V alone' $? "FM_PSMUX_PROBED=${FM_PSMUX_PROBED:-unset}"
fm_psmux_host_is_windows
check 'fm_psmux_host_is_windows is true under Git Bash' $? "OSTYPE=${OSTYPE:-}"
declare -F tmux >/dev/null
check 'the tmux argument-conversion guard is installed under psmux' $?

# --- 2. server, session, and missing-session wording ---------------------------

no_server_out=$(LC_ALL=C command tmux list-windows -t =firstmate 2>&1)
no_server_rc=$?
measure 'list-windows with no server running' "rc=$no_server_rc $(visible "$no_server_out")"
fm_backend_tmux_window_inventory '=firstmate' >/dev/null
check_status 'a missing server reads as definitively absent (inventory verdict 2)' $? 2

session=$(fm_backend_tmux_container_ensure)
check_eq 'container ensure creates and names the firstmate session' "$session" firstmate
tmux has-session -t firstmate 2>/dev/null
check 'has-session finds the created session' $?

ghost_out=$(LC_ALL=C command tmux list-windows -t =ghost 2>&1)
ghost_rc=$?
measure 'list-windows for an absent session on a running server' "rc=$ghost_rc $(visible "$ghost_out")"
fm_backend_tmux_window_inventory '=ghost' >/dev/null
check_status 'an absent session on a live server reads as definitively absent (verdict 2)' $? 2

# --- 3. task window: Git Bash, Windows start directory, stable id ---------------

WNAME=fm-live1
wid=$(fm_backend_tmux_create_task "$session" "$WNAME" "$PROJ")
create_rc=$?
measure 'new-window window id' "rc=$create_rc $(visible "$wid")"
check 'create_task succeeds under real psmux' "$create_rc"
case "$wid" in @[0-9]*) rc=0 ;; *) rc=1 ;; esac
check 'create_task prints a clean @<id> window id (no CR)' "$rc" "$(visible "$wid")"
TARGET="$session:$WNAME"

fm_backend_tmux_create_task "$session" "$WNAME" "$PROJ" >/dev/null 2>&1
check_fails 'create_task refuses an existing window name' $?

windows_raw=$(LC_ALL=C command tmux list-windows -t "$session" -F '#{window_name}')
measure 'list-windows -F #{window_name}' "$(visible "$windows_raw")"
fm_backend_tmux_window_inventory "$session" | grep -qxF -- "$WNAME"
check 'window inventory lists the task window by exact name' $?

shell_name() { fm_psmux_normalize_name "$(fm_backend_tmux_current_command "$TARGET")"; }
shell_is_bash() { [ "$(shell_name)" = bash ]; }
wait_for 20 shell_is_bash
check 'the task window runs bash (pane_current_command normalizes to bash)' $? "got '$(fm_backend_tmux_current_command "$TARGET")'"
measure 'pane_current_command of an idle Git Bash task window' "$(visible "$(fm_backend_tmux_current_command "$TARGET")")"

tty_value=$(tmux display-message -p -t "$TARGET" '#{pane_tty}' | tr -d '\r')
pid_value=$(tmux display-message -p -t "$TARGET" '#{pane_pid}' | tr -d '\r')
measure '#{pane_tty}' "$tty_value"
measure '#{pane_pid}' "$pid_value"
case "$tty_value" in /dev/pty[0-9]*) rc=0 ;; *) rc=1 ;; esac
check '#{pane_tty} is the synthetic /dev/pty<id> the adapter refuses to ps -t' "$rc" "$tty_value"
case "$pid_value" in ''|*[!0-9]*) rc=1 ;; *) rc=0 ;; esac
check '#{pane_pid} is numeric' "$rc" "$pid_value"

crlf_probe=$(tmux display-message -p -t "$TARGET" '#{window_name}')
measure 'display-message -p output bytes' "$(visible "$crlf_probe")"

# --- 4. typing into the window: literal text, Enter, capture --------------------

typed_and_seen() {  # <literal text to type> <expected output substring>
  fm_backend_tmux_send_literal "$TARGET" "$1" || return 1
  fm_backend_tmux_send_key "$TARGET" Enter || return 1
  wait_for 15 capture_has "$2"
}
capture_has() { fm_backend_tmux_capture "$TARGET" 200 2>/dev/null | tr -d '\r' | grep -qF -- "$1"; }

# shellcheck disable=SC2016 # the line is typed literally; Git Bash expands it.
typed_and_seen 'echo FM_LIVE_SUM_$((20 + 22))' 'FM_LIVE_SUM_42'
check 'literal text plus Enter reaches Git Bash and its output is captured' $?

# shellcheck disable=SC2016
typed_and_seen 'echo "SHELL_KIND_$(uname -s | cut -c1-5)"' 'SHELL_KIND_'
check 'the pane is a POSIX Git Bash, not PowerShell' $?
measure 'uname -s inside the task window' "$(fm_backend_tmux_capture "$TARGET" 200 | tr -d '\r' | grep 'SHELL_KIND_' | tail -n 1)"

# MSYS rewrites POSIX-looking argv into Windows paths when it starts a native
# executable. The adapter's tmux() guard disables that; the unguarded call below
# measures what would happen without it.
LIT='/no-mistakes VAR=/tmp/x a:/b C:/Windows'
typed_and_seen "printf 'LITERAL_OUT:%s\\n' '$LIT'" "LITERAL_OUT:$LIT"
check 'guarded send-keys -l delivers POSIX-looking text unchanged' $?

env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL "$SHIM_DIR/tmux" send-keys -t "$TARGET" -l "printf 'UNGUARDED_OUT:%s\\n' '$LIT'" >/dev/null 2>&1
fm_backend_tmux_send_key "$TARGET" Enter
sleep 1
unguarded_line=$(fm_backend_tmux_capture "$TARGET" 200 | tr -d '\r' | grep 'UNGUARDED_OUT:' | grep -v printf | tail -n 1)
measure 'unguarded send-keys -l (MSYS argument conversion left on)' "${unguarded_line:-<no output>}"

# --- 5. live working directory, Windows path flavor ------------------------------

WT="$TMP_ROOT/wt dir"
mkdir -p "$WT"
fm_backend_tmux_send_literal "$TARGET" "cd '$WT'" && fm_backend_tmux_send_key "$TARGET" Enter
raw_path=$(tmux display-message -p -t "$TARGET" '#{pane_current_path}')
cwd_matches() {
  local got
  got=$(fm_backend_tmux_current_path "$TARGET") || return 1
  [ -n "$got" ] || return 1
  [ "$(cygpath -m "$got" | tr '[:upper:]' '[:lower:]')" = "$(cygpath -m "$WT" | tr '[:upper:]' '[:lower:]')" ]
}
wait_for 15 cwd_matches
check 'current_path follows a cd and normalizes to a path Git Bash can use' $? "got '$(fm_backend_tmux_current_path "$TARGET")', want '$WT'"
raw_path=$(tmux display-message -p -t "$TARGET" '#{pane_current_path}')
measure 'raw #{pane_current_path} after cd' "$(visible "$raw_path")"
measure 'fm_backend_tmux_current_path after cd' "$(visible "$(fm_backend_tmux_current_path "$TARGET")")"
norm_path=$(fm_backend_tmux_current_path "$TARGET")
if [ -d "$norm_path" ]; then rc=0; else rc=1; fi
check 'the normalized current_path is an existing directory in Git Bash' "$rc" "'$norm_path'"

# --- 6. agent liveness: classification by pane_current_command ------------------

# A copy of an MSYS binary under an agent name stands in for a harness process:
# psmux names a pane by the executable's file stem, which is all the classifier
# reads. The copy runs from AGENT_DIR so the Windows-side census can find it.
cp "$(command -v sleep)" "$AGENT_DIR/claude.exe"
cp "$(command -v sleep)" "$AGENT_DIR/node.exe"

check_eq 'an idle Git Bash task window is a dead agent (shell only)' "$(fm_backend_tmux_agent_state "$TARGET")" dead

fm_backend_tmux_send_literal "$TARGET" "'$AGENT_DIR/claude.exe' 300" && fm_backend_tmux_send_key "$TARGET" Enter
agent_name() { fm_psmux_normalize_name "$(fm_backend_tmux_current_command "$TARGET")"; }
agent_is_claude() { [ "$(agent_name)" = claude ]; }
wait_for 20 agent_is_claude
check 'a claude.exe child makes pane_current_command read claude' $? "got '$(fm_backend_tmux_current_command "$TARGET")'"
measure 'pane_current_command while a claude.exe child runs' "$(visible "$(fm_backend_tmux_current_command "$TARGET")")"
check_eq 'agent_state reports alive for it' "$(fm_backend_tmux_agent_state "$TARGET")" alive
measure 'Windows processes under the agent directory while it runs' "$(win_agent_count)"

fm_backend_tmux_send_key "$TARGET" C-c
back_to_bash() { [ "$(agent_name)" = bash ]; }
wait_for 20 back_to_bash
check 'C-c ends the child and the pane reads bash again' $? "got '$(fm_backend_tmux_current_command "$TARGET")'"
check_eq 'agent_state reports dead again after the child exits' "$(fm_backend_tmux_agent_state "$TARGET")" dead

fm_backend_tmux_send_literal "$TARGET" "'$AGENT_DIR/node.exe' 300" && fm_backend_tmux_send_key "$TARGET" Enter
agent_is_node() { [ "$(agent_name)" = node ]; }
wait_for 20 agent_is_node
check 'a node.exe child makes pane_current_command read node' $? "got '$(fm_backend_tmux_current_command "$TARGET")'"
check_eq 'a bare node is ambiguous, never dead' "$(fm_backend_tmux_agent_state "$TARGET")" ambiguous
fm_backend_tmux_send_key "$TARGET" C-c
wait_for 20 back_to_bash || true

# --- 7. endpoint close reaps the pane's whole process tree -----------------------

fm_backend_tmux_send_literal "$TARGET" "'$AGENT_DIR/claude.exe' 300" && fm_backend_tmux_send_key "$TARGET" Enter
wait_for 20 agent_is_claude || true
running_before=$(win_agent_count)
measure 'Windows processes under the agent directory before the window is killed' "$running_before"
case "$running_before" in ''|*[!0-9]*|0) rc=1 ;; *) rc=0 ;; esac
check 'the census sees the running child before the kill (the proof is not vacuous)' "$rc" "census='$running_before'"

fm_backend_tmux_kill "$TARGET"
check 'kill of a live task window succeeds' $?
gone() { [ "$(win_agent_count)" = 0 ]; }
wait_for 20 gone
check 'kill-window ends the pane process tree (no child outlives the window)' $? "census='$(win_agent_count)'"
fm_backend_tmux_window_inventory "$session" | grep -qxF -- "$WNAME"
check_fails 'the killed window is gone from the inventory' $?
fm_backend_tmux_kill "$TARGET"
check 'killing the already-gone window is a silent success' $?
check_eq 'agent_state of the killed window is missing' "$(fm_backend_tmux_agent_state "$TARGET")" missing

# --- 8. whole-session loss -----------------------------------------------------

tmux kill-session -t firstmate >/dev/null 2>&1
check 'kill-session removes the session' $?
sleep 1
dead_out=$(LC_ALL=C command tmux list-windows -t =firstmate 2>&1)
measure 'list-windows after the last session was killed' "rc=$? $(visible "$dead_out")"
fm_backend_tmux_kill "$TARGET"
check 'killing a window of a vanished session is a silent success' $?
check_eq 'agent_state of a vanished session is missing' "$(fm_backend_tmux_agent_state "$TARGET")" missing

if [ "$FAILS" -ne 0 ]; then
  printf 'not ok - fm-backend-psmux-live-e2e: %d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
pass 'fm-backend-psmux-live-e2e'
