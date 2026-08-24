use kaname_link_core::{
    LinkError, Result,
    server::spawn_gateway,
    shell::{
        ShellResponse, default_gateway_state_root, execute_gateway_admin,
        read_gateway_admin_request, state_root_override, write_shell_response,
    },
};
use serde_json::json;
use std::{io::Write, net::SocketAddr, path::PathBuf};

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        let response = json!({
            "schemaVersion": 1,
            "ok": false,
            "error": { "code": error.code() }
        });
        let _ = writeln!(std::io::stderr().lock(), "{response}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = arguments.first().map(String::as_str) else {
        return Err(LinkError::Invalid("missing_command"));
    };
    let state_root =
        state_root_override(&arguments)?.map_or_else(default_gateway_state_root, Ok)?;
    match command {
        "admin" => {
            let response = match read_gateway_admin_request() {
                Ok(request) => execute_gateway_admin(&state_root, request),
                Err(response) => *response,
            };
            write_shell_response(&response)
        }
        "serve" => {
            let bind = required_flag(&arguments, "--bind")?
                .to_string_lossy()
                .parse::<SocketAddr>()
                .map_err(|_| LinkError::Invalid("invalid_bind_address"))?;
            let gateway = spawn_gateway(&state_root, bind).await?;
            let startup = ShellResponse {
                schema_version: 1,
                request_id: "startup".to_owned(),
                ok: true,
                result: Some(json!({ "listeningAddress": gateway.address.to_string() })),
                snapshot: None,
                error_code: None,
                error: None,
            };
            write_shell_response(&startup)?;
            tokio::signal::ctrl_c().await?;
            gateway.shutdown().await
        }
        _ => Err(LinkError::Invalid("unknown_command")),
    }
}

fn required_flag(arguments: &[String], flag: &'static str) -> Result<PathBuf> {
    let index = arguments
        .iter()
        .position(|argument| argument == flag)
        .ok_or(LinkError::Invalid("missing_argument"))?;
    let value = arguments
        .get(index + 1)
        .filter(|value| !value.is_empty())
        .ok_or(LinkError::Invalid("missing_argument"))?;
    Ok(PathBuf::from(value))
}
