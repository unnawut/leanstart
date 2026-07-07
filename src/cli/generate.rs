use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Args;

use crate::config::generator::{generate_validator_config, write_validator_config};
use crate::config::spec::{DevnetSpec, MAX_SUBNETS, parse_client_spec};
use crate::genesis::runner::{
    append_genesis_validators, generate_annotated_validators, run_genesis_tool, write_config_yaml,
};
use crate::k8s::values::{generate_helm_values, generate_pod_secrets, write_helm_values};
use crate::keys::keygen::{generate_hash_sig_keys, write_node_keys};

#[derive(Debug, Args)]
pub struct GenerateArgs {
    /// Client specs: "ream:1", "zeam:2", etc. (same as `run`).
    #[arg(long, default_value = "ethlambda:1,qlean:1")]
    pub clients: String,

    /// Validators per Kubernetes pod.
    #[arg(long, default_value = "1")]
    pub validators_per_pod: u32,

    /// Kubernetes namespace.
    #[arg(long, default_value = "lean-devnet")]
    pub namespace: String,

    /// Output directory for all generated artifacts.
    #[arg(long, default_value = "./output")]
    pub output_dir: PathBuf,

    /// Hash-sig active epoch exponent (2^N).
    #[arg(long, default_value = "18")]
    pub active_epoch: u32,

    /// Key type.
    #[arg(long, default_value = "hash-sig")]
    pub key_type: String,

    /// Hex-encoded 32-byte seed for deterministic key generation.
    #[arg(long, default_value = "0000000000000000000000000000000000000000000000000000000000000001")]
    pub seed: String,

    /// Seconds until genesis time from now.
    #[arg(long, default_value = "120")]
    pub genesis_offset: u32,

    /// Kubernetes storage class for PVCs.
    #[arg(long)]
    pub storage_class: Option<String>,

    /// Number of bootnode pods per client type.
    #[arg(long, default_value = "5")]
    pub bootnode_count: u32,

    /// Skip Docker-based genesis generation (config-only mode).
    #[arg(long)]
    pub config_only: bool,

    /// Number of attestation subnets (1..=5). Each client allocation is
    /// replicated once per subnet and one aggregator per subnet is selected.
    #[arg(long, default_value = "1")]
    pub subnets: u32,

    /// Override config.attestation_committee_count. Defaults to --subnets.
    #[arg(long)]
    pub attestation_committee_count: Option<u32>,

    /// Comma-separated per-subnet host labels for aggregator placement, e.g.
    /// `agg0,agg1`. Pins the aggregator pod of subnet i to the node labelled
    /// `leanstart.io/host=<label>`. Must list exactly one label per subnet.
    #[arg(long, value_delimiter = ',')]
    pub aggregator_hosts: Vec<String>,

    /// Generate for a remote multi-node cluster: emit injected-mode Helm values
    /// (no shared genesis PVC; keys/genesis injected per-pod at deploy time).
    #[arg(long)]
    pub injected: bool,
}

impl GenerateArgs {
    fn parse_seed(&self) -> Result<[u8; 32]> {
        let bytes = hex::decode(&self.seed).context("Invalid hex seed")?;
        let arr: [u8; 32] = bytes
            .try_into()
            .map_err(|v: Vec<u8>| anyhow::anyhow!("Seed must be 32 bytes, got {}", v.len()))?;
        Ok(arr)
    }
}

pub fn run(args: GenerateArgs) -> Result<()> {
    let log_path = crate::logging::init(&args.output_dir)?;
    println!("Logging this run to {}", log_path.display());

    let result = run_inner(args);
    crate::logging::shutdown();
    result
}

fn run_inner(args: GenerateArgs) -> Result<()> {
    let clients: Vec<_> = args
        .clients
        .split(',')
        .map(|s| parse_client_spec(s.trim()))
        .collect::<Result<_>>()?;

    if args.subnets == 0 || args.subnets > MAX_SUBNETS {
        anyhow::bail!(
            "--subnets must be between 1 and {} (got {})",
            MAX_SUBNETS,
            args.subnets
        );
    }

    let spec = DevnetSpec {
        clients,
        validators_per_pod: args.validators_per_pod,
        namespace: args.namespace.clone(),
        output_dir: args.output_dir.clone(),
        active_epoch: args.active_epoch,
        key_type: args.key_type.clone(),
        seed: args.parse_seed()?,
        genesis_offset: args.genesis_offset,
        storage_class: args.storage_class.clone(),
        bootnode_count: args.bootnode_count,
        subnets: args.subnets,
        attestation_committee_count: args.attestation_committee_count,
        aggregator_hosts: args.aggregator_hosts.clone(),
        injected: args.injected,
    };

    let genesis_dir = args.output_dir.join("genesis");

    // Step 1: Generate validator-config.yaml
    println!("==> Generating validator-config.yaml...");
    let vc = generate_validator_config(&spec)?;
    write_validator_config(&vc, &genesis_dir)?;

    // Step 2: Write node key files
    println!("==> Writing node key files...");
    let key_pairs: Vec<(String, String)> = vc
        .validators
        .iter()
        .map(|v| (v.name.clone(), v.privkey.clone()))
        .collect();
    write_node_keys(&key_pairs, &genesis_dir)?;

    if !args.config_only {
        // Step 3: Generate hash-sig keys
        let total_validators: u32 = vc.validators.iter().map(|v| v.count).sum();
        println!("==> Generating hash-sig keys for {total_validators} validators...");
        generate_hash_sig_keys(total_validators, spec.active_epoch, &genesis_dir)?;

        // Step 4: Write config.yaml and run genesis tool
        println!("==> Writing config.yaml...");
        write_config_yaml(&vc, spec.genesis_offset, &genesis_dir)?;

        println!("==> Running genesis generation tool...");
        run_genesis_tool(&genesis_dir)?;

        // Step 5: Append GENESIS_VALIDATORS to config.yaml
        println!("==> Appending GENESIS_VALIDATORS to config.yaml...");
        append_genesis_validators(&vc, &genesis_dir)?;

        // Step 6: Build annotated_validators.yaml for clients that consume it.
        println!("==> Writing annotated_validators.yaml...");
        generate_annotated_validators(&genesis_dir)?;
    }

    // Step 6: Generate Helm values and pod secrets
    println!("==> Generating Helm values...");
    let helm_values = generate_helm_values(&spec, &vc)?;
    write_helm_values(&helm_values, &args.output_dir)?;

    println!("==> Generating pod secret manifests...");
    generate_pod_secrets(&vc, &spec.namespace, &args.output_dir)?;

    println!("\nGeneration complete. Output in {}", args.output_dir.display());
    Ok(())
}
