use crate::{LinkError, Result};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use snow::{Builder, HandshakeState, params::NoiseParams};

use crate::model::{MAXIMUM_NOISE_MESSAGE_BYTES, MAXIMUM_NOISE_PAYLOAD_BYTES};

const ENROLLMENT_PATTERN: &str = "Noise_IKpsk1_25519_ChaChaPoly_BLAKE2s";
const SESSION_PATTERN: &str = "Noise_IK_25519_ChaChaPoly_BLAKE2s";
const ENROLLMENT_PROLOGUE: &[u8] = b"kaname-link/enrollment/v1";
const SESSION_PROLOGUE: &[u8] = b"kaname-link/session/v1";
pub const STATIC_KEY_BYTES: usize = 32;
pub const INVITE_SECRET_BYTES: usize = 32;

pub struct StaticKeypair {
    pub private: Vec<u8>,
    pub public: Vec<u8>,
}

pub fn generate_static_keypair() -> Result<StaticKeypair> {
    let params: NoiseParams = SESSION_PATTERN
        .parse()
        .map_err(|_| LinkError::Invalid("invalid_noise_pattern"))?;
    let pair = Builder::new(params).generate_keypair()?;
    Ok(StaticKeypair {
        private: pair.private,
        public: pair.public,
    })
}

pub fn generate_invite_secret() -> Result<Vec<u8>> {
    let mut secret = vec![0_u8; INVITE_SECRET_BYTES];
    getrandom::fill(&mut secret).map_err(|_| LinkError::Unavailable("random_unavailable"))?;
    Ok(secret)
}

pub fn enrollment_initiator(
    client_private: &[u8],
    host_public: &[u8],
    invite_secret: &[u8],
) -> Result<HandshakeState> {
    validate_key(client_private)?;
    validate_key(host_public)?;
    validate_invite_secret(invite_secret)?;
    let params: NoiseParams = ENROLLMENT_PATTERN
        .parse()
        .map_err(|_| LinkError::Invalid("invalid_noise_pattern"))?;
    let invite_secret: &[u8; INVITE_SECRET_BYTES] = invite_secret
        .try_into()
        .map_err(|_| LinkError::Invalid("invalid_invite_secret"))?;
    Ok(Builder::new(params)
        .local_private_key(client_private)?
        .remote_public_key(host_public)?
        .psk(1, invite_secret)?
        .prologue(ENROLLMENT_PROLOGUE)?
        .build_initiator()?)
}

pub fn enrollment_responder(host_private: &[u8], invite_secret: &[u8]) -> Result<HandshakeState> {
    validate_key(host_private)?;
    validate_invite_secret(invite_secret)?;
    let params: NoiseParams = ENROLLMENT_PATTERN
        .parse()
        .map_err(|_| LinkError::Invalid("invalid_noise_pattern"))?;
    let invite_secret: &[u8; INVITE_SECRET_BYTES] = invite_secret
        .try_into()
        .map_err(|_| LinkError::Invalid("invalid_invite_secret"))?;
    Ok(Builder::new(params)
        .local_private_key(host_private)?
        .psk(1, invite_secret)?
        .prologue(ENROLLMENT_PROLOGUE)?
        .build_responder()?)
}

pub fn session_initiator(client_private: &[u8], host_public: &[u8]) -> Result<HandshakeState> {
    validate_key(client_private)?;
    validate_key(host_public)?;
    let params: NoiseParams = SESSION_PATTERN
        .parse()
        .map_err(|_| LinkError::Invalid("invalid_noise_pattern"))?;
    Ok(Builder::new(params)
        .local_private_key(client_private)?
        .remote_public_key(host_public)?
        .prologue(SESSION_PROLOGUE)?
        .build_initiator()?)
}

pub fn session_responder(host_private: &[u8]) -> Result<HandshakeState> {
    validate_key(host_private)?;
    let params: NoiseParams = SESSION_PATTERN
        .parse()
        .map_err(|_| LinkError::Invalid("invalid_noise_pattern"))?;
    Ok(Builder::new(params)
        .local_private_key(host_private)?
        .prologue(SESSION_PROLOGUE)?
        .build_responder()?)
}

pub fn write_handshake_message(state: &mut HandshakeState, payload: &[u8]) -> Result<Vec<u8>> {
    if payload.len() > MAXIMUM_NOISE_PAYLOAD_BYTES {
        return Err(LinkError::Invalid("noise_payload_too_large"));
    }
    let mut output = vec![0_u8; MAXIMUM_NOISE_MESSAGE_BYTES];
    let count = state.write_message(payload, &mut output)?;
    output.truncate(count);
    Ok(output)
}

pub fn read_handshake_message(state: &mut HandshakeState, message: &[u8]) -> Result<Vec<u8>> {
    if message.is_empty() || message.len() > MAXIMUM_NOISE_MESSAGE_BYTES {
        return Err(LinkError::Invalid("noise_message_bounds"));
    }
    let mut output = vec![0_u8; MAXIMUM_NOISE_PAYLOAD_BYTES];
    let count = state.read_message(message, &mut output)?;
    output.truncate(count);
    Ok(output)
}

pub fn remote_static(state: &HandshakeState) -> Result<Vec<u8>> {
    state
        .get_remote_static()
        .map(ToOwned::to_owned)
        .ok_or(LinkError::Invalid("remote_static_missing"))
}

pub fn encode_bytes(value: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(value)
}

pub fn decode_bytes(value: &str, maximum: usize, code: &'static str) -> Result<Vec<u8>> {
    if value.is_empty() || value.len() > maximum.saturating_mul(2) {
        return Err(LinkError::Invalid(code));
    }
    let decoded = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| LinkError::Invalid(code))?;
    if decoded.is_empty() || decoded.len() > maximum {
        return Err(LinkError::Invalid(code));
    }
    Ok(decoded)
}

pub fn key_fingerprint(public: &[u8]) -> Result<String> {
    validate_key(public)?;
    Ok(hex::encode(Sha256::digest(public)))
}

/// A short, human-comparable representation of an authenticated static key.
///
/// The full SHA-256 fingerprint remains available for machine identity. Link
/// shows this 80-bit prefix on both endpoints so a host and collaborator can
/// compare the pending device through an independent channel before approval.
pub fn verification_code(public: &[u8]) -> Result<String> {
    let fingerprint = key_fingerprint(public)?;
    Ok(fingerprint.as_bytes()[..20]
        .chunks(4)
        .map(|chunk| String::from_utf8_lossy(chunk).to_ascii_uppercase())
        .collect::<Vec<_>>()
        .join("-"))
}

pub fn sha256_hex(value: &[u8]) -> String {
    hex::encode(Sha256::digest(value))
}

fn validate_key(key: &[u8]) -> Result<()> {
    if key.len() != STATIC_KEY_BYTES {
        return Err(LinkError::Invalid("invalid_static_key"));
    }
    Ok(())
}

fn validate_invite_secret(secret: &[u8]) -> Result<()> {
    if secret.len() != INVITE_SECRET_BYTES {
        return Err(LinkError::Invalid("invalid_invite_secret"));
    }
    Ok(())
}
