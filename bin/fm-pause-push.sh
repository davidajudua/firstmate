#!/usr/bin/env bash
# fm-pause-push.sh - push a paused ship task's branch to its project's origin.
#
# Usage:
#   fm-pause-push.sh scan
#
# A ship task whose declared wait is a `paused:` line (status_declared_wait_line
# and status_is_paused in bin/fm-classify-lib.sh own that reading) gets one plain
# `git push origin refs/heads/<branch>:refs/heads/<branch>` of its existing task
# branch, so paused work also lives on the remote while the worker waits.
# `scan` visits every task record in this home and attempts each paused line
# once; bin/fm-watch.sh runs it only when a paused task is due.
# Transient current-state deferrals retry after FM_PAUSE_PUSH_RETRY_SECS
# (default 300), without consuming the paused line.
#
# The push never forces, never deletes a ref, never creates a commit, never
# opens a pull request, and never targets the project's default branch.
# Uncommitted and untracked files are left exactly as they are and reported.
# A rejected push is reported and never retried with force; a push refused only
# because the remote branch already contains this copy's HEAD reads `behind`,
# because the work is already on the remote.
# The push runs with the repository's own hooks and is bounded by
# FM_PAUSE_PUSH_TIMEOUT_SECS (default 30, valid 1..300) with credential prompts
# off, so a stuck network or credential prompt cannot hold the watcher.
# The worker's pause is its own status line, so nothing here can block it.
#
# Tasks this never pushes, silently: a scout or secondmate record, a local-only
# project, a forge=external or forge=gerrit project (their review tool owns
# publication), a record with no branch= or whose worktree is not a git
# checkout, and a task whose current state from bin/fm-crew-state.sh is
# anything but paused. That last gate keeps this push out of an active or
# gate-parked no-mistakes run, which owns the branch's publication and pushes
# it with its own lease. A ship task that should have been pushed but was not -
# detached HEAD, a branch other than its recorded one, the default branch, no
# origin remote, or firstmate's own repository without publication authority
# (fm_role_gate_self_publish in bin/fm-role-lib.sh) - is reported as not-pushed.
#
# Each attempt replaces state/<id>.pause-push with key=value lines:
#   line=<cksum of the paused line>  outcome=<outcome>  branch=<branch>
#   head=<sha>  dirty=<count>  at=<epoch>  detail=<text>
# where outcome is one of skipped, pushed, up-to-date, behind, rejected,
# failed, not-pushed, or deferred. A rejected, failed, or not-pushed outcome, or any
# dirty file, appends one `check: pause-push <id> ...` wake row keyed
# pause-push:<id>:<line> and prints `actionable: <payload>`; the watcher wakes
# firstmate on that output. bin/fm-teardown.sh removes the record.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"

CREW_STATE_BIN="${FM_PAUSE_PUSH_CREW_STATE_BIN:-$FM_CREW_STATE_BIN}"
PAUSE_PUSH_TIMEOUT=${FM_PAUSE_PUSH_TIMEOUT_SECS:-30}
case "$PAUSE_PUSH_TIMEOUT" in ''|*[!0-9]*|0) PAUSE_PUSH_TIMEOUT=30 ;; esac
[ "$PAUSE_PUSH_TIMEOUT" -le 300 ] || PAUSE_PUSH_TIMEOUT=300

PAUSE_PUSH_RETRY=${FM_PAUSE_PUSH_RETRY_SECS:-300}
case "$PAUSE_PUSH_RETRY" in ''|*[!0-9]*) PAUSE_PUSH_RETRY=300 ;; esac

usage() {
  printf 'usage: fm-pause-push.sh scan\n' >&2
  exit 2
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

record_value() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-1024
}

write_record() {  # <id> <line> <outcome> <branch> <head> <dirty> <detail>
  local record="$STATE/$1.pause-push" tmp
  tmp=$(mktemp "$STATE/.pause-push.XXXXXX") || return 1
  if {
    printf 'line=%s\n' "$2"
    printf 'outcome=%s\n' "$3"
    printf 'branch=%s\n' "$(clean_field "$4")"
    printf 'head=%s\n' "$5"
    printf 'dirty=%s\n' "$6"
    printf 'at=%s\n' "$(date +%s)"
    printf 'detail=%s\n' "$(clean_field "$7")"
  } > "$tmp" && mv -f -- "$tmp" "$record"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

default_branch() {  # <worktree>
  local ref
  ref=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=
  printf '%s\n' "${ref#origin/}"
}

# Attempt one task. Prints `actionable: <payload>` when firstmate must hear the
# result.
attempt() {  # <id>
  local id=$1 meta="$STATE/$1.meta" status="$STATE/$1.status"
  local line hash kind mode forge wt state branch current default dirty_raw dirty_count=0
  local dirty_list='' head='' outcome detail out rc payload deferred_at
  [ -f "$meta" ] || return 0
  line=$(status_declared_wait_line "$status")
  status_is_paused "$line" || return 0
  hash=$(printf '%s' "$line" | cksum | cut -d' ' -f1)
  if [ "$(record_value "$STATE/$id.pause-push" line)" = "$hash" ]; then
    [ "$(record_value "$STATE/$id.pause-push" outcome)" = deferred ] || return 0
    deferred_at=$(record_value "$STATE/$id.pause-push" at)
    case "$deferred_at" in ''|*[!0-9]*) deferred_at=0 ;; esac
    [ "$(( $(date +%s) - deferred_at ))" -ge "$PAUSE_PUSH_RETRY" ] || return 0
  fi

  kind=$(meta_value "$meta" kind)
  mode=$(meta_value "$meta" mode)
  forge=$(meta_value "$meta" forge)
  wt=$(meta_value "$meta" worktree)
  branch=$(meta_value "$meta" branch)
  if [ "${kind:-ship}" != ship ] || [ "$mode" = local-only ] \
    || [ "$forge" = external ] || [ "$forge" = gerrit ] || [ -z "$branch" ] \
    || [ -z "$wt" ] || ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    write_record "$id" "$hash" skipped "" "" 0 "not a pushable ship task"
    return 0
  fi
  state=$(fm_run_timed "$PAUSE_PUSH_TIMEOUT" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_NO_FORGE=1 "$CREW_STATE_BIN" "$id" 2>/dev/null) || state=
  case "$state" in
    'state: paused '*) ;;
    *)
      write_record "$id" "$hash" deferred "$branch" "" 0 "current state is not paused or unavailable"
      return 0
      ;;
  esac

  current=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || current=
  head=$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null) || head=

  if dirty_raw=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null); then
    if [ -n "$dirty_raw" ]; then
      dirty_count=$(printf '%s\n' "$dirty_raw" | wc -l | tr -d '[:space:]')
      dirty_list=$(printf '%s\n' "$dirty_raw" | head -n 10 | sed 's/^...//' | tr '\n' ' ')
    fi
  else
    dirty_count=unknown
  fi

  default=$(default_branch "$wt")
  if [ -z "$current" ]; then
    outcome=not-pushed detail="worktree is on a detached HEAD"
  elif [ "$current" != "$branch" ]; then
    outcome=not-pushed detail="worktree is on $current, not the recorded branch $branch"
  elif [ "$branch" = "$default" ] || [ "$branch" = main ] || [ "$branch" = master ]; then
    outcome=not-pushed detail="refusing to push the default branch $branch"
  elif ! git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    outcome=not-pushed detail="project has no origin remote"
  else
    rc=0
    fm_role_gate_self_publish "$FM_HOME" "$CONFIG" "$(meta_value "$meta" project)" "$FM_ROOT" \
      "$(meta_value "$meta" upstream_consent)" || rc=$?
    if [ "$rc" -eq 1 ]; then
      outcome=not-pushed detail="firstmate repository publication not authorized: ${FM_ROLE_PUB_DENIAL:-no maintainer scope or task consent}"
    else
      rc=0
      out=$(fm_run_timed "$PAUSE_PUSH_TIMEOUT" env GIT_TERMINAL_PROMPT=0 \
        git -C "$wt" push --porcelain origin "refs/heads/$branch:refs/heads/$branch" 2>&1) || rc=$?
      if [ "$rc" -eq 0 ]; then
        case "$out" in
          *$'\n='*|=*) outcome=up-to-date detail="origin/$branch already at HEAD" ;;
          *) outcome=pushed detail="pushed $branch to origin" ;;
        esac
      elif [ "$rc" -eq 124 ]; then
        outcome=failed detail="push timed out after ${PAUSE_PUSH_TIMEOUT}s"
      elif printf '%s\n' "$out" | grep -q '^!'; then
        if [ -n "$head" ] \
          && fm_run_timed "$PAUSE_PUSH_TIMEOUT" env GIT_TERMINAL_PROMPT=0 \
            git -C "$wt" fetch --quiet origin "refs/heads/$branch" >/dev/null 2>&1 \
          && git -C "$wt" merge-base --is-ancestor "$head" FETCH_HEAD 2>/dev/null; then
          outcome=behind detail="origin/$branch already contains HEAD"
        else
          outcome=rejected
          detail="origin rejected $branch ($(printf '%s\n' "$out" | awk -F '\t' '/^!/ { print $3; exit }')); not retried with force"
        fi
      else
        outcome=failed detail="push failed: $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 2 | tr '\n' ' ')"
      fi
    fi
  fi

  write_record "$id" "$hash" "$outcome" "$branch" "$head" "$dirty_count" "$detail" || return 1
  case "$outcome:$dirty_count" in
    rejected:*|failed:*|not-pushed:*) ;;
    *:0) return 0 ;;
  esac
  payload="check: pause-push $id $outcome branch=$branch - $detail"
  if [ "$dirty_count" != 0 ]; then
    payload="$payload; $dirty_count uncommitted or untracked file(s) left in place: $dirty_list"
  fi
  payload=$(clean_field "$payload")
  fm_wake_append check "pause-push:$id:$hash" "$payload" || return 1
  printf 'actionable: %s\n' "$payload"
}

case "${1:-}" in
  scan)
    [ "$#" -eq 1 ] || usage
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      attempt "$id" || printf 'fm-pause-push: could not record the result for %s\n' "$id" >&2
    done
    ;;
  *) usage ;;
esac
