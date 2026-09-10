#!/bin/sh
# Runs ON THE OPENBSD BUILD HOST (as root). Rebuilds the official
# installXX.iso into a self-contained autoinstall image:
#
#   1. Fetch the official install ISO + SHA256 for RELEASE/ARCH.
#   2. Extract its contents.
#   3. Tar up site/ into site${RELEASE_SHORT}.tgz and drop it next to
#      the standard sets.
#   4. Patch bsd.rd (via rdsetroot) to carry install.conf as
#      /auto_install.conf, so booting and choosing (A)utoinstall needs
#      no network.
#   5. Repack everything with mkhybrid using the same flags OpenBSD's
#      own release build uses (distrib/${ARCH}/iso/Makefile).
#
# NOT YET VALIDATED end-to-end against a real build host in this
# session (no OpenBSD machine was available to test against). Treat
# this as a documented first draft based on:
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

: "${RELEASE:?set RELEASE, e.g. 7.9}"
: "${RELEASE_SHORT:?set RELEASE_SHORT, e.g. 79}"
: "${ARCH:?set ARCH, e.g. amd64}"
: "${MIRROR:?set MIRROR, e.g. https://cdn.openbsd.org/pub/OpenBSD}"
: "${BUILD_DIR:?set BUILD_DIR, e.g. /root/openbsd-builder}"

if [ "$(id -u)" -ne 0 ]; then
	echo "build-image.sh: must run as root (needs vnconfig/mount)" >&2
	exit 1
fi

WORK="${BUILD_DIR}/work"
SRC="${MIRROR}/${RELEASE}/${ARCH}"
CDDIR="${WORK}/cd-dir"
SETDIR="${CDDIR}/${RELEASE_SHORT}/${ARCH}"
OUT="${BUILD_DIR}/out"

rm -rf "${WORK}"
mkdir -p "${CDDIR}" "${OUT}"
cd "${WORK}"

echo "==> Fetching official install media for ${RELEASE}/${ARCH}"
ftp -o "${WORK}/install.iso" "${SRC}/install${RELEASE_SHORT}.iso"

echo "==> Extracting install.iso"
vnconfig vnd1 "${WORK}/install.iso"
mkdir -p "${WORK}/iso-mnt"
mount -t cd9660 -o ro /dev/vnd1c "${WORK}/iso-mnt"
pax -rw -pe "${WORK}/iso-mnt/." "${CDDIR}/"
umount "${WORK}/iso-mnt"
vnconfig -u vnd1

echo "==> Building custom site set from ${BUILD_DIR}/site"
SITEDIR="${BUILD_DIR}/site"
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
cp "${BUILD_DIR}/install.conf" "${WORK}/auto_install.conf"
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
	-o "${OUT}/install${RELEASE_SHORT}-custom.iso" \
	-A "OpenBSD ${RELEASE} ${ARCH} Custom Install CD" \
	-V "OpenBSD/${ARCH} ${RELEASE} Custom Install CD" \
	-b "${RELEASE_SHORT}/${ARCH}/cdbr" -c "${RELEASE_SHORT}/${ARCH}/boot.catalog" \
	-e "${RELEASE_SHORT}/${ARCH}/eficdboot" \
	"${CDDIR}"

echo "==> Done: ${OUT}/install${RELEASE_SHORT}-custom.iso"
