use std::fs;
use std::path::Path;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::config::clients::{build_args, get_client};
use crate::config::generator::ValidatorConfig;
use crate::config::spec::DevnetSpec;

/// Top-level Helm values structure.
#[derive(Debug, Serialize, Deserialize)]
pub struct HelmValues {
    pub namespace: String,
    pub genesis: GenesisValues,
    pub clients: Vec<ClientValues>,
    #[serde(rename = "initScripts")]
    pub init_scripts: InitScriptsValues,
    #[serde(rename = "bootnodeCount")]
    pub bootnode_count: u32,
    pub prometheus: PrometheusValues,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct GenesisValues {
    #[serde(rename = "configMapName")]
    pub config_map_name: String,
    #[serde(rename = "pvcName")]
    pub pvc_name: String,
    #[serde(rename = "storageClass")]
    pub storage_class: String,
    #[serde(rename = "storageSize")]
    pub storage_size: String,
    /// Multi-node "injected" mode: no shared genesis PVC; the orchestrator
    /// gates the init container and copies IP-correct genesis + per-pod keys
    /// straight into /config. False = legacy kind path (ConfigMap + shared PVC).
    pub injected: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ClientValues {
    pub name: String,
    pub image: String,
    pub replicas: u32,
    pub args: Vec<Vec<String>>,
    #[serde(rename = "seccompUnconfined")]
    pub seccomp_unconfined: bool,
    #[serde(rename = "hasHttpPort")]
    pub has_http_port: bool,
    /// Attestation subnet this pod belongs to (0-based). Surfaced for K8s
    /// labelling / kubectl filtering when running multi-subnet devnets.
    pub subnet: u32,
    /// Host to pin this pod to via `nodeSelector: leanstart.io/host=<host>`,
    /// from the `@host` spec suffix. When None the chart applies
    /// topologySpreadConstraints so the pod auto-spreads across nodes.
    #[serde(rename = "nodeSelectorHost", skip_serializing_if = "Option::is_none")]
    pub node_selector_host: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct InitScriptsValues {
    #[serde(rename = "resolverImage")]
    pub resolver_image: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PrometheusValues {
    pub enabled: bool,
}

/// Generate Helm values.yaml from DevnetSpec and ValidatorConfig.
///
/// Each validator entry becomes its own StatefulSet with replicas=1,
/// ensuring every pod gets its correct per-pod args (node-id, keys, etc).
pub fn generate_helm_values(
    spec: &DevnetSpec,
    vc: &ValidatorConfig,
) -> Result<HelmValues> {
    let mut clients = Vec::new();

    let multi_subnet = spec.subnets > 1;
    let committee_count = if multi_subnet || spec.attestation_committee_count.is_some() {
        Some(spec.effective_committee_count())
    } else {
        None
    };
    let aggregate_subnet_ids = if multi_subnet {
        Some(
            (0..spec.subnets)
                .map(|i| i.to_string())
                .collect::<Vec<_>>()
                .join(","),
        )
    } else {
        None
    };

    for entry in vc.validators.iter() {
        let client_def = get_client(&entry.client)
            .ok_or_else(|| anyhow::anyhow!("Unknown client: {}", entry.client))?;

        let args = build_args(
            client_def,
            &entry.name,
            entry.is_aggregator,
            committee_count,
            aggregate_subnet_ids.as_deref(),
        );

        // Cloud-sweep scaffolding: LS_IMAGE_<CLIENT> overrides the pinned image
        // verbatim (used to A/B custom builds, e.g. an AVX-512 ream). Falls back
        // to the pinned image (+ arch suffix when arch-aware).
        let image = std::env::var(format!("LS_IMAGE_{}", client_def.name.to_uppercase()))
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                if client_def.arch_aware {
                    format!("{}-{}", client_def.image, image_arch_suffix())
                } else {
                    client_def.image.to_string()
                }
            });

        // K8s-safe name: zeam_0 -> zeam-0, zeam_s1_p0 -> zeam-s1-p0
        let k8s_name = entry.name.replace('_', "-");

        clients.push(ClientValues {
            name: k8s_name,
            image,
            replicas: 1,
            args: vec![args],
            seccomp_unconfined: client_def.seccomp_unconfined,
            has_http_port: client_def.has_http_port,
            subnet: entry.subnet,
            node_selector_host: entry.host.clone(),
        });
    }

    Ok(HelmValues {
        namespace: spec.namespace.clone(),
        genesis: GenesisValues {
            config_map_name: "genesis-config".into(),
            pvc_name: "genesis-data".into(),
            storage_class: spec.storage_class.clone().unwrap_or_default(),
            storage_size: "5Gi".into(),
            injected: spec.injected,
        },
        clients,
        init_scripts: InitScriptsValues {
            resolver_image: "busybox:1.36".into(),
        },
        bootnode_count: spec.bootnode_count,
        prometheus: PrometheusValues { enabled: true },
    })
}

/// Image-tag arch suffix for clients that publish per-arch tags (e.g. qlean,
/// lantern). Kind on Apple Silicon runs arm64 nodes, so requesting an amd64
/// image leaves the pod in ImagePullBackOff.
fn image_arch_suffix() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" | "arm64" => "arm64",
        _ => "amd64",
    }
}

/// Write Helm values to a YAML file.
pub fn write_helm_values(values: &HelmValues, output_dir: &Path) -> Result<()> {
    fs::create_dir_all(output_dir)?;
    let path = output_dir.join("helm-values.yaml");
    let yaml = serde_yaml::to_string(values)?;
    fs::write(&path, yaml)?;
    println!("Wrote {}", path.display());
    Ok(())
}

/// Generate per-pod Secret manifests for node keys.
pub fn generate_pod_secrets(
    vc: &ValidatorConfig,
    namespace: &str,
    output_dir: &Path,
) -> Result<()> {
    let secrets_dir = output_dir.join("secrets");
    // Clear stale secret manifests from prior runs so we don't apply secrets for
    // clients/pods that aren't part of this devnet.
    let _ = fs::remove_dir_all(&secrets_dir);
    fs::create_dir_all(&secrets_dir)?;

    for entry in &vc.validators {
        let secret = serde_yaml::to_string(&serde_yaml::Value::Mapping({
            let mut m = serde_yaml::Mapping::new();
            m.insert("apiVersion".into(), "v1".into());
            m.insert("kind".into(), "Secret".into());
            let mut metadata = serde_yaml::Mapping::new();
            let k8s_name = entry.name.replace('_', "-");
            metadata.insert("name".into(), format!("{k8s_name}-keys").into());
            metadata.insert("namespace".into(), namespace.into());
            m.insert("metadata".into(), serde_yaml::Value::Mapping(metadata));
            m.insert("type".into(), "Opaque".into());
            let mut data = serde_yaml::Mapping::new();
            data.insert("node.key".into(), entry.privkey.clone().into());
            m.insert("stringData".into(), serde_yaml::Value::Mapping(data));
            m
        }))?;

        let k8s_name = entry.name.replace('_', "-");
        let path = secrets_dir.join(format!("{k8s_name}-keys.yaml"));
        fs::write(&path, secret)?;
    }

    println!(
        "Wrote {} pod secret manifests to {}",
        vc.validators.len(),
        secrets_dir.display()
    );
    Ok(())
}
