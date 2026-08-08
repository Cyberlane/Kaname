//! Rust-owned control-plane schema boundary.
//!
//! This module is generated from the same canonical proto files as the Swift
//! `KanameProtocol` target. No generated source is hand-maintained here.

pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/kaname.v1.rs"));
}

pub mod fake_provider;
pub mod journal;
pub mod policy;

pub const SCHEMA_MAJOR: u32 = 1;
pub const MAXIMUM_ENVELOPE_BYTES: usize = 64 * 1024;
