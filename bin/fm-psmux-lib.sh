#!/usr/bin/env bash
# fm-psmux-lib.sh - psmux awareness for the tmux session-provider backend.
#
# psmux (https://github.com/psmux/psmux) is a native Windows terminal
# multiplexer that speaks tmux's command language and installs itself as
# `psmux`, `pmux`, and `tmux`. This file is the single owner of every decision
# that differs when the `tmux` Firstmate drives is psmux running under Git Bash
# on Windows: detection, process-name vocabulary, path flavor, the shell a task
# window runs, and the MSYS argument-conversion guard. Everything here engages
# only when fm_psmux_active is true, so Linux and macOS tmux behavior is
# untouched. docs/tmux-backend.md "psmux on Windows" owns the user-facing
# contract and docs/verification/runtime-backends.md "psmux" the evidence.
#
# Sourced by bin/backends/tmux.sh, bin/fm-tmux-lib.sh, and bin/fm-bootstrap.sh;
# sourcing has no side effect beyond defining functions - and, only when psmux
# is active, the `tmux` argument-conversion wrapper at the bottom.
#
# Detection (fm_psmux_active), first match wins:
#   1. FM_TMUX_FLAVOR=psmux|tmux  explicit operator or test override.
#   2. PSMUX_SESSION non-empty    psmux plants it in every pane it spawns.
#   3. `tmux -V`                  psmux prints a second line starting `psmux `;
#      real tmux prints one line. Probed only on a Windows shell (Git Bash,
#      MSYS2, Cygwin) or when FM_PSMUX_PROBE=1, and cached in FM_PSMUX_PROBED so
#      a re-sourcing subshell never pays another fork.
# FM_PSMUX_HOST=windows|posix overrides the host-OS read (tests, odd shells).
# FM_PSMUX_BASH names the bash a task window runs (default: this shell's own).

_FM_PSMUX_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_PSMUX_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_PSMUX_LIB_DIR=.

# fm_psmux_host_is_windows: true when this shell is Git Bash, MSYS2, or Cygwin.
fm_psmux_host_is_windows() {
  case "${FM_PSMUX_HOST:-}" in
    windows) return 0 ;;
    posix) return 1 ;;
  esac
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*) return 0 ;;
  esac
  return 1
}

fm_psmux_active() {
  local version
  case "${FM_TMUX_FLAVOR:-}" in
    psmux) return 0 ;;
    tmux) return 1 ;;
  esac
  [ -z "${PSMUX_SESSION:-}" ] || return 0
  case "${FM_PSMUX_PROBED:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if ! fm_psmux_host_is_windows && [ "${FM_PSMUX_PROBE:-}" != 1 ]; then
    return 1
  fi
  command -v tmux >/dev/null 2>&1 || return 1
  version=$(LC_ALL=C command tmux -V 2>/dev/null) || version=
  case "$version" in
    *$'\n'psmux\ *|psmux\ *) FM_PSMUX_PROBED=1 ;;
    *) FM_PSMUX_PROBED=0 ;;
  esac
  export FM_PSMUX_PROBED
  [ "$FM_PSMUX_PROBED" = 1 ]
}

# fm_psmux_install_hint: the install command bootstrap prints for psmux. The
# commands are the package managers psmux's own README lists (winget first).
fm_psmux_install_hint() {
  printf '%s' "winget install psmux  # or: choco install psmux, cargo install psmux, scoop (see https://github.com/psmux/psmux)"
}

# fm_psmux_normalize_name: a Windows process name as psmux reports it
# (`#{pane_current_command}` is the executable's file stem with its real
# casing: `pwsh`, `PING`, `claude`) folded to the lowercase, extension-free,
# directory-free form the shared vocabulary uses.
fm_psmux_normalize_name() {  # <name>
  local name=${1%$'\r'}
  name=${name##*[/\\]}
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  name=${name%.exe}
  printf '%s' "$name"
}

# fm_psmux_classify_name: agent|shell|other for one psmux foreground command
# name. psmux panes default to PowerShell, so pwsh/powershell/cmd join the
# shells bin/fm-agent-process-lib.sh already knows; every other verdict is that
# owner's, run on the normalized name so `claude.exe` and `Claude` read as
# `claude`. A bare `node` stays `other` (ambiguous), never dead.
fm_psmux_classify_name() {  # <name>
  local name
  if ! declare -F fm_agent_process_classify_name >/dev/null; then
    # shellcheck source=bin/fm-agent-process-lib.sh
    . "${_FM_PSMUX_LIB_DIR:-/}/fm-agent-process-lib.sh"
  fi
  name=$(fm_psmux_normalize_name "$1")
  case "$name" in
    pwsh|powershell|cmd|command|nu|elvish|xonsh|busybox) printf 'shell' ;;
    *) fm_agent_process_classify_name "$name" ;;
  esac
}

# Path flavor. psmux answers #{pane_current_path} with a Windows path
# (`C:\Users\x\wt`) and expects Windows paths for `new-window -c`; Git Bash
# works in POSIX paths (`/c/Users/x/wt`). cygpath converts; without it (a
# non-Windows test host) the value passes through unchanged.
fm_psmux_path_to_posix() {  # <path>
  [ -n "${1:-}" ] || return 0
  command -v cygpath >/dev/null 2>&1 || { printf '%s\n' "$1"; return 0; }
  cygpath -u -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

fm_psmux_path_to_native() {  # <path> -> mixed form (C:/Users/x/wt)
  [ -n "${1:-}" ] || return 0
  command -v cygpath >/dev/null 2>&1 || { printf '%s\n' "$1"; return 0; }
  cygpath -m -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

# fm_psmux_pane_shell: the Windows-form path of the bash a task window runs.
# New psmux panes default to PowerShell, but every command Firstmate types into
# a task window is bash syntax, so the window launches Git Bash explicitly
# (as the command of `new-window`, never via `set -g default-shell`, which
# would edit the user's live psmux session). Defaults to the bash running this
# script, which is guaranteed to exist and to be the intended flavor.
fm_psmux_pane_shell() {
  local sh=${FM_PSMUX_BASH:-} native
  [ -n "$sh" ] || sh=${BASH:-}
  [ -n "$sh" ] || sh=$(command -v bash 2>/dev/null) || return 1
  native=$(fm_psmux_path_to_native "$sh")
  # cygpath maps the POSIX name without its extension; psmux execs the argv
  # directly, so name the executable file.
  case "$native" in
    *.[Ee][Xx][Ee]) ;;
    *) native="$native.exe" ;;
  esac
  printf '%s\n' "$native"
}

# Git Bash rewrites POSIX-looking arguments (`/no-mistakes`, `VAR=/tmp/x`,
# `a:/b`) into Windows paths when it starts a native executable, which would
# silently corrupt text typed into a pane. psmux IS a native executable, so
# under psmux every tmux call runs with that conversion disabled. Functions are
# inherited by subshells and command substitutions; `command tmux` still
# resolves the real binary, or a PATH fake in tests.
if fm_psmux_active; then
  tmux() {
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command tmux "$@"
  }
fi
