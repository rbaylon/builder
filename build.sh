#!/bin/sh
# Builds a self-contained, autoinstall-capable OpenBSD install ISO.
#
# Runs locally, directly on an OpenBSD host, as root: it needs
# rdsetroot(8) (patches bsd.rd's ramdisk), vnconfig(8) + mount (to
# read the source ISO and edit the ramdisk image), and mkhybrid (to
# repack the hybrid BIOS+EFI bootable ISO) -- none of which exist on
# non-OpenBSD systems.
#
#   1. Fetch the official install ISO for RELEASE/ARCH from MIRROR.
#   2. Extract its contents.
#   3. Tar up site/ into site${RELEASE_SHORT}.tgz and drop it next to
#      the standard sets (under RELEASE/ARCH, e.g. 7.9/amd64 -- the
#      on-disc dir uses the full release string, not RELEASE_SHORT).
#   4. Patch bsd.rd (via rdsetroot) to carry install.conf as
#      /auto_install.conf, so booting and choosing (A)utoinstall needs
#      no network. bsd.rd ships gzip-compressed on the media, so it's
#      gunzipped first and re-gzipped after patching.
#   5. Regenerate SHA256 for that set directory, after bsd.rd is
#      patched (unsigned -- there's no signify key for this custom
#      build, so install.conf must answer "yes" to the resulting
#      "continue without verification?" prompt).
#   6. Repack everything with mkhybrid using the same flags OpenBSD's
#      own release build uses (distrib/${ARCH}/iso/Makefile).
#
# VALIDATED on a real OpenBSD 7.9/amd64 host: the script runs
# end-to-end and produces a structurally correct ISO (site set present,
# bsd.rd correctly re-gzipped, SHA256 matches the patched files, and
# the embedded auto_install.conf is byte-identical to the source
# install.conf). NOT yet validated: actually booting the resulting ISO
# and confirming (A)utoinstall completes unattended -- do that before
# trusting a build fully. Background:
#   - autoinstall(8), rdsetroot(8), install.site(5)
#   - https://www.openbsd.org/faq/faq4.html
#   - https://github.com/openbsd/src/blob/master/distrib/amd64/iso/Makefile
#   - https://github.com/tbaumgard/openbsd-custom-image
#
# Known things to check on first run:
#   - vnd1 is assumed free; `vnconfig -l` if it's already in use.
#   - `mkhybrid` must be on PATH (it ships in base as part of
#     gnu/usr.sbin/mkhybrid); if missing, build it from src.git.
#   - rdsetroot has a fixed reserved-space budget inside bsd.rd
#     (`rdsetroot -s bsd.rd`); a large install.conf could in theory not
#     fit, though this is unlikely in practice.
#   - EFI boot (-e eficdboot) only applies on arches that ship it
#     (amd64/arm64); adjust the mkhybrid line if targeting others.
#   - mkhybrid's -V (Volume ID) is capped at 32 characters -- keep it
#     short if RELEASE/ARCH strings grow.

set -e
cd "$(dirname "$0")"

. ./config.sh
if [ -f ./config.local.sh ]; then
	. ./config.local.sh
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "build.sh: must run as root (needs vnconfig/mount/rdsetroot)" >&2
	exit 1
fi

if [ ! -f ./install.conf ]; then
	echo "install.conf not found. Copy install.conf.example to" >&2
	echo "install.conf and edit it for your target system." >&2
	exit 1
fi

: "${RELEASE:?set RELEASE, e.g. 7.9}"
: "${RELEASE_SHORT:?set RELEASE_SHORT, e.g. 79}"
: "${ARCH:?set ARCH, e.g. amd64}"
: "${MIRROR:?set MIRROR, e.g. https://cdn.openbsd.org/pub/OpenBSD}"
: "${BUILD_DIR:?set BUILD_DIR, e.g. ./build}"
: "${OUT_DIR:?set OUT_DIR, e.g. ./out}"

REPO_DIR="$(pwd)"
WORK="${BUILD_DIR}/work"
SRC="${MIRROR}/${RELEASE}/${ARCH}"
CDDIR="${WORK}/cd-dir"
SETDIR="${CDDIR}/${RELEASE}/${ARCH}"
SITEDIR="${REPO_DIR}/site"

echo "==> Cleaning up any leftovers from a previous, interrupted run"
umount "${WORK}/rd-mnt" 2>/dev/null || true
umount "${WORK}/iso-mnt" 2>/dev/null || true
vnconfig -u vnd1 2>/dev/null || true
rm -rf "${WORK}"
mkdir -p "${CDDIR}" "${OUT_DIR}"

echo "==> Fetching official install media for ${RELEASE}/${ARCH}"
if [ -f "${BUILD_DIR}/install${RELEASE_SHORT}.iso" ]; then
    cp -v ${BUILD_DIR}/install${RELEASE_SHORT}.iso "${WORK}/install.iso"
else
	ftp -o "${BUILD_DIR}/install${RELEASE_SHORT}.iso" "${SRC}/install${RELEASE_SHORT}.iso"
	cp -v ${BUILD_DIR}/install${RELEASE_SHORT}.iso "${WORK}/install.iso"
fi

echo "==> Extracting install.iso"
vnconfig vnd1 "${WORK}/install.iso"
mkdir -p "${WORK}/iso-mnt"
mount -t cd9660 -o ro /dev/vnd1c "${WORK}/iso-mnt"
( cd "${WORK}/iso-mnt" && pax -rw -pe . "${CDDIR}/" )
umount "${WORK}/iso-mnt"
vnconfig -u vnd1

echo "==> Building custom site set from ${SITEDIR}"
SITETGZ="site${RELEASE_SHORT}.tgz"
if [ -f "${SITEDIR}/install.site" ]; then
	chmod +x "${SITEDIR}/install.site"
fi
( cd "${SITEDIR}" && tar -czphf "${SETDIR}/${SITETGZ}" . )

echo "==> Patching bsd.rd with embedded auto_install.conf"
BSDRD="${SETDIR}/bsd.rd"
cp "${REPO_DIR}/install.conf" "${WORK}/auto_install.conf"
# bsd.rd ships gzip-compressed on the install media (the bootloader
# inflates it at boot time); rdsetroot needs the raw ELF underneath.
gzip -dc "${BSDRD}" > "${WORK}/bsd.rd"
rdsetroot -x "${WORK}/bsd.rd" "${WORK}/ramdisk.fs"
vnconfig vnd1 "${WORK}/ramdisk.fs"
mkdir -p "${WORK}/rd-mnt"
mount /dev/vnd1a "${WORK}/rd-mnt"
cp "${WORK}/auto_install.conf" "${WORK}/rd-mnt/auto_install.conf"
umount "${WORK}/rd-mnt"
vnconfig -u vnd1
rdsetroot "${WORK}/bsd.rd" "${WORK}/ramdisk.fs"
gzip -9c "${WORK}/bsd.rd" > "${BSDRD}"

echo "==> Refreshing SHA256 for the set directory"
( cd "${SETDIR}" && sha256 -- *.tgz bsd bsd.mp bsd.rd > SHA256 )
rm -f "${SETDIR}/SHA256.sig"

echo "==> Repacking ISO with mkhybrid"
mkhybrid -a -R -T -L -l -d -D -N \
	-o "${OUT_DIR}/install${RELEASE_SHORT}-custom.iso" \
	-A "OpenBSD ${RELEASE} ${ARCH} Custom Install CD" \
	-V "OpenBSD/${ARCH} ${RELEASE} Custom" \
	-b "${RELEASE}/${ARCH}/cdbr" -c "${RELEASE}/${ARCH}/boot.catalog" \
	-e "${RELEASE}/${ARCH}/eficdboot" \
	"${CDDIR}"

echo "==> Done: ${OUT_DIR}/install${RELEASE_SHORT}-custom.iso"
