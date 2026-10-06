#!/usr/bin/env bash
# tests/fm-psmux.test.sh - portable regression for the psmux-aware tmux backend
# (bin/fm-psmux-lib.sh, bin/backends/tmux.sh, bin/fm-tmux-lib.sh).
#
# psmux is a native Windows tmux whose pane tty, pane pid and pane path are not
# POSIX. This suite cannot run psmux, so it drives the public backend functions
# against a PATH fake that answers the way psmux 3.3.8 does (synthetic
# /dev/pty<id> ttys, Windows pane paths, a second `psmux ` line in `-V`) plus a
# fake cygpath and a decoy `ps` that would lie if it were consulted. The real
# psmux proof is the windows-latest job in .github/workflows/windows-psmux.yml.
#
# Each case runs in its own bash so detection, which is decided when the
# library is sourced, is exercised exactly as a script would meet it.
# The single-quoted snippets handed to run_case are deliberately unexpanded here:
# they are evaluated by the child shell, which owns the variables they name.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-psmux) || exit 1
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
# A psmux-shaped tmux: state lives in $FM_FAKE_STATE, every call is logged.
set -u
S=${FM_FAKE_STATE:?FM_FAKE_STATE required}
mkdir -p "$S"
args=("$@")
{ printf 'call'; for a in "${args[@]}"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$S/calls"
printf 'conv=%s pathconv=%s\n' "${MSYS2_ARG_CONV_EXCL:-}" "${MSYS_NO_PATHCONV:-}" >> "$S/env"
touch "$S/windows"
eol='\n'
[ "${FM_FAKE_CRLF:-}" != 1 ] || eol='\r\n'

if [ "${1:-}" = -V ]; then
  if [ "${FM_FAKE_VERSION:-psmux}" = psmux ]; then
    printf 'tmux 3.3.8\npsmux 3.3.8 (fake 2026-01-01)\n'
  else
    printf 'tmux 3.5a\n'
  fi
  exit 0
fi

# Window lookup: @id, session:name, =session:=name, or a bare name.
resolve() {  # <target>
  local t=${1#=} name
  case "$t" in
    @*) name=$(awk -F'\t' -v i="$t" '$2 == i { print $2 }' "$S/windows") ;;
    *:*) t=${t#*:}; t=${t#=}; name=$(awk -F'\t' -v n="$t" '$1 == n { print $2 }' "$S/windows") ;;
    *) name=$(awk -F'\t' -v n="$t" '$1 == n { print $2 }' "$S/windows") ;;
  esac
  [ -n "$name" ] || return 1
  printf '%s' "$name"
}
session_absent() {
  if [ -f "$S/noserver" ]; then
    echo "psmux: no server running on C:\\Users\\fake\\.psmux" >&2
    return 0
  fi
  if [ ! -f "$S/session" ]; then
    echo "psmux: can't find session: ${1:-?}" >&2
    return 0
  fi
  return 1
}

cmd=${1:-}
shift || true
case "$cmd" in
  has-session)
    [ -f "$S/session" ] && [ ! -f "$S/noserver" ]
    exit $? ;;
  new-session)
    name=
    while [ "$#" -gt 0 ]; do case "$1" in -s) shift; name=$1 ;; esac; shift; done
    printf '%s\n' "${name:-0}" > "$S/session"
    exit 0 ;;
  list-windows)
    t= all=0 fmt=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift; t=$1 ;; -a) all=1 ;; -F) shift; fmt=$1 ;; esac
      shift
    done
    if session_absent "$t"; then exit 1; fi
    while IFS=$'\t' read -r name id; do
      [ -n "$name" ] || continue
      case "$fmt" in
        '#{session_name}:#{window_name}') printf "%s:%s$eol" "$(cat "$S/session")" "$name" ;;
        *) printf "%s$eol" "$name" ;;
      esac
    done < "$S/windows"
    exit 0 ;;
  new-window)
    name= dir= fmt= print=0 ddash=0 shellcmd=()
    while [ "$#" -gt 0 ]; do
      if [ "$ddash" = 1 ]; then shellcmd+=("$1"); shift; continue; fi
      case "$1" in
        -n) shift; name=$1 ;;
        -c) shift; dir=$1 ;;
        -F) shift; fmt=$1 ;;
        -t) shift ;;
        -dP|-Pd) print=1 ;;
        -d) ;;
        -P) print=1 ;;
        --) ddash=1 ;;
      esac
      shift
    done
    n=$(( $(wc -l < "$S/windows") + 1 ))
    id="@$n"
    printf '%s\t%s\n' "$name" "$id" >> "$S/windows"
    printf '%s\n' "$dir" > "$S/dir.$id"
    { for a in "${shellcmd[@]}"; do printf '[%s]' "$a"; done; printf '\n'; } > "$S/shellcmd.$id"
    [ -f "$S/cmd.default" ] && cp "$S/cmd.default" "$S/cmd.$id"
    [ -f "$S/path.default" ] && cp "$S/path.default" "$S/path.$id"
    [ "$print" = 1 ] && [ "$fmt" = '#{window_id}' ] && printf "%s$eol" "$id"
    exit 0 ;;
  display-message)
    t= fmt=
    while [ "$#" -gt 0 ]; do
      case "$1" in -p) ;; -t) shift; t=$1 ;; *) fmt=$1 ;; esac
      shift
    done
    id=$(resolve "$t") || { echo "psmux: can't find window: $t" >&2; exit 1; }
    case "$fmt" in
      '#{pane_current_command}') cat "$S/cmd.$id" 2>/dev/null || echo bash ;;
      '#{pane_current_path}') cat "$S/path.$id" 2>/dev/null || echo 'C:\Users\fake\proj' ;;
      '#{pane_tty}') printf '/dev/pty%s\n' "${id#@}" ;;
      '#{pane_pid}') printf '4242\n' ;;
      '#{pane_id}') printf '%%%s\n' "${id#@}" ;;
      '#{cursor_y}') printf '0\n' ;;
      *) printf '\n' ;;
    esac
    exit 0 ;;
  send-keys)
    t= lit=0 rest=()
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift; t=$1 ;; -l) lit=1 ;; *) rest+=("$1") ;; esac
      shift
    done
    id=$(resolve "$t") || { echo "psmux: can't find window: $t" >&2; exit 1; }
    printf 'lit=%s text=%s\n' "$lit" "${rest[*]}" >> "$S/sent.$id"
    exit 0 ;;
  capture-pane)
    t=
    while [ "$#" -gt 0 ]; do case "$1" in -t) shift; t=$1 ;; esac; shift; done
    id=$(resolve "$t") || { echo "psmux: can't find window: $t" >&2; exit 1; }
    cat "$S/screen.$id" 2>/dev/null
    exit 0 ;;
  kill-window)
    t=
    while [ "$#" -gt 0 ]; do case "$1" in -t) shift; t=$1 ;; esac; shift; done
    id=$(resolve "$t") || { echo "psmux: can't find window: $t" >&2; exit 1; }
    awk -F'\t' -v i="$id" '$2 != i' "$S/windows" > "$S/windows.new" && mv "$S/windows.new" "$S/windows"
    exit 0 ;;
  set-window-option) exit 0 ;;
esac
echo "psmux: unknown command: $cmd" >&2
exit 1
SH
chmod +x "$FAKEBIN/tmux"

# cygpath for a host that has none: C:\a\b and C:/a/b <-> /c/a/b; a POSIX path
# with no drive maps under a pretend Git root, as /usr/bin/bash does on Windows.
cat > "$FAKEBIN/cygpath" <<'SH'
#!/usr/bin/env bash
mode=$1
shift
[ "${1:-}" != -- ] || shift
p=$1
case "$mode" in
  -u)
    case "$p" in
      [A-Za-z]:[\\/]*)
        d=$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')
        rest=${p#?:}
        rest=${rest//\\//}
        printf '/%s%s\n' "$d" "$rest" ;;
      *) printf '%s\n' "$p" ;;
    esac ;;
  -m)
    case "$p" in
      [A-Za-z]:[\\/]*) p=${p//\\//}; printf '%s\n' "$p" ;;
      /[a-z]/*) printf '%s:%s\n' "$(printf '%s' "${p:1:1}" | tr '[:lower:]' '[:upper:]')" "${p:2}" ;;
      /*) printf 'C:/fake/git%s\n' "$p" ;;
      *) printf '%s\n' "$p" ;;
    esac ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/cygpath"

# The decoy `ps`: if the backend ever consults a process table under psmux, this
# reports a harness in the foreground and logs that it was asked.
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_STATE:-}" ] || printf 'ps %s\n' "$*" >> "$FM_FAKE_STATE/ps.log"
case " $* " in
  *" -t "*) printf '  100   100   100 claude\n' ;;
  *" -p "*) printf 'claude --resume\n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/ps"

new_state() {
  mktemp -d "$TMP_ROOT/state.XXXXXX"
}

# run_case <state> <env-assignment>... -- <bash snippet>
# Sources the tmux backend in a fresh bash with the fakes first on PATH.
run_case() {
  local state=$1 snippet envs=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  snippet=$1
  env -u PSMUX_SESSION -u FM_TMUX_FLAVOR -u FM_PSMUX_PROBED -u FM_PSMUX_PROBE -u FM_PSMUX_HOST \
    -u FM_PSMUX_BASH -u TMUX \
    PATH="$FAKEBIN:$PATH" FM_FAKE_STATE="$state" ROOT="$ROOT" "${envs[@]}" \
    bash -c 'set -u; . "$ROOT/bin/fm-backend.sh"; fm_backend_source tmux || exit 99; '"$snippet" 2>&1
}

PSMUX=(PSMUX_SESSION=fake-session)
NATIVE=(FM_TMUX_FLAVOR=tmux)

# --- detection ---------------------------------------------------------------
state=$(new_state)
out=$(run_case "$state" "${PSMUX[@]}" -- 'fm_psmux_active && echo active || echo inactive')
assert_equals active "$out" "PSMUX_SESSION marks psmux active"

state=$(new_state)
out=$(run_case "$state" -- 'fm_psmux_active && echo active || echo inactive')
assert_equals inactive "$out" "a POSIX host with no psmux signal is not psmux"
[ ! -s "$state/calls" ] || fail "an inactive POSIX host must not spend a tmux call probing for psmux: $(cat "$state/calls")"

state=$(new_state)
out=$(run_case "$state" "${PSMUX[@]}" "${NATIVE[@]}" -- 'fm_psmux_active && echo active || echo inactive')
assert_equals inactive "$out" "FM_TMUX_FLAVOR=tmux overrides PSMUX_SESSION"

state=$(new_state)
out=$(run_case "$state" FM_TMUX_FLAVOR=psmux -- 'fm_psmux_active && echo active || echo inactive')
assert_equals active "$out" "FM_TMUX_FLAVOR=psmux forces psmux"

state=$(new_state)
out=$(run_case "$state" FM_PSMUX_HOST=windows -- 'fm_psmux_active; fm_psmux_active; fm_psmux_active && echo "active probed=$FM_PSMUX_PROBED"')
assert_equals "active probed=1" "$out" "tmux -V with a psmux second line is detected on a Windows shell"
assert_equals 1 "$(grep -c '\[-V\]' "$state/calls")" "the tmux -V probe is cached after its first use"

state=$(new_state)
out=$(run_case "$state" FM_PSMUX_HOST=windows FM_FAKE_VERSION=tmux -- 'fm_psmux_active && echo active || echo "inactive probed=$FM_PSMUX_PROBED"')
assert_equals "inactive probed=0" "$out" "a one-line tmux -V is real tmux, not psmux"

state=$(new_state)
out=$(run_case "$state" FM_PSMUX_PROBE=1 -- 'fm_psmux_active && echo active || echo inactive')
assert_equals active "$out" "FM_PSMUX_PROBE=1 probes tmux -V on a POSIX host"
pass "psmux detection: PSMUX_SESSION, tmux -V second line, overrides, and a cached probe"

# --- process-name classification ----------------------------------------------
state=$(new_state)
classes=$(run_case "$state" "${PSMUX[@]}" -- '
for n in claude Claude claude.exe CLAUDE.EXE codex.exe Pi pwsh PowerShell powershell.exe cmd CMD.EXE bash bash.exe \
  "C:\Program Files\Git\usr\bin\bash.exe" PING node notaharness musescore; do
  printf "%s=%s\n" "$n" "$(fm_psmux_classify_name "$n")"
done')
expected='claude=agent
Claude=agent
claude.exe=agent
CLAUDE.EXE=agent
codex.exe=agent
Pi=agent
pwsh=shell
PowerShell=shell
powershell.exe=shell
cmd=shell
CMD.EXE=shell
bash=shell
bash.exe=shell
C:\Program Files\Git\usr\bin\bash.exe=shell
PING=other
node=other
notaharness=other
musescore=other'
assert_equals "$expected" "$classes" "psmux process names classify with .exe and case stripped, PowerShell and cmd as shells"
pass "psmux process-name vocabulary: claude.exe/pwsh/powershell/cmd/bash classify, node and strangers stay other"

# --- agent state from pane_current_command (never ps -t) ------------------------
agent_state_for() {  # <state> <env...> -- <pane_current_command>; prints the verdict
  local state=$1 name envs=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  name=$1
  printf '%s\n' "$name" > "$state/cmd.default"
  run_case "$state" "${envs[@]}" -- '
fm_backend_tmux_create_task fm-sess fm-t /c/proj >/dev/null || exit 98
fm_backend_tmux_agent_state fm-sess:fm-t'
}
for pair in claude:alive Claude:alive claude.exe:alive pwsh:dead powershell:dead cmd:dead bash:dead PING:ambiguous node:ambiguous; do
  name=${pair%%:*}
  want=${pair#*:}
  state=$(new_state)
  printf 'fm-sess\n' > "$state/session"
  got=$(agent_state_for "$state" "${PSMUX[@]}" -- "$name")
  assert_equals "$want" "$got" "psmux pane_current_command '$name' classifies as $want"
  [ ! -e "$state/ps.log" ] || fail "psmux agent state for '$name' consulted ps: $(cat "$state/ps.log")"
done
pass "psmux agent state falls back to pane_current_command and never reads a process table"

state=$(new_state)
printf 'fm-sess\n' > "$state/session"
got=$(run_case "$state" "${PSMUX[@]}" -- 'fm_backend_tmux_agent_state fm-sess:nope')
assert_equals missing "$got" "an absent psmux window is missing"
state=$(new_state)
: > "$state/noserver"
got=$(run_case "$state" "${PSMUX[@]}" -- 'fm_backend_tmux_agent_state fm-sess:nope')
assert_equals missing "$got" "psmux's 'no server running' answer is a missing endpoint"
state=$(new_state)
printf 'fm-sess\n' > "$state/session"
printf 'claude\n' > "$state/cmd.default"
got=$(run_case "$state" "${PSMUX[@]}" FM_FAKE_CRLF=1 -- '
fm_backend_tmux_create_task fm-sess fm-t /c/proj >/dev/null || exit 98
fm_backend_tmux_agent_state fm-sess:fm-t')
assert_equals alive "$got" "CRLF window listings from a native tmux still match the exact window"
pass "psmux missing-window and CRLF inventory handling"

# The same fake with psmux switched off must still read ps -t: Linux/macOS tmux
# keeps the foreground-process-group probe, and the two signals really diverge
# (pane_current_command says shell while the decoy foreground group says agent).
state=$(new_state)
printf 'fm-sess\n' > "$state/session"
got=$(agent_state_for "$state" "${PSMUX[@]}" -- pwsh)
assert_equals dead "$got" "precondition: psmux reads the shell command, not the decoy"
state=$(new_state)
printf 'fm-sess\n' > "$state/session"
got=$(agent_state_for "$state" "${NATIVE[@]}" -- bash)
assert_equals alive "$got" "native tmux still trusts the foreground process group over pane_current_command"
grep -q -- '-t pty1' "$state/ps.log" || fail "native tmux no longer asked ps for the pane tty: $(cat "$state/ps.log" 2>/dev/null)"
pass "native tmux keeps ps -t foreground attribution; psmux does not"

# --- pane path normalization ---------------------------------------------------
state=$(new_state)
printf 'fm-sess\n' > "$state/session"
printf 'C:\\Users\\fake\\wt\n' > "$state/path.default"
got=$(run_case "$state" "${PSMUX[@]}" -- '
fm_backend_tmux_create_task fm-sess fm-t /c/proj >/dev/null || exit 98
fm_backend_tmux_current_path fm-sess:fm-t')
assert_equals /c/Users/fake/wt "$got" "psmux's Windows pane path becomes a Git Bash path"
got=$(run_case "$state" "${NATIVE[@]}" -- '
fm_backend_tmux_create_task fm-sess fm-t2 /c/proj >/dev/null || exit 98
fm_backend_tmux_current_path fm-sess:fm-t2')
assert_equals 'C:\Users\fake\wt' "$got" "native tmux paths are passed through untouched"
pass "pane_current_path is normalized with cygpath -u only under psmux"

# --- task window creation ------------------------------------------------------
state=$(new_state)
printf 'fm-sess\n' > "$state/session"
wid=$(run_case "$state" "${PSMUX[@]}" FM_PSMUX_BASH=/usr/bin/bash -- 'fm_backend_tmux_create_task fm-sess fm-t /c/Users/fake/proj')
assert_equals @1 "$wid" "the created psmux window id is returned"
assert_equals '[C:/fake/git/usr/bin/bash.exe][-i]' "$(cat "$state/shellcmd.@1")" "the task window runs Git Bash explicitly, as a direct argv"
assert_equals 'C:/Users/fake/proj' "$(cat "$state/dir.@1")" "new-window -c takes the mixed Windows form of the project path"
err=$(run_case "$state" "${PSMUX[@]}" -- 'fm_backend_tmux_create_task fm-sess fm-t /c/proj; echo "rc=$?"')
assert_contains "$err" "window fm-sess:fm-t already exists" "a duplicate psmux window name is refused"
assert_contains "$err" "rc=1" "a duplicate psmux window name fails"
assert_no_grep 'default-shell' "$state/calls" "the user's psmux default-shell is never changed"

state=$(new_state)
printf 'fm-sess\n' > "$state/session"
wid=$(run_case "$state" "${NATIVE[@]}" -- 'fm_backend_tmux_create_task fm-sess fm-t /c/Users/fake/proj')
assert_equals @1 "$wid" "native tmux window creation is unchanged"
assert_equals '' "$(cat "$state/shellcmd.@1")" "native tmux windows run the user's default shell"
assert_equals '/c/Users/fake/proj' "$(cat "$state/dir.@1")" "native tmux -c keeps the POSIX project path"
pass "psmux task windows launch Git Bash with a Windows start directory; native tmux is unchanged"

state=$(new_state)
printf 'fm-sess\n' > "$state/session"
out=$(run_case "$state" "${PSMUX[@]}" FM_PSMUX_BASH='C:\Program Files\Git\bin\bash.exe' -- 'fm_psmux_pane_shell')
assert_equals 'C:/Program Files/Git/bin/bash.exe' "$out" "a Windows-form FM_PSMUX_BASH is normalized to forward slashes"
pass "FM_PSMUX_BASH override"

# --- MSYS argument conversion guard ---------------------------------------------
state=$(new_state)
printf 'fm-sess\n' > "$state/session"
run_case "$state" "${PSMUX[@]}" -- '
fm_backend_tmux_create_task fm-sess fm-t /c/proj >/dev/null || exit 98
fm_backend_tmux_send_literal fm-sess:fm-t "/no-mistakes VAR=/tmp/x"
fm_backend_tmux_send_text_line fm-sess:fm-t "export GOTMPDIR=/tmp/t"' >/dev/null
assert_grep 'lit=1 text=/no-mistakes VAR=/tmp/x' "$state/sent.@1" "slash-led literal text reaches psmux verbatim"
last_env=$(tail -n 1 "$state/env")
assert_equals "conv=* pathconv=1" "$last_env" "every tmux call runs with MSYS path conversion off under psmux"
state=$(new_state)
printf 'fm-sess\n' > "$state/session"
run_case "$state" "${NATIVE[@]}" -- '
fm_backend_tmux_create_task fm-sess fm-t /c/proj >/dev/null || exit 98
fm_backend_tmux_send_literal fm-sess:fm-t "/no-mistakes"' >/dev/null
assert_equals "conv= pathconv=" "$(tail -n 1 "$state/env")" "native tmux calls are not wrapped"
pass "psmux calls disable MSYS argument conversion; native tmux calls are untouched"

# --- kill and inventory -------------------------------------------------------------
state=$(new_state)
printf 'fm-sess\n' > "$state/session"
out=$(run_case "$state" "${PSMUX[@]}" -- '
fm_backend_tmux_create_task fm-sess fm-t /c/proj >/dev/null || exit 98
fm_backend_tmux_kill fm-sess:fm-t; echo "first=$?"
fm_backend_tmux_kill fm-sess:fm-t; echo "again=$?"
fm_backend_tmux_agent_state fm-sess:fm-t')
assert_contains "$out" "first=0" "closing a live psmux window succeeds"
assert_contains "$out" "again=0" "closing an already-gone psmux window stays a silent success"
assert_contains "$out" "missing" "a closed psmux window reads as missing"
state=$(new_state)
: > "$state/noserver"
out=$(run_case "$state" "${PSMUX[@]}" -- 'fm_backend_tmux_window_inventory fm-sess; echo "rc=$?"')
assert_contains "$out" "rc=2" "psmux's 'no server running' wording is the definitive absent-server verdict"
pass "psmux kill and inventory verdicts"

# --- composer identity probes never touch ps under psmux -------------------------------
state=$(new_state)
printf 'fm-sess\n' > "$state/session"
printf 'Pi\n' > "$state/cmd.default"
out=$(run_case "$state" "${PSMUX[@]}" -- '
fm_backend_tmux_create_task fm-sess fm-t /c/proj >/dev/null || exit 98
printf "some output\n" > "$FM_FAKE_STATE/screen.@1"
fm_tmux_composer_identity fm-sess:fm-t | tr "\t" "|"; echo
fm_tmux_pane_is_cursor fm-sess:fm-t; echo "cursor=$?"')
assert_contains "$out" "pi|idle" "psmux identifies pi from the normalized pane_current_command"
assert_contains "$out" "cursor=1" "psmux has no Cursor foreground attribution"
[ ! -e "$state/ps.log" ] || fail "psmux composer identity probes consulted ps: $(cat "$state/ps.log")"
pass "composer identity probes use pane_current_command under psmux and never ps -t"

printf 'ok - fm-psmux\n'
