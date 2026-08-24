//! Portable, external-principal-only Kaname Link authority.
//!
//! This crate deliberately has no dependency on Kaname's mobile, workflow,
//! provider, filesystem, approval, or tool-control domains. It exposes only
//! scoped Link spaces, device enrollment, text messages, and exact transport
//! receipts.

pub mod client;
pub mod error;
pub mod gateway;
pub mod model;
pub mod noise;
pub mod private_store;
pub mod secret_store;
pub mod server;
pub mod shell;

pub use error::{LinkError, Result};

use std::path::PathBuf;

pub(crate) fn default_state_root(role: &str) -> Result<PathBuf> {
    #[cfg(target_os = "windows")]
    let root = std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("APPDATA"))
        .map(PathBuf::from)
        .map(|path| path.join("Kaname Link"));
    #[cfg(target_os = "macos")]
    let root = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|path| path.join("Library/Application Support/Kaname Link"));
    #[cfg(all(unix, not(target_os = "macos")))]
    let root = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .map(|path| path.join(".local/state"))
        })
        .map(|path| path.join("kaname-link"));
    #[cfg(not(any(unix, windows)))]
    let root: Option<PathBuf> = None;
    root.map(|path| path.join(role))
        .ok_or(LinkError::Unavailable("state_root_unavailable"))
}
