#!/bin/sh
# Builds a self-contained, autoinstall-capable OpenBSD USB install
# image (install${RELEASE_SHORT}.img) -- the USB/disk counterpart to
# build.sh's ISO. Run as root on an OpenBSD host, same as build.sh.
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
#   - bsd.rd on this image is the exact same gzip-compressed file as
#     on the ISO (same upstream release artifact), so the
#     .profile/install.sub sed patches from build.sh apply unchanged.
#
# File-level layout, CONFIRMED by an actual build run (not just the
# partition-table parse above): install79.img carries bsd.rd in TWO
# places -- /bsd.rd at the FS root (what the bootloader actually
# boots) and /${RELEASE}/${ARCH}/bsd.rd (mirrors the ISO's sets
# directory, otherwise inert). This script finds every bsd.rd with
# `find` and patches all of them identically rather than betting on
# which one boots -- see the inline comment where BSDRD_MATCHES is
# computed. The RELEASE/ARCH one is specifically picked out (by path)
# as the sets directory for site.tgz/SHA256.
#
# IMPORTANT difference from build.sh: USB media is a *disk* to the
# installer, not a CD-ROM, so install.conf's "Location of sets = cdrom"
# does not apply and would stall autoinstall. This script therefore
# requires its own install.conf.usb (see install.conf.usb.example)
# with "Location of sets = disk" and different follow-up questions.
# Confirmed against the real install.sub text (install_sets() ->
# install_disk() -> mount_mnt2() -> ask_which()): the partition answer
# is fixed at "a" (that really is where the sets live, per the
# disklabel parse above), but the disk device name (e.g. "sd1")
# depends on how many disks the *target* machine has and can't be
# known in advance -- see install.conf.usb.example.
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
#   4. Patch each bsd.rd found, exactly like build.sh does: gunzip,
#      rdsetroot -x, mount the inner ramdisk -- on a *second* vnd unit,
#      since the outer 'a' partition mount has to stay up throughout
#      this whole script, unlike build.sh where the ISO mount is long
#      gone by the time bsd.rd gets patched -- embed install.conf.usb
#      as /auto_install.conf, sed-patch /.profile (TIMEOUT_PERIOD_SEC
#      5->1) and /install.sub (media-removal pause before reboot),
#      unmount, rdsetroot the ramdisk back in, re-gzip straight back
#      onto that copy's bsd.rd.
#   5. Regenerate SHA256 in the RELEASE/ARCH sets directory.
#   6. Unmount/release both vnd units. The edited working copy of
#      install79.img *is* the final image now -- there's no repack
#      step like mkhybrid -- so it's just moved into OUT_DIR with a
#      versioned name.
#   7. On success, version.sh bump advances VERSION (the same counter
#      build.sh's ISO builds use -- one shared sequence across both
#      artifact types).
#
# UNVALIDATED: this script has not been run on a real OpenBSD host.
# The partition/disklabel facts above come from directly parsing the
# real downloaded install79.img; the actual vnconfig/mount/sed
# mechanics in this script are new and untested, the same caveat
# build.sh carried before its own first real run.

set -e
BUILD_DIR=`pwd`
cd $BUILD_DIR

su - admin -c "sh ${BUILD_DIR}/buildapps.sh $BUILD_DIR"

. ./config.sh
if [ -f ./config.local.sh ]; then
	. ./config.local.sh
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "build_usb.sh: must run as root (needs vnconfig/mount/rdsetroot)" >&2
	exit 1
fi

if [ ! -f ./install.conf.usb ]; then
	echo "install.conf.usb not found. Copy install.conf.usb.example to" >&2
	echo "install.conf.usb and edit it for your target system. It's" >&2
	echo "separate from install.conf because USB media needs different" >&2
	echo "'Location of sets' answers than the ISO does." >&2
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

# A real install79.img carries bsd.rd in TWO places (confirmed by an
# actual build: /bsd.rd at the FS root AND /${RELEASE}/${ARCH}/bsd.rd),
# not one -- root is what the bootloader actually boots (its
# hardcoded default path, with no /etc/boot.conf override needed; the
# bootloader binary's own embedded strings reference "bsd.rd" at the
# top level), while the RELEASE/ARCH copy just mirrors the ISO's sets
# directory layout and is otherwise inert. Rather than bet the whole
# build on which one actually boots, every bsd.rd found gets patched
# identically below -- they're the same upstream file, so patching
# more than the one that boots is harmless.
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

cp "${REPO_DIR}/install.conf.usb" "${WORK}/auto_install.conf"

# install.sub's patch as a sed script file rather than an inline
# literal: written once here, flush-left, so there's no risk of the
# `for` loop's indentation below leaking a stray leading tab onto the
# line that closes the quoted sed program (which would land as a bogus
# extra "command" right after the `a\` block's closing `fi`).
cat > "${WORK}/install_sub.sed" <<'SEDEOF'
/prep_root_mail \/tmp\/ai\/ai/a\
echo\
echo "Autoinstall finished. Remove the installation media, then press ENTER/RETURN to reboot."\
if command -v pause >/dev/null 2>&1; then\
	pause\
else\
	read _removed\
fi
SEDEOF

# Patch every bsd.rd copy found above. Using `set --`/`for` rather than
# `cmd | while read` deliberately: a pipeline's while-loop runs in a
# subshell in this shell, where `exit` would only kill the subshell and
# let the rest of the script carry on past a real failure.
set -- $(printf '%s\n' "${BSDRD_MATCHES}")
for BSDRD; do
	echo "==> Patching bsd.rd with embedded auto_install.conf: ${BSDRD}"
	# bsd.rd ships gzip-compressed on the install media (the bootloader
	# inflates it at boot time); rdsetroot needs the raw ELF underneath.
	gzip -dc "${BSDRD}" > "${WORK}/bsd.rd"
	rdsetroot -x "${WORK}/bsd.rd" "${WORK}/ramdisk.fs"
	vnconfig vnd2 "${WORK}/ramdisk.fs"
	mkdir -p "${WORK}/rd-mnt"
	mount /dev/vnd2a "${WORK}/rd-mnt"
	cp "${WORK}/auto_install.conf" "${WORK}/rd-mnt/auto_install.conf"

	echo "==> Patching .profile's menu countdown (TIMEOUT_PERIOD_SEC 5 -> 1)"
	# See build.sh for the full explanation: the real autoinstall
	# countdown lives in the ramdisk's /.profile, not install.sub.
	RDPROFILE="${WORK}/rd-mnt/.profile"
	[ -f "${RDPROFILE}" ] || {
		echo "build_usb.sh: ${RDPROFILE} not found -- can't patch .profile" >&2
		exit 1
	}
	t_count=$(grep -c '^TIMEOUT_PERIOD_SEC=5$' "${RDPROFILE}")
	if [ "${t_count}" -ne 1 ]; then
		echo "build_usb.sh: .profile's 'TIMEOUT_PERIOD_SEC=5' not found exactly once (got ${t_count})." >&2
		echo "build_usb.sh: this OpenBSD release's .profile has likely changed -- update the sed" >&2
		echo "build_usb.sh: pattern in build_usb.sh. Aborting rather than silently keeping the 5s wait." >&2
		exit 1
	fi
	sed 's/^TIMEOUT_PERIOD_SEC=5$/TIMEOUT_PERIOD_SEC=1/' "${RDPROFILE}" > "${RDPROFILE}.new"
	grep -q '^TIMEOUT_PERIOD_SEC=1$' "${RDPROFILE}.new" || {
		echo "build_usb.sh: .profile patch did not apply as expected -- aborting" >&2
		rm -f "${RDPROFILE}.new"
		exit 1
	}
	# cat into the existing file rather than `mv`-ing over it -- see the
	# install.sub patch below for why (confirmed by a real test boot of
	# build.sh's ISO).
	cat "${RDPROFILE}.new" > "${RDPROFILE}"
	rm -f "${RDPROFILE}.new"

	echo "==> Patching install.sub with a media-removal prompt before reboot"
	RDSUB="${WORK}/rd-mnt/install.sub"
	[ -f "${RDSUB}" ] || {
		echo "build_usb.sh: ${RDSUB} not found -- can't patch install.sub" >&2
		exit 1
	}
	a_count=$(grep -c 'prep_root_mail /tmp/ai/ai' "${RDSUB}")
	if [ "${a_count}" -ne 1 ]; then
		echo "build_usb.sh: install.sub anchor not found exactly once (got ${a_count})." >&2
		echo "build_usb.sh: this OpenBSD release's install.sub wording has likely drifted --" >&2
		echo "build_usb.sh: update the sed pattern in build_usb.sh to match it. Aborting rather" >&2
		echo "build_usb.sh: than silently shipping an image without the media-removal prompt." >&2
		exit 1
	fi

	sed -f "${WORK}/install_sub.sed" "${RDSUB}" > "${RDSUB}.new"

	grep -q 'Autoinstall finished. Remove the installation media' "${RDSUB}.new" || {
		echo "build_usb.sh: install.sub patch did not apply as expected -- aborting" >&2
		rm -f "${RDSUB}.new"
		exit 1
	}
	# cat into the existing file, NOT `mv` over it: install.sub needs to
	# stay executable (/autoinstall, /install, /upgrade are symlinks to
	# it), and `mv` would swap in a freshly-created file at default umask
	# permissions (no exec bit), breaking all three with "cannot execute:
	# Permission denied" at the boot menu -- confirmed by an actual test
	# boot of build.sh's ISO. cat preserves the original inode (and its
	# mode/owner), overwriting only its content.
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
