//! Bounded subprocess transport shared by the injectable workflow hosts.
//!
//! Kaname keeps validation, journaling, and replay inside the durable executor.
//! A host implementation only needs a way to describe itself once and to run one
//! idempotent invocation. This module owns that single mechanism so the LLM
//! provider and the capability host cannot each invent a different process
//! contract.
//!
//! The transport is deliberately narrow. It passes one canonical JSON request on
//! standard input, reads one bounded JSON response from standard output, clears
//! the inherited environment so no ambient credential or host path crosses the
//! boundary, discards standard error, and kills a child that outlives its
//! registered deadline.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub(crate) const MAXIMUM_HOST_RESPONSE_BYTES: usize = 512 * 1024;
const POLL_INTERVAL: Duration = Duration::from_millis(2);
const MINIMUM_DEADLINE: Duration = Duration::from_millis(50);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ProcessHostFailure {
    /// The host could not be started at all, so nothing was invoked.
    Unavailable(String),
    /// The child outlived its registered deadline and was killed.
    TimedOut,
    /// The child answered, but not with one bounded well-formed response.
    Malformed(String),
    /// The child failed or exited without a usable response.
    Crashed(String),
}

impl ProcessHostFailure {
    pub(crate) fn summary(&self) -> String {
        match self {
            Self::Unavailable(reason) => format!("The host process could not start: {reason}."),
            Self::TimedOut => "The host process exceeded its registered deadline.".into(),
            Self::Malformed(reason) => {
                format!("The host process returned an unusable response: {reason}.")
            }
            Self::Crashed(reason) => format!("The host process failed: {reason}."),
        }
    }
}

/// One version-pinned external host executable.
pub(crate) struct ProcessHostCommand {
    program: PathBuf,
}

impl ProcessHostCommand {
    /// Reads the configured program from `variable`, or returns `None` when the
    /// variable is absent or empty so the caller stays unavailable.
    pub(crate) fn from_environment(variable: &str) -> Option<Self> {
        let program = PathBuf::from(std::env::var_os(variable)?);
        (!program.as_os_str().is_empty()).then_some(Self { program })
    }

    pub(crate) fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
        }
    }

    /// Runs `program <mode>` with `request` on standard input and returns the
    /// bounded standard-output bytes.
    pub(crate) fn run(
        &self,
        mode: &str,
        request: &[u8],
        timeout: Duration,
    ) -> std::result::Result<Vec<u8>, ProcessHostFailure> {
        let mut child = Command::new(&self.program)
            .arg(mode)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .env_clear()
            .spawn()
            .map_err(|error| ProcessHostFailure::Unavailable(error.kind().to_string()))?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| ProcessHostFailure::Crashed("standard input unavailable".into()))?;
        let mut stdout = child
            .stdout
            .take()
            .ok_or_else(|| ProcessHostFailure::Crashed("standard output unavailable".into()))?;
        let payload = request.to_vec();
        let writer = std::thread::spawn(move || {
            let _ = stdin.write_all(&payload);
            let _ = stdin.flush();
        });
        let reader = std::thread::spawn(move || {
            let mut buffer = Vec::new();
            let _ = stdout
                .by_ref()
                .take(MAXIMUM_HOST_RESPONSE_BYTES as u64 + 1)
                .read_to_end(&mut buffer);
            buffer
        });
        let deadline = Instant::now() + timeout.max(MINIMUM_DEADLINE);
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) if Instant::now() >= deadline => {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = writer.join();
                    let _ = reader.join();
                    return Err(ProcessHostFailure::TimedOut);
                }
                Ok(None) => std::thread::sleep(POLL_INTERVAL),
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = writer.join();
                    let _ = reader.join();
                    return Err(ProcessHostFailure::Crashed(error.kind().to_string()));
                }
            }
        };
        let _ = writer.join();
        let response = reader
            .join()
            .map_err(|_| ProcessHostFailure::Crashed("the response reader failed".into()))?;
        if !status.success() {
            return Err(ProcessHostFailure::Crashed(format!(
                "exit status {}",
                status.code().unwrap_or(-1)
            )));
        }
        if response.len() > MAXIMUM_HOST_RESPONSE_BYTES {
            return Err(ProcessHostFailure::Malformed(
                "the response exceeded the bounded host response size".into(),
            ));
        }
        Ok(response)
    }
}

/// Parses one bounded JSON document from a host response.
pub(crate) fn parse_response<T: serde::de::DeserializeOwned>(
    response: &[u8],
) -> std::result::Result<T, ProcessHostFailure> {
    serde_json::from_slice(response)
        .map_err(|error| ProcessHostFailure::Malformed(error.to_string()))
}

/// Encodes one bounded JSON request for a host.
pub(crate) fn encode_request<T: serde::Serialize>(
    request: &T,
) -> std::result::Result<Vec<u8>, ProcessHostFailure> {
    serde_json::to_vec(request).map_err(|error| ProcessHostFailure::Malformed(error.to_string()))
}
