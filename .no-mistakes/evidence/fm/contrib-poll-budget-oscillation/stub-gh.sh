#!/usr/bin/env bash
# Stub GitHub forge for the lab: behavior selected by $FORGE/fault (ok|down|head|slow)
set -eu
F=${FORGE:?}; printf '%s\n' "$*" >> "$F/calls"
fault=$(cat "$F/fault" 2>/dev/null || echo ok)
head=$(cat "$F/head")
case "$fault:$*" in
  down:*) echo 'HTTP 502' >&2; exit 1 ;;
  slow:'api repos/o/r/pulls/8') sleep 7 ;;
  head:'pr view '*) printf '{"headRefOid":"%s","reviewDecision":"APPROVED"}\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; exit 0 ;;
esac
case "$*" in
  'pr view '*headRefOid,reviewDecision*) jq -n --arg h "$head" '{headRefOid:$h,reviewDecision:"APPROVED"}' ;;
  'api repos/o/r/pulls/8') jq -n --arg h "$head" '{state:"open",user:{login:"author"},head:{sha:$h},draft:false,mergeable:true,merged_at:null}' ;;
  'api repos/o/r/issues/'*'/events?'*|'api repos/o/r/issues/'*'/comments?'*|'api repos/o/r/pulls/'*'/reviews?'*|'api repos/o/r/pulls/'*'/comments?'*) echo '[]' ;;
  'api repos/o/r/commits/'*'/check-runs?'*) echo '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]' ;;
  'api repos/o/r/commits/'*'/statuses?'*) echo '[[]]' ;;
  'api repos/o/r') echo '{"permissions":{"push":false}}' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
