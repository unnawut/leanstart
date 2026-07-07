#!/usr/bin/env python3
"""Merge run config (env) + measurements JSON into a per-run result file and
append a row to the consolidated runs.csv.

Inputs (all via environment, set by gke-sweep.sh):
  LS_RESULTS_DIR        output dir (default ./results)
  LS_RUN_ID             unique run id (also the json filename stem)
  LS_TIMESTAMP          ISO8601 UTC
  LS_STATUS             run-level status when there are no measurements
                        (e.g. "error" if deploy failed). Ignored if the
                        measurements JSON is present (overall verdict wins).
  LS_MEASUREMENTS_JSON  path to check-budgets --json-out (optional)
  config fields: LS_CLIENTS LS_SUBNETS LS_VPP LS_TOTAL_VALIDATORS
                 LS_AGG_HOSTS LS_LEAF_MACHINE LS_AGG_MACHINE LS_WORKERS_MACHINE
                 LS_ZONE LS_SPOT LS_GENESIS_OFFSET LS_SETTLE LS_WINDOW
                 LS_CLUSTER LS_PROJECT LS_LEANSTART_SHA LS_REAM_IMAGE

Writes:
  <results_dir>/<run_id>.json       full per-run record
  <results_dir>/consolidated.csv    one flattened row per run (header auto-created)
"""
import os, json, csv

SCHEMA_VERSION = 1
E = os.environ.get

def _int(x):
    try: return int(x)
    except (TypeError, ValueError): return None

def _cores(machine):
    # vCPU count from a GCE machine type, e.g. "c4-standard-16" -> 16.
    try: return int(str(machine).rsplit("-", 1)[1])
    except (IndexError, ValueError, AttributeError): return None

# Columns that are whole numbers (slots, counts) — normalize "175.0" -> "175".
_INT_COLS = ("finalization_lag_slots", "finalized_advancing_slots", "fast_confirm_lag_slots",
             "sigs_aggregated_total", "head_slot", "justified_slot", "finalized_slot")

def _heal(er, fieldnames):
    # Backfill/normalize an older CSV row when the schema is rewritten.
    out = {k: er.get(k, "") for k in fieldnames}
    if not out.get("aggregator_cores"):
        out["aggregator_cores"] = _cores(er.get("aggregator_machine")) or ""
    if not out.get("non_aggregator_cores"):
        out["non_aggregator_cores"] = _cores(er.get("workers_machine")) or ""
    for col in _INT_COLS:
        v = out.get(col)
        if v not in (None, ""):
            try: out[col] = int(round(float(v)))
            except (TypeError, ValueError): pass
    return out

def main():
    results_dir = E("LS_RESULTS_DIR", "./results")
    run_id = E("LS_RUN_ID") or "unknown-run"
    os.makedirs(results_dir, exist_ok=True)

    config = {
        "clients":            E("LS_CLIENTS"),
        "subnets":            _int(E("LS_SUBNETS")),
        "validators_per_pod": _int(E("LS_VPP")),
        "total_validators":   _int(E("LS_TOTAL_VALIDATORS")),
        "aggregator_hosts":   [h for h in (E("LS_AGG_HOSTS", "")).split(",") if h],
        "leaf_machine":       E("LS_LEAF_MACHINE"),
        "aggregator_machine": E("LS_AGG_MACHINE"),
        "workers_machine":    E("LS_WORKERS_MACHINE"),
        "zone":               E("LS_ZONE"),
        "spot":               E("LS_SPOT") == "1",
        "genesis_offset_s":   _int(E("LS_GENESIS_OFFSET")),
        "settle_s":           _int(E("LS_SETTLE")),
        "window":             E("LS_WINDOW"),
        "cluster":            E("LS_CLUSTER"),
        "project":            E("LS_PROJECT"),
        "leanstart_sha":      E("LS_LEANSTART_SHA"),
        "ream_image":         E("LS_REAM_IMAGE"),
    }

    budgets = measurements = verdicts = None
    mpath = E("LS_MEASUREMENTS_JSON")
    if mpath and os.path.exists(mpath):
        with open(mpath) as fh:
            m = json.load(fh)
        budgets, measurements, verdicts = m.get("budgets"), m.get("measurements"), m.get("verdicts")

    record = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "timestamp": E("LS_TIMESTAMP"),
        "config": config,
        "budgets": budgets,
        "measurements": measurements,
        "verdicts": verdicts,
    }

    json_path = os.path.join(results_dir, f"{run_id}.json")
    with open(json_path, "w") as fh:
        json.dump(record, fh, indent=2)
    print(f"  wrote per-run result -> {json_path}")

    # Flattened consolidated CSV row.
    m = measurements or {}
    b = budgets or {}
    row = {
        "run_id": run_id,
        "timestamp": record["timestamp"],
        "clients": config["clients"],
        "subnets": config["subnets"],
        "validators_per_pod": config["validators_per_pod"],
        "total_validators": config["total_validators"],
        "leaf_machine": config["leaf_machine"],
        "aggregator_machine": config["aggregator_machine"],
        "workers_machine": config["workers_machine"],
        # Cores per role: aggregators run on the aggregator pool, non-aggregators
        # on the workers pool.
        "aggregator_cores": _cores(config["aggregator_machine"]),
        "non_aggregator_cores": _cores(config["workers_machine"]),
        "zone": config["zone"],
        "spot": config["spot"],
        "genesis_offset_s": config["genesis_offset_s"],
        "settle_s": config["settle_s"],
        "window": config["window"],
        "leaf_agg_p99_ms": m.get("leaf_agg_p99_ms"),
        "recursion_p99_ms": m.get("recursion_p99_ms"),
        "finalization_lag_slots": m.get("finalization_lag_slots"),
        "finalized_advancing_slots": m.get("finalized_advancing_slots"),
        "fast_confirm_lag_slots": m.get("fast_confirm_lag_slots"),
        "avg_sigs_per_agg": m.get("avg_sigs_per_agg"),
        "sigs_aggregated_total": m.get("sigs_aggregated_total"),
        "head_slot": m.get("head_slot"),
        "justified_slot": m.get("justified_slot"),
        "finalized_slot": m.get("finalized_slot"),
        "connected_peers_avg": m.get("connected_peers_avg"),
        "cpu_agg_cores_avg": m.get("cpu_agg_cores_avg"),
        "cpu_nonagg_cores_avg": m.get("cpu_nonagg_cores_avg"),
        "mem_agg_mib_avg": m.get("mem_agg_mib_avg"),
        "mem_nonagg_mib_avg": m.get("mem_nonagg_mib_avg"),
        "leaf_budget_ms": b.get("leaf_ms"),
        "recursion_budget_ms": b.get("recursion_ms"),
        "final_slots_budget": b.get("final_slots"),
        "leanstart_sha": config["leanstart_sha"],
        "ream_image": config["ream_image"],
    }
    csv_path = os.path.join(results_dir, "consolidated.csv")
    fieldnames = list(row.keys())
    old_fields, existing_rows = None, []
    if os.path.exists(csv_path):
        with open(csv_path, newline="") as fh:
            r = csv.DictReader(fh)
            old_fields, existing_rows = r.fieldnames, list(r)

    if old_fields == fieldnames:
        # Header already matches — cheap append.
        with open(csv_path, "a", newline="") as fh:
            csv.DictWriter(fh, fieldnames=fieldnames).writerow(row)
    else:
        # New file or schema changed (columns added/removed): rewrite with the
        # current header, healing older rows — backfill derived cores from the
        # recorded machine type and normalize whole-number slot/count columns.
        with open(csv_path, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
            w.writeheader()
            for er in existing_rows:
                w.writerow(_heal(er, fieldnames))
            w.writerow(row)
    print(f"  appended consolidated row -> {csv_path}")

if __name__ == "__main__":
    main()
