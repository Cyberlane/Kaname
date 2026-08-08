use kaname_core::fake_provider::{embedded_scenarios, run_scenario, scale_fixture};
use serde::Deserialize;
use std::{collections::BTreeSet, path::PathBuf};

#[derive(Debug, Deserialize)]
struct Expected {
    #[serde(rename = "fixtureID")]
    fixture_id: String,
    #[serde(rename = "taskState")]
    task_state: String,
    health: String,
}

#[test]
fn all_core_scenarios_execute_with_stable_ids_times_and_effect_counts() {
    let scenarios = embedded_scenarios().unwrap();
    assert_eq!(scenarios.len(), 14);
    let ids: Vec<_> = scenarios
        .iter()
        .map(|scenario| scenario.fixture_id.clone())
        .collect();
    assert_eq!(
        ids,
        (1..=14)
            .map(|number| format!("F-{number:02}"))
            .collect::<Vec<_>>()
    );

    for scenario in scenarios {
        assert_eq!(scenario.corpus_version, 1);
        assert!(scenario.fixed_clock_unix_millis > 0);
        let report = run_scenario(&scenario).unwrap();
        let expected = expected(&scenario.fixture_id);
        assert_eq!(report.fixture_id, expected.fixture_id);
        assert_eq!(report.task_state, expected.task_state);
        assert_eq!(report.health.as_str(), expected.health);
        assert_eq!(report.effect_count, scenario.expected_effect_count);
    }
}

#[test]
fn scale_fixtures_are_exactly_reproducible_and_have_no_random_ids() {
    for (name, expected_count) in [
        ("S-01", 500),
        ("S-02", 10_000),
        ("S-03", 100_000),
        ("S-04", 1_000),
    ] {
        let first = scale_fixture(name).unwrap();
        let second = scale_fixture(name).unwrap();
        assert_eq!(first.len(), expected_count);
        assert_eq!(first, second);
        let ids: BTreeSet<_> = first.iter().map(|event| &event.event_id).collect();
        assert_eq!(ids.len(), expected_count);
    }
    assert!(scale_fixture("S-04").unwrap().iter().all(|event| {
        event
            .provenance
            .as_ref()
            .unwrap()
            .raw_evidence_digest
            .starts_with("sha256:scale-")
    }));
}

fn expected(id: &str) -> Expected {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../Fixtures/expected/v1")
        .join(format!("{id}.json"));
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}
