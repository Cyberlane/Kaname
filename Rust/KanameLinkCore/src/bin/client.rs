use kaname_link_core::{
    LinkError, Result,
    shell::{
        default_client_state_root, execute_client_rpc, read_client_shell_request,
        state_root_override, write_shell_response,
    },
};
use serde_json::json;
use std::io::Write;

fn main() {
    if let Err(error) = run() {
        let response = json!({
            "schemaVersion": 1,
            "ok": false,
            "error": { "code": error.code() }
        });
        let _ = writeln!(std::io::stderr().lock(), "{response}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.first().map(String::as_str) != Some("rpc") {
        return Err(LinkError::Invalid("unknown_command"));
    }
    let state_root = state_root_override(&arguments)?.map_or_else(default_client_state_root, Ok)?;
    let response = match read_client_shell_request() {
        Ok(request) => execute_client_rpc(&state_root, request),
        Err(response) => *response,
    };
    write_shell_response(&response)
}
