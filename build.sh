#!/usr/bin/env bash
# Driver run locally (git-bash/WSL on Windows, or any POSIX shell) that
# ships this project's site/ set and install.conf to the remote
# OpenBSD build host, runs remote/build-image.sh there over SSH, and
# copies the resulting ISO back into ./out/.
set -euo pipefail
cd "$(dirname "$0")"

source ./config.sh
if [ -f ./config.local.sh ]; then
	source ./config.local.sh
fi

if [ -z "${REMOTE_HOST:-}" ]; then
	echo "REMOTE_HOST is not set. Copy config.local.sh.example to" >&2
	echo "config.local.sh and fill in your OpenBSD build host." >&2
	exit 1
fi

if [ ! -f ./install.conf ]; then
	echo "install.conf not found. Copy install.conf.example to" >&2
	echo "install.conf and edit it for your target system." >&2
	exit 1
fi

echo "==> Preparing remote build directory ${REMOTE_DIR} on ${REMOTE_HOST}"
ssh -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p ${REMOTE_DIR}/site"

echo "==> Uploading site set, install.conf and build script"
scp -P "${REMOTE_PORT}" -r site/. "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/site/"
scp -P "${REMOTE_PORT}" install.conf "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/install.conf"
scp -P "${REMOTE_PORT}" remote/build-image.sh "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/build-image.sh"

echo "==> Running remote build (release=${RELEASE} arch=${ARCH})"
ssh -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" "
	chmod +x ${REMOTE_DIR}/build-image.sh &&
	doas env RELEASE=${RELEASE} RELEASE_SHORT=${RELEASE_SHORT} ARCH=${ARCH} MIRROR=${MIRROR} BUILD_DIR=${REMOTE_DIR} ${REMOTE_DIR}/build-image.sh
"

echo "==> Fetching built ISO"
mkdir -p "${OUT_DIR}"
scp -P "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/out/install${RELEASE_SHORT}-custom.iso" "${OUT_DIR}/"

echo "==> Done: ${OUT_DIR}/install${RELEASE_SHORT}-custom.iso"
