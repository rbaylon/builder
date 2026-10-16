#!/bin/sh
# Builds a self-contained OpenBSD install ISO carrying a custom site
# set -- NOT an autoinstall/unattended image. This boots to the
# standard interactive installer; the custom site${RELEASE_SHORT}.tgz
# set shows up *pre-selected* ("[X]") on the set-picker screen (see
# step 4 below) -- still a normal, de-selectable checkbox, just
# checked by default instead of requiring the installer to type
# "+site${RELEASE_SHORT}.tgz" by hand. install.site runs automatically
# once the set is selected and extracted (install.site(5)), same as
# any other site set.
#
# Previously this also embedded an autoinstall response file and
# patched bsd.rd's /.profile for an unattended countdown + a
# media-removal prompt before reboot; that's been removed entirely
# (see git history to bring it back). install.conf/install.conf.usb
# and their .example templates are unused leftovers from that and can
# be deleted if autoinstall isn't coming back. The remaining
# install.sub patch (step 4) is new and unrelated to that -- it only
# changes the set-picker's default selection, not installer behavior
# otherwise.
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
#   4. bsd.rd ships gzip-compressed on the install media (the
#      bootloader inflates it at boot time); gunzip it, extract its
#      ramdisk image with rdsetroot -x, mount it, and sed-patch
#      install.sub: append "site$VERSION.tgz" (expands at install time
#      to exactly our site set's filename) onto both of its
#      DEFAULTSETS definitions (uniprocessor and SMP/bsd.mp) --
#      confirmed directly against a real bsd.rd that this is what
#      controls the set-picker's starting "[X]"/"[ ]" state; a site
#      set is already *offered* ($ALLSETS always includes it) but never
#      pre-selected otherwise. Hard-fails if it doesn't find exactly 2
#      DEFAULTSETS= lines before patching, or exactly 2 patched ones
#      after, rather than silently shipping unpatched. Unmount, write
#      the ramdisk back with rdsetroot, re-gzip it back to bsd.rd.
#   5. Regenerate SHA256 for that set directory, after bsd.rd is
#      patched (unsigned -- there's no signify key for this custom
#      build, so the installer will ask "Directory does not contain
#      SHA256.sig. Continue without verification?" -- answer yes by
#      hand when prompted).
#   6. Repack everything with mkhybrid using the same flags OpenBSD's
#      own release build uses (distrib/${ARCH}/iso/Makefile).
#
# VALIDATED on a real OpenBSD 7.9/amd64 host (before the autoinstall
# removal above): the script ran end-to-end and produced a
# structurally correct, boot-tested ISO. Background:
#   - install.site(5)
#   - https://www.openbsd.org/faq/faq4.html
#   - https://github.com/openbsd/src/blob/master/distrib/amd64/iso/Makefile
#
# Known things to check on first run:
#   - vnd1 is assumed free; `vnconfig -l` if it's already in use.
#   - `mkhybrid` must be on PATH (it ships in base as part of
#     gnu/usr.sbin/mkhybrid); if missing, build it from src.git.
#   - rdsetroot has a fixed reserved-space budget inside bsd.rd
#     (`rdsetroot -s bsd.rd`); the DEFAULTSETS patch only adds ~15
#     bytes per line, so this is extremely unlikely to matter.
#   - EFI boot (-e eficdboot) only applies on arches that ship it
#     (amd64/arm64); adjust the mkhybrid line if targeting others.
#   - mkhybrid's -V (Volume ID) is capped at 32 characters -- keep it
#     short if RELEASE/ARCH strings grow.
#   - The install.sub DEFAULTSETS patch (step 4)'s precondition check
#     originally just matched any line starting with "DEFAULTSETS=".
#     A real build_usb.sh run (same install.sub) hit "expected exactly
#     2, found 3": install.sub also has a
#     `DEFAULTSETS=$(rmel $_f $DEFAULTSETS)` reassignment (set-picker
#     toggle logic) that starts the same way but isn't one of the two
#     initial definitions being targeted. Fixed by requiring the line
#     to *also* end with the literal `$SETS"` the substitution actually
#     targets -- re-tested against a synthetic file containing all 4
#     real DEFAULTSETS-related lines (the two real targets, the `rmel`
#     reassignment, and a third `$UPGRADE_BSDRD && DEFAULTSETS=` form)
#     to confirm exactly 2 match now.

set -e
BUILD_DIR=`pwd`
cd $BUILD_DIR

su - admin -c "sh ${BUILD_DIR}/buildapps.sh $BUILD_DIR"

. ./config.sh
if [ -f ./config.local.sh ]; then
	. ./config.local.sh
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "build.sh: must run as root (needs vnconfig/mount)" >&2
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
if [ ! -f "${BUILD_DIR}/install${RELEASE_SHORT}.iso" ]; then
	ftp -o "${BUILD_DIR}/install${RELEASE_SHORT}.iso" "${SRC}/install${RELEASE_SHORT}.iso"
fi
# Hardlink rather than copy -- WORK is always a subdirectory of
# BUILD_DIR (same filesystem), so this is instant and, unlike cp,
# doesn't temporarily double the ~800MB image on disk.
ln -f "${BUILD_DIR}/install${RELEASE_SHORT}.iso" "${WORK}/install.iso"

echo "==> Extracting install.iso"
vnconfig vnd1 "${WORK}/install.iso"
mkdir -p "${WORK}/iso-mnt"
mount -t cd9660 -o ro /dev/vnd1c "${WORK}/iso-mnt"
( cd "${WORK}/iso-mnt" && pax -rw -pe . "${CDDIR}/" )
umount "${WORK}/iso-mnt"
vnconfig -u vnd1
# Done with the raw ISO now that its contents are extracted; drop the
# WORK-side link (the BUILD_DIR cache copy is untouched, since the
# other hardlink still holds its blocks) to leave headroom for the
# repacked ISO later.
rm -f "${WORK}/install.iso"
VERSION_NUM="$(sh "${REPO_DIR}/version.sh" show)"
echo $VERSION_NUM > ${SITEDIR}/usr/local/arkgate/RELEASE
echo "==> Building custom site set from ${SITEDIR}"
SITETGZ="site${RELEASE_SHORT}.tgz"
if [ -f "${SITEDIR}/install.site" ]; then
	chmod +x "${SITEDIR}/install.site"
fi
( cd "${SITEDIR}" && tar -czphf "${SETDIR}/${SITETGZ}" . )

echo "==> Patching install.sub so the custom site set is pre-selected by default"
# Confirmed directly against a real bsd.rd: the installer's set-picker
# only pre-checks ("[X]") entries in install.sub's $DEFAULTSETS -- a
# site set is already *offered* (it's in $ALLSETS unconditionally) but
# never pre-selected. This appends "site$VERSION.tgz" (expands at
# install time to exactly our site${RELEASE_SHORT}.tgz filename) onto
# both of install.sub's DEFAULTSETS definitions (uniprocessor and
# SMP/bsd.mp), mirroring how $ALLSETS already includes it. The
# installer still shows it as a normal, de-selectable checkbox -- this
# only changes its starting state.
BSDRD="${SETDIR}/bsd.rd"
gzip -dc "${BSDRD}" > "${WORK}/bsd.rd"
rdsetroot -x "${WORK}/bsd.rd" "${WORK}/ramdisk.fs"
vnconfig vnd1 "${WORK}/ramdisk.fs"
mkdir -p "${WORK}/rd-mnt"
mount /dev/vnd1a "${WORK}/rd-mnt"

RDSUB="${WORK}/rd-mnt/install.sub"
[ -f "${RDSUB}" ] || {
	echo "build.sh: ${RDSUB} not found -- can't patch install.sub" >&2
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
	echo "build.sh: expected exactly 2 DEFAULTSETS=...\$SETS\" lines in install.sub, found ${d_count}." >&2
	echo "build.sh: this OpenBSD release's install.sub wording has likely drifted --" >&2
	echo "build.sh: update the sed pattern in build.sh to match it. Aborting rather" >&2
	echo "build.sh: than silently shipping without the site set pre-selected." >&2
	exit 1
fi
sed '/^[[:blank:]]*DEFAULTSETS=.*\$SETS"$/s/\$SETS"$/$SETS site$VERSION.tgz"/' "${RDSUB}" > "${RDSUB}.new"
new_count=$(grep -cE '^[[:blank:]]*DEFAULTSETS=.*site\$VERSION\.tgz"$' "${RDSUB}.new")
if [ "${new_count}" -ne 2 ]; then
	echo "build.sh: install.sub patch did not apply as expected -- aborting" >&2
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
vnconfig -u vnd1
rdsetroot "${WORK}/bsd.rd" "${WORK}/ramdisk.fs"
gzip -9c "${WORK}/bsd.rd" > "${BSDRD}"

echo "==> Refreshing SHA256 for the set directory"
( cd "${SETDIR}" && sha256 -- *.tgz bsd bsd.mp bsd.rd > SHA256 )
rm -f "${SETDIR}/SHA256.sig"

echo "==> Repacking ISO with mkhybrid"
now=`date '+%Y%m%d%H%M'`
OUTISO="${OUT_DIR}/specz-os-${RELEASE_SHORT}-v${VERSION_NUM}-${now}.iso"
mkhybrid -a -R -T -L -l -d -D -N \
	-o "${OUTISO}" \
	-A "OpenBSD ${RELEASE} ${ARCH} Custom Install CD" \
	-V "OpenBSD/${ARCH} ${RELEASE} Custom" \
	-b "${RELEASE}/${ARCH}/cdbr" -c "${RELEASE}/${ARCH}/boot.catalog" \
	-e "${RELEASE}/${ARCH}/eficdboot" \
	"${CDDIR}"

sh "${REPO_DIR}/version.sh" bump >/dev/null
echo "==> Done: ${OUTISO}"
