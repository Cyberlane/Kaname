//! Reproducible, provider-free Phase 1 local-core measurements.
//!
//! This binary only constructs the checked-in S-01/S-02/S-03 corpus in an
//! in-memory SQLite journal. It never opens a provider, repository, account,
//! network connection, or credential source.

use kaname_core::{
    fake_provider::scale_fixture,
    journal::Journal,
    v1::{CommandEnvelope, OpaqueTypedPayload, SchemaVersion},
};
use prost::Message;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{env, process::Command, time::Instant};

const CURSOR_KEY: [u8; 32] = [0x73; 32];

#[derive(Serialize)]
struct MeasurementReport {
    format_version: u32,
    build_mode: &'static str,
    repetitions: usize,
    machine: MachineMetadata,
    datasets: Vec<DatasetMetadata>,
    metrics: Vec<Metric>,
}

#[derive(Serialize)]
struct MachineMetadata {
    architecture: &'static str,
    os_version: String,
    hardware_model: String,
    power_state: String,
    rust_version: String,
}

#[derive(Serialize)]
struct DatasetMetadata {
    id: String,
    event_count: usize,
    sha256: String,
}

#[derive(Serialize)]
struct Metric {
    id: &'static str,
    unit: &'static str,
    p50: f64,
    p95: f64,
    p99: f64,
    failures: usize,
}

fn main() {
    let repetitions = parse_repetitions();
    let result = measure(repetitions).and_then(|report| {
        serde_json::to_string_pretty(&report).map_err(|error| error.to_string())
    });
    match result {
        Ok(json) => println!("{json}"),
        Err(error) => {
            eprintln!("kaname-phase1-measure: {error}");
            std::process::exit(1);
        }
    }
}

fn parse_repetitions() -> usize {
    let mut arguments = env::args().skip(1);
    match (arguments.next().as_deref(), arguments.next()) {
        (None, None) => 25,
        (Some("--repetitions"), Some(value)) => value
            .parse::<usize>()
            .ok()
            .filter(|value| *value > 0)
            .unwrap_or(25),
        _ => 25,
    }
}

fn measure(repetitions: usize) -> Result<MeasurementReport, String> {
    let s01 = scale_fixture("S-01").map_err(|error| error.to_string())?;
    let s02 = scale_fixture("S-02").map_err(|error| error.to_string())?;
    let s03 = scale_fixture("S-03").map_err(|error| error.to_string())?;
    let small = load(&s01)?;
    let mut thread = load(&s02)?;
    let project = load(&s03)?;
    thread
        .create_snapshot("thread:thread:scale-single")
        .map_err(|error| error.to_string())?;

    let mut accepted = Journal::open_in_memory(&CURSOR_KEY).map_err(|error| error.to_string())?;
    let acceptance = samples(repetitions, |index| {
        accepted
            .admit_command(&command(index))
            .map(|_| ())
            .map_err(|error| error.to_string())
    });
    let replay = samples(repetitions, |_| {
        small
            .replay("thread:thread:scale-single", None, 500)
            .map(|page| if page.events.len() == 500 { () } else { () })
            .map_err(|error| error.to_string())
    });
    let thread_rebuild = samples(repetitions, |_| {
        thread
            .rebuild_thread_projection("thread:thread:scale-single")
            .map(|_| ())
            .map_err(|error| error.to_string())
    });
    let project_rebuild = samples(repetitions, |_| {
        project
            .rebuild_project_projection("project:scale-project")
            .map(|projection| {
                if projection.threads.len() == 100 {
                    ()
                } else {
                    ()
                }
            })
            .map_err(|error| error.to_string())
    });
    let snapshot_read = samples(repetitions, |_| {
        thread
            .load_latest_snapshot("thread:thread:scale-single")
            .map(|_| ())
            .map_err(|error| error.to_string())
    });

    Ok(MeasurementReport {
        format_version: 1,
        build_mode: if cfg!(debug_assertions) {
            "debug"
        } else {
            "release"
        },
        repetitions,
        machine: MachineMetadata {
            architecture: env::consts::ARCH,
            os_version: command_output("/usr/bin/sw_vers", &["-productVersion"]),
            hardware_model: command_output("/usr/sbin/sysctl", &["-n", "hw.model"]),
            power_state: command_output("/usr/bin/pmset", &["-g", "batt"]),
            rust_version: command_output("/usr/bin/env", &["rustc", "--version"]),
        },
        datasets: vec![
            dataset("S-01", &s01),
            dataset("S-02", &s02),
            dataset("S-03", &s03),
        ],
        metrics: vec![
            metric("command_journal_acceptance", acceptance),
            metric("replay_page_500", replay),
            metric("rebuild_thread_10000", thread_rebuild),
            metric("rebuild_project_100000", project_rebuild),
            metric("snapshot_read_validation", snapshot_read),
        ],
    })
}

fn load(events: &[kaname_core::v1::EventEnvelope]) -> Result<Journal, String> {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).map_err(|error| error.to_string())?;
    for event in events.iter().cloned() {
        journal
            .append_event(event)
            .map_err(|error| error.to_string())?;
    }
    Ok(journal)
}

fn command(index: usize) -> CommandEnvelope {
    CommandEnvelope {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        command_id: format!("benchmark-command-{index:03}"),
        idempotency_key: format!("benchmark-key-{index:03}"),
        kind: "intent.enqueue".into(),
        payload: Some(OpaqueTypedPayload {
            type_url: "kaname.benchmark.v1".into(),
            content_type: "application/x-protobuf".into(),
            value: Vec::new(),
            payload_version: 1,
        }),
        scope: None,
        actor_id: "benchmark".into(),
        expected_revision: 0,
        submitted_at_unix_millis: 1_762_100_000_000,
    }
}

fn samples(
    repetitions: usize,
    mut operation: impl FnMut(usize) -> Result<(), String>,
) -> (Vec<f64>, usize) {
    let mut values = Vec::with_capacity(repetitions);
    let mut failures = 0;
    for index in 0..repetitions {
        let started = Instant::now();
        if operation(index).is_err() {
            failures += 1;
        }
        values.push(started.elapsed().as_secs_f64() * 1_000.0);
    }
    (values, failures)
}

fn metric(id: &'static str, (mut values, failures): (Vec<f64>, usize)) -> Metric {
    values.sort_by(f64::total_cmp);
    let percentile =
        |percent: f64| values[((values.len() as f64 * percent).ceil() as usize).saturating_sub(1)];
    Metric {
        id,
        unit: "milliseconds",
        p50: percentile(0.50),
        p95: percentile(0.95),
        p99: percentile(0.99),
        failures,
    }
}

fn dataset(id: &str, events: &[kaname_core::v1::EventEnvelope]) -> DatasetMetadata {
    let mut hasher = Sha256::new();
    for event in events {
        hasher.update(event.encode_to_vec());
    }
    DatasetMetadata {
        id: id.into(),
        event_count: events.len(),
        sha256: hex::encode(hasher.finalize()),
    }
}

fn command_output(executable: &str, arguments: &[&str]) -> String {
    Command::new(executable)
        .args(arguments)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .unwrap_or_else(|| "unavailable".into())
}
