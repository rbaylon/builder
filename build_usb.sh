#!/bin/sh
# Builds a self-contained OpenBSD USB install image
# (install${RELEASE_SHORT}.img) carrying a custom site set -- the
# USB/disk counterpart to build.sh's ISO. NOT an autoinstall/
# unattended image -- see build.sh's header for why that was removed.
# This boots to the standard interactive installer; the custom
# site${RELEASE_SHORT}.tgz set shows up *pre-selected* on the
# set-picker screen (see step 4 below and build.sh's header for the
# full explanation) -- still a normal, de-selectable checkbox, just
# checked by default. Run as root on an OpenBSD host, same as build.sh.
#
# Confirmed by downloading the real install79.img straight from the
# mirror and parsing it directly with plain Python struct code (MBR
# partition table, then the embedded OpenBSD disklabel) -- no OpenBSD
# host needed just to check this part:
#   - It's two MBR partitions: a small (960-sector) EFI System
#     Partition (FAT, disklabel letter 'i'), and a large OpenBSD
#     partition (MBR type 0xa6, disklabel letter 'a', fstype 7 =
#     BSDFFS) that IS the whole install tree -- same bsd.rd/*.tgz/
#     SHA256 content as the ISO, just stored as a native FFS
#     filesystem instead of ISO9660.
#   - vnconfig(8) reads that embedded disklabel automatically, so
#     `vnconfig vndN install79.img` exposes /dev/vndNa (the FFS data)
#     and /dev/vndNi (the ESP) directly -- no manual fdisk/disklabel
#     step needed, unlike building the image from scratch.
#
# File-level layout, CONFIRMED by an actual build run (not just the
# partition-table parse above): install79.img carries bsd.rd in TWO
# places -- /bsd.rd at the FS root and /${RELEASE}/${ARCH}/bsd.rd
# (mirrors the ISO's sets directory). The RELEASE/ARCH copy's
# directory is located (by path, via `find`) since that's where
# site.tgz/SHA256 go -- same directory the standard
# *.tgz/SHA256/index.txt already live in, matching the ISO's layout.
# Both copies get the DEFAULTSETS patch below (step 4) -- they're the
# same upstream bsd.rd file, so patching both is harmless and avoids
# betting on which one actually boots (see the comment above
# BSDRD_MATCHES below).
#
#   1. Fetch the official install${RELEASE_SHORT}.img for RELEASE/ARCH
#      from MIRROR, cached in BUILD_DIR. A real *copy* is made for
#      editing, not a hardlink: this image is modified in place
#      through its own mount below, so (unlike build.sh's ISO
#      hardlink trick, where the ISO is only ever read) a hardlink
#      here would corrupt the cached pristine download for future
#      runs.
#   2. vnconfig it and mount its 'a' partition (FFS) read-write.
#   3. find every bsd.rd on it (there are two -- see above); tar site/
#      into site${RELEASE_SHORT}.tgz next to the RELEASE/ARCH one.
#   4. Patch each bsd.rd found exactly like build.sh does: gunzip,
#      rdsetroot -x, mount the inner ramdisk -- on a *second* vnd unit,
#      since the outer 'a' partition mount has to stay up throughout
#      this whole script -- sed-patch install.sub's two DEFAULTSETS
#      definitions to pre-select the site set, unmount, rdsetroot the
#      ramdisk back in, re-gzip straight back onto that copy's bsd.rd.
#   5. Regenerate SHA256 in the RELEASE/ARCH sets directory.
#   6. Unmount/release both vnd units. The edited working copy of
#      install79.img *is* the final image now -- there's no repack
#      step like mkhybrid -- so it's just moved into OUT_DIR with a
#      versioned name.
#   7. On success, version.sh bump advances VERSION (the same counter
#      build.sh's ISO builds use -- one shared sequence across both
#      artifact types).
#
# Real-build history: a real run of this script (on the install79.img
# partition/file layout above -- that's how the bsd.rd-in-two-places
# fact was found) caught a real bug in the DEFAULTSETS patch's
# precondition check: it originally matched any line starting with
# "DEFAULTSETS=", but install.sub also has a
# `DEFAULTSETS=$(rmel $_f $DEFAULTSETS)` reassignment (set-picker
# toggle logic) that starts the same way but isn't one of the two
# initial definitions being targeted -- it failed with "expected
# exactly 2, found 3". Fixed by requiring the line to *also* end with
# the literal `$SETS"` the substitution actually targets. See build.sh's
# header for the full DEFAULTSETS patch explanation and how the fix was
# re-verified.
#
# UNVALIDATED past that point: a full run through the (now-fixed)
# patch loop, SHA256 regeneration, and finalizing the image, plus
# actually booting the result and confirming the site set shows
# pre-selected.

set -e
BUILD_DIR=`pwd`
cd $BUILD_DIR

su - admin -c "sh ${BUILD_DIR}/buildapps.sh $BUILD_DIR"

. ./config.sh
if [ -f ./config.local.sh ]; then
	. ./config.local.sh
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "build_usb.sh: must run as root (needs vnconfig/mount)" >&2
	exit 1
fi

: "${RELEASE:?set RELEASE, e.g. 7.9}"
: "${RELEASE_SHORT:?set RELEASE_SHORT, e.g. 79}"
: "${ARCH:?set ARCH, e.g. amd64}"
: "${MIRROR:?set MIRROR, e.g. https://cdn.openbsd.org/pub/OpenBSD}"
: "${BUILD_DIR:?set BUILD_DIR, e.g. ./build}"
: "${OUT_DIR:?set OUT_DIR, e.g. ./out}"

REPO_DIR="$(pwd)"
WORK="${BUILD_DIR}/work-usb"
SRC="${MIRROR}/${RELEASE}/${ARCH}"
SITEDIR="${REPO_DIR}/site"

echo "==> Cleaning up any leftovers from a previous, interrupted run"
umount "${WORK}/rd-mnt" 2>/dev/null || true
umount "${WORK}/fs-mnt" 2>/dev/null || true
vnconfig -u vnd2 2>/dev/null || true
vnconfig -u vnd1 2>/dev/null || true
rm -rf "${WORK}"
mkdir -p "${WORK}" "${OUT_DIR}"

echo "==> Fetching official USB install image for ${RELEASE}/${ARCH}"
if [ ! -f "${BUILD_DIR}/install${RELEASE_SHORT}.img" ]; then
	ftp -o "${BUILD_DIR}/install${RELEASE_SHORT}.img" "${SRC}/install${RELEASE_SHORT}.img"
fi
cp "${BUILD_DIR}/install${RELEASE_SHORT}.img" "${WORK}/install.img"

echo "==> Mounting the image's FFS partition"
vnconfig vnd1 "${WORK}/install.img"
mkdir -p "${WORK}/fs-mnt"
mount /dev/vnd1a "${WORK}/fs-mnt"

# Find bsd.rd (there are two copies -- see header) purely to locate
# the RELEASE/ARCH sets directory; neither copy is touched otherwise.
BSDRD_MATCHES=$(find "${WORK}/fs-mnt" -name bsd.rd 2>/dev/null)
BSDRD_COUNT=$(printf '%s\n' "${BSDRD_MATCHES}" | grep -c .)
if [ "${BSDRD_COUNT}" -lt 1 ]; then
	echo "build_usb.sh: no bsd.rd found anywhere under ${WORK}/fs-mnt" >&2
	exit 1
fi
echo "==> Found ${BSDRD_COUNT} bsd.rd cop$([ "${BSDRD_COUNT}" -eq 1 ] && echo y || echo ies):"
printf '%s\n' "${BSDRD_MATCHES}" | sed 's/^/    /'

# The sets directory (where site.tgz goes and SHA256 gets refreshed)
# is specifically the RELEASE/ARCH copy's directory, matching the
# ISO's layout -- that's where the standard *.tgz/SHA256/index.txt
# actually live, not the FS root.
SETDIR=$(printf '%s\n' "${BSDRD_MATCHES}" | grep -F "/${RELEASE}/${ARCH}/bsd.rd" | head -1)
if [ -z "${SETDIR}" ]; then
	echo "build_usb.sh: none of the bsd.rd copies found live under ${RELEASE}/${ARCH} --" >&2
	echo "build_usb.sh: can't identify the sets directory for site.tgz/SHA256. Found:" >&2
	printf '%s\n' "${BSDRD_MATCHES}" >&2
	exit 1
fi
SETDIR=$(dirname "${SETDIR}")

VERSION_NUM="$(sh "${REPO_DIR}/version.sh" show)"
mkdir -p "${SITEDIR}/usr/local/arkgate"
echo "${VERSION_NUM}" > "${SITEDIR}/usr/local/arkgate/RELEASE"

echo "==> Building custom site set from ${SITEDIR}"
SITETGZ="site${RELEASE_SHORT}.tgz"
if [ -f "${SITEDIR}/install.site" ]; then
	chmod +x "${SITEDIR}/install.site"
fi
( cd "${SITEDIR}" && tar -czphf "${SETDIR}/${SITETGZ}" . )

# Patch every bsd.rd copy found above so the custom site set is
# pre-selected by default on the installer's set-picker screen -- see
# build.sh's header for the full explanation of the DEFAULTSETS
# mechanism. Using `set --`/`for` rather than `cmd | while read`
# deliberately: a pipeline's while-loop runs in a subshell in this
# shell, where `exit` would only kill the subshell and let the rest of
# the script carry on past a real failure.
set -- $(printf '%s\n' "${BSDRD_MATCHES}")
for BSDRD; do
	echo "==> Patching install.sub in ${BSDRD}"
	gzip -dc "${BSDRD}" > "${WORK}/bsd.rd"
	rdsetroot -x "${WORK}/bsd.rd" "${WORK}/ramdisk.fs"
	vnconfig vnd2 "${WORK}/ramdisk.fs"
	mkdir -p "${WORK}/rd-mnt"
	mount /dev/vnd2a "${WORK}/rd-mnt"

	RDSUB="${WORK}/rd-mnt/install.sub"
	[ -f "${RDSUB}" ] || {
		echo "build_usb.sh: ${RDSUB} not found -- can't patch install.sub" >&2
		exit 1
	}
	# Match only lines that both start with DEFAULTSETS= *and* end with
	# the literal `$SETS"` our substitution below targets -- install.sub
	# also has a `DEFAULTSETS=$(rmel $_f $DEFAULTSETS)` reassignment
	# (set-picker toggle logic, confirmed against a real bsd.rd) that
	# starts with "DEFAULTSETS=" too but isn't one of the two initial
	# definitions we want; a looser prefix-only anchor miscounts it as a
	# 3rd match and aborts here even though the substitution itself would
	# have left it untouched (it doesn't end in `$SETS"`).
	d_count=$(grep -cE '^[[:blank:]]*DEFAULTSETS=.*\$SETS"$' "${RDSUB}")
	if [ "${d_count}" -ne 2 ]; then
		echo "build_usb.sh: expected exactly 2 DEFAULTSETS=...\$SETS\" lines in install.sub, found ${d_count}." >&2
		echo "build_usb.sh: this OpenBSD release's install.sub wording has likely drifted --" >&2
		echo "build_usb.sh: update the sed pattern in build_usb.sh to match it. Aborting rather" >&2
		echo "build_usb.sh: than silently shipping without the site set pre-selected." >&2
		exit 1
	fi
	sed '/^[[:blank:]]*DEFAULTSETS=.*\$SETS"$/s/\$SETS"$/$SETS site$VERSION.tgz"/' "${RDSUB}" > "${RDSUB}.new"
	new_count=$(grep -cE '^[[:blank:]]*DEFAULTSETS=.*site\$VERSION\.tgz"$' "${RDSUB}.new")
	if [ "${new_count}" -ne 2 ]; then
		echo "build_usb.sh: install.sub patch did not apply as expected -- aborting" >&2
		rm -f "${RDSUB}.new"
		exit 1
	fi
	# cat into the existing file, NOT `mv` over it: install.sub needs to
	# stay executable (/autoinstall, /install, /upgrade are symlinks to
	# it); `mv` would swap in a freshly-created file at default umask
	# permissions (no exec bit) -- a real bug caught by an earlier test
	# boot. cat preserves the original inode (and its mode/owner),
	# overwriting only its content.
	cat "${RDSUB}.new" > "${RDSUB}"
	rm -f "${RDSUB}.new"

	umount "${WORK}/rd-mnt"
	vnconfig -u vnd2
	rdsetroot "${WORK}/bsd.rd" "${WORK}/ramdisk.fs"
	gzip -9c "${WORK}/bsd.rd" > "${BSDRD}"
done

echo "==> Refreshing SHA256 for the set directory"
( cd "${SETDIR}" && sha256 -- *.tgz bsd bsd.mp bsd.rd > SHA256 )
rm -f "${SETDIR}/SHA256.sig"

umount "${WORK}/fs-mnt"
vnconfig -u vnd1

echo "==> Finalizing USB image"
now=`date '+%Y%m%d%H%M'`
OUTIMG="${OUT_DIR}/specz-os-${RELEASE_SHORT}-v${VERSION_NUM}-${now}.img"
mv "${WORK}/install.img" "${OUTIMG}"

sh "${REPO_DIR}/version.sh" bump >/dev/null
echo "==> Done: ${OUTIMG}"
echo "==> Write it to a USB stick with, e.g.: doas dd if=${OUTIMG} of=/dev/rsdXc bs=1m"
