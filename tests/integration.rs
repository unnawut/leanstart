use std::path::PathBuf;

use leanstart::config::generator::generate_validator_config;
use leanstart::config::spec::{ClientAllocation, DevnetSpec, parse_client_spec};
use leanstart::k8s::values::generate_helm_values;

fn test_spec(clients: Vec<(&str, u32)>) -> DevnetSpec {
    DevnetSpec {
        clients: clients
            .into_iter()
            .map(|(name, instances)| ClientAllocation {
                name: name.to_string(),
                instances,
                host: None,
            })
            .collect(),
        validators_per_pod: 1,
        namespace: "test-ns".to_string(),
        output_dir: PathBuf::from("/tmp/leanstart-test"),
        active_epoch: 18,
        key_type: "hash-sig".to_string(),
        seed: [1u8; 32],
        genesis_offset: 120,
        storage_class: None,
        bootnode_count: 5,
        subnets: 1,
        attestation_committee_count: None,
        aggregator_hosts: vec![],
        injected: false,
    }
}

#[test]
fn test_parse_client_spec() {
    let c = parse_client_spec("ream").unwrap();
    assert_eq!(c.name, "ream");
    assert_eq!(c.instances, 1);

    let c = parse_client_spec("zeam:3").unwrap();
    assert_eq!(c.name, "zeam");
    assert_eq!(c.instances, 3);
    assert_eq!(c.host, None);

    // @host placement
    let c = parse_client_spec("ream:3@nbg1").unwrap();
    assert_eq!(c.name, "ream");
    assert_eq!(c.instances, 3);
    assert_eq!(c.host.as_deref(), Some("nbg1"));

    let c = parse_client_spec("zeam@nbg2").unwrap();
    assert_eq!(c.name, "zeam");
    assert_eq!(c.instances, 1);
    assert_eq!(c.host.as_deref(), Some("nbg2"));

    assert!(parse_client_spec("bad:spec:extra").is_err());
    assert!(parse_client_spec("zeam:abc").is_err());
    assert!(parse_client_spec("ream@").is_err()); // empty host
    assert!(parse_client_spec("ream:2@bad_host!").is_err()); // invalid host char
    assert!(parse_client_spec("@nbg1").is_err()); // empty name
}

#[test]
fn test_generate_validator_config_basic() {
    let spec = test_spec(vec![("ethlambda", 1), ("qlean", 1)]);
    let vc = generate_validator_config(&spec).unwrap();

    assert_eq!(vc.validators.len(), 2);
    assert_eq!(vc.validators[0].name, "ethlambda_0");
    assert_eq!(vc.validators[0].count, 1);
    assert_eq!(vc.validators[1].name, "qlean_0");
    assert_eq!(vc.validators[1].count, 1);

    assert!(vc.validators[0].is_aggregator);
    assert!(!vc.validators[1].is_aggregator);
}

#[test]
fn test_aggregator_hosts_pin_per_subnet() {
    // 2 subnets, 2 pods/subnet. Each subnet's aggregator (first pod) should be
    // pinned to its subnet's label; non-aggregators keep their (None) placement.
    let mut spec = test_spec(vec![("ream", 2)]);
    spec.subnets = 2;
    spec.attestation_committee_count = Some(2);
    spec.aggregator_hosts = vec!["agg0".to_string(), "agg1".to_string()];
    let vc = generate_validator_config(&spec).unwrap();

    // subnet 0: ream_s0_p0 (aggregator -> agg0), ream_s0_p1 (no pin)
    // subnet 1: ream_s1_p0 (aggregator -> agg1), ream_s1_p1 (no pin)
    let by_name = |n: &str| vc.validators.iter().find(|v| v.name == n).unwrap();
    let a0 = by_name("ream_s0_p0");
    assert!(a0.is_aggregator);
    assert_eq!(a0.host.as_deref(), Some("agg0"));
    assert!(!by_name("ream_s0_p1").is_aggregator);
    assert_eq!(by_name("ream_s0_p1").host, None);
    let a1 = by_name("ream_s1_p0");
    assert!(a1.is_aggregator);
    assert_eq!(a1.host.as_deref(), Some("agg1"));
    assert_eq!(by_name("ream_s1_p1").host, None);
}

#[test]
fn test_multi_subnet_interleaves_ids_to_match_ream_committees() {
    // ream assigns a validator's committee as `validator_id % committee_count`
    // (== subnets), and the genesis tool assigns ids in `vc.validators` order.
    // So the Vec must INTERLEAVE subnets: id i belongs to subnet i % subnets,
    // ensuring each subnet's aggregator lands in a distinct ream committee.
    let mut spec = test_spec(vec![("ream", 2)]);
    spec.subnets = 2;
    spec.attestation_committee_count = Some(2);
    let vc = generate_validator_config(&spec).unwrap();
    let subnets = spec.subnets as usize;

    // Every validator's position (== ream validator_id) must satisfy
    // id % subnets == its subnet, so leanstart-subnet-k == ream-committee-k.
    for (id, v) in vc.validators.iter().enumerate() {
        assert_eq!(
            id % subnets,
            v.subnet as usize,
            "validator id {id} ({}) lands in ream committee {} but is tagged subnet {}",
            v.name,
            id % subnets,
            v.subnet
        );
    }

    // Concretely: the two aggregators (first pod of each subnet) must occupy
    // distinct ream committees — the exact thing that was broken before.
    let agg_ids: Vec<usize> = vc
        .validators
        .iter()
        .enumerate()
        .filter(|(_, v)| v.is_aggregator)
        .map(|(id, _)| id % subnets)
        .collect();
    assert_eq!(agg_ids, vec![0, 1], "each subnet's aggregator must be in its own committee");
}

#[test]
fn test_multi_subnet_with_multiple_validators_per_pod_errors() {
    // vpp>1 can't map to ream's contiguous-per-pod committee assignment.
    let mut spec = test_spec(vec![("ream", 2)]);
    spec.subnets = 2;
    spec.validators_per_pod = 2;
    spec.attestation_committee_count = Some(2);
    assert!(generate_validator_config(&spec).is_err());
}

#[test]
fn test_aggregator_hosts_length_mismatch_errors() {
    let mut spec = test_spec(vec![("ream", 1)]);
    spec.subnets = 2;
    spec.attestation_committee_count = Some(2);
    spec.aggregator_hosts = vec!["agg0".to_string()]; // 1 label for 2 subnets
    assert!(generate_validator_config(&spec).is_err());
}

#[test]
fn test_generate_multi_instance() {
    let spec = test_spec(vec![("ream", 1), ("zeam", 2)]);
    let vc = generate_validator_config(&spec).unwrap();

    assert_eq!(vc.validators.len(), 3);
    assert_eq!(vc.validators[0].name, "ream_0");
    assert_eq!(vc.validators[1].name, "zeam_0");
    assert_eq!(vc.validators[2].name, "zeam_1");

    let total: u32 = vc.validators.iter().map(|v| v.count).sum();
    assert_eq!(total, 3);
}

#[test]
fn test_deterministic_privkeys() {
    let spec = test_spec(vec![("ethlambda", 1), ("qlean", 1)]);
    let vc1 = generate_validator_config(&spec).unwrap();
    let vc2 = generate_validator_config(&spec).unwrap();

    for (a, b) in vc1.validators.iter().zip(vc2.validators.iter()) {
        assert_eq!(a.privkey, b.privkey);
    }
    assert_ne!(vc1.validators[0].privkey, vc1.validators[1].privkey);
}

#[test]
fn test_helm_values_per_pod_statefulset() {
    let spec = test_spec(vec![("ream", 1), ("zeam", 2)]);
    let vc = generate_validator_config(&spec).unwrap();
    let values = generate_helm_values(&spec, &vc).unwrap();

    // One StatefulSet per pod (replicas=1 each)
    assert_eq!(values.clients.len(), 3);
    assert_eq!(values.clients[0].name, "ream-0");
    assert_eq!(values.clients[0].replicas, 1);
    assert_eq!(values.clients[1].name, "zeam-0");
    assert_eq!(values.clients[1].replicas, 1);
    assert_eq!(values.clients[2].name, "zeam-1");
    assert_eq!(values.clients[2].replicas, 1);

    // zeam should have seccomp unconfined
    assert!(values.clients[1].seccomp_unconfined);
    assert!(values.clients[2].seccomp_unconfined);
    assert!(!values.clients[0].seccomp_unconfined);
}

#[test]
fn test_total_validators() {
    let spec = test_spec(vec![("ream", 1), ("zeam", 2)]);
    assert_eq!(spec.total_validators(), 3);

    let mut spec2 = test_spec(vec![("ream", 3), ("zeam", 5)]);
    spec2.validators_per_pod = 10;
    assert_eq!(spec2.total_validators(), 80);
}
