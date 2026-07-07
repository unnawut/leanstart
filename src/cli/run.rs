use std::path::{Path, PathBuf};
use std::process::Command;
use std::{fs, thread, time};

use anyhow::{bail, Context, Result};
use clap::Args;

use crate::config::clients::{get_client, CLIENTS};
use crate::config::generator::{
    generate_validator_config, write_validator_config, ValidatorConfig,
};
use crate::config::spec::{parse_client_spec, ClientAllocation, DevnetSpec, MAX_SUBNETS};
use crate::genesis::runner::{
    append_genesis_validators, generate_annotated_validators, run_genesis_tool, write_config_yaml,
};
use crate::k8s::values::{generate_helm_values, generate_pod_secrets, write_helm_values};
use crate::keys::keygen::{generate_hash_sig_keys, write_node_keys};

/// Run a devnet with the specified clients.
///
/// Examples:
///   leanstart ream zeam:2
///   leanstart ream:3
///   leanstart ream:1 zeam:2 grandine:3 --namespace my-devnet
#[derive(Debug, Args)]
pub struct RunArgs {
    /// Client specs: "ream", "zeam:2", "grandine:3", etc.
    #[arg(required = true)]
    pub clients: Vec<String>,

    /// Kubernetes namespace.
    #[arg(long, default_value = "lean-devnet")]
    pub namespace: String,

    /// Kind cluster name.
    #[arg(long, default_value = "lean-devnet")]
    pub cluster: String,

    /// Output directory for generated artifacts.
    #[arg(long, default_value = "./output")]
    pub output_dir: PathBuf,

    /// Validators per pod.
    #[arg(long, default_value = "1")]
    pub validators_per_pod: u32,

    /// Hash-sig active epoch exponent.
    #[arg(long, default_value = "18")]
    pub active_epoch: u32,

    /// Seconds until genesis time.
    #[arg(long, default_value = "120")]
    pub genesis_offset: u32,

    /// Hex-encoded 32-byte seed for deterministic key generation.
    #[arg(
        long,
        default_value = "0000000000000000000000000000000000000000000000000000000000000001"
    )]
    pub seed: String,

    /// Skip deployment, only generate config files.
    #[arg(long)]
    pub config_only: bool,

    /// Kubernetes storage class for PVCs.
    #[arg(long)]
    pub storage_class: Option<String>,

    /// Number of bootnode pods per client type.
    #[arg(long, default_value = "5")]
    pub bootnode_count: u32,

    /// Number of attestation subnets (1..=5). Each client allocation is
    /// replicated once per subnet and one aggregator per subnet is selected.
    #[arg(long, default_value = "1")]
    pub subnets: u32,

    /// Override config.attestation_committee_count. Defaults to --subnets.
    #[arg(long)]
    pub attestation_committee_count: Option<u32>,

    /// Comma-separated per-subnet host labels for aggregator placement, e.g.
    /// `agg0,agg1`. Pins the aggregator pod of subnet i to the node labelled
    /// `leanstart.io/host=<label>`, overriding any client `@host`. Must list
    /// exactly one label per subnet. Used by the GKE sweep tooling to give each
    /// subnet aggregator a dedicated node.
    #[arg(long, value_delimiter = ',')]
    pub aggregator_hosts: Vec<String>,

    /// Skip Kind cluster creation and image loading. Use when targeting an
    /// existing multi-node K8s cluster instead of a local Kind cluster.
    #[arg(long)]
    pub skip_kind: bool,

    /// Override the kubectl/helm context. Defaults to `kind-{cluster}`.
    /// Required when using --skip-kind.
    #[arg(long)]
    pub context: Option<String>,

    /// Skip installing kube-prometheus-stack (e.g. if it is already installed).
    #[arg(long)]
    pub skip_metrics: bool,
}

pub fn run(args: RunArgs) -> Result<()> {
    // Each invocation writes to its own timestamped subdir under
    // <output_dir>/runs/, with a `latest` symlink pointing at the newest one.
    fs::create_dir_all(&args.output_dir)
        .with_context(|| format!("Failed to create {}", args.output_dir.display()))?;
    let run_dir = create_run_dir(&args.output_dir)?;

    // Tee all stdout/stderr (including subprocess output) to a log file so the
    // user has a complete record of the run.
    let log_path = crate::logging::init(&run_dir)?;
    println!("Logging this run to {}", log_path.display());

    let result = run_inner(args, &run_dir);
    crate::logging::shutdown();
    result
}

fn run_inner(args: RunArgs, run_dir: &Path) -> Result<()> {
    let clients: Vec<ClientAllocation> = args
        .clients
        .iter()
        .map(|s| parse_client_spec(s))
        .collect::<Result<_>>()?;

    for c in &clients {
        if get_client(&c.name).is_none() {
            let known: Vec<&str> = CLIENTS.iter().map(|c| c.name).collect();
            bail!(
                "Unknown client '{}'. Known clients: {}",
                c.name,
                known.join(", ")
            );
        }
    }

    if args.subnets == 0 || args.subnets > MAX_SUBNETS {
        bail!(
            "--subnets must be between 1 and {} (got {})",
            MAX_SUBNETS,
            args.subnets
        );
    }

    let total_instances: u32 = clients.iter().map(|c| c.instances).sum::<u32>() * args.subnets;
    let total_validators = total_instances * args.validators_per_pod;

    if args.subnets > 1 {
        println!(
            "Devnet: {} subnets, {} pods, {} validators",
            args.subnets, total_instances, total_validators
        );
    } else {
        println!(
            "Devnet: {} instances, {} validators",
            total_instances, total_validators
        );
    }
    for c in &clients {
        let def = get_client(&c.name).unwrap();
        println!("  {} x{} ({})", c.name, c.instances, def.image);
    }
    println!();

    let seed = {
        let bytes = hex::decode(&args.seed)?;
        let arr: [u8; 32] = bytes
            .try_into()
            .map_err(|v: Vec<u8>| anyhow::anyhow!("Seed must be 32 bytes, got {}", v.len()))?;
        arr
    };

    let spec = DevnetSpec {
        clients,
        validators_per_pod: args.validators_per_pod,
        namespace: args.namespace.clone(),
        output_dir: args.output_dir.clone(),
        active_epoch: args.active_epoch,
        key_type: "hash-sig".to_string(),
        seed,
        genesis_offset: args.genesis_offset,
        storage_class: args.storage_class.clone(),
        bootnode_count: args.bootnode_count,
        subnets: args.subnets,
        attestation_committee_count: args.attestation_committee_count,
        aggregator_hosts: args.aggregator_hosts.clone(),
        // Remote multi-node clusters (--skip-kind) use the injected gated-init
        // path; local kind keeps the legacy shared-PVC + restart path.
        injected: args.skip_kind,
    };

    let genesis_dir = args.output_dir.join("genesis");
    let chart_dir = find_chart_dir()?;

    // Step 1: Generate validator-config.yaml (with placeholder IPs)
    println!("==> Generating validator config...");
    let vc = generate_validator_config(&spec)?;
    write_validator_config(&vc, &genesis_dir)?;

    let key_pairs: Vec<(String, String)> = vc
        .validators
        .iter()
        .map(|v| (v.name.clone(), v.privkey.clone()))
        .collect();
    write_node_keys(&key_pairs, &genesis_dir)?;

    // Step 2: Generate genesis artifacts (hash-sig keys + eth-beacon-genesis +
    // GENESIS_VALIDATORS + annotated_validators.yaml). Pod IPs are placeholders
    // here — fix_peer_ips re-runs the latter steps after pods get real IPs.
    let total_validators_for_keys: u32 = vc.validators.iter().map(|v| v.count).sum();
    println!(
        "==> Generating hash-sig keys for {total_validators_for_keys} validators..."
    );
    generate_hash_sig_keys(total_validators_for_keys, args.active_epoch, &genesis_dir)?;

    println!("==> Writing config.yaml...");
    write_config_yaml(&vc, args.genesis_offset, &genesis_dir)?;

    println!("==> Running genesis generation...");
    run_genesis_tool(&genesis_dir)?;
    append_genesis_validators(&vc, &genesis_dir)?;
    generate_annotated_validators(&genesis_dir)?;

    if args.config_only {
        println!("==> Generating Helm values...");
        let helm_values = generate_helm_values(&spec, &vc)?;
        write_helm_values(&helm_values, &args.output_dir)?;
        generate_pod_secrets(&vc, &spec.namespace, &args.output_dir)?;
        println!("\nConfig generated in {}", args.output_dir.display());
        return Ok(());
    }

    let context = args
        .context
        .clone()
        .unwrap_or_else(|| format!("kind-{}", args.cluster));

    // Step 3: Create kind cluster (skipped for existing clusters)
    if !args.skip_kind {
        println!("==> Creating kind cluster '{}'...", args.cluster);
        create_kind_cluster(&args.cluster)?;

        println!("==> Loading Docker images into kind...");
        load_images_into_kind(&spec, &args.cluster)?;
    }

    // Step 4: Install metrics stack
    if !args.skip_metrics {
        install_metrics_stack(&context)?;
    }

    // Step 5: Generate Helm values
    println!("==> Generating Helm values...");
    let helm_values = generate_helm_values(&spec, &vc)?;
    write_helm_values(&helm_values, &args.output_dir)?;
    generate_pod_secrets(&vc, &spec.namespace, &args.output_dir)?;

    // Step 6: Create K8s resources and deploy
    println!("==> Deploying to Kubernetes...");
    setup_k8s_resources(
        &context,
        &args.namespace,
        &vc,
        &genesis_dir,
        &args.output_dir,
        spec.injected,
    )?;
    helm_install(
        &context,
        &args.namespace,
        &chart_dir,
        &args.output_dir,
        !args.skip_metrics,
    )?;

    // Derive expected pod names from the validator config.
    let pod_names: Vec<(String, String)> = vc
        .validators
        .iter()
        .map(|e| {
            let k8s_name = e.name.replace('_', "-");
            (format!("{k8s_name}-0"), e.name.clone())
        })
        .collect();

    // Step 7: Wait for pods, fix peer discovery.
    if spec.injected {
        // Remote multi-node: gated-init. Pods block in their init container
        // until we inject IP-correct genesis + this pod's keys, then start the
        // client exactly once (no restart, no shared PVC, no docker/crictl).
        println!("==> Waiting for pods to be scheduled (IP assignment)...");
        if let Err(e) = wait_for_pods_scheduled(&context, &args.namespace, &pod_names) {
            snapshot_previous_logs(&context, &args.namespace, &pod_names, run_dir);
            eprintln!(
                "\nSome pods failed to schedule. Check {} for details.",
                run_dir.display()
            );
            return Err(e);
        }

        println!("==> Injecting peer discovery + keys (gated-init)...");
        inject_peers_gated(
            &context,
            &args.namespace,
            &vc,
            &genesis_dir,
            args.genesis_offset,
            &pod_names,
        )?;

        println!("==> Waiting for pods to be ready...");
        if let Err(e) = wait_for_pods(&context, &args.namespace, &vc) {
            snapshot_previous_logs(&context, &args.namespace, &pod_names, run_dir);
            eprintln!(
                "\nSome pods failed to become ready. Check {} for details.",
                run_dir.display()
            );
            return Err(e);
        }
    } else {
        println!("==> Waiting for pods...");
        if let Err(e) = wait_for_pods(&context, &args.namespace, &vc) {
            // Snapshot --previous logs for any pod that crashed so the user has a
            // record on disk before we bail (streaming hasn't started yet).
            snapshot_previous_logs(&context, &args.namespace, &pod_names, run_dir);
            eprintln!(
                "\nSome pods failed to become ready. Check {} for details.",
                run_dir.display()
            );
            return Err(e);
        }

        println!("==> Fixing peer discovery...");
        fix_peer_ips(
            &context,
            &args.namespace,
            &args.cluster,
            &vc,
            &genesis_dir,
            args.genesis_offset,
            &pod_names,
        )?;
    }

    // Stream logs AFTER peer discovery: the kind path restarts containers and we
    // want the long-running ones; the injected path starts each client exactly
    // once after the sentinel is dropped.
    println!("==> Streaming logs to {}/...", run_dir.display());
    start_log_streaming(&context, &args.namespace, &pod_names, run_dir)?;

    if !args.skip_metrics {
        provision_grafana_dashboard(&context)?;
        start_metrics_port_forwards(&context)?;
    }

    // Done
    println!("\nDevnet is running!");
    println!("  Logs:    {}/", run_dir.display());
    println!("  Status:  leanstart status");
    println!("  Stop:    leanstart destroy");
    if !args.skip_metrics {
        println!();
        println!("Metrics:");
        println!("  Grafana:    http://localhost:3000  (admin / admin)");
        println!("  Prometheus: http://localhost:9090");
    }

    Ok(())
}

/// Create `<output_dir>/runs/<timestamp>/` and refresh the `latest` symlink
/// to point at it.
fn create_run_dir(output_dir: &Path) -> Result<PathBuf> {
    let runs_root = output_dir.join("runs");
    fs::create_dir_all(&runs_root)?;

    let ts = run_timestamp();
    let run_dir = runs_root.join(&ts);
    fs::create_dir_all(&run_dir)?;

    let latest = runs_root.join("latest");
    let _ = fs::remove_file(&latest);
    #[cfg(unix)]
    std::os::unix::fs::symlink(&ts, &latest)?;

    Ok(run_dir)
}

/// Local-time `YYYY-MM-DD_HH-MM-SS` for run-dir names. Uses libc rather than
/// pulling in chrono.
fn run_timestamp() -> String {
    let now = time::SystemTime::now()
        .duration_since(time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&now, &mut tm) };
    format!(
        "{:04}-{:02}-{:02}_{:02}-{:02}-{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec
    )
}

/// Find the Helm chart directory.
fn find_chart_dir() -> Result<PathBuf> {
    let candidates = [
        PathBuf::from("helm/lean-devnet"),
        PathBuf::from("../leanstart/helm/lean-devnet"),
    ];
    for p in &candidates {
        if p.join("Chart.yaml").exists() {
            return Ok(fs::canonicalize(p)?);
        }
    }
    // Try relative to the executable
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent().and_then(|p| p.parent()) {
            let p = dir.join("helm/lean-devnet");
            if p.join("Chart.yaml").exists() {
                return Ok(p);
            }
        }
    }
    bail!("Helm chart not found. Run from the leanstart project directory.")
}

/// Create a kind cluster if it doesn't already exist.
fn create_kind_cluster(name: &str) -> Result<()> {
    let output = Command::new("kind")
        .args(["get", "clusters"])
        .output()
        .context("kind not found. Install with: brew install kind")?;

    let clusters = String::from_utf8_lossy(&output.stdout);
    if clusters.lines().any(|l| l.trim() == name) {
        println!("  Cluster '{}' already exists, reusing.", name);
        return Ok(());
    }

    let status = Command::new("kind")
        .args(["create", "cluster", "--name", name])
        .status()?;

    if !status.success() {
        bail!("Failed to create kind cluster");
    }
    Ok(())
}

/// Load required Docker images into the kind cluster.
fn load_images_into_kind(spec: &DevnetSpec, cluster: &str) -> Result<()> {
    let node = format!("{cluster}-control-plane");

    // Collect unique images
    let mut images: Vec<String> = Vec::new();
    for c in &spec.clients {
        let def = get_client(&c.name).unwrap();
        let image = def.image.to_string();
        if !images.contains(&image) {
            images.push(image);
        }
    }

    for image in &images {
        println!("  Loading {}...", image);

        // Always pull to ensure we have the latest version
        let status = Command::new("docker").args(["pull", image]).status()?;
        if !status.success() {
            bail!("Failed to pull image {image}. Check that the image exists in the registry.");
        }

        // Load into kind via docker save | ctr import
        let status = Command::new("sh")
            .args([
                "-c",
                &format!(
                    "docker save {image} | docker exec -i {node} ctr --namespace=k8s.io images import --no-unpack -"
                ),
            ])
            .status()?;

        if !status.success() {
            eprintln!("  Warning: failed to load {image} into kind (may already be present)");
        }
    }

    Ok(())
}

/// Set up K8s namespace, ConfigMap, PVC, secrets, and load hash-sig keys.
///
/// In `injected` (multi-node) mode the shared genesis PVC and the hash-sig
/// loader pod are skipped — `inject_peers_gated` copies IP-correct genesis and
/// each pod's own keys straight into its init container instead.
fn setup_k8s_resources(
    context: &str,
    namespace: &str,
    vc: &ValidatorConfig,
    genesis_dir: &PathBuf,
    output_dir: &PathBuf,
    injected: bool,
) -> Result<()> {
    let kc = |args: &[&str]| -> Result<bool> {
        let status = Command::new("kubectl")
            .args(["--context", context])
            .args(args)
            .status()?;
        Ok(status.success())
    };

    // Create namespace with Helm labels, wait for service account
    let _ = kc(&["create", "namespace", namespace]);
    thread::sleep(time::Duration::from_secs(3));
    let _ = kc(&[
        "label",
        "namespace",
        namespace,
        "app.kubernetes.io/managed-by=Helm",
        "--overwrite",
    ]);
    let _ = kc(&[
        "annotate",
        "namespace",
        namespace,
        &format!("meta.helm.sh/release-name={namespace}"),
        &format!("meta.helm.sh/release-namespace={namespace}"),
        "--overwrite",
    ]);

    // Create ConfigMap with all genesis files
    let mut cm_args = vec![
        "create".to_string(),
        "configmap".to_string(),
        "genesis-config".to_string(),
        "-n".to_string(),
        namespace.to_string(),
    ];
    let genesis_files = [
        "config.yaml",
        "validators.yaml",
        "annotated_validators.yaml",
        "nodes.yaml",
        "genesis.json",
        "genesis.ssz",
        "validator-config.yaml",
    ];
    for f in &genesis_files {
        let path = genesis_dir.join(f);
        if path.exists() {
            cm_args.push(format!("--from-file={}={}", f, path.display()));
        }
    }
    // Add node key files
    for entry in &vc.validators {
        let key_path = genesis_dir.join(format!("{}.key", entry.name));
        if key_path.exists() {
            cm_args.push(format!(
                "--from-file={}.key={}",
                entry.name,
                key_path.display()
            ));
        }
    }
    let cm_refs: Vec<&str> = cm_args.iter().map(|s| s.as_str()).collect();
    kc(&cm_refs)?;

    // Shared genesis PVC + hash-sig loader pod are only for the legacy kind
    // path. Injected mode delivers keys per-pod via inject_peers_gated instead.
    if !injected {
    // Create PVC
    let pvc_yaml = format!(
        "apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata:\n  name: genesis-data\n  namespace: {namespace}\nspec:\n  accessModes: [ReadWriteOnce]\n  resources:\n    requests:\n      storage: 1Gi\n"
    );
    let mut child = Command::new("kubectl")
        .args(["--context", context, "apply", "-n", namespace, "-f", "-"])
        .stdin(std::process::Stdio::piped())
        .spawn()?;
    use std::io::Write;
    child.stdin.take().unwrap().write_all(pvc_yaml.as_bytes())?;
    child.wait()?;

    // Load hash-sig keys into PVC via a loader pod
    let hash_sig_dir = genesis_dir.join("hash-sig-keys");
    if hash_sig_dir.exists() {
        println!("  Loading hash-sig keys into PVC...");
        let loader_yaml = format!(
            "apiVersion: v1\nkind: Pod\nmetadata:\n  name: genesis-loader\n  namespace: {namespace}\nspec:\n  containers:\n  - name: loader\n    image: busybox:1.36\n    command: [\"sleep\", \"3600\"]\n    volumeMounts:\n    - name: genesis-data\n      mountPath: /genesis\n  volumes:\n  - name: genesis-data\n    persistentVolumeClaim:\n      claimName: genesis-data\n  restartPolicy: Never\n"
        );
        let mut child = Command::new("kubectl")
            .args(["--context", context, "apply", "-n", namespace, "-f", "-"])
            .stdin(std::process::Stdio::piped())
            .spawn()?;
        child
            .stdin
            .take()
            .unwrap()
            .write_all(loader_yaml.as_bytes())?;
        child.wait()?;

        // Wait for loader pod
        let _ = Command::new("kubectl")
            .args([
                "--context",
                context,
                "wait",
                "--for=condition=ready",
                "pod/genesis-loader",
                "-n",
                namespace,
                "--timeout=60s",
            ])
            .status()?;

        let _ = Command::new("kubectl")
            .args([
                "--context",
                context,
                "exec",
                "genesis-loader",
                "-n",
                namespace,
                "--",
                "mkdir",
                "-p",
                "/genesis/hash-sig-keys",
            ])
            .status()?;

        let _ = Command::new("kubectl")
            .args([
                "--context",
                context,
                "cp",
                &format!("{}/", hash_sig_dir.display()),
                &format!("{namespace}/genesis-loader:/genesis/hash-sig-keys/"),
            ])
            .status()?;

        // Flatten nested dir if kubectl cp created one
        let _ = Command::new("kubectl")
            .args(["--context", context, "exec", "genesis-loader", "-n", namespace,
                   "--", "sh", "-c",
                   "if [ -d /genesis/hash-sig-keys/hash-sig-keys ]; then mv /genesis/hash-sig-keys/hash-sig-keys/* /genesis/hash-sig-keys/ && rmdir /genesis/hash-sig-keys/hash-sig-keys; fi"])
            .status()?;

        let _ = Command::new("kubectl")
            .args([
                "--context",
                context,
                "delete",
                "pod",
                "genesis-loader",
                "-n",
                namespace,
            ])
            .status()?;
    }
    } // end if !injected

    // Apply secrets
    let secrets_dir = output_dir.join("secrets");
    if secrets_dir.exists() {
        let _ = Command::new("kubectl")
            .args([
                "--context",
                context,
                "apply",
                "-f",
                &secrets_dir.display().to_string(),
                "-n",
                namespace,
            ])
            .status()?;
    }

    Ok(())
}

/// Wait until every pod exists and has been assigned a pod IP. In injected mode
/// pods deliberately block in their init container, so we wait for scheduling
/// (IP assignment) rather than readiness.
fn wait_for_pods_scheduled(
    context: &str,
    namespace: &str,
    pods: &[(String, String)],
) -> Result<()> {
    let deadline = time::Instant::now() + time::Duration::from_secs(180);
    for (pod_name, _) in pods {
        print!("  Waiting for {pod_name} to be scheduled...");
        loop {
            let output = Command::new("kubectl")
                .args([
                    "--context", context, "get", "pod", pod_name, "-n", namespace,
                    "-o", "jsonpath={.status.podIP}",
                ])
                .output()?;
            let ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !ip.is_empty() {
                println!(" {ip}");
                break;
            }
            if time::Instant::now() > deadline {
                println!();
                bail!("Pod {pod_name} was not assigned an IP within timeout");
            }
            thread::sleep(time::Duration::from_secs(2));
        }
    }
    Ok(())
}

/// Validator index range [start, end) each pod owns, derived from per-entry
/// `count` in generation order. Matches the hash-sig key file numbering
/// (`validator_<idx>_*`) and the manifest `index` fields.
fn pod_validator_indices(vc: &ValidatorConfig) -> Vec<(String, u32, u32)> {
    let mut out = Vec::new();
    let mut start = 0u32;
    for e in &vc.validators {
        out.push((e.name.clone(), start, start + e.count));
        start += e.count;
    }
    out
}

/// Build a hash-sig manifest containing only validators in [start, end),
/// preserving original `index` fields so a client still maps its global
/// validator index to the shipped key files.
fn filtered_manifest(hash_sig_dir: &Path, start: u32, end: u32) -> Result<String> {
    let path = hash_sig_dir.join("validator-keys-manifest.yaml");
    let content = fs::read_to_string(&path)?;
    let mut doc: serde_yaml::Value = serde_yaml::from_str(&content)?;
    if let Some(arr) = doc
        .get_mut("validators")
        .and_then(|v| v.as_sequence_mut())
    {
        arr.retain(|e| {
            e.get("index")
                .and_then(|i| i.as_u64())
                .map(|i| (i as u32) >= start && (i as u32) < end)
                .unwrap_or(false)
        });
        let n = arr.len();
        if let Some(nv) = doc.get_mut("num_validators") {
            *nv = serde_yaml::Value::Number(n.into());
        }
    }
    Ok(serde_yaml::to_string(&doc)?)
}

/// Gated-init peer discovery for remote multi-node clusters.
///
/// Pods are blocked in their init container (waiting on /config/.ready). For all
/// pods we read the assigned pod IPs, rewrite validator-config.yaml with the real
/// IPs, and regenerate signed ENRs once. Then, per pod, we copy the IP-correct
/// genesis files, the pod's node key, and the pod's own hash-sig keys into
/// /config and drop the sentinel — so each client starts exactly once with
/// correct peering. No container restart, no shared PVC, no docker/crictl.
fn inject_peers_gated(
    context: &str,
    namespace: &str,
    vc: &ValidatorConfig,
    genesis_dir: &PathBuf,
    genesis_offset: u32,
    pods: &[(String, String)],
) -> Result<()> {
    // 1. Read real pod IPs (entry_name -> ip), in pod (== entry) order.
    let mut ips: Vec<(String, String)> = Vec::new();
    for (pod_name, entry_name) in pods {
        let output = Command::new("kubectl")
            .args([
                "--context", context, "get", "pod", pod_name, "-n", namespace,
                "-o", "jsonpath={.status.podIP}",
            ])
            .output()?;
        let ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if ip.is_empty() {
            bail!("Pod {pod_name} has no IP");
        }
        println!("  {entry_name} -> {ip}");
        ips.push((entry_name.clone(), ip));
    }

    // 2. Rewrite validator-config.yaml IPs in entry order (one `ip:` per entry).
    let vc_path = genesis_dir.join("validator-config.yaml");
    let content = fs::read_to_string(&vc_path)?;
    let mut ip_idx = 0;
    let mut result = String::new();
    for line in content.lines() {
        if line.contains("ip:") && ip_idx < ips.len() {
            let indent = &line[..line.find("ip:").unwrap()];
            result.push_str(&format!("{indent}ip: \"{}\"\n", ips[ip_idx].1));
            ip_idx += 1;
        } else {
            result.push_str(line);
            result.push('\n');
        }
    }
    fs::write(&vc_path, &result)?;

    // 3. Regenerate genesis with real IPs (re-signed ENRs). Hash-sig keys are
    //    untouched — they already exist under genesis_dir/hash-sig-keys/.
    for f in &[
        "config.yaml", "genesis.ssz", "genesis.json", "nodes.yaml",
        "validators.yaml", "annotated_validators.yaml",
    ] {
        let _ = fs::remove_file(genesis_dir.join(f));
    }
    write_config_yaml(vc, genesis_offset, genesis_dir)?;
    run_genesis_tool(genesis_dir)?;
    append_genesis_validators(vc, genesis_dir)?;
    generate_annotated_validators(genesis_dir)?;

    // 4. Per-pod injection into the waiting init container.
    const INIT_C: &str = "resolve-peers";
    let genesis_files = [
        "config.yaml", "validators.yaml", "annotated_validators.yaml",
        "nodes.yaml", "genesis.json", "genesis.ssz", "validator-config.yaml",
    ];
    let hash_sig_dir = genesis_dir.join("hash-sig-keys");
    let ranges = pod_validator_indices(vc);

    for (pod_name, entry_name) in pods {
        let cp = |src: &Path, dest: &str| -> Result<()> {
            let status = Command::new("kubectl")
                .args([
                    "--context", context, "cp",
                    &src.display().to_string(),
                    &format!("{namespace}/{pod_name}:{dest}"),
                    "-c", INIT_C,
                ])
                .status()?;
            if !status.success() {
                bail!("kubectl cp {} -> {pod_name}:{dest} failed", src.display());
            }
            Ok(())
        };

        for f in &genesis_files {
            let src = genesis_dir.join(f);
            if src.exists() {
                cp(&src, &format!("/config/{f}"))?;
            }
        }

        let key_src = genesis_dir.join(format!("{entry_name}.key"));
        if key_src.exists() {
            cp(&key_src, &format!("/config/{entry_name}.key"))?;
        }

        // This pod's hash-sig keys: .ssz only (.json privkeys are ~55MB and
        // unused), plus a manifest filtered to this pod's validators.
        let (_, start, end) = ranges
            .iter()
            .find(|(n, _, _)| n == entry_name)
            .cloned()
            .unwrap_or((entry_name.clone(), 0, 0));
        if hash_sig_dir.exists() && end > start {
            let _ = Command::new("kubectl")
                .args([
                    "--context", context, "exec", pod_name, "-c", INIT_C, "-n",
                    namespace, "--", "mkdir", "-p", "/config/hash-sig-keys",
                ])
                .status();
            for idx in start..end {
                for role in ["attester", "proposer"] {
                    for kind in ["sk", "pk"] {
                        let fname = format!("validator_{idx}_{role}_key_{kind}.ssz");
                        let src = hash_sig_dir.join(&fname);
                        if src.exists() {
                            cp(&src, &format!("/config/hash-sig-keys/{fname}"))?;
                        }
                    }
                }
            }
            if let Ok(manifest) = filtered_manifest(&hash_sig_dir, start, end) {
                let tmp = genesis_dir.join(format!(".manifest-{entry_name}.yaml"));
                fs::write(&tmp, manifest)?;
                let _ = cp(&tmp, "/config/hash-sig-keys/validator-keys-manifest.yaml");
                let _ = fs::remove_file(&tmp);
            }
        }

        // Drop the sentinel — releases the init container; the client starts once.
        let status = Command::new("kubectl")
            .args([
                "--context", context, "exec", pod_name, "-c", INIT_C, "-n",
                namespace, "--", "touch", "/config/.ready",
            ])
            .status()?;
        if !status.success() {
            bail!("Failed to release init sentinel for {pod_name}");
        }
        println!("  injected {entry_name} (validators {start}..{end})");
    }

    Ok(())
}

/// Inject the lean-devnet Grafana dashboard as a ConfigMap. kube-prometheus-stack's
/// Grafana sidecar watches for ConfigMaps labelled `grafana_dashboard=1` across all
/// namespaces and auto-loads them — no manual import needed.
fn provision_grafana_dashboard(context: &str) -> Result<()> {
    const DASHBOARD_JSON: &str =
        include_str!("../../metrics/dashboards/client-dashboard.json");

    // Build a YAML literal-block ConfigMap so the JSON doesn't need escaping.
    let indented = DASHBOARD_JSON
        .lines()
        .map(|l| format!("    {l}"))
        .collect::<Vec<_>>()
        .join("\n");
    let cm_yaml = format!(
        "apiVersion: v1\n\
         kind: ConfigMap\n\
         metadata:\n\
         \x20 name: lean-devnet-dashboard\n\
         \x20 namespace: monitoring\n\
         \x20 labels:\n\
         \x20   grafana_dashboard: \"1\"\n\
         \x20 annotations:\n\
         \x20   grafana_folder: \"Lean Ethereum Clients\"\n\
         data:\n\
         \x20 lean-devnet.json: |\n\
         {indented}\n"
    );

    let mut child = Command::new("kubectl")
        .args(["--context", context, "apply", "-f", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    use std::io::Write as _;
    child.stdin.take().unwrap().write_all(cm_yaml.as_bytes())?;
    child.wait()?;

    Ok(())
}

/// Spawn background port-forwards so Grafana (3000) and Prometheus (9090)
/// are reachable on localhost immediately after `leanstart run` returns.
/// These are orphan processes — they die when the terminal closes.
fn start_metrics_port_forwards(context: &str) -> Result<()> {
    for (svc, local_port, remote_port) in [
        ("svc/lean-prometheus-stack-prometheus", "9090", "9090"),
        ("svc/lean-prometheus-stack-grafana",    "3000", "80"),
    ] {
        Command::new("kubectl")
            .args([
                "--context", context,
                "port-forward", svc,
                "-n", "monitoring",
                &format!("{local_port}:{remote_port}"),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .with_context(|| format!("Failed to port-forward {svc}"))?;
    }
    Ok(())
}

/// Install kube-prometheus-stack with Grafana. Uses `upgrade --install` so it
/// is safe to re-run on an existing cluster.
fn install_metrics_stack(context: &str) -> Result<()> {
    println!("==> Installing metrics stack (kube-prometheus-stack)...");

    // Add helm repos (failures are OK — already added)
    let _ = Command::new("helm")
        .args(["repo", "add", "prometheus-community",
               "https://prometheus-community.github.io/helm-charts"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    let _ = Command::new("helm")
        .args(["repo", "update"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    // Minimal install: Prometheus Operator + Prometheus + Grafana only.
    // alertmanager, kube-state-metrics, and node-exporter are disabled to
    // keep resource usage low on devnet clusters.
    //
    // serviceMonitorSelectorNilUsesHelmValues=false makes Prometheus pick up
    // ServiceMonitor objects from all namespaces regardless of release labels.
    let status = Command::new("helm")
        .args([
            "upgrade", "--install",
            "lean-prometheus-stack",
            "prometheus-community/kube-prometheus-stack",
            "--namespace", "monitoring",
            "--create-namespace",
            "--kube-context", context,
            "--set", "alertmanager.enabled=false",
            "--set", "kubeStateMetrics.enabled=false",
            "--set", "nodeExporter.enabled=false",
            "--set", "grafana.adminPassword=admin",
            // Put built-in k8s/infra dashboards in their own folder
            "--set", "grafana.defaultDashboardsFolder=Infra",
            // Allow ConfigMap annotations to declare which folder a dashboard belongs to
            "--set", "grafana.sidecar.dashboards.folderAnnotation=grafana_folder",
            // Set the Lean Ethereum Clients dashboard as the home dashboard
            "--set", "grafana.grafana\\.ini.dashboards.default_home_dashboard_path=/tmp/dashboards/Lean Ethereum Clients/lean-devnet.json",
            "--set", "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false",
            "--set", "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false",
            "--wait", "--timeout", "10m",
        ])
        .status()
        .context("helm not found. Install with: brew install helm")?;

    if !status.success() {
        eprintln!("Warning: kube-prometheus-stack install failed (may need manual intervention)");
    } else {
        println!("  Metrics stack ready.");
    }

    Ok(())
}

/// Install the Helm chart.
fn helm_install(
    context: &str,
    namespace: &str,
    chart_dir: &PathBuf,
    output_dir: &PathBuf,
    metrics_enabled: bool,
) -> Result<()> {
    let values_path = output_dir.join("helm-values.yaml");

    // The ServiceMonitor needs the Prometheus Operator CRD; skip it when metrics
    // aren't installed so the deploy doesn't fail on a missing CRD.
    let prometheus_set = format!("prometheus.enabled={metrics_enabled}");
    let status = Command::new("helm")
        .args([
            "install",
            namespace,
            &chart_dir.display().to_string(),
            "-f",
            &values_path.display().to_string(),
            "--set",
            "genesis.external=true",
            "--set",
            &prometheus_set,
            "-n",
            namespace,
            "--kube-context",
            context,
        ])
        .status()
        .context("helm not found. Install with: brew install helm")?;

    if !status.success() {
        bail!("Helm install failed");
    }
    Ok(())
}

/// Wait for all pods to be running. Returns (pod_name, validator_entry_name) pairs.
fn wait_for_pods(
    context: &str,
    namespace: &str,
    vc: &ValidatorConfig,
) -> Result<Vec<(String, String)>> {
    // Collect expected pod names from the validator config
    // Each validator entry becomes a StatefulSet with 1 replica, pod name = {k8s_name}-0
    let mut pods: Vec<(String, String)> = Vec::new();
    for entry in &vc.validators {
        let k8s_name = entry.name.replace('_', "-");
        let pod_name = format!("{k8s_name}-0");
        pods.push((pod_name, entry.name.clone()));
    }

    for (pod_name, _) in &pods {
        println!("  Waiting for {pod_name}...");
        let status = Command::new("kubectl")
            .args([
                "--context",
                context,
                "wait",
                "--for=condition=ready",
                &format!("pod/{pod_name}"),
                "-n",
                namespace,
                "--timeout=120s",
            ])
            .status()?;
        if !status.success() {
            bail!("Pod {pod_name} did not become ready");
        }
    }

    Ok(pods)
}

/// Get actual pod IPs, regenerate genesis, inject into running pods, restart containers.
fn fix_peer_ips(
    context: &str,
    namespace: &str,
    cluster: &str,
    vc: &ValidatorConfig,
    genesis_dir: &PathBuf,
    genesis_offset: u32,
    pods: &[(String, String)],
) -> Result<()> {
    let node = format!("{cluster}-control-plane");

    // Get actual pod IPs
    let mut ips: Vec<(String, String)> = Vec::new(); // (entry_name, ip)
    for (pod_name, entry_name) in pods {
        let output = Command::new("kubectl")
            .args([
                "--context",
                context,
                "get",
                "pod",
                pod_name,
                "-n",
                namespace,
                "-o",
                "jsonpath={.status.podIP}",
            ])
            .output()?;
        let ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
        println!("  {entry_name} -> {ip}");
        ips.push((entry_name.clone(), ip));
    }

    // Rewrite validator-config.yaml with actual IPs
    let vc_path = genesis_dir.join("validator-config.yaml");
    let content = fs::read_to_string(&vc_path)?;
    let mut ip_idx = 0;
    let mut result = String::new();
    for line in content.lines() {
        if line.contains("ip:") && ip_idx < ips.len() {
            // Replace the IP value
            let indent = &line[..line.find("ip:").unwrap()];
            result.push_str(&format!("{indent}ip: \"{}\"\n", ips[ip_idx].1));
            ip_idx += 1;
        } else {
            result.push_str(line);
            result.push('\n');
        }
    }
    fs::write(&vc_path, &result)?;

    // Remove old genesis outputs and regenerate (skip hash-sig keys — already
    // present in genesis_dir/hash-sig-keys/ from the initial run).
    for f in &[
        "config.yaml",
        "genesis.ssz",
        "genesis.json",
        "nodes.yaml",
        "validators.yaml",
        "annotated_validators.yaml",
    ] {
        let _ = fs::remove_file(genesis_dir.join(f));
    }

    write_config_yaml(vc, genesis_offset, genesis_dir)?;
    run_genesis_tool(genesis_dir)?;
    append_genesis_validators(vc, genesis_dir)?;
    generate_annotated_validators(genesis_dir)?;

    // Update the ConfigMap with corrected genesis files so that when
    // init containers re-run on restart, they copy the correct data.
    println!("  Updating ConfigMap with corrected IPs...");
    let _ = Command::new("kubectl")
        .args([
            "--context",
            context,
            "delete",
            "configmap",
            "genesis-config",
            "-n",
            namespace,
        ])
        .status();

    let genesis_files = [
        "config.yaml",
        "validators.yaml",
        "annotated_validators.yaml",
        "nodes.yaml",
        "genesis.json",
        "genesis.ssz",
        "validator-config.yaml",
    ];
    let mut cm_args = vec![
        "--context".to_string(),
        context.to_string(),
        "create".to_string(),
        "configmap".to_string(),
        "genesis-config".to_string(),
        "-n".to_string(),
        namespace.to_string(),
    ];
    for f in &genesis_files {
        let path = genesis_dir.join(f);
        if path.exists() {
            cm_args.push(format!("--from-file={}={}", f, path.display()));
        }
    }
    // Add node key files
    for (_, entry_name) in pods {
        let key_path = genesis_dir.join(format!("{entry_name}.key"));
        if key_path.exists() {
            cm_args.push(format!(
                "--from-file={}.key={}",
                entry_name,
                key_path.display()
            ));
        }
    }
    let cm_refs: Vec<&str> = cm_args.iter().map(|s| s.as_str()).collect();
    let _ = Command::new("kubectl").args(&cm_refs).status()?;

    // Also inject directly into running pods for immediate effect
    // (some containers may not restart cleanly via init)
    let files_to_inject = genesis_files;
    for (pod_name, entry_name) in pods {
        let k8s_name = entry_name.replace('_', "-");

        // Try kubectl cp first (works if container has tar)
        let test = Command::new("kubectl")
            .args([
                "--context",
                context,
                "cp",
                &genesis_dir.join("nodes.yaml").display().to_string(),
                &format!("{namespace}/{pod_name}:/config/nodes.yaml"),
                "-c",
                &k8s_name,
            ])
            .output()?;

        if test.status.success() {
            for f in &files_to_inject {
                let src = genesis_dir.join(f);
                if src.exists() {
                    let _ = Command::new("kubectl")
                        .args([
                            "--context",
                            context,
                            "cp",
                            &src.display().to_string(),
                            &format!("{namespace}/{pod_name}:/config/{f}"),
                            "-c",
                            &k8s_name,
                        ])
                        .status();
                }
            }
        } else {
            // No tar in container — use docker cp via the kind node
            if let Ok(cid) = get_container_id(&node, pod_name, &k8s_name) {
                if let Ok(mount) = get_config_mount(&node, &cid) {
                    for f in &files_to_inject {
                        let src = genesis_dir.join(f);
                        if src.exists() {
                            let _ = Command::new("docker")
                                .args([
                                    "cp",
                                    &src.display().to_string(),
                                    &format!("{node}:{mount}/{f}"),
                                ])
                                .status();
                        }
                    }
                }
            }
        }
    }

    // Restart all containers via crictl (not pod deletion — preserves IPs).
    // Note: `kill -9 1` does NOT work on PID 1 inside containers (runtime protects it).
    println!("  Restarting containers...");
    for (pod_name, entry_name) in pods {
        let k8s_name = entry_name.replace('_', "-");
        if let Ok(cid) = get_container_id(&node, pod_name, &k8s_name) {
            let _ = Command::new("docker")
                .args(["exec", &node, "crictl", "stop", &cid])
                .status();
        }
    }

    // Wait for containers to restart
    thread::sleep(time::Duration::from_secs(5));

    for (pod_name, _) in pods {
        let _ = Command::new("kubectl")
            .args([
                "--context",
                context,
                "wait",
                "--for=condition=ready",
                &format!("pod/{pod_name}"),
                "-n",
                namespace,
                "--timeout=60s",
            ])
            .status()?;
    }

    // Verify IPs are still correct
    for (pod_name, entry_name) in pods {
        let output = Command::new("kubectl")
            .args([
                "--context",
                context,
                "get",
                "pod",
                pod_name,
                "-n",
                namespace,
                "-o",
                "jsonpath={.status.podIP}",
            ])
            .output()?;
        let actual_ip = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let expected_ip = ips
            .iter()
            .find(|(n, _)| n == entry_name)
            .map(|(_, ip)| ip.as_str())
            .unwrap_or("");
        if actual_ip != expected_ip {
            eprintln!("  Warning: {entry_name} IP changed {expected_ip} -> {actual_ip} (peering may be degraded)");
        }
    }

    Ok(())
}

/// Get a container ID from the kind node using crictl.
fn get_container_id(node: &str, pod_name: &str, container_name: &str) -> Result<String> {
    let output = Command::new("docker")
        .args([
            "exec",
            node,
            "crictl",
            "ps",
            "--name",
            container_name,
            "-o",
            "json",
        ])
        .output()?;

    let json: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    let containers = json["containers"].as_array().context("no containers")?;

    for c in containers {
        let labels = &c["labels"];
        if labels["io.kubernetes.pod.name"].as_str() == Some(pod_name) {
            if let Some(id) = c["id"].as_str() {
                return Ok(id.to_string());
            }
        }
    }

    bail!("Container not found for pod {pod_name}")
}

/// Get the /config emptyDir mount path on the kind node.
fn get_config_mount(node: &str, container_id: &str) -> Result<String> {
    let output = Command::new("docker")
        .args(["exec", node, "crictl", "inspect", container_id])
        .output()?;

    let json: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    let mounts = json["info"]["runtimeSpec"]["mounts"]
        .as_array()
        .context("no mounts in container inspect")?;

    for m in mounts {
        if m["destination"].as_str() == Some("/config") {
            if let Some(src) = m["source"].as_str() {
                return Ok(src.to_string());
            }
        }
    }

    bail!("No /config mount found in container {container_id}")
}

/// Start background log streaming for all pods into the run directory.
fn start_log_streaming(
    context: &str,
    namespace: &str,
    pods: &[(String, String)],
    logs_dir: &Path,
) -> Result<()> {
    fs::create_dir_all(logs_dir)?;

    for (pod_name, entry_name) in pods {
        let k8s_name = entry_name.replace('_', "-");
        let log_path = logs_dir.join(format!("{entry_name}.log"));

        let log_file = fs::File::create(&log_path)?;

        // Wrap `kubectl logs -f` in a retry loop so the stream reconnects when
        // a container restarts (e.g. crash-loops, manual restarts). Stream is
        // appended to the same file across restarts. The shell process becomes
        // an orphan when leanstart exits — that's intentional.
        let cmd = format!(
            "while true; do \
               kubectl --context {ctx} logs -f {pod} -n {ns} -c {k8s} 2>/dev/null; \
               sleep 1; \
             done",
            ctx = context,
            pod = pod_name,
            ns = namespace,
            k8s = k8s_name,
        );

        Command::new("sh")
            .args(["-c", &cmd])
            .stdout(log_file)
            .stderr(std::process::Stdio::null())
            .spawn()
            .with_context(|| format!("Failed to start log streaming for {entry_name}"))?;

        println!("  {entry_name} -> {}", log_path.display());
    }

    Ok(())
}

/// Append `kubectl logs --previous` for each pod to its log file. Called when
/// `wait_for_pods` fails so the user has crash output even if the streaming
/// `kubectl logs -f` only captured the most recent (post-crash) restart.
fn snapshot_previous_logs(
    context: &str,
    namespace: &str,
    pods: &[(String, String)],
    logs_dir: &Path,
) {
    let _ = fs::create_dir_all(logs_dir);

    for (pod_name, entry_name) in pods {
        let k8s_name = entry_name.replace('_', "-");
        let log_path = logs_dir.join(format!("{entry_name}.previous.log"));
        let Ok(file) = fs::File::create(&log_path) else {
            continue;
        };
        let _ = Command::new("kubectl")
            .args([
                "--context",
                context,
                "logs",
                pod_name,
                "-n",
                namespace,
                "-c",
                &k8s_name,
                "--previous",
                "--tail=500",
            ])
            .stdout(file)
            .stderr(std::process::Stdio::null())
            .status();
    }
}
