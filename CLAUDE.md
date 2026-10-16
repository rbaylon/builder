# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Builds a custom, self-contained OpenBSD install image carrying your
own `siteXX.tgz` file set (arbitrary files/scripts overlaid onto the
target root filesystem, plus an optional `install.site` post-install
hook). Two scripts produce two artifact types from the same `site/`:
`build.sh` makes an ISO, `build_usb.sh` makes a raw USB disk image
(for `dd`'ing onto a flash drive).

**Not autoinstall/unattended.** Both images boot to OpenBSD's standard
interactive installer -- hostname, passwords, disk layout, etc. are
still all typed in by hand. This project used to also embed an
autoinstall response file and patch `bsd.rd` for unattended installs --
that was removed entirely (see git history, commit around "not use
auto install at all", to resurrect it). `install.conf`,
`install.conf.usb`, and their `.example` templates are unused
leftovers from that removed feature; delete them if autoinstall isn't
coming back.

**The custom site set IS pre-selected**, though: both scripts patch
`install.sub` so `site${RELEASE_SHORT}.tgz` shows up checked (`[X]`)
by default on the installer's set-picker screen, instead of requiring
`+site${RELEASE_SHORT}.tgz` typed by hand -- see "The DEFAULTSETS
patch" below for the mechanism. It's still a normal, de-selectable
checkbox; this only changes its starting state.

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
doas ./build.sh        # build an ISO, written to out/
doas ./build_usb.sh    # build a USB image, written to out/
```

No setup beyond having `site/` the way you want it -- there's no
`install.conf` to copy/edit anymore. There is no lint/test suite --
correctness is verified by booting the resulting ISO/image in a VM and
confirming it installs with the custom site set selectable.

## Architecture / data flow

```
site/                 -> tar'd as-is into site${RELEASE_SHORT}.tgz
                          (root-relative: site/etc/foo -> /etc/foo on target)
site/install.site      -> if present & executable, run chroot()'d into the
                          target after the site set is selected and
                          extracted during a normal interactive install
                          (install.site(5))
```

`build.sh` does, in order, all on the local OpenBSD host:
1. Fetch the official `install${RELEASE_SHORT}.iso` for
   `RELEASE`/`ARCH` from `MIRROR`.
2. Mount it (`vnconfig` + `mount -t cd9660`) and copy its contents out
   with `pax`.
3. Tar `site/` into `site${RELEASE_SHORT}.tgz`, dropped next to the
   standard sets in `<RELEASE>/<ARCH>/` on the extracted tree (the
   ISO's on-disc directory uses the full release string, e.g.
   `7.9/amd64`, not the short form used for filenames like
   `install79.iso`). Before this, `VERSION` (via `version.sh show`) is
   written into `site/usr/local/arkgate/RELEASE`, so the installed
   system carries its own build version.
4. **The DEFAULTSETS patch.** `bsd.rd` ships gzip-compressed on the
   install media; gunzip it, extract its ramdisk image with
   `rdsetroot -x`, mount it, and sed-patch `/install.sub`. Confirmed
   directly against a real `bsd.rd`: the set-picker screen
   (`select_sets()`) only pre-checks (`[X]`) entries already in
   `install.sub`'s `$DEFAULTSETS` shell variable; a site set is always
   *offered* (`$ALLSETS` unconditionally includes
   `site$VERSION.tgz`, where `$VERSION` is install.sub's own runtime
   variable for the release, e.g. `79`) but is never pre-selected on
   its own. The patch appends literal text `site$VERSION.tgz` onto
   both of `install.sub`'s `DEFAULTSETS=` definitions (uniprocessor
   and SMP/`bsd.mp` -- there are two, one inside an `if ((NCPU > 1))`
   block and tab-indented) so it matches `$ALLSETS`. Hard-fails if it
   doesn't find exactly 2 `DEFAULTSETS=` lines before patching, or
   exactly 2 correctly-patched ones after. Unmount, write the ramdisk
   back with `rdsetroot`, re-gzip it back to `bsd.rd`.
5. Regenerate `SHA256` for that set directory, after `bsd.rd` is
   patched (unsigned -- there's no `signify` key for this custom
   build, so the installer will ask "Directory does not contain
   SHA256.sig. Continue without verification?" -- a human answers that
   by hand).
6. Repack everything with `mkhybrid`, using the same flags as
   OpenBSD's own `distrib/${ARCH}/iso/Makefile`. The output is named
   `specz-os-${RELEASE_SHORT}-v<VERSION>-<timestamp>.iso`.
7. After mkhybrid succeeds, `version.sh bump` advances `VERSION`
   (default patch: 1.0.0 -> 1.0.1). `VERSION` holds the version the
   *next* build will get, so the first build is v1.0.0. A failed build
   doesn't bump, so its version number is reused on retry. Use
   `sh version.sh bump minor|major` by hand to change the other parts.

Config layering: `config.sh` (committed defaults: release/arch/mirror/
build & output dirs) is sourced first, then `config.local.sh`
(gitignored, optional) overrides it if present.

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
- `bsd.rd` exists in **two places** on the image, confirmed by an
  actual build run: `/bsd.rd` at the FS root and
  `/${RELEASE}/${ARCH}/bsd.rd` (mirrors the ISO's sets directory). The
  `RELEASE`/`ARCH` copy's directory is located with `find` since
  that's where `site.tgz`/`SHA256` go -- the same directory the
  standard `*.tgz`/`SHA256`/`index.txt` already live in. **Both**
  copies get the DEFAULTSETS patch (see `build.sh`'s step 4) in a
  loop, rather than betting on which one actually boots -- they're the
  same upstream file, so patching both is harmless. Two `vnd` units
  are needed concurrently for this (`vnd1` for the outer FFS
  partition, `vnd2` for the inner ramdisk-within-`bsd.rd`), since the
  outer mount has to stay up for the whole script.

## Key references

- [OpenBSD FAQ 4](https://www.openbsd.org/faq/faq4.html) -- `siteXX.tgz`
  / `install.site` semantics.
- [install.site(5)](https://man.openbsd.org/install.site.5)
- [distrib/amd64/iso/Makefile](https://github.com/openbsd/src/blob/master/distrib/amd64/iso/Makefile)
  -- the official `mkhybrid` invocation this project's repack step mirrors.
- [tbaumgard/openbsd-custom-image](https://github.com/tbaumgard/openbsd-custom-image)
  -- prior art this project started from (that project does autoinstall;
  this one deliberately doesn't anymore).

## Known gaps / things to verify before trusting a build

- `build.sh`'s site-set/SHA256/mkhybrid pipeline was validated
  end-to-end (including a real boot test) **before** the autoinstall
  removal -- those parts (fetch, extract, tar site/, refresh SHA256,
  repack) are unchanged by the removal, but haven't been re-run as the
  current script. Known-good details from that run: the on-disc set
  directory uses the full release string (`7.9/amd64`), not
  `RELEASE_SHORT` (`79/amd64`); `pax -rw` with an absolute source path
  embeds the full path into the destination -- must `cd` into the
  source dir first; `mkhybrid -V` (ISO9660 Volume ID) is capped at 32
  characters; and a fresh `${BUILD_DIR}` needs its leftover
  mounts/`vnd1` cleared before `rm -rf`, in case a previous run was
  interrupted mid-mount.
- **The DEFAULTSETS patch's precondition check was too loose, caught by
  a real `build_usb.sh` run** (not just synthetic testing): it failed
  with "expected exactly 2 DEFAULTSETS= lines, found 3". The anchor
  `^[[:blank:]]*DEFAULTSETS=` matched any line starting with that text
  -- including `DEFAULTSETS=$(rmel $_f $DEFAULTSETS)`, a reassignment
  inside the set-picker's toggle logic, not one of the two initial
  definitions being targeted. Fixed by requiring the matched line to
  *also* end with the literal `$SETS"` the substitution actually
  targets (`^[[:blank:]]*DEFAULTSETS=.*\$SETS"$`), applied to both the
  precondition count and the sed address itself. Re-verified against a
  synthetic file containing all 4 real DEFAULTSETS-related lines (the
  two real targets, the `rmel` reassignment, and a third
  `$UPGRADE_BSDRD && DEFAULTSETS=` form) -- exactly 2 match now. What's
  still NOT validated: a full run past this point (both scripts), and
  booting a result to confirm the site set really shows `[X]` on the
  set-picker screen.
- `build_usb.sh` has been run far enough on a real OpenBSD host to
  confirm `install79.img`'s partition/file layout and to hit (and fix)
  the DEFAULTSETS bug above. Not yet validated: a full run past the
  patch loop -- SHA256 regen, finalizing the image -- and booting the
  resulting `.img` (or a `dd`'d USB stick) to confirm it works.
