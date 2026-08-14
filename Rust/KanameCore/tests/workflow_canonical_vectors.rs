use kaname_core::workflow_canonical::{self, WorkflowCanonicalError};
use serde::Deserialize;
use std::{fs, path::Path};

#[derive(Deserialize)]
struct Corpus {
    contract: String,
    vectors: Vec<Vector>,
    rejected: Vec<Rejected>,
}

#[derive(Deserialize)]
struct Vector {
    id: String,
    role: String,
    input: String,
    canonical: String,
    sha256: String,
}

#[derive(Deserialize)]
struct Rejected {
    id: String,
    input: String,
    error: String,
}

fn corpus() -> Corpus {
    serde_json::from_slice(
        &fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../Fixtures/workflow-v2/canonical-vectors.json"),
        )
        .unwrap(),
    )
    .unwrap()
}

#[test]
fn every_digest_role_matches_exact_rfc_8785_bytes_after_restart() {
    let corpus = corpus();
    assert_eq!(corpus.contract, "RFC 8785");
    assert_eq!(corpus.vectors.len(), 6);
    let expected_roles = [
        "compiledArtifactDigest",
        "configurationContractDigest",
        "definitionDigest",
        "dependencyLockDigest",
        "layoutDigest",
        "schemaBundleDigest",
    ];
    let mut actual_roles = corpus
        .vectors
        .iter()
        .map(|vector| vector.role.as_str())
        .collect::<Vec<_>>();
    actual_roles.sort_unstable();
    assert_eq!(actual_roles, expected_roles);
    for vector in corpus.vectors {
        let first = workflow_canonical::canonicalize(vector.input.as_bytes()).unwrap();
        let after_restart = workflow_canonical::canonicalize(vector.input.as_bytes()).unwrap();
        assert_eq!(first, after_restart, "{}", vector.id);
        assert_eq!(
            first.canonical_bytes,
            vector.canonical.as_bytes(),
            "{}",
            vector.id
        );
        assert_eq!(first.sha256, vector.sha256, "{}", vector.id);
    }
}

#[test]
fn every_non_i_json_vector_fails_closed_without_echoing_input() {
    for rejected in corpus().rejected {
        let error = workflow_canonical::canonicalize(rejected.input.as_bytes()).unwrap_err();
        let code = match error {
            WorkflowCanonicalError::InputOutOfBounds => "workflow_canonical_input_out_of_bounds",
            WorkflowCanonicalError::InvalidIJson => "workflow_canonical_input_invalid",
            WorkflowCanonicalError::EncodingFailed => "workflow_canonical_encoding_failed",
        };
        assert_eq!(code, rejected.error, "{}", rejected.id);
        if !rejected.input.is_empty() {
            assert!(!code.contains(&rejected.input));
        }
    }
}
