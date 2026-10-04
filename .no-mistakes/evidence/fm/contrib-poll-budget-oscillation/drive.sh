#!/usr/bin/env bash
# drive.sh <lab> <shim-or-script> : cadence polls through the generated watcher check shim
LAB=$1; CHECK=$2
step() { # fault time label
  printf '%s\n' "$1" > "$LAB/forge/fault"
  out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_CONTRIBUTIONS_BUDGET \
    PATH="$LAB/fakebin:$PATH" FORGE="$LAB/forge" FM_HOME="$LAB" FM_CONTRIBUTIONS_NOW="$2" bash $CHECK 2>&1); rc=$?
  rec=$(jq -c '.records[0] | {checked_at,error:(.error!=null),recovery_reads}' "$LAB/data/delivery/contributions.json")
  printf '%-22s forge=%-5s rc=%s wake=%-4s record=%s\n' "$2" "$1" "$rc" "$([ -n "$out" ] && echo YES || echo -)" "$rec"
  [ -n "$out" ] && printf '    stdout: %s\n' "$out"
  true
}
echo "## 1. Oscillating slow forge, observed every cadence (fail/ok/fail/ok...)"
step down 2026-10-04T09:00:00Z
step ok   2026-10-04T09:05:00Z
step down 2026-10-04T09:10:00Z
step ok   2026-10-04T09:15:00Z
step down 2026-10-04T09:20:00Z
step ok   2026-10-04T09:25:00Z
step down 2026-10-04T09:30:00Z
echo "## 2. Rotation with 3+ parked URLs: URL observed only every 15+ min, single success in between"
step ok   2026-10-04T09:45:00Z
step down 2026-10-04T10:00:00Z
step ok   2026-10-04T11:00:00Z
step down 2026-10-04T12:30:00Z
echo "## 3. Head change during read inside an open episode (must still surface)"
step ok   2026-10-04T12:35:00Z
step head 2026-10-04T12:40:00Z
echo "## 4. Two consecutive successful reads end the episode; a genuine outage then wakes again"
step ok   2026-10-04T12:45:00Z
step ok   2026-10-04T12:50:00Z
step down 2026-10-04T12:55:00Z
echo "## 5. Read slower than the 5s per-read cap (budget refusal, not a forge failure)"
step ok   2026-10-04T13:00:00Z
step ok   2026-10-04T13:05:00Z
step slow 2026-10-04T13:30:00Z
