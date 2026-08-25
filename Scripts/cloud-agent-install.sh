#!/usr/bin/env bash
# Cloud Agent install: prepare the Linux-buildable subset of Kaname.
#
# Kaname's macOS/iOS Swift app targets (SwiftUI, AppKit, XPC, launchd) cannot be
# built on a Linux Cloud Agent. This script prepares the cross-platform pieces
# that do run here: the Rust local core, the Cloudflare Worker relay, and the
# dependency-free Python schema guards.
#
# The script is idempotent: it can run repeatedly against a warm or partially
# prepared checkout.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# The Rust crates declare `edition = "2024"`, which requires Rust >= 1.85.
# Installing/selecting the stable toolchain is a no-op when it already matches.
rustup toolchain install stable
rustup default stable

# Fetch dependencies and compile the Rust crates so the cargo cache is warm.
cargo build --manifest-path Rust/KanameCore/Cargo.toml
cargo build --manifest-path Rust/KanameXPCQualificationCore/Cargo.toml

# Cloudflare Worker relay dependencies (Node 22 ships in the base image).
npm --prefix Relay ci
