# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Builds a custom, self-contained OpenBSD install image that
autoinstalls unattended: a custom `siteXX.tgz` file set (arbitrary
files/scripts overlaid onto the target root filesystem, plus an
optional `install.site` post-install hook) and an autoinstall response
file, both embedded directly in the image so no network is needed at
boot. Two scripts produce two artifact types from the same `site/`:
`build.sh` makes an ISO (for CD/virtual-media boot), `build_usb.sh`
makes a raw USB disk image (for `dd`'ing onto a flash drive). They
share `config.sh`/`site/`/`version.sh` but need separate response
files (`install.conf` vs `install.conf.usb`) -- see "build_usb.sh" below
for why.

Default target is OpenBSD 7.9 / amd64, controlled by `config.sh`.

## Hard constraint: build must run on OpenBSD

The actual image remastering needs native OpenBSD tools with no
Windows/Linux equivalent: `rdsetroot(8)` (patches the ramdisk kernel
`bsd.rd`), `vnconfig(8)` + `mount` (to edit filesystem images), and
`mkhybrid` (rebuilds the hybrid BIOS+EFI bootable ISO; `build_usb.sh`
doesn't need it -- see below). There is no cross-build path from other
OSes.

Both `build.sh` and `build_usb.sh` are POSIX `/bin/sh` scripts that run
**directly on an OpenBSD host, as root** (e.g. via `doas ./build.sh`)
and do their entire fetch/patch/repack pipeline themselves -- there is
no separate remote driver or SSH hop.

Never try to run `rdsetroot`/`vnconfig`/`mkhybrid` on a non-OpenBSD
machine -- they don't exist there. Any change to the build logic
belongs in `build.sh`/`build_usb.sh`, and needs to be validated by
actually running it on an OpenBSD host, not just read for plausibility.

## Commands

```sh
# One-time setup
cp install.conf.example install.conf           # for build.sh (ISO)
cp install.conf.usb.example install.conf.usb   # for build_usb.sh (USB)
# edit both: hostname/ssh key/timezone, and the USB one's disk names

# Build an ISO (fetches the install ISO, embeds site/ + install.conf,
# repacks it, and writes the result to out/)
doas ./build.sh

# Build a USB image (fetches install.img, embeds site/ +
# install.conf.usb, edits it in place, and writes the result to out/)
doas ./build_usb.sh
```

There is no lint/test suite -- correctness is verified by booting the
resulting ISO/image in a VM and confirming autoinstall completes.

## Architecture / data flow

```
site/                 -> tar'd as-is into site${RELEASE_SHORT}.tgz
                          (root-relative: site/etc/foo -> /etc/foo on target)
site/install.site      -> if present & executable, run chroot()'d into the
                          target after all sets extract (install.site(5))
install.conf           -> answers to installer prompts (autoinstall(8)),
                          embedded into bsd.rd's ramdisk as /auto_install.conf
                          via rdsetroot, so (A)utoinstall needs no DHCP/HTTP
```

`build.sh` does, in order, all on the local OpenBSD host:
1. Fetch the official `install${RELEASE_SHORT}.iso` for
   `RELEASE`/`ARCH` from `MIRROR`.
2. Mount it (`vnconfig` + `mount -t cd9660`) and copy its contents out
   with `pax`.
3. Tar `site/` into `site${RELEASE_SHORT}.tgz`, dropped next to the
   standard sets in `<RELEASE>/<ARCH>/` on the extracted tree (the ISO's
   on-disc directory uses the full release string, e.g. `7.9/amd64`,
   not the short form used for filenames like `install79.iso`).
4. Regenerate `SHA256` for that set directory (unsigned -- there's no
   `signify` key for this custom build, so `install.conf` must answer
   "yes" to the resulting "continue without verification?" prompt).
5. `bsd.rd` ships gzip-compressed on the install media (the bootloader
   inflates it at boot); gunzip it, extract its ramdisk image with
   `rdsetroot -x`, mount it, drop in `install.conf` as
   `/auto_install.conf`, and while still mounted, sed-patch two of its
   scripts:
   - `/.profile`: this is where the *real* autoinstall countdown lives
     (not `install.sub`). When `/auto_install.conf` is present (our
     case) or the box netbooted, `.profile` prints "Starting
     non-interactive mode in `${TIMEOUT_PERIOD_SEC}` seconds...",
     starts a background `sleep $TIMEOUT_PERIOD_SEC && kill $$`
     watchdog, and the `(I)/(U)/(A)/(S)` menu `read` defaults to `(A)`
     once that watchdog fires. `build.sh` changes
     `TIMEOUT_PERIOD_SEC=5` to `=1`.
   - `/install.sub`: adds a pause-or-read (`command -v pause`, else
     `read`) prompt to remove the install media right before
     `do_autoinstall()`'s `exec reboot` -- stock install.sub reboots
     straight back into the same CD with no such prompt.

   Both anchors are confirmed byte-exact against the real
   `install79.iso`'s `bsd.rd` (downloaded and grepped directly -- see
   "Known gaps" below), and each must match exactly once or the build
   aborts rather than silently shipping without this behavior. Unmount,
   write the ramdisk back with `rdsetroot`, then re-gzip it back to
   `bsd.rd`. (`bsd`/`bsd.mp` are plain ELF, not compressed -- only
   `bsd.rd` needs this.) SHA256 is regenerated *after* this step, not
   before, since it must hash the final patched `bsd.rd`.
6. Repack everything with `mkhybrid`, using the same flags as
   OpenBSD's own `distrib/${ARCH}/iso/Makefile`. The output is named
   `specz-os-${RELEASE_SHORT}-v<VERSION>-<timestamp>.iso`.
7. After mkhybrid succeeds, `version.sh bump` advances `VERSION`
   (default patch: 1.0.0 -> 1.0.1). `VERSION` holds the version the
   *next* ISO will get, so the first build is v1.0.0. A failed build
   doesn't bump, so its version number is reused on retry. Use
   `sh version.sh bump minor|major` by hand to change the other parts.

Config layering: `config.sh` (committed defaults: release/arch/mirror/
build & output dirs) is sourced first, then `config.local.sh`
(gitignored, optional) overrides it if present. `install.conf` is also
gitignored by default since it may end up carrying host-specific or
sensitive answers -- `install.conf.example` is the tracked template.

## build_usb.sh (USB image variant)

Same `site/`/`config.sh`/`version.sh`, different media and a genuinely
different on-disk layout, confirmed by downloading the real
`install79.img` and parsing its MBR + embedded OpenBSD disklabel
directly with Python (no OpenBSD host needed just to check structure):
it's two MBR partitions -- a small EFI System Partition (FAT,
disklabel `i`) and a large OpenBSD partition (MBR type `0xa6`,
disklabel `a`, fstype 7/BSDFFS) that *is* the whole install tree,
natively FFS instead of ISO9660. `vnconfig` reads that embedded
disklabel automatically, so `vnconfig vndN install79.img` exposes
`/dev/vndNa` directly -- no manual `fdisk`/`disklabel` step needed.

Consequences for the script, vs. `build.sh`:
- No extract-then-repack: the FFS partition is mounted read-write and
  edited *in place*; the edited working copy of `install79.img` IS the
  final artifact. There's no `mkhybrid` step.
- The pristine download is `cp`'d, not hardlinked, into the working
  dir before editing -- `build.sh` can safely hardlink its ISO because
  that mount is read-only; here the mount is read-write, so a hardlink
  would corrupt the cached download for future runs.
- Two `vnd` units are needed concurrently (`vnd1` for the outer FFS
  partition, `vnd2` for the inner ramdisk-within-`bsd.rd`), since the
  outer mount has to stay up for the whole script -- unlike `build.sh`,
  where the ISO mount is long gone before `bsd.rd` gets patched.
- `bsd.rd`'s location inside the FFS tree was *not* independently
  confirmed (only the partition-level layout above was actually
  parsed); the script locates it with `find` rather than a hardcoded
  path, and hard-fails if it doesn't find exactly one.
- The `/.profile` and `/install.sub` sed patches are identical to
  `build.sh`'s, since it's the same `bsd.rd` file either way.

**USB media is a disk to the installer, not a CD-ROM**, so
`install.conf`'s `Location of sets = cdrom` doesn't apply and would
stall autoinstall -- hence the separate `install.conf.usb`. Confirmed
against the real `install.sub` text (`install_sets()` ->
`install_disk()` -> `mount_mnt2()` -> `ask_which()`, whose prompt
format is literally `"Which $name $query?"`):
```
Location of sets = disk
Is the disk partition already mounted? = no
Which disk contains the install media? = sd1
Which sd1 partition has the install sets? = a
```
The partition answer (`a`) is fixed -- that's genuinely where the sets
live, per the disklabel parse above. The disk name (`sd1`) is NOT: it
depends on how many disks the *target* machine has, and can't be known
in advance. `install.conf.usb.example` documents this.

## Key references

- [autoinstall(8)](https://man.openbsd.org/autoinstall.8) -- response
  file format and discovery mechanism.
- [rdsetroot(8)](https://man.openbsd.org/rdsetroot) -- embedding files
  into the ramdisk kernel.
- [OpenBSD FAQ 4](https://www.openbsd.org/faq/faq4.html) -- `siteXX.tgz`
  / `install.site` semantics.
- [distrib/amd64/iso/Makefile](https://github.com/openbsd/src/blob/master/distrib/amd64/iso/Makefile)
  -- the official `mkhybrid` invocation this project's repack step mirrors.
- [tbaumgard/openbsd-custom-image](https://github.com/tbaumgard/openbsd-custom-image)
  -- prior art for this whole approach.

## Known gaps / things to verify before trusting a build

- `build.sh` has been run end-to-end on a real OpenBSD 7.9/amd64 host
  and produces a structurally correct ISO: `site79.tgz` is present
  next to the standard sets, `bsd.rd` is validly re-gzipped, `SHA256`
  matches the final (patched) files, and the embedded
  `auto_install.conf` is byte-identical to the source `install.conf`.
  Bugs found and fixed during that run: the on-disc set directory uses
  the full release string (`7.9/amd64`), not `RELEASE_SHORT`
  (`79/amd64`); `pax -rw` with an absolute source path embeds the full
  path into the destination -- must `cd` into the source dir first;
  `bsd.rd` is gzip-compressed on the media and must be gunzipped
  before `rdsetroot -x` and re-gzipped afterward; `mkhybrid -V` (ISO9660
  Volume ID) is capped at 32 characters; and a fresh `${BUILD_DIR}`
  needs its leftover mounts/`vnd1` cleared before `rm -rf`, in case a
  previous run was interrupted mid-mount.
- **Not yet validated:** actually booting the resulting ISO and
  confirming `(A)utoinstall` completes unattended. Exact installer
  prompt wording in `install.conf` can drift between OpenBSD releases
  -- if autoinstall stalls, it's waiting on a prompt whose text doesn't
  match; run the installer interactively once against the target
  release to get exact wording.
- The `.profile`/`install.sub` sed patch anchors (step 5) are confirmed
  byte-exact against the **real** target: `install79.iso`'s `bsd.rd`
  was downloaded straight from `cdn.openbsd.org` and `gzip -dc`'d --
  that alone is enough to grep its text, since the ramdisk's raw FFS
  blocks sit undecoded but still readable inside the decompressed ELF
  (no `rdsetroot`/`vnconfig`/OpenBSD host needed just to check this).
  That's how the real countdown was found in the first place: an
  earlier version of this patch targeted `install.sub` on the mistaken
  assumption that's where the "5 seconds" lived; it doesn't -- `.profile`
  owns the countdown, `install.sub` never had one. **Still not
  validated:** the actual `vnconfig`/`mount`/`sed`-in-place mechanics
  in `build.sh`, on a real OpenBSD host. If `RELEASE`/`ARCH` changes,
  re-run the same curl+gzip+grep check against the new `bsd.rd` before
  trusting the anchors still match -- `build.sh` hard-fails loudly if
  they don't, rather than silently skipping the patch.
- **`build_usb.sh` has not been run at all** -- its partition/disklabel
  facts come from directly parsing a real downloaded `install79.img`
  (see "build_usb.sh" above), but the script's actual
  `vnconfig`/`mount`/`sed`-in-place mechanics are untested on a real
  OpenBSD host, and the exact in-tree path to `bsd.rd` was never
  confirmed (mitigated with `find` + a hard-fail guard, not a known
  answer). Validate the same way `build.sh` was: run it, then boot the
  resulting `.img` (or a `dd`'d USB stick) in a VM.
