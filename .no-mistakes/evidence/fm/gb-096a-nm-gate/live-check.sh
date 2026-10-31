#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$(mktemp -d "$PWD/.test-tmp/live.XXXXXX")
trap 'chmod -R u+w "$LAB"; rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB/home"
export FM_HOME="$LAB/home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$LAB/project" "$FM_HOME/data/task"
printf -- '- project [no-mistakes-prod-only +require-no-mistakes] - live validation\n' > "$FM_HOME/data/projects.md"
git init -q -b main "$LAB/project"
printf 'base\n' > "$LAB/project/file"
git -C "$LAB/project" add file
git -C "$LAB/project" -c user.name=Test -c user.email=test@example.invalid commit -qm base
git -C "$LAB/project" worktree add -qb fm/task "$LAB/work"
printf 'unfinished\n' > "$LAB/work/unfinished"
FM_HOME="$FM_HOME" bin/fm-brief.sh task project --mode direct-PR > /dev/null
python3 - "$FM_HOME/data/task/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}','Exercise the required pipeline.').replace('{FIRSTMATE_SPEC}','Preserve unfinished work.')
open(p,'w').write(s)
PY
printf 'window=fm-lab-validation:task\nproject=%s\nworktree=%s\nkind=ship\nmode=direct-PR\nharness=claude\nyolo=off\n' "$LAB/project" "$LAB/work" > "$FM_HOME/state/task.meta"
cp "$FM_HOME/state/task.meta" "$LAB/before.meta"
cp "$FM_HOME/data/task/brief.md" "$LAB/before.brief"
before=$(git -C "$LAB/work" status --porcelain)
head=$(git -C "$LAB/work" rev-parse HEAD)
for mode in direct-PR local-only; do
  sed -i "s/^mode=.*/mode=$mode/" "$FM_HOME/state/task.meta"
  cp "$FM_HOME/state/task.meta" "$LAB/before.meta"
  for entry in spawn control; do
    echo "SCENARIO relaunch $entry $mode without exception"
    set +e
    if [ "$entry" = spawn ]; then bin/fm-spawn.sh task "$LAB/project" --relaunch; else bin/fm-control.sh task relaunch --note 'Continue unfinished work'; fi
    rc=$?
    set -e
    echo "exit=$rc"
    [ "$rc" -ne 0 ]
    cmp "$FM_HOME/state/task.meta" "$LAB/before.meta"
    cmp "$FM_HOME/data/task/brief.md" "$LAB/before.brief"
    [ "$(git -C "$LAB/work" status --porcelain)" = "$before" ]
    [ "$(git -C "$LAB/work" rev-parse HEAD)" = "$head" ]
    [ "$(git -C "$LAB/work" symbolic-ref --short HEAD)" = fm/task ]
    echo 'Task record, instructions, HEAD, branch, and unfinished work unchanged.'
  done
done
for mode in direct-PR local-only; do
  id="new-$mode"
  bin/fm-brief.sh "$id" project --mode "$mode" >/dev/null
  sed -i 's/{TASK}/Exercise refusal./g; s/{FIRSTMATE_SPEC}/Preserve work./g' "$FM_HOME/data/$id/brief.md"
  echo "SCENARIO fresh spawn $mode without exception"
  set +e
  bin/fm-spawn.sh "$id" "$LAB/project" --mode "$mode" --yolo off
  rc=$?
  set -e
  echo "exit=$rc"
  [ "$rc" -ne 0 ]
  [ ! -e "$FM_HOME/state/$id.meta" ]
done
sed -i 's/^kind=ship$/kind=scout/' "$FM_HOME/state/task.meta"
echo 'SCENARIO scout promotion without exception'
set +e
bin/fm-promote.sh task --mode direct-PR --yolo off
rc=$?
set -e
echo "exit=$rc"
[ "$rc" -ne 0 ]
grep -qx 'kind=scout' "$FM_HOME/state/task.meta"
echo 'SCENARIO scout attempts a real Git push'
bin/fm-git-push-guard.sh write-scout "$LAB/guard" "$FM_HOME/state/task.meta"
bin/fm-git-strip-ai-trailers.sh install --push-guard "$LAB/guard" "$LAB/hooks" "$LAB/work"
git init -q --bare "$LAB/remote.git"
git -C "$LAB/work" remote add published "$LAB/remote.git"
set +e
git -C "$LAB/work" -c core.hooksPath="$LAB/hooks" push published HEAD:refs/heads/scout
rc=$?
set -e
echo "exit=$rc"
[ "$rc" -ne 0 ]
! git -C "$LAB/remote.git" show-ref --verify refs/heads/scout
echo 'Remote has no scout branch.'
sed -i 's/^kind=scout$/kind=ship/' "$FM_HOME/state/task.meta"
echo 'SCENARIO guard permits a ship after promotion'
git -C "$LAB/work" -c core.hooksPath="$LAB/hooks" push published HEAD:refs/heads/ship
git -C "$LAB/remote.git" show-ref --verify refs/heads/ship

echo 'SCENARIO promotion with a quoted exception'
sed -i 's/^kind=ship$/kind=scout/' "$FM_HOME/state/task.meta"
bin/fm-promote.sh task --mode direct-PR --yolo off --no-mistakes-exception 'Ship this one without no-mistakes.'
grep -qx 'kind=ship' "$FM_HOME/state/task.meta"
grep -F 'NO-MISTAKES-EXCEPTION:' "$FM_HOME/data/task/brief.md"
echo 'SCENARIO project policy is opt-in'
bin/fm-project-mode.sh --require-no-mistakes project
printf -- '- project [no-mistakes-prod-only] - live validation\n' > "$FM_HOME/data/projects.md"
bin/fm-project-mode.sh --require-no-mistakes project
