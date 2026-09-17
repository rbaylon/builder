#!/bin/sh
# Default build configuration. Safe to commit -- no secrets here.
# Local overrides (if you ever need any) go in config.local.sh, which
# is gitignored and sourced after this file, if present.

RELEASE="7.9"
RELEASE_SHORT="79"
ARCH="amd64"
MIRROR="https://cdn.openbsd.org/pub/OpenBSD"

BUILD_DIR="/usr/obj/arkgate/build"
OUT_DIR="/usr/obj/arkgate/out"
