#!/usr/bin/env bash
# Behavioral coverage for bin/fm-pause-push.sh: a paused ship task's branch is
# pushed to its origin without force, dirty files are reported and left alone,
# a rejected push is reported, and ineligible tasks are never pushed.
set -u

# shellcheck source=tests/lib.sh
. "/home/david/.no-mistakes/worktrees/12215e17a012/01M661V98Z7P30AR17K05JVK2G/tests/lib.sh"

PAUSE_PUSH="$ROOT/bin/fm-pause-push.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-pause-push)
fm_git_identity fmtest fmtest@example.invalid

# make_task <name> [meta key=val ...]: a home with one ship task whose worktree
# sits on fm/<name> with one commit not yet on origin.
make_task() {
  local name=$1
  shift
  WORLD="$TMP_ROOT/$name"
  HOME_DIR="$WORLD/home"
  REPO="$WORLD/repo"
  WT="$WORLD/wt"
  ORIGIN="$REPO.origin.git"
  BRANCH="fm/$name"
  ID=$name
  mkdir -p "$HOME_DIR"/{state,config,data}
  fm_git_worktree "$REPO" "$WT" "$BRANCH"
  printf 'work\n' > "$WT/work.txt"
  git -C "$WT" add work.txt
  git -C "$WT" commit -qm "task work"
  fm_write_meta "$HOME_DIR/state/$ID.meta" \
    "window=firstmate:fm-$ID" "worktree=$WT" "project=$REPO" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' "branch=$BRANCH" "$@"
  make_crew_state
}

declare_status() {  # <line>
  printf '%s\n' "$1" >> "$HOME_DIR/state/$ID.status"
}

# The current-state read is stubbed: FM_FAKE_CREW_STATE (default paused) is
# what bin/fm-crew-state.sh would report for the task.
make_crew_state() {
  mkdir -p "$WORLD/fakebin"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_CREW_STATE:-paused}"
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
}

pause_push() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_PAUSE_PUSH_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" "$PAUSE_PUSH" "$@"
}

run_scan() {
  pause_push scan
}

remote_sha() {
  git --git-dir="$ORIGIN" rev-parse --verify --quiet "refs/heads/$BRANCH" 2>/dev/null || true
}

record() {  # <key>
  sed -n "s/^$1=//p" "$HOME_DIR/state/$ID.pause-push" 2>/dev/null
}

wake_rows() {
  [ -f "$HOME_DIR/state/.wake-queue" ] || { echo 0; return; }
  grep -c 'pause-push' "$HOME_DIR/state/.wake-queue" || true
}

test_pause_pushes_branch_and_reports_dirty_files() {
  local head commits out again
  make_task ff-dirty
  head=$(git -C "$WT" rev-parse HEAD)
  commits=$(git -C "$WT" rev-list --count HEAD)
  printf 'edited\n' >> "$WT/README.md"
  printf 'scratch\n' > "$WT/notes.txt"
  declare_status 'working [at=1]: building'
  declare_status 'paused [at=2]: waiting on review data'

  out=$(run_scan) || fail "scan exited nonzero"

  assert_equals "$head" "$(remote_sha)" "paused branch was not pushed to origin under its own name"
  assert_equals "$head" "$(git -C "$WT" rev-parse HEAD)" "push-on-pause moved HEAD"
  assert_equals "$commits" "$(git -C "$WT" rev-list --count HEAD)" "push-on-pause created a commit"
  assert_equals "fm/ff-dirty" "$(git -C "$WT" symbolic-ref --short HEAD)" "push-on-pause switched branches"
  grep -qx 'edited' <(tail -n 1 "$WT/README.md") || fail "tracked edit was not left in place"
  [ -f "$WT/notes.txt" ] || fail "untracked file was not left in place"
  assert_equals pushed "$(record outcome)" "record outcome"
  assert_equals 2 "$(record dirty)" "record dirty count"
  assert_contains "$out" "actionable: check: pause-push ff-dirty pushed branch=fm/ff-dirty" "dirty push not reported"
  assert_contains "$out" "notes.txt" "dirty report does not name the untracked file"
  assert_contains "$out" "README.md" "dirty report does not name the tracked edit"
  assert_equals 1 "$(wake_rows)" "dirty push did not queue exactly one wake row"

  again=$(run_scan) || fail "second scan exited nonzero"
  assert_equals "" "$again" "the same paused line was handled twice"
  assert_equals 1 "$(wake_rows)" "the same paused line queued a second wake"
  pass "a paused task's branch is pushed without a commit and dirty files are reported, not touched"
}

test_clean_pause_push_is_silent_and_skips_non_paused_tasks() {
  local out head
  make_task clean
  head=$(git -C "$WT" rev-parse HEAD)
  declare_status 'working [at=1]: building'
  out=$(run_scan) || fail "scan exited nonzero"
  assert_equals "" "$(remote_sha)" "a working task was pushed"
  [ ! -e "$HOME_DIR/state/$ID.pause-push" ] || fail "a working task got a pause-push record"

  declare_status 'paused [at=2]: waiting on CI'
  out=$(run_scan) || fail "scan exited nonzero"
  assert_equals "$head" "$(remote_sha)" "clean paused branch was not pushed"
  assert_equals "" "$out" "a clean successful push woke firstmate"
  assert_equals 0 "$(wake_rows)" "a clean successful push queued a wake"
  pass "a clean paused push is silent and a working task is never pushed"
}

test_rejected_push_is_reported_and_remote_untouched() {
  local other out remote_before
  make_task rejected
  other="$WORLD/other"
  git clone --quiet "$ORIGIN" "$other"
  git -C "$other" checkout -q -b "$BRANCH"
  printf 'theirs\n' > "$other/theirs.txt"
  git -C "$other" add theirs.txt
  git -C "$other" commit -qm "diverged remote work"
  git -C "$other" push -q origin "$BRANCH"
  remote_before=$(remote_sha)
  declare_status 'paused [at=3]: waiting'

  out=$(run_scan) || fail "scan exited nonzero"

  assert_equals "$remote_before" "$(remote_sha)" "a diverged remote branch was overwritten"
  assert_equals rejected "$(record outcome)" "record outcome"
  assert_contains "$out" "actionable: check: pause-push rejected rejected branch=fm/rejected" "rejected push not reported"
  assert_contains "$out" "not retried with force" "rejected report does not say force was not used"
  assert_equals 1 "$(wake_rows)" "rejected push did not queue a wake"
  pass "a rejected push is reported and the diverged remote branch is left untouched"
}

test_remote_already_containing_head_reads_behind() {
  local out
  make_task behind
  git -C "$WT" push -q origin "$BRANCH"
  git -C "$WT" reset -q --hard HEAD~1
  declare_status 'paused [at=4]: waiting'
  out=$(run_scan) || fail "scan exited nonzero"
  assert_equals behind "$(record outcome)" "record outcome"
  assert_equals "" "$out" "work already on origin woke firstmate"
  pass "a copy whose HEAD origin already contains reads behind and stays quiet"
}

test_ineligible_tasks_are_never_pushed() {
  local out
  make_task local-only 'mode=local-only'
  sed -i.bak '/^mode=no-mistakes$/d' "$HOME_DIR/state/$ID.meta"
  declare_status 'paused [at=5]: waiting'
  out=$(run_scan) || fail "scan exited nonzero"
  assert_equals "" "$(remote_sha)" "a local-only task was pushed"
  assert_equals skipped "$(record outcome)" "local-only record outcome"
  assert_equals "" "$out" "a local-only skip woke firstmate"

  make_task scout
  sed -i.bak 's/^kind=ship$/kind=scout/' "$HOME_DIR/state/$ID.meta"
  declare_status 'paused [at=6]: waiting'
  out=$(run_scan) || fail "scan exited nonzero"
  assert_equals "" "$(remote_sha)" "a scout was pushed"
  assert_equals "" "$out" "a scout skip woke firstmate"

  make_task no-branch
  sed -i.bak '/^branch=/d' "$HOME_DIR/state/$ID.meta"
  declare_status 'paused [at=6]: waiting'
  out=$(run_scan) || fail "scan exited nonzero"
  assert_equals "" "$(remote_sha)" "a record with no recorded branch was pushed"
  assert_equals "" "$out" "a record with no recorded branch woke firstmate"

  make_task not-a-checkout
  sed -i.bak "s#^worktree=.*#worktree=$WORLD#" "$HOME_DIR/state/$ID.meta"
  declare_status 'paused [at=6]: waiting'
  out=$(run_scan) || fail "scan exited nonzero"
  assert_equals skipped "$(record outcome)" "non-checkout worktree outcome"
  assert_equals "" "$out" "a worktree that is not a git checkout woke firstmate"

  make_task detached
  git -C "$WT" checkout -q --detach
  declare_status 'paused [at=7]: waiting'
  out=$(run_scan) || fail "scan exited nonzero"
  assert_equals "" "$(remote_sha)" "a detached copy was pushed"
  assert_equals not-pushed "$(record outcome)" "detached record outcome"
  assert_contains "$out" "detached HEAD" "detached copy not reported"
  pass "local-only, scout, branchless, and non-checkout records are never pushed, and a detached ship copy is reported"
}

test_active_pipeline_run_is_never_pushed() {
  local out
  make_task pipeline
  declare_status 'paused [at=10]: waiting on my no-mistakes run'
  out=$(FM_FAKE_CREW_STATE='working · source: run-step · fixing' run_scan) || fail "scan exited nonzero"
  assert_equals "" "$(remote_sha)" "a task with an active pipeline run was pushed"
  [ ! -e "$HOME_DIR/state/$ID.pause-push" ] || fail "transient state consumed the pause"
  run_scan >/dev/null || fail "later scan failed"
  assert_equals "$(git -C "$WT" rev-parse HEAD)" "$(remote_sha)" "later paused read was not retried"
  assert_equals "" "$out" "an active pipeline skip woke firstmate"
  pass "a paused line written during an active pipeline run leaves the push to the pipeline"
}

test_failed_push_is_reported_once() {
  local out
  make_task retry
  declare_status 'paused [at=8]: waiting'
  git -C "$WT" remote set-url origin "$WORLD/missing.git"
  out=$(run_scan) || fail "scan exited nonzero"
  assert_equals failed "$(record outcome)" "unreachable origin outcome"
  assert_contains "$out" "pause-push retry failed" "failed push not reported"

  git -C "$WT" remote set-url origin "file://$ORIGIN"
  assert_equals "" "$(run_scan)" "a handled pause was retried by scan"
  assert_equals "" "$(remote_sha)" "a handled failure pushed on a later scan"
  assert_equals failed "$(record outcome)" "later scan changed the failure record"
  assert_equals 1 "$(wake_rows)" "a handled failure queued another wake"
  pass "a failed push is reported once and later scans do not retry it"
}

test_watcher_poll_pushes_and_wakes() {
  local pid i out
  make_task watcher
  printf 'scratch\n' > "$WT/notes.txt"
  declare_status 'paused [at=9]: waiting'
  FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR/state" "$HOME_DIR/state/$ID.status"
  mkdir -p "$WORLD/fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORLD/fakebin/tmux"
  chmod +x "$WORLD/fakebin"/*
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_PAUSE_PUSH_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_equals "$(git -C "$WT" rev-parse HEAD)" "$(remote_sha)" "the watcher poll did not push the paused branch"
  grep -Fxq 'check: pause-push' "$out" || fail "the watcher did not wake on the dirty pause: $(cat "$out")"
  assert_equals 1 "$(wake_rows)" "the watcher wake has no durable queue row"
  pass "the real watcher poll pushes a paused branch and wakes firstmate on a dirty copy"
}

make_task real-reader
declare_status 'paused [at=100]: waiting for review'
echo 'Real crew-state response for a task without a registered live endpoint:'
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$ID"
echo 'Invoking real pause scan with real crew-state reader:'
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PAUSE_PUSH_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" "$PAUSE_PUSH" scan
[ -z "$(remote_sha)" ] || exit 1
[ ! -e "$HOME_DIR/state/$ID.pause-push" ] || exit 1
echo 'Remote task branch remains absent; pause remains eligible for a later scan.'
