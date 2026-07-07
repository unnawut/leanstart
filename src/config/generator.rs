use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::config::clients::get_client;
use crate::config::spec::{DevnetSpec, MAX_SUBNETS};
use crate::keys::keygen::deterministic_privkey;

/// A single entry in the generated validator-config.yaml.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidatorEntry {
    pub name: String,
    /// Client type prefix (e.g. "zeam"). Persisted so we don't have to parse `name`.
    #[serde(skip)]
    pub client: String,
    /// Host to pin this pod to (from `@host`), or None to auto-spread. Deploy-time
    /// metadata only — not part of the genesis input, so skipped in serde.
    #[serde(skip)]
    pub host: Option<String>,
    pub privkey: String,
    #[serde(rename = "enrFields")]
    pub enr_fields: EnrFields,
    #[serde(rename = "metricsPort")]
    pub metrics_port: u16,
    #[serde(rename = "httpPort", skip_serializing_if = "Option::is_none")]
    pub http_port: Option<u16>,
    #[serde(rename = "isAggregator")]
    pub is_aggregator: bool,
    /// Subnet (attestation committee) index this node belongs to.
    pub subnet: u32,
    pub count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnrFields {
    pub ip: String,
    pub quic: u16,
}

/// Top-level validator-config.yaml structure.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidatorConfig {
    pub shuffle: String,
    pub deployment_mode: String,
    pub config: ValidatorConfigMeta,
    pub validators: Vec<ValidatorEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidatorConfigMeta {
    #[serde(rename = "activeEpoch")]
    pub active_epoch: u32,
    #[serde(rename = "keyType")]
    pub key_type: String,
    #[serde(
        rename = "attestation_committee_count",
        skip_serializing_if = "Option::is_none"
    )]
    pub attestation_committee_count: Option<u32>,
}

/// Generate the complete validator-config.yaml from a DevnetSpec.
///
/// When `spec.subnets > 1`, each client's pods are replicated once per subnet.
/// Pod naming is `{client}_{pod_idx}` for single-subnet (backward-compat) and
/// `{client}_s{subnet}_p{pod_idx}` when multi-subnet. Exactly one aggregator
/// is selected per subnet (the first pod of the first client in that subnet).
pub fn generate_validator_config(spec: &DevnetSpec) -> Result<ValidatorConfig> {
    if spec.subnets == 0 || spec.subnets > MAX_SUBNETS {
        bail!(
            "subnets must be between 1 and {} (got {})",
            MAX_SUBNETS,
            spec.subnets
        );
    }

    if !spec.aggregator_hosts.is_empty() && spec.aggregator_hosts.len() != spec.subnets as usize {
        bail!(
            "aggregator_hosts must have exactly one label per subnet: got {} label(s) for {} subnet(s)",
            spec.aggregator_hosts.len(),
            spec.subnets
        );
    }

    // Multi-subnet + multiple validators per pod can't map cleanly to ream's
    // committee assignment: ream derives a validator's committee from
    // `validator_id % attestation_committee_count`, but the genesis tool hands
    // each pod a *contiguous* block of validator ids — a block of size >1 spans
    // multiple residues, so a pod's validators would split across committees and
    // its aggregator could only ever serve one of them. Refuse rather than emit
    // a config that silently never finalizes.
    if spec.subnets > 1 && spec.validators_per_pod > 1 {
        bail!(
            "multi-subnet (subnets={}) with validators-per-pod={} is not supported: ream assigns \
             committees by validator_id % committee_count, which requires one validator per pod \
             so each pod maps to exactly one committee. Use --validators-per-pod 1 for multi-subnet.",
            spec.subnets,
            spec.validators_per_pod
        );
    }

    let mut validators = Vec::new();
    let mut global_pod_index: u32 = 0;
    let multi_subnet = spec.subnets > 1;

    // Emit entries with the SUBNET as the innermost loop so consecutive global
    // validator ids alternate subnets (subnet 0 -> ids 0,2,4..; subnet 1 -> ids
    // 1,3,5..; etc.). ream computes a validator's attestation committee as
    // `validator_id % attestation_committee_count` (== subnets), so this
    // interleaving makes leanstart-subnet-k hold exactly ream-committee-k's
    // validators. That guarantees each subnet's aggregator (the first pod of the
    // first client) lands in a DISTINCT ream committee — one aggregator per
    // committee, which is what ream needs to form cross-subnet quorum.
    //
    // (Subnet-major ordering instead gave every subnet's first pod an even id,
    // collapsing all aggregators onto committee 0; committee 1+ then had no
    // aggregator, their attestations were never aggregated, and the chain never
    // justified. With vpp=1 the interleave makes pod ids == ream committee ids.)
    for (client_idx, client) in spec.clients.iter().enumerate() {
        let client_name = &client.name;
        let validator_count = client.instances * spec.validators_per_pod;
        let client_def = get_client(client_name)
            .with_context(|| format!("Unknown client: {client_name}"))?;

        if validator_count == 0 {
            bail!("Client {client_name} has 0 validators allocated");
        }

        let pod_count = validator_count.div_ceil(spec.validators_per_pod);
        let mut remaining = validator_count;

        for pod_idx in 0..pod_count {
            let count = remaining.min(spec.validators_per_pod);
            remaining -= count;

            // The aggregator of every subnet is the first pod of the first
            // client. With the interleaved ordering above, that pod's validator
            // id in subnet k is congruent to k (mod subnets) == ream committee k.
            let is_aggregator = client_idx == 0 && pod_idx == 0;

            for subnet_idx in 0..spec.subnets {
                let name = if multi_subnet {
                    format!("{client_name}_s{subnet_idx}_p{pod_idx}")
                } else {
                    format!("{client_name}_{pod_idx}")
                };
                let privkey = deterministic_privkey(&spec.seed, global_pod_index);

                // Aggregator placement: when per-subnet aggregator hosts are
                // supplied, the aggregator pod is pinned to its subnet's label,
                // overriding any client `@host`. Others keep client placement.
                let host = if is_aggregator && !spec.aggregator_hosts.is_empty() {
                    spec.aggregator_hosts.get(subnet_idx as usize).cloned()
                } else {
                    client.host.clone()
                };

                // Use 0.0.0.0 as placeholder — the genesis tool requires a valid IP.
                // Actual pod IPs are resolved at runtime by the init container.
                let entry = ValidatorEntry {
                    name,
                    client: client_name.clone(),
                    host,
                    privkey,
                    enr_fields: EnrFields {
                        ip: "0.0.0.0".to_string(),
                        quic: 9000,
                    },
                    metrics_port: 8080,
                    http_port: if client_def.has_http_port {
                        Some(5055)
                    } else {
                        None
                    },
                    is_aggregator,
                    subnet: subnet_idx,
                    count,
                };

                validators.push(entry);
                global_pod_index += 1;
            }
        }
    }

    let committee_count = if multi_subnet || spec.attestation_committee_count.is_some() {
        Some(spec.effective_committee_count())
    } else {
        None
    };

    Ok(ValidatorConfig {
        shuffle: "roundrobin".to_string(),
        deployment_mode: "kubernetes".to_string(),
        config: ValidatorConfigMeta {
            active_epoch: spec.active_epoch,
            key_type: spec.key_type.clone(),
            attestation_committee_count: committee_count,
        },
        validators,
    })
}

/// Write the validator config to a YAML file.
pub fn write_validator_config(config: &ValidatorConfig, output_dir: &Path) -> Result<()> {
    fs::create_dir_all(output_dir)?;
    let path = output_dir.join("validator-config.yaml");
    let yaml = serde_yaml::to_string(config)?;
    fs::write(&path, yaml)?;
    println!("Wrote {}", path.display());
    Ok(())
}
