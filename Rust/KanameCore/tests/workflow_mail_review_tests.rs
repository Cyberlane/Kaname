use kaname_core::{
    workflow_mail::{WorkflowMailThreadEnvelope, normalize_fixture_json},
    workflow_mail_review::{
        WorkflowMailObservationPage, WorkflowMailReviewError, WorkflowMailReviewRoute,
        freeze_read_only_review, observation_plan_digest,
    },
};
use std::collections::BTreeMap;

const GMAIL: &[u8] = include_bytes!("../../../Fixtures/workflow-mail/wfp-101-gmail-metadata.json");

fn thread() -> WorkflowMailThreadEnvelope {
    normalize_fixture_json(GMAIL).unwrap()
}

#[test]
fn paged_review_deduplicates_correlates_retains_and_proposes_no_effects() {
    let envelope = thread();
    let first_message = envelope.messages[0].clone();
    let second_message = envelope.messages[1].clone();
    let first = WorkflowMailThreadEnvelope {
        messages: vec![first_message.clone()],
        ..envelope.clone()
    };
    let duplicate_and_second = WorkflowMailThreadEnvelope {
        messages: vec![first_message, second_message],
        ..envelope
    };
    let pages = vec![
        WorkflowMailObservationPage {
            page_number: 1,
            request_cursor_fingerprint: None,
            next_cursor_fingerprint: Some("sha256:cursor-page-two".into()),
            threads: vec![first],
        },
        WorkflowMailObservationPage {
            page_number: 2,
            request_cursor_fingerprint: Some("sha256:cursor-page-two".into()),
            next_cursor_fingerprint: None,
            threads: vec![duplicate_and_second],
        },
    ];
    let receipt = freeze_read_only_review(pages, &BTreeMap::new(), 5_000, 10_000).unwrap();
    assert_eq!(receipt.page_count, 2);
    assert_eq!(receipt.thread_count, 2);
    assert_eq!(receipt.unique_message_count, 2);
    assert_eq!(receipt.duplicate_message_count, 1);
    assert_eq!(receipt.proposed_effect_count, 0);
    assert!(receipt.frozen_digest.starts_with("sha256:"));
    assert_eq!(receipt.purge_eligible_at_unix_millis, 10_000);
}

#[test]
fn shadow_mismatch_is_visible_without_changing_the_deterministic_route() {
    let envelope = thread();
    let fingerprint = envelope.messages[0].message_fingerprint.clone();
    let page = WorkflowMailObservationPage {
        page_number: 1,
        request_cursor_fingerprint: None,
        next_cursor_fingerprint: None,
        threads: vec![envelope],
    };
    let shadow = BTreeMap::from([(fingerprint.clone(), WorkflowMailReviewRoute::Newsletter)]);
    let receipt = freeze_read_only_review(vec![page], &shadow, 5_000, 10_000).unwrap();
    assert_eq!(receipt.shadow_mismatches.len(), 1);
    assert_eq!(
        receipt.shadow_mismatches[0].message_fingerprint,
        fingerprint
    );
    assert_ne!(
        receipt.shadow_mismatches[0].expected,
        receipt.shadow_mismatches[0].actual
    );
}

#[test]
fn cursor_cycles_identity_drift_and_collisions_fail_closed() {
    let envelope = thread();
    let repeated = vec![
        WorkflowMailObservationPage {
            page_number: 1,
            request_cursor_fingerprint: None,
            next_cursor_fingerprint: Some("sha256:repeat".into()),
            threads: vec![envelope.clone()],
        },
        WorkflowMailObservationPage {
            page_number: 2,
            request_cursor_fingerprint: Some("sha256:repeat".into()),
            next_cursor_fingerprint: Some("sha256:repeat".into()),
            threads: vec![envelope.clone()],
        },
    ];
    assert_eq!(
        freeze_read_only_review(repeated, &BTreeMap::new(), 5_000, 10_000),
        Err(WorkflowMailReviewError::CursorRepeated)
    );

    let mut drifted = envelope.clone();
    drifted.account_binding_id = "another-account".into();
    let identity_drift = vec![WorkflowMailObservationPage {
        page_number: 1,
        request_cursor_fingerprint: None,
        next_cursor_fingerprint: None,
        threads: vec![envelope.clone(), drifted],
    }];
    assert_eq!(
        freeze_read_only_review(identity_drift, &BTreeMap::new(), 5_000, 10_000),
        Err(WorkflowMailReviewError::AccountDrift)
    );

    let mut collision = envelope.clone();
    collision.messages[0].occurred_at_unix_millis += 1;
    let collision_page = WorkflowMailObservationPage {
        page_number: 1,
        request_cursor_fingerprint: None,
        next_cursor_fingerprint: None,
        threads: vec![envelope, collision],
    };
    assert_eq!(
        freeze_read_only_review(vec![collision_page], &BTreeMap::new(), 5_000, 10_000),
        Err(WorkflowMailReviewError::MessageCollision)
    );
}

#[test]
fn bounded_observation_plan_is_digest_bound_but_has_no_account_access() {
    let digest =
        observation_plan_digest("synthetic-account", "sha256:synthetic-query", 4, 500).unwrap();
    assert!(digest.starts_with("sha256:"));
    assert!(observation_plan_digest("synthetic-account", "query", 0, 500).is_none());
}
