# leanstart GKE topology-sweep tooling

Run a leanstart devnet on an **ephemeral GKE cluster** and measure whether a
given aggregation topology meets the budgets:

- **leaf aggregation** ≤ 600 ms (the 800 ms aggregate interval minus 200 ms
  propagation, per the pq-devnet feasibility model)
- **recursion** ≤ 2400 ms (configurable working budget)
- **finalization** holds ≤ 3 slots behind head

plus tracking of **fast-confirmation (safe-target) lag** as you scale validators
and subnets. Budgets and node tiers are anchored to lean-bench's
aggregation-topology feasibility analysis (bench.leanroadmap.org/topology.html) —
see *Why these defaults* below.

> Status: **local / experimental.** Not wired into CI or committed upstream yet.
> First runs should be watched; the EXIT trap deletes the cluster, but confirm
> in the GCP console after an early run.

## Scripts

| Script | Purpose |
|---|---|
| `gke-sweep.sh` | **Primary.** One topology, end-to-end: provision → `leanstart run` → settle → `check-budgets.sh` → delete cluster (even on Ctrl-C/failure). |
| `check-budgets.sh` | Query a running devnet's Prometheus and print PASS/FAIL vs budgets. Works against **any** context — local `kind` too. |
| `watch-progress.sh` | Poll Prometheus during the settle and log `head/just/fin/safe/peers` on an interval, so the sweep log shows live chain movement instead of a blank soak. Observer only (always exits 0); wired into `gke-sweep.sh`. |
| `gke-up.sh` | Standalone: provision a cluster and leave it up for manual poking. |
| `gke-down.sh` | Standalone teardown / cost safety-net. Idempotent. |
| `gke-lib.sh` | Shared, scoped-auth helpers (sourced by the others). |

## Prerequisites

- `gcloud`, `kubectl`, `helm`, `curl`, `python3`
- `gke-gcloud-auth-plugin` — `gcloud components install gke-gcloud-auth-plugin`
  (the GKE kubeconfig auth provider needs it)
- A built `leanstart` binary (`cargo build` → `target/debug/leanstart`), or pass
  `--leanstart <path>`
- A GCP service-account JSON key (see IAM below)

Auth is **fully scoped**: each run activates the SA inside a throwaway
`CLOUDSDK_CONFIG`, and `KUBECONFIG` points at a throwaway file — your personal
`gcloud`/`kubectl` session and `~/.kube/config` are never touched (mirrors
leanBench's provisioner).

## One-time GCP / IAM setup

Reuse the **same project** as leanBench. You can extend leanBench's SA or make a
dedicated one. The cluster-lifecycle SA needs Kubernetes Engine admin plus the
ability to attach the node service account:

```bash
PROJECT=<your-project-id>
gcloud config set project "$PROJECT"

# Enable the API
gcloud services enable container.googleapis.com --project "$PROJECT"

# Dedicated SA (or reuse lean-bench@...):
gcloud iam service-accounts create leanstart-gke \
  --display-name "leanstart GKE sweeps" --project "$PROJECT"
SA="leanstart-gke@${PROJECT}.iam.gserviceaccount.com"

# Kubernetes Engine Admin: create/delete clusters + node pools, get credentials
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA}" --role roles/container.admin

# Let GKE attach the default compute SA to the nodes it creates
PROJNUM=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
gcloud iam service-accounts add-iam-policy-binding \
  "${PROJNUM}-compute@developer.gserviceaccount.com" \
  --member "serviceAccount:${SA}" --role roles/iam.serviceAccountUser \
  --project "$PROJECT"

# Key file (gitignored — never commit)
gcloud iam service-accounts keys create gcp-credentials.json --iam-account "$SA"
```

> `roles/container.admin` is broad by nature (cluster admin). A tighter custom
> role (`container.clusters.*`, `container.operations.*`, node-pool perms) is
> possible later; start here to get robust, then narrow.

## Configuration via `.env` (optional)

Instead of passing `--credentials` (and zone/machine flags) every time, copy
`.env.example` to `.env` at the repo root and set them once:

```bash
cp .env.example .env
# edit: GKE_CREDENTIALS=./gcp-credentials.json  (+ optional GKE_PROJECT, GKE_ZONE, …)
```

The scripts auto-load it (repo-root `.env`, or `$LEANSTART_ENV`, or `./.env`). A
relative `GKE_CREDENTIALS` is resolved against the `.env`'s directory, so it
works from any working directory. With `GKE_CREDENTIALS` set you can drop
`--credentials` from every command. `.env` is gitignored; the JSON key stays a
file (gcloud needs a file path, not inline contents). Flags still override
`.env` values.

## Usage

### Run a single topology

```bash
# 10 validators across 2 subnets (5 pods/subnet, 1 validator each), Spot nodes.
scripts/cloud/gke-sweep.sh \
  --clients "ream:5" --subnets 2 --validators-per-pod 1
```

This provisions a workers pool + `agg0` and `agg1` aggregator nodes, deploys with
`--aggregator-hosts agg0,agg1` so each subnet's aggregator owns a dedicated node,
soaks, prints the budget table, writes a result record, and deletes the cluster.

### Scale up / sweep

Invoke once per topology (each gets a clean ephemeral cluster — the chosen
lifecycle); all runs accumulate in the same `results/` dir:

```bash
for s in 2 3 4 5; do
  scripts/cloud/gke-sweep.sh --clients "ream:5" --subnets "$s"
done
```

## Results

Each run writes two things under `--results-dir` (default `./results/`):

- **`<run_id>.json`** — a full per-run record: `config` (clients, subnets,
  validators, leaf/aggregator/workers machine types, zone, spot, settle/genesis,
  cluster, project, leanstart SHA, ream image), `budgets`, `measurements`, and
  `verdicts`. `run_id` = `<UTC-stamp>__<topology-slug>` (e.g.
  `20260621T0300Z__ream4-s1-vpp1`).
- **`consolidated.csv`** — one flattened row per run appended across every sweep, for
  side-by-side comparison. Columns include the full config plus
  `leaf_agg_p99_ms`, `recursion_p99_ms`, `finalization_lag_slots`,
  `finalized_advancing_slots`, `fast_confirm_lag_slots`, `head_slot`,
  `justified_slot`, `finalized_slot`, `connected_peers_avg`, the budgets, and
  `status`.

`results/` is committed (shared dataset, like leanBench's). Watching
`consolidated.csv` as you scale subnets/validators shows the fast-confirmation
and finalization delays grow.

### Measure a devnet you already have running (incl. local kind)

```bash
# table only, or --json-out to capture a measurements JSON
scripts/cloud/check-budgets.sh --context kind-lean-devnet
```

### Manual cluster / safety net

```bash
scripts/cloud/gke-up.sh   --credentials gcp-credentials.json --subnets 2   # leaves it up
scripts/cloud/gke-down.sh --credentials gcp-credentials.json                # tear down
```

## Why these defaults

From lean-bench's measured `flat()`/`recursion()` cost models (devnet4,
`log_inv_rate=2`), recursion is the binding, strongly core-bound constraint:

| machine | leaf flat(625) | rec fan-in 4 | rec fan-in 8 |
|---|---|---|---|
| c4-standard-16 | 2062 ms | 1921 ms | 3821 ms |
| c4-standard-32 | 1520 ms | 1484 ms | 2928 ms |

c4-standard-16 has thin-to-negative headroom at fan-in ≥ 4, so the **aggregator
pool defaults to `c4-standard-32`** and the **leaf pool to `c4-standard-16`**
(both `--agg-machine` / `--leaf-machine` overridable). Zone defaults to
`us-central1-a` and nodes to Spot, matching leanBench. The right tier ultimately
matches the machine you select in the topology explorer for your target
topology — these are starting points, not law.

## Cost

Ephemeral: the cluster and nodes exist only during a sweep and are deleted on
exit. A single zonal cluster's control-plane fee is covered by the GKE free
tier; you pay only Spot node-hours during the run. `gke-down.sh` is the
safety-net if a run is killed before its trap fires.

## Caveat

`check-budgets.sh` reads the **consensus client's** metrics
(`lean_committee_signatures_aggregation_time`,
`lean_block_building_payload_aggregation_time`), whereas lean-bench measures the
**leanVM proving primitive** in isolation. Confirming the two agree on the same
c4 tier is precisely the point of running this.
