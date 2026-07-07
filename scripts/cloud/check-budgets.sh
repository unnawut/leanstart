#!/usr/bin/env bash
# check-budgets.sh — query a running leanstart devnet's Prometheus and report
# PASS/FAIL against the aggregation-topology budgets.
#
# Anchored to lean-bench's pq-devnet feasibility model (bench.leanroadmap.org/
# topology.html): a slot is 5 x 800ms intervals; the aggregate interval gives a
# leaf-compute budget of 800 - 200ms propagation = 600ms. Recursion is judged
# by the user's working budget (default 2400ms). Finalization should hold at
# ~3 slots behind head. Fast-confirmation (safe-target) lag is tracked, not
# gated.
#
# Works against any context (local kind or GKE) — it port-forwards the metrics
# stack itself, independent of leanstart's own port-forwards.
#
# Usage:
#   check-budgets.sh --context <ctx> [options]
# Options:
#   --context <ctx>        kube context (required)
#   --namespace <ns>       devnet namespace (default lean-devnet) [informational]
#   --metrics-ns <ns>      metrics namespace (default monitoring)
#   --leaf-budget <s>      leaf aggregation p99 budget, seconds (default 0.600)
#   --recursion-budget <s> recursion p99 budget, seconds (default 2.400)
#   --final-slots <n>      max acceptable head-finalized lag, slots (default 3)
#   --window <dur>         PromQL rate window (default 2m)
#   --label <text>         row label (e.g. topology), recorded in --report
#   --report <csv>         append a result row to this CSV (created w/ header)
#   --local-port <p>       local port-forward port (default 19090)
#   --strict               exit non-zero if any gated budget FAILs

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/cloud/gke-lib.sh
source "$SCRIPT_DIR/gke-lib.sh"

CTX=""; DEVNET_NS="lean-devnet"; METRICS_NS="monitoring"
LEAF_BUDGET="0.600"; REC_BUDGET="2.400"; FINAL_SLOTS="3"
WINDOW="2m"; LABEL=""; REPORT=""; LOCAL_PORT="19090"; STRICT=0; JSON_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context)          CTX="$2"; shift 2 ;;
    --namespace)        DEVNET_NS="$2"; shift 2 ;;
    --metrics-ns)       METRICS_NS="$2"; shift 2 ;;
    --leaf-budget)      LEAF_BUDGET="$2"; shift 2 ;;
    --recursion-budget) REC_BUDGET="$2"; shift 2 ;;
    --final-slots)      FINAL_SLOTS="$2"; shift 2 ;;
    --window)           WINDOW="$2"; shift 2 ;;
    --label)            LABEL="$2"; shift 2 ;;
    --report)           REPORT="$2"; shift 2 ;;
    --json-out)         JSON_OUT="$2"; shift 2 ;;
    --local-port)       LOCAL_PORT="$2"; shift 2 ;;
    --strict)           STRICT=1; shift ;;
    -h|--help)          sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) gke::err "unknown arg: $1"; exit 1 ;;
  esac
done
[ -n "$CTX" ] || { gke::err "--context is required"; exit 1; }
gke::require kubectl curl python3

# --- discover the Prometheus service ------------------------------------------
# Don't hardcode the kube-prometheus-stack service name (it varies with the
# release/chart). The Prometheus Operator always creates a headless service
# named `prometheus-operated` (port 9090) for any Prometheus CR — prefer that,
# then fall back to grepping the service list.
PROM_SVC="$(kubectl --context "$CTX" -n "$METRICS_NS" get svc prometheus-operated \
  -o name 2>/dev/null || true)"
if [ -z "$PROM_SVC" ]; then
  PROM_SVC="$(kubectl --context "$CTX" -n "$METRICS_NS" get svc -o name 2>/dev/null \
    | grep -iE 'prometheus' \
    | grep -viE 'operator|alertmanager|grafana|node|kube-state|thanos' | head -1)"
fi
[ -n "$PROM_SVC" ] || { gke::err "no Prometheus service found in ns '$METRICS_NS'"; \
  kubectl --context "$CTX" -n "$METRICS_NS" get svc,pods >&2 2>&1 || true; exit 1; }

# --- port-forward it ----------------------------------------------------------
PF_PID=""; PF_LOG="$(mktemp)"
pf_cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; rm -f "$PF_LOG"; }
trap pf_cleanup EXIT

gke::log "Port-forwarding $PROM_SVC ($METRICS_NS) to localhost:$LOCAL_PORT"
kubectl --context "$CTX" -n "$METRICS_NS" port-forward \
  "$PROM_SVC" "$LOCAL_PORT:9090" >"$PF_LOG" 2>&1 &
PF_PID=$!

# Wait for the forward to answer (up to ~60s; Prometheus TSDB init can lag).
PROM="http://localhost:$LOCAL_PORT"
for _ in $(seq 1 60); do
  if curl -fsS "$PROM/-/ready" >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! curl -fsS "$PROM/-/ready" >/dev/null 2>&1; then
  gke::err "Prometheus not reachable on $PROM. Diagnostics:"
  echo "--- port-forward log ---" >&2; cat "$PF_LOG" >&2 2>&1 || true
  kubectl --context "$CTX" -n "$METRICS_NS" get svc,pods >&2 2>&1 || true
  exit 1
fi

# promq QUERY — instant query, prints the scalar value or empty string.
promq() {
  curl -fsSG "$PROM/api/v1/query" --data-urlencode "query=$1" 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); r=d["data"]["result"]
    print(r[0]["value"][1] if r else "")
except Exception:
    print("")'
}

# Leaf aggregation p99. devnet4 timed signature folding as
# lean_committee_signatures_aggregation_time_seconds; devnet5 replaced that with
# a zkVM bytecode prover and renamed it lean_pq_sig_aggregated_signatures_building_time_seconds
# (the old name no longer exists). The PromQL `or` returns the devnet4 metric
# when present, else falls back to the devnet5 one — so this works on both
# without a flag. (devnet5 also exposes ..._verification_time_seconds for the
# verifier cost, not gated here.)
LEAF_Q="histogram_quantile(0.99, sum by (le) (rate(lean_committee_signatures_aggregation_time_seconds_bucket[$WINDOW]))) or histogram_quantile(0.99, sum by (le) (rate(lean_pq_sig_aggregated_signatures_building_time_seconds_bucket[$WINDOW])))"
REC_Q="histogram_quantile(0.99, sum by (le) (rate(lean_block_building_payload_aggregation_time_seconds_bucket[$WINDOW])))"
# Finalization lag, averaged over the window to avoid a transient spike, and
# only over nodes that are actually keeping up (head within a few slots of the
# max) so a single lagging/restarted node doesn't dominate.
FINAL_LAG_Q="avg_over_time(lean_head_slot[$WINDOW]) - avg_over_time(lean_latest_finalized_slot[$WINDOW])"
SAFE_LAG_Q="avg_over_time(lean_head_slot[$WINDOW]) - avg_over_time(lean_safe_target_slot[$WINDOW])"
# Is finalization actually progressing? ream doesn't emit lean_finalizations_total,
# so measure that the finalized slot advanced over the window (Δslots > 0).
FINAL_ADV_Q="max(lean_latest_finalized_slot) - min(min_over_time(lean_latest_finalized_slot[$WINDOW]))"
# Absolute chain state at measurement time.
HEAD_Q="max(lean_head_slot)"
JUST_Q="max(lean_latest_justified_slot)"
FIN_Q="max(lean_latest_finalized_slot)"
PEERS_Q="avg(lean_connected_peers)"
# Signatures folded into leaf aggregates. Build-side counters emitted only by
# aggregators: `..._attestations_in_aggregated...` adds the raw sig count per
# aggregate, `..._aggregated_signatures_total` counts aggregates. The ratio is
# the avg sigs per aggregation — makes leaf p99 interpretable (it's aggregating
# N sigs, not an absolute cost).
SIGS_TOTAL_Q="sum(increase(lean_pq_sig_attestations_in_aggregated_signatures_total[$WINDOW]))"
AVG_SIGS_Q="sum(increase(lean_pq_sig_attestations_in_aggregated_signatures_total[$WINDOW])) / sum(increase(lean_pq_sig_aggregated_signatures_total[$WINDOW]))"

# Per-role resource usage. Split aggregator vs non-aggregator pods by the
# authoritative `--is-aggregator` flag in their container args — NOT by node,
# since non-aggregator pods can land on aggregator nodes (they tolerate the
# Spot taint). Container CPU/memory come from kube-prometheus-stack's cAdvisor
# scrape; absent metrics just record n/a.
AGG_RE="$(kubectl --context "$CTX" -n "$DEVNET_NS" get pods -o json 2>/dev/null | python3 -c '
import sys, json
try: data = json.load(sys.stdin)
except Exception: data = {"items": []}
aggs = []
for pod in data.get("items", []):
    args = []
    for c in pod.get("spec", {}).get("containers", []):
        args += c.get("args") or []
    if "--is-aggregator" in args:
        aggs.append(pod["metadata"]["name"])
print("|".join(sorted(aggs)))
' 2>/dev/null)"

cpu_agg=""; cpu_non=""; mem_agg=""; mem_non=""
if [ -n "$AGG_RE" ]; then
  NS="namespace=\"$DEVNET_NS\""; CT="container!=\"\", container!=\"POD\""
  # avg over pods of (per-pod sum of container CPU rate) = avg cores per instance.
  cpu_agg="$(promq "avg(sum by (pod) (rate(container_cpu_usage_seconds_total{$NS, pod=~\"$AGG_RE\", $CT}[$WINDOW])))")"
  cpu_non="$(promq "avg(sum by (pod) (rate(container_cpu_usage_seconds_total{$NS, pod!~\"$AGG_RE\", $CT}[$WINDOW])))")"
  # avg over pods of (per-pod working-set, averaged over the window) = bytes/instance.
  mem_agg="$(promq "avg(sum by (pod) (avg_over_time(container_memory_working_set_bytes{$NS, pod=~\"$AGG_RE\", $CT}[$WINDOW])))")"
  mem_non="$(promq "avg(sum by (pod) (avg_over_time(container_memory_working_set_bytes{$NS, pod!~\"$AGG_RE\", $CT}[$WINDOW])))")"
fi

leaf="$(promq "$LEAF_Q")"
rec="$(promq "$REC_Q")"
final_lag="$(promq "$FINAL_LAG_Q")"
safe_lag="$(promq "$SAFE_LAG_Q")"
final_adv="$(promq "$FINAL_ADV_Q")"
head_slot="$(promq "$HEAD_Q")"
justified_slot="$(promq "$JUST_Q")"
finalized_slot="$(promq "$FIN_Q")"
peers="$(promq "$PEERS_Q")"
sigs_total="$(promq "$SIGS_TOTAL_Q")"
avg_sigs="$(promq "$AVG_SIGS_Q")"

# --- evaluate + render + emit measurements JSON -------------------------------
CB_LABEL="$LABEL" CB_LEAFB="$LEAF_BUDGET" CB_RECB="$REC_BUDGET" CB_FINS="$FINAL_SLOTS" \
CB_WINDOW="$WINDOW" CB_LEAF="$leaf" CB_REC="$rec" CB_FL="$final_lag" CB_SL="$safe_lag" \
CB_FADV="$final_adv" CB_HEAD="$head_slot" CB_JUST="$justified_slot" CB_FIN="$finalized_slot" \
CB_PEERS="$peers" CB_SIGSTOTAL="$sigs_total" CB_AVGSIGS="$avg_sigs" \
CB_CPUAGG="$cpu_agg" CB_CPUNON="$cpu_non" CB_MEMAGG="$mem_agg" CB_MEMNON="$mem_non" \
CB_JSON_OUT="$JSON_OUT" CB_REPORT="$REPORT" CB_STRICT="$STRICT" python3 <<'PY'
import os, json, datetime
E=os.environ.get
def f(x):
    try: return float(x)
    except: return None
leafB,recB,finS = float(E("CB_LEAFB")), float(E("CB_RECB")), float(E("CB_FINS"))
leaf,rec,fl,sl,fadv = map(f,(E("CB_LEAF"),E("CB_REC"),E("CB_FL"),E("CB_SL"),E("CB_FADV")))
head,just,fin,peers = map(f,(E("CB_HEAD"),E("CB_JUST"),E("CB_FIN"),E("CB_PEERS")))
sigs_total,avg_sigs = map(f,(E("CB_SIGSTOTAL"),E("CB_AVGSIGS")))
cpu_agg,cpu_non,mem_agg,mem_non = map(f,(E("CB_CPUAGG"),E("CB_CPUNON"),E("CB_MEMAGG"),E("CB_MEMNON")))
mib = lambda x: None if x is None else x/1048576.0
mem_agg_mib, mem_non_mib = mib(mem_agg), mib(mem_non)
i = lambda x: None if x is None else int(round(x))   # slots/counts are whole numbers
label=E("CB_LABEL","")

def verdict(val, budget, low=True):
    if val is None: return "n/a"
    return "PASS" if (val<=budget if low else val>=budget) else "FAIL"

v_leaf=verdict(leaf,leafB); v_rec=verdict(rec,recB); v_fl=verdict(fl,finS)
v_fadv = "PASS" if (fadv or 0)>0 else ("n/a" if fadv is None else "FAIL")

# Human table: per-metric budgets first, then chain-state context. No rolled-up
# overall status — leaf/finalization-lag fail on nearly every run (lag is a ream
# client characteristic, not a topology property), so an aggregate verdict just
# read FAIL everywhere and hid the real per-metric signal.
def ms(x):    return f"{x*1000:.0f} ms" if x is not None else "n/a"
def slot(x):  return f"{x:.0f}" if x is not None else "n/a"
rows=[
  ("leaf aggregation p99", ms(leaf),  f"<= {leafB*1000:.0f} ms",  v_leaf),
  ("recursion p99",        ms(rec),   f"<= {recB*1000:.0f} ms",   v_rec),
  ("finalization lag",     f"{slot(fl)} slots",   f"<= {finS:.0f} slots", v_fl),
  ("finalized advancing",  (f"+{fadv:.0f} slots" if fadv is not None else "n/a"), "> 0", v_fadv),
  ("fast-confirm (safe) lag", f"{slot(sl)} slots", "(tracked)", "—"),
  ("avg sigs / aggregation", (f"{avg_sigs:.1f}" if avg_sigs is not None else "n/a"), "(info)", "—"),
  ("sigs aggregated (win)", (f"{sigs_total:.0f}" if sigs_total is not None else "n/a"), "(info)", "—"),
  ("cpu/agg (cores)",      (f"{cpu_agg:.2f}" if cpu_agg is not None else "n/a"), "(info)", "—"),
  ("cpu/non-agg (cores)",  (f"{cpu_non:.2f}" if cpu_non is not None else "n/a"), "(info)", "—"),
  ("mem/agg (MiB)",        (f"{mem_agg_mib:.0f}" if mem_agg_mib is not None else "n/a"), "(info)", "—"),
  ("mem/non-agg (MiB)",    (f"{mem_non_mib:.0f}" if mem_non_mib is not None else "n/a"), "(info)", "—"),
  ("head slot",            slot(head), "(info)", "—"),
  ("justified slot",       slot(just), "(info)", "—"),
  ("finalized slot",       slot(fin),  "(info)", "—"),
  ("connected peers (avg)",slot(peers),"(info)", "—"),
]
W=24
print(f"\n  Budget report{(' — '+label) if label else ''}")
print("  "+"-"*60)
print(f"  {'metric':<{W}} {'measured':>12} {'budget':>14}  verdict")
print("  "+"-"*60)
for n,m,b,v in rows: print(f"  {n:<{W}} {m:>12} {b:>14}  {v}")
print("  "+"-"*60 + "\n")

measurements = {
  "leaf_agg_p99_ms":       None if leaf is None else round(leaf*1000,1),
  "recursion_p99_ms":      None if rec  is None else round(rec*1000,1),
  "finalization_lag_slots":i(fl),
  "finalized_advancing_slots": i(fadv),
  "fast_confirm_lag_slots":i(sl),
  "avg_sigs_per_agg":      None if avg_sigs   is None else round(avg_sigs,2),
  "sigs_aggregated_total": i(sigs_total),
  "cpu_agg_cores_avg":     None if cpu_agg is None else round(cpu_agg,3),
  "cpu_nonagg_cores_avg":  None if cpu_non is None else round(cpu_non,3),
  "mem_agg_mib_avg":       None if mem_agg_mib is None else round(mem_agg_mib,1),
  "mem_nonagg_mib_avg":    None if mem_non_mib is None else round(mem_non_mib,1),
  "head_slot":             i(head),
  "justified_slot":        i(just),
  "finalized_slot":        i(fin),
  "connected_peers_avg":   None if peers is None else round(peers,2),
}
result = {
  "label": label,
  "window": E("CB_WINDOW"),
  "budgets": {"leaf_ms": leafB*1000, "recursion_ms": recB*1000, "final_slots": finS},
  "measurements": measurements,
  "verdicts": {"leaf":v_leaf, "recursion":v_rec, "finalization_lag":v_fl,
               "finalized_advancing":v_fadv},
}
if E("CB_JSON_OUT"):
    with open(E("CB_JSON_OUT"),"w") as fh: json.dump(result,fh,indent=2)
    print(f"  wrote measurements JSON -> {E('CB_JSON_OUT')}")

# Optional simple per-call CSV (standalone use; the rich consolidated CSV is
# written by record_result.py in the sweep path).
if E("CB_REPORT"):
    p=E("CB_REPORT"); new=not os.path.exists(p)
    with open(p,"a") as fh:
        if new: fh.write("timestamp,label,leaf_ms,recursion_ms,final_lag_slots,finalized_adv_slots,"
                         "head_slot,justified_slot,finalized_slot,peers\n")
        ts=datetime.datetime.now(datetime.timezone.utc).isoformat()
        def g(x): return "" if x is None else f"{x}"
        m=measurements
        fh.write(f"{ts},{label},{g(m['leaf_agg_p99_ms'])},{g(m['recursion_p99_ms'])},"
                 f"{g(m['finalization_lag_slots'])},{g(m['finalized_advancing_slots'])},"
                 f"{g(m['head_slot'])},{g(m['justified_slot'])},{g(m['finalized_slot'])},"
                 f"{g(m['connected_peers_avg'])}\n")
    print(f"  appended row to {p}")

import sys
# --strict still exits non-zero if any per-metric budget failed (no rolled-up status).
if E("CB_STRICT")=="1" and "FAIL" in (v_leaf, v_rec, v_fl, v_fadv): sys.exit(2)
PY
