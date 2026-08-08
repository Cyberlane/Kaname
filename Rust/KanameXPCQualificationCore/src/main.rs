use prost::Message;
use std::io::{self, Read, Write};

pub mod qualification {
    include!(concat!(env!("OUT_DIR"), "/kaname.qualification.v1.rs"));
}

const MAXIMUM_REQUEST_BYTES: usize = 64 * 1024;

fn main() {
    let status = match std::env::args().nth(1).as_deref() {
        Some("round-trip") => round_trip(),
        _ => Err("unsupported_operation"),
    };

    let mut stdout = io::stdout().lock();
    match status {
        Ok(response) => {
            let _ = stdout.write_all(&[0]);
            let _ = stdout.write_all(&response);
        }
        Err(code) => {
            let _ = stdout.write_all(&[1]);
            let _ = stdout.write_all(code.as_bytes());
        }
    }
}

fn round_trip() -> Result<Vec<u8>, &'static str> {
    let mut stdin = io::stdin().lock();
    let mut length_bytes = [0_u8; 4];
    stdin
        .read_exact(&mut length_bytes)
        .map_err(|_| "malformed_envelope")?;
    let length = u32::from_be_bytes(length_bytes) as usize;
    if length > MAXIMUM_REQUEST_BYTES {
        return Err("request_too_large");
    }
    let mut input = vec![0_u8; length];
    stdin
        .read_exact(&mut input)
        .map_err(|_| "malformed_envelope")?;

    let envelope =
        qualification::Envelope::decode(input.as_slice()).map_err(|_| "malformed_envelope")?;
    if envelope.schema_major != 1 {
        return Err("unsupported_protocol_major");
    }
    if envelope.cursor == b"expired" {
        return Err("expired_cursor");
    }
    if envelope.operation != "replay" {
        return Err("unsupported_operation");
    }

    let mut response = Vec::with_capacity(envelope.encoded_len());
    envelope.encode(&mut response).map_err(|_| "core_failed")?;
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::{MAXIMUM_REQUEST_BYTES, qualification::Envelope};
    use prost::Message;

    #[test]
    fn preserves_unknown_type_payload_as_opaque_bytes() {
        let envelope = Envelope {
            schema_major: 1,
            type_url: "kaname.event.future.unsupported.v9".into(),
            payload: vec![0x08, 0x96, 0x01],
            cursor: b"future-cursor".to_vec(),
            operation: "replay".into(),
        };
        let mut bytes = Vec::new();
        envelope.encode(&mut bytes).unwrap();
        let decoded = Envelope::decode(bytes.as_slice()).unwrap();
        assert_eq!(decoded, envelope);
    }

    #[test]
    fn request_bound_is_fixed() {
        assert_eq!(MAXIMUM_REQUEST_BYTES, 64 * 1024);
    }
}
