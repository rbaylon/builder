#!/usr/bin/env bash
# Default build configuration. Safe to commit -- no secrets here.
# Host-specific / secret values (REMOTE_HOST etc.) go in config.local.sh,
# which is gitignored. Copy config.local.sh.example to get started.

RELEASE="7.9"
RELEASE_SHORT="79"
ARCH="amd64"
MIRROR="https://cdn.openbsd.org/pub/OpenBSD"

REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-/root/openbsd-builder}"

OUT_DIR="out"
