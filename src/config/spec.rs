use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// High-level specification for a devnet deployment.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DevnetSpec {
    /// Client allocations as (client_name, instance_count).
    pub clients: Vec<ClientAllocation>,
    /// Number of validators assigned to each pod.
    pub validators_per_pod: u32,
    /// Kubernetes namespace.
    pub namespace: String,
    /// Output directory for generated artifacts.
    pub output_dir: PathBuf,
    /// Exponent for hash-sig active epochs (2^active_epoch).
    pub active_epoch: u32,
    /// Key type (e.g., "hash-sig").
    pub key_type: String,
    /// Seed for deterministic key generation.
    pub seed: [u8; 32],
    /// Seconds from now until genesis time.
    pub genesis_offset: u32,
    /// Kubernetes storage class for PVCs.
    pub storage_class: Option<String>,
    /// Number of bootnode pods per client type.
    pub bootnode_count: u32,
    /// Number of attestation subnets (1..=5). Each client allocation is replicated
    /// once per subnet, and `attestation_committee_count` is set to this value.
    pub subnets: u32,
    /// Explicit override for `config.attestation_committee_count`. Defaults to
    /// `subnets` when None.
    pub attestation_committee_count: Option<u32>,
    /// Optional per-subnet host labels for aggregator placement. When non-empty,
    /// the aggregator pod of subnet `i` is pinned (via `nodeSelector:
    /// leanstart.io/host=<label>`) to `aggregator_hosts[i]`, overriding any
    /// client-level `@host`. Length must equal `subnets`. Empty => aggregators
    /// inherit their client's placement (the default). Used by the GKE sweep
    /// tooling to give each subnet aggregator its own dedicated node so
    /// leaf/recursion timings reflect the protocol, not co-tenant CPU.
    pub aggregator_hosts: Vec<String>,
    /// Multi-node "injected" peering/key delivery mode (set for remote clusters,
    /// i.e. `--skip-kind`). When true the orchestrator gates the init container
    /// and injects IP-correct genesis + per-pod keys instead of using the
    /// kind-only shared PVC + container-restart path.
    pub injected: bool,
}

/// Maximum number of subnets supported (matches lean-quickstart MAX_SUBNETS).
pub const MAX_SUBNETS: u32 = 5;

/// A client type and how many instances (pods) to run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientAllocation {
    pub name: String,
    pub instances: u32,
    /// Optional host to pin this client's pods to, from the `@host` suffix
    /// (e.g. `ream:3@nbg1`). Maps to the node label `leanstart.io/host=<host>`.
    /// `None` => pods auto-spread across all nodes.
    #[serde(default)]
    pub host: Option<String>,
}

impl DevnetSpec {
    /// Total number of validators across all clients (counts every subnet).
    #[allow(dead_code)] // used by integration tests
    pub fn total_validators(&self) -> u32 {
        self.clients.iter().map(|c| c.instances).sum::<u32>()
            * self.validators_per_pod
            * self.subnets
    }

    /// Effective attestation_committee_count emitted in config: explicit override
    /// when set, otherwise the number of subnets.
    pub fn effective_committee_count(&self) -> u32 {
        self.attestation_committee_count.unwrap_or(self.subnets)
    }
}

/// Parse a client spec string like "ream", "zeam:2", "grandine:5", or with a
/// host pin: "ream:3@nbg1", "zeam@nbg2".
///
/// Grammar: `<name>[:<count>][@<host>]`. The `@host` pins the client's pods to
/// the node labelled `leanstart.io/host=<host>`; omitting it auto-spreads.
pub fn parse_client_spec(spec: &str) -> anyhow::Result<ClientAllocation> {
    // Peel off an optional "@host" suffix first.
    let (left, host) = match spec.split_once('@') {
        Some((l, h)) => {
            if h.is_empty() {
                anyhow::bail!("Empty host in client spec '{spec}'. Use 'name:count@host'");
            }
            if !is_dns_label(h) {
                anyhow::bail!(
                    "Invalid host '{h}' in '{spec}'. Hosts must be lowercase \
                     alphanumeric or '-' (a Kubernetes label value)"
                );
            }
            (l, Some(h.to_string()))
        }
        None => (spec, None),
    };

    let parts: Vec<&str> = left.split(':').collect();
    match parts.len() {
        1 if !parts[0].is_empty() => Ok(ClientAllocation {
            name: parts[0].to_string(),
            instances: 1,
            host,
        }),
        2 if !parts[0].is_empty() => Ok(ClientAllocation {
            name: parts[0].to_string(),
            instances: parts[1]
                .parse()
                .map_err(|_| anyhow::anyhow!("Invalid instance count in '{spec}'"))?,
            host,
        }),
        _ => anyhow::bail!(
            "Invalid client spec '{spec}'. Use 'name', 'name:count', or 'name:count@host'"
        ),
    }
}

/// Whether `s` is a valid Kubernetes label value usable as a `@host` token:
/// non-empty, <=63 chars, alphanumeric/`-`/`_`/`.`, starting and ending
/// alphanumeric. We keep it conservative (DNS-label-ish) since it lands in a
/// `nodeSelector`.
fn is_dns_label(s: &str) -> bool {
    if s.is_empty() || s.len() > 63 {
        return false;
    }
    let bytes = s.as_bytes();
    let alnum = |b: u8| b.is_ascii_alphanumeric();
    if !alnum(bytes[0]) || !alnum(bytes[bytes.len() - 1]) {
        return false;
    }
    s.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}
