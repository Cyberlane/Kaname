use crate::{LinkError, Result};
use keyring::Entry;
use sha2::{Digest, Sha256};
use std::{fs, path::Path, sync::Arc};

const SERVICE_NAME: &str = "com.cyber-lane.kaname-link";

/// Minimal secret-store boundary used by the portable core.
///
/// Production callers use [`PlatformSecretStore`]. Tests can inject an isolated
/// implementation with `GatewayStore::open_with_secret_store`,
/// `LinkClient::open_with_secret_store`, and `spawn_gateway_with_secret_store`.
pub trait SecretStore: Send + Sync {
    fn put(&self, reference: &str, secret: &[u8]) -> Result<()>;
    fn get(&self, reference: &str) -> Result<Vec<u8>>;
    fn delete(&self, reference: &str) -> Result<()>;
}

pub type SharedSecretStore = Arc<dyn SecretStore>;

#[derive(Debug, Default)]
pub struct PlatformSecretStore;

impl PlatformSecretStore {
    pub fn open() -> Result<Self> {
        Entry::store_status()
            .as_ref()
            .map_err(|_| LinkError::Unavailable("secret_store_unavailable"))?;
        Ok(Self)
    }

    fn entry(reference: &str) -> Result<Entry> {
        Entry::new(SERVICE_NAME, reference)
            .map_err(|_| LinkError::Unavailable("secret_store_unavailable"))
    }
}

impl SecretStore for PlatformSecretStore {
    fn put(&self, reference: &str, secret: &[u8]) -> Result<()> {
        Self::entry(reference)?
            .set_secret(secret)
            .map_err(|_| LinkError::Unavailable("secret_store_write_failed"))
    }

    fn get(&self, reference: &str) -> Result<Vec<u8>> {
        Self::entry(reference)?
            .get_secret()
            .map_err(|_| LinkError::Unavailable("secret_store_read_failed"))
    }

    fn delete(&self, reference: &str) -> Result<()> {
        match Self::entry(reference)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(_) => Err(LinkError::Unavailable("secret_store_delete_failed")),
        }
    }
}

pub fn production_secret_store() -> Result<SharedSecretStore> {
    Ok(Arc::new(PlatformSecretStore::open()?))
}

pub fn state_secret_reference(state_root: &Path, role: &str, record: &str) -> Result<String> {
    let canonical_root = fs::canonicalize(state_root)?;
    let mut digest = Sha256::new();
    digest.update(canonical_root.to_string_lossy().as_bytes());
    let root_digest = hex::encode(digest.finalize());
    Ok(format!("{role}:{}:{record}", &root_digest[..32]))
}
