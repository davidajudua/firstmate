#!/usr/bin/env bash
# Behavior for a +require-no-mistakes project (bin/fm-project-mode.sh owns the
# token, bin/fm-dod-lib.sh the NO-MISTAKES-EXCEPTION marker): a ship spawn or a
# scout promotion that would skip the pipeline is refused unless the captain's
# quoted exception is recorded for that task, and a scout cannot push. These
# drive the real brief, spawn, and promote paths with a fake terminal.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. The push cases set
# that override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-require-no-mistakes)
QUOTE='Yes, ship this one as direct-PR.'

# make_case <name> <registry-tokens>: a home whose registry holds the tokens and
# a project with a pooled worktree. Sets HOME_DIR, PROJECT_DIR, POOL_DIR,
# FAKEBIN_DIR.
make_case() {
  local name=$1 tokens=$2 dir
  dir="$TMP_ROOT/$name"
  HOME_DIR="$dir/home"
  PROJECT_DIR="$dir/project"
  POOL_DIR="$dir/pool"
  FAKEBIN_DIR=$(make_spawn_fakebin "$dir/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  printf -- '- project [%s] - fixture (added 2026-01-01)\n' "$tokens" > "$HOME_DIR/data/projects.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
}

scaffold() {  # <id> <brief-flags...>
  local id=$1 content
  shift
  FM_HOME="$HOME_DIR" "$BRIEF" "$id" project "$@" >/dev/null || fail "the brief for $id should scaffold"
  content=$(cat "$HOME_DIR/data/$id/brief.md")
  content=${content//'{TASK}'/Fix the bug.}
  content=${content//'{FIRSTMATE_SPEC}'/Exercise the spawn path.}
  printf '%s\n' "$content" > "$HOME_DIR/data/$id/brief.md"
}

run_spawn() {  # <id> <args...>
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

refused_before_launch() {  # <id> <status> <out> <label>
  [ "$2" -ne 0 ] || fail "$4 launched"$'\n'"$3"
  assert_contains "$3" "registered +require-no-mistakes" "$4 was refused without naming the requirement"
  assert_contains "$3" "--no-mistakes-exception" "$4 was refused without naming the exception remedy"
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "$4 still published a task record"
}

test_spawn_refuses_modes_that_skip_the_pipeline() {
  local out status
  make_case refuse "no-mistakes-prod-only +require-no-mistakes"
  scaffold nm-r1 --mode direct-PR
  out=$(run_spawn nm-r1 --mode direct-PR --yolo off); status=$?
  refused_before_launch nm-r1 "$status" "$out" "a direct-PR spawn on a flagged project"
  scaffold nm-r2 --mode local-only
  out=$(run_spawn nm-r2 --mode local-only --yolo off); status=$?
  refused_before_launch nm-r2 "$status" "$out" "a local-only spawn on a flagged project"
  scaffold nm-r3 --mode no-mistakes
  out=$(run_spawn nm-r3 --mode no-mistakes --yolo off); status=$?
  expect_code 0 "$status" "a no-mistakes spawn on a flagged project should launch"$'\n'"$out"
  pass "fm-spawn: a flagged project refuses direct-PR and local-only before launch and launches no-mistakes"
}

test_spawn_launches_with_the_captains_quoted_exception() {
  local out status brief
  make_case exception "no-mistakes-prod-only +require-no-mistakes"
  scaffold nm-e1 --mode direct-PR --no-mistakes-exception "$QUOTE"
  brief="$HOME_DIR/data/nm-e1/brief.md"
  grep -qxF "NO-MISTAKES-EXCEPTION: \"$QUOTE\"" "$brief" || fail "the brief did not record the quoted exception"
  out=$(run_spawn nm-e1 --mode direct-PR --yolo off); status=$?
  expect_code 0 "$status" "a direct-PR spawn carrying the captain's quoted exception should launch"$'\n'"$out"

  # An emptied quote is not an exception.
  scaffold nm-e2 --mode direct-PR --no-mistakes-exception "$QUOTE"
  sed -i.bak 's/^NO-MISTAKES-EXCEPTION: .*/NO-MISTAKES-EXCEPTION: "  "/' "$HOME_DIR/data/nm-e2/brief.md"
  out=$(run_spawn nm-e2 --mode direct-PR --yolo off); status=$?
  refused_before_launch nm-e2 "$status" "$out" "a direct-PR spawn whose exception quote is blank"
  pass "fm-spawn: the captain's quoted exception admits one direct-PR task, and a blank quote does not"
}

test_unflagged_project_keeps_todays_behavior() {
  local out status
  make_case unflagged "no-mistakes-prod-only"
  scaffold nm-u1 --mode direct-PR
  out=$(run_spawn nm-u1 --mode direct-PR --yolo off); status=$?
  expect_code 0 "$status" "a direct-PR spawn on an unflagged project should launch"$'\n'"$out"
  pass "fm-spawn: a project without the token still launches direct-PR"
}

test_brief_validates_the_exception() {
  local home out status
  home="$TMP_ROOT/brief-flags/home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$BRIEF" b1 project --mode direct-PR --no-mistakes-exception '   ' 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a blank exception quote scaffolded"
  assert_contains "$out" "empty quote approves nothing" "the blank quote refusal did not say why"
  out=$(FM_HOME="$home" "$BRIEF" b2 project --mode direct-PR --no-mistakes-exception "$(printf 'one\ntwo')" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a multi-line exception quote scaffolded"
  out=$(FM_HOME="$home" "$BRIEF" b3 project --mode no-mistakes --no-mistakes-exception "$QUOTE" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an exception on a no-mistakes brief scaffolded"
  assert_contains "$out" "meaningless on mode=no-mistakes" "the no-mistakes refusal did not say why"
  out=$(FM_HOME="$home" "$BRIEF" b4 project --scout --no-mistakes-exception "$QUOTE" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an exception on a scout brief scaffolded"
  printf 'Standing rule.\nNO-MISTAKES-EXCEPTION: "always"\n' > "$home/config/brief-include.md"
  out=$(FM_HOME="$home" "$BRIEF" b5 project --mode direct-PR 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a home include carrying a standing exception scaffolded"
  assert_contains "$out" "NO-MISTAKES-EXCEPTION:" "the include refusal did not name the marker"
  for id in b1 b2 b3 b4 b5; do
    [ ! -e "$home/data/$id/brief.md" ] || fail "the refused scaffold $id still wrote a brief"
  done
  pass "fm-brief: the exception needs a one-line nonblank quote on a non-no-mistakes ship brief, never from the home include"
}

test_scout_on_a_flagged_project_cannot_push() {
  local out status bare hooks meta
  make_case scout "no-mistakes-prod-only +require-no-mistakes"
  scaffold nm-s1 --scout
  out=$(run_spawn nm-s1 --scout); status=$?
  expect_code 0 "$status" "a scout spawn on a flagged project should launch"$'\n'"$out"
  hooks="$HOME_DIR/state/nm-s1.git-hooks"
  meta="$HOME_DIR/state/nm-s1.meta"
  bare="$TMP_ROOT/scout/published.git"
  git init -q --bare "$bare"
  git -C "$POOL_DIR" remote add published "file://$bare"
  git -C "$POOL_DIR" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m 'scout experiment'
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks \
    git -C "$POOL_DIR" push published HEAD:refs/heads/fm/nm-s1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a scout on a flagged project pushed a branch"
  assert_contains "$out" "never a pushed branch or PR" "the scout push was refused without saying why"
  ! git -C "$bare" rev-parse --verify --quiet refs/heads/fm/nm-s1 >/dev/null || fail "the scout branch reached the remote"

  sed -i.bak 's/^kind=scout$/kind=ship/' "$meta"
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks \
    git -C "$POOL_DIR" push published HEAD:refs/heads/fm/nm-s1 2>&1); status=$?
  expect_code 0 "$status" "the same hooks still refused the push after the task record became a ship"$'\n'"$out"

  make_case scout-plain "no-mistakes-prod-only"
  scaffold nm-s2 --scout
  out=$(run_spawn nm-s2 --scout); status=$?
  expect_code 0 "$status" "a scout spawn on an unflagged project should launch"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/nm-s2.push-guard" ] || fail "an unflagged project's scout got the push guard"
  pass "fm-spawn: a scout on a flagged project cannot push until it is promoted, and an unflagged scout gets no guard"
}

test_promotion_applies_the_same_gate() {
  local out status meta id
  make_case promote "no-mistakes-prod-only +require-no-mistakes"
  for id in nm-p1 nm-p2 nm-p3; do
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\nproject=%s\n' "$id" "$PROJECT_DIR" > "$HOME_DIR/state/$id.meta"
    scaffold "$id" --scout
  done
  meta="$HOME_DIR/state/nm-p1.meta"
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$PROMOTE" nm-p1 --mode direct-PR --yolo off 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a scout on a flagged project was promoted to direct-PR"
  assert_contains "$out" "registered +require-no-mistakes" "the promotion refusal did not name the requirement"
  grep -qx 'kind=scout' "$meta" || fail "the refused promotion still flipped the task record"

  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$PROMOTE" nm-p2 --mode direct-PR --yolo off \
    --no-mistakes-exception "$QUOTE" 2>&1) || fail "a promotion carrying the quoted exception was refused: $out"
  grep -qxF "NO-MISTAKES-EXCEPTION: \"$QUOTE\"" "$HOME_DIR/data/nm-p2/ship-instructions.md" \
    || fail "the promoted worker's instructions do not record the exception"
  grep -qxF "NO-MISTAKES-EXCEPTION: \"$QUOTE\"" "$HOME_DIR/data/nm-p2/brief.md" \
    || fail "the promoted brief does not record the exception for a relaunch"

  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$PROMOTE" nm-p3 --mode no-mistakes --yolo off 2>&1) \
    || fail "a no-mistakes promotion on a flagged project was refused: $out"
  pass "fm-promote: a flagged project refuses a direct-PR promotion unless it carries the quoted exception"
}

test_spawn_refuses_modes_that_skip_the_pipeline
test_spawn_launches_with_the_captains_quoted_exception
test_unflagged_project_keeps_todays_behavior
test_brief_validates_the_exception
test_scout_on_a_flagged_project_cannot_push
test_promotion_applies_the_same_gate

echo "# all fm-spawn-require-no-mistakes tests passed"
