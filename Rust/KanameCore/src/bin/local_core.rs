use kaname_core::fake_provider::{
    embedded_scenarios, run_scenario, run_scenario_at_path, scale_fixture,
};
use serde::Serialize;

#[derive(Serialize)]
struct ScaleReport {
    fixture_id: String,
    event_count: usize,
    first_event_id: String,
    last_event_id: String,
}

fn main() {
    let result = match std::env::args().skip(1).collect::<Vec<_>>().as_slice() {
        [operation, fixture_id] if operation == "scenario" => scenario(fixture_id),
        [operation, fixture_id, journal_path] if operation == "scenario-store" => {
            scenario_store(fixture_id, journal_path)
        }
        [operation, fixture_id] if operation == "scale" => scale(fixture_id),
        _ => Err("usage: kaname-local-core scenario <F-01..F-14> | scenario-store <F-01..F-14> <journal-path> | scale <S-01..S-04>".to_owned()),
    };
    match result {
        Ok(json) => println!("{json}"),
        Err(error) => {
            eprintln!("kaname-local-core: {error}");
            std::process::exit(64);
        }
    }
}

fn scenario(fixture_id: &str) -> Result<String, String> {
    scenario_with(fixture_id, run_scenario)
}

fn scenario_store(fixture_id: &str, journal_path: &str) -> Result<String, String> {
    scenario_with(fixture_id, |metadata| {
        run_scenario_at_path(metadata, journal_path)
    })
}

fn scenario_with(
    fixture_id: &str,
    run: impl FnOnce(
        &kaname_core::fake_provider::ScenarioMetadata,
    ) -> kaname_core::journal::Result<kaname_core::fake_provider::ScenarioReport>,
) -> Result<String, String> {
    let metadata = embedded_scenarios()
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|scenario| scenario.fixture_id == fixture_id)
        .ok_or_else(|| "unknown_scenario".to_owned())?;
    serde_json::to_string(&run(&metadata).map_err(|error| error.to_string())?)
        .map_err(|error| error.to_string())
}

fn scale(fixture_id: &str) -> Result<String, String> {
    let events = scale_fixture(fixture_id).map_err(|error| error.to_string())?;
    let report = ScaleReport {
        fixture_id: fixture_id.into(),
        event_count: events.len(),
        first_event_id: events
            .first()
            .map(|event| event.event_id.clone())
            .unwrap_or_default(),
        last_event_id: events
            .last()
            .map(|event| event.event_id.clone())
            .unwrap_or_default(),
    };
    serde_json::to_string(&report).map_err(|error| error.to_string())
}
