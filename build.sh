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
#      the standard sets.
#   4. Regenerate SHA256 for that set directory (unsigned -- install.conf
#      must answer "yes" to the resulting "continue without verification?"
#      prompt).
#   5. Patch bsd.rd (via rdsetroot) to carry install.conf as
#      /auto_install.conf, so booting and choosing (A)utoinstall needs
#      no network.
#   6. Repack everything with mkhybrid using the same flags OpenBSD's
#      own release build uses (distrib/${ARCH}/iso/Makefile).
#
# NOT YET VALIDATED end-to-end against a real OpenBSD host. Treat this
# as a documented first draft based on:
#   - autoinstall(8), rdsetroot(8), install.site(5)
#   - https://www.openbsd.org/faq/faq4.html
#   - https://github.com/openbsd/src/blob/master/distrib/amd64/iso/Makefile
#   - https://github.com/tbaumgard/openbsd-custom-image
# Before relying on it: run it, then boot the resulting ISO in a VM and
# confirm autoinstall actually fires and completes.
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
SETDIR="${CDDIR}/${RELEASE_SHORT}/${ARCH}"
SITEDIR="${REPO_DIR}/site"

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
pax -rw -pe "${WORK}/iso-mnt/." "${CDDIR}/"
umount "${WORK}/iso-mnt"
vnconfig -u vnd1

echo "==> Building custom site set from ${SITEDIR}"
SITETGZ="site${RELEASE_SHORT}.tgz"
if [ -f "${SITEDIR}/install.site" ]; then
	chmod +x "${SITEDIR}/install.site"
fi
( cd "${SITEDIR}" && tar -czphf "${SETDIR}/${SITETGZ}" . )

echo "==> Refreshing SHA256 for the set directory"
( cd "${SETDIR}" && sha256 -- *.tgz bsd bsd.mp bsd.rd > SHA256 )
rm -f "${SETDIR}/SHA256.sig"

echo "==> Patching bsd.rd with embedded auto_install.conf"
BSDRD="${SETDIR}/bsd.rd"
cp "${REPO_DIR}/install.conf" "${WORK}/auto_install.conf"
rdsetroot -x "${BSDRD}" "${WORK}/ramdisk.fs"
vnconfig vnd1 "${WORK}/ramdisk.fs"
mkdir -p "${WORK}/rd-mnt"
mount /dev/vnd1a "${WORK}/rd-mnt"
cp "${WORK}/auto_install.conf" "${WORK}/rd-mnt/auto_install.conf"
umount "${WORK}/rd-mnt"
vnconfig -u vnd1
rdsetroot "${BSDRD}" "${WORK}/ramdisk.fs"

echo "==> Repacking ISO with mkhybrid"
mkhybrid -a -R -T -L -l -d -D -N \
	-o "${OUT_DIR}/install${RELEASE_SHORT}-custom.iso" \
	-A "OpenBSD ${RELEASE} ${ARCH} Custom Install CD" \
	-V "OpenBSD/${ARCH} ${RELEASE} Custom Install CD" \
	-b "${RELEASE_SHORT}/${ARCH}/cdbr" -c "${RELEASE_SHORT}/${ARCH}/boot.catalog" \
	-e "${RELEASE_SHORT}/${ARCH}/eficdboot" \
	"${CDDIR}"

echo "==> Done: ${OUT_DIR}/install${RELEASE_SHORT}-custom.iso"
