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
#   5. While the ramdisk is mounted, also patch two of its scripts with
#      sed, anchored on literal strings confirmed against a real
#      install79.iso's bsd.rd for 7.9/amd64 (downloaded and inspected
#      directly -- see "Known things to check" below for how):
#        - /.profile: when /auto_install.conf is present (our case) or
#          the box netbooted, .profile prints "Starting non-interactive
#          mode in ${TIMEOUT_PERIOD_SEC} seconds...", starts a
#          background `sleep $TIMEOUT_PERIOD_SEC && kill $$` watchdog,
#          and the "(I)nstall, (U)pgrade, (A)utoinstall or (S)hell?"
#          read defaults to (A) once that watchdog fires.
#          TIMEOUT_PERIOD_SEC=5 is changed to 1 here. (install.sub
#          itself has no such countdown -- the wait happens entirely in
#          .profile, before install.sub is ever reached.)
#        - /install.sub: a pause-or-read prompt is inserted to remove
#          the install media right before do_autoinstall()'s `exec
#          reboot`, since unattended autoinstall otherwise reboots
#          straight back into the same CD with zero chance to pull it.
#      Both patches hard-fail the build if their anchors don't match
#      exactly once, so a future OpenBSD release that reworded either
#      script can't silently ship without this behavior.
#   6. Regenerate SHA256 for that set directory, after bsd.rd is
#      patched (unsigned -- there's no signify key for this custom
#      build, so install.conf must answer "yes" to the resulting
#      "continue without verification?" prompt).
#   7. Repack everything with mkhybrid using the same flags OpenBSD's
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
#   - The .profile/install.sub sed patches (step 5) have their anchor
#     strings confirmed byte-exact against the real target release:
#     `curl`'d install79.iso's bsd.rd directly from the mirror,
#     `gzip -dc`'d it (no rdsetroot/vnconfig needed just to read text --
#     the ramdisk's raw FFS blocks sit undecoded but still grep-able
#     inside the decompressed ELF), and grepped the result. The actual
#     mount-and-sed-in-place mechanics (this script's real code path)
#     are still unvalidated on a real OpenBSD host -- if RELEASE/ARCH
#     changes, re-run that same curl+gzip+grep check against the new
#     bsd.rd before trusting the anchors still match.

set -e
BUILD_DIR=`pwd`
cd $BUILD_DIR

su - admin -c "sh ${BUILD_DIR}/buildapps.sh $BUILD_DIR"

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

echo "==> Patching .profile's menu countdown (TIMEOUT_PERIOD_SEC 5 -> 1)"
# The real autoinstall countdown lives in the ramdisk's /.profile, not
# install.sub: when /auto_install.conf is present (our case) or the
# box netbooted, .profile prints "Starting non-interactive mode in
# ${TIMEOUT_PERIOD_SEC} seconds...", starts a background `sleep
# $TIMEOUT_PERIOD_SEC && kill $$` watchdog, and the
# "(I)nstall, (U)pgrade, (A)utoinstall or (S)hell?" read defaults to
# (A) when that watchdog fires. TIMEOUT_PERIOD_SEC=5 is the "5 seconds"
# being reduced here.
RDPROFILE="${WORK}/rd-mnt/.profile"
[ -f "${RDPROFILE}" ] || {
	echo "build.sh: ${RDPROFILE} not found -- can't patch .profile" >&2
	exit 1
}
t_count=$(grep -c '^TIMEOUT_PERIOD_SEC=5$' "${RDPROFILE}")
if [ "${t_count}" -ne 1 ]; then
	echo "build.sh: .profile's 'TIMEOUT_PERIOD_SEC=5' not found exactly once (got ${t_count})." >&2
	echo "build.sh: this OpenBSD release's .profile has likely changed -- update the sed" >&2
	echo "build.sh: pattern in build.sh. Aborting rather than silently keeping the 5s wait." >&2
	exit 1
fi
sed 's/^TIMEOUT_PERIOD_SEC=5$/TIMEOUT_PERIOD_SEC=1/' "${RDPROFILE}" > "${RDPROFILE}.new"
grep -q '^TIMEOUT_PERIOD_SEC=1$' "${RDPROFILE}.new" || {
	echo "build.sh: .profile patch did not apply as expected -- aborting" >&2
	rm -f "${RDPROFILE}.new"
	exit 1
}
mv "${RDPROFILE}.new" "${RDPROFILE}"

echo "==> Patching install.sub with a media-removal prompt before reboot"
RDSUB="${WORK}/rd-mnt/install.sub"
[ -f "${RDSUB}" ] || {
	echo "build.sh: ${RDSUB} not found -- can't patch install.sub" >&2
	exit 1
}

# Anchor: the prep_root_mail call site for the autoinstall log, right
# before do_autoinstall()'s `exec reboot`. Matched on the /tmp/ai/ai
# path (escaped) so it can't match the prep_root_mail() definition
# itself, or the unrelated prep_root_mail call in the interactive
# install/upgrade path (which logs to /tmp/i/$MODE.resp, not
# /tmp/ai/ai.log).
a_count=$(grep -c 'prep_root_mail /tmp/ai/ai' "${RDSUB}")
if [ "${a_count}" -ne 1 ]; then
	echo "build.sh: install.sub anchor not found exactly once (got ${a_count})." >&2
	echo "build.sh: this OpenBSD release's install.sub wording has likely drifted --" >&2
	echo "build.sh: update the sed pattern in build.sh to match it. Aborting rather" >&2
	echo "build.sh: than silently shipping an ISO without the media-removal prompt." >&2
	exit 1
fi

sed '
/prep_root_mail \/tmp\/ai\/ai/a\
echo\
echo "Autoinstall finished. Remove the installation media, then press ENTER/RETURN to reboot."\
if command -v pause >/dev/null 2>&1; then\
	pause\
else\
	read _removed\
fi
' "${RDSUB}" > "${RDSUB}.new"

grep -q 'Autoinstall finished. Remove the installation media' "${RDSUB}.new" || {
	echo "build.sh: install.sub patch did not apply as expected -- aborting" >&2
	rm -f "${RDSUB}.new"
	exit 1
}
mv "${RDSUB}.new" "${RDSUB}"

umount "${WORK}/rd-mnt"
vnconfig -u vnd1
rdsetroot "${WORK}/bsd.rd" "${WORK}/ramdisk.fs"
gzip -9c "${WORK}/bsd.rd" > "${BSDRD}"

echo "==> Refreshing SHA256 for the set directory"
( cd "${SETDIR}" && sha256 -- *.tgz bsd bsd.mp bsd.rd > SHA256 )
rm -f "${SETDIR}/SHA256.sig"

echo "==> Repacking ISO with mkhybrid"
now=`date '+%Y%m%d%H%M'`
VERSION_NUM="$(sh "${REPO_DIR}/version.sh" show)"
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
