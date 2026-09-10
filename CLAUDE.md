# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Builds a custom, self-contained OpenBSD install ISO that autoinstalls
unattended: a custom `siteXX.tgz` file set (arbitrary files/scripts
overlaid onto the target root filesystem, plus an optional
`install.site` post-install hook) and an `install.conf` autoinstall
response file, both embedded directly in the ISO so no network is
needed at boot.

Default target is OpenBSD 7.9 / amd64, controlled by `config.sh`.

## Hard constraint: build must run on OpenBSD

The actual ISO remastering needs native OpenBSD tools with no
Windows/Linux equivalent: `rdsetroot(8)` (patches the ramdisk kernel
`bsd.rd`), `vnconfig(8)` + `mount` (to edit the ramdisk FFS image and
to read the source ISO's cd9660 filesystem), and `mkhybrid` (rebuilds
the hybrid BIOS+EFI bootable ISO). There is no cross-build path from
Windows.

Because of this, the workflow is split in two:
- **Local driver** (`build.sh`) runs anywhere with bash/ssh/scp (git-bash
  or WSL on Windows) and just orchestrates.
- **Remote build script** (`remote/build-image.sh`) runs as root on a
  remote OpenBSD host over SSH and does the actual work.

Never try to run `rdsetroot`/`vnconfig`/`mkhybrid` locally on this
Windows machine -- they don't exist here. Any change to the build logic
belongs in `remote/build-image.sh`, and needs to be validated by
actually running it against an OpenBSD host, not just read for
plausibility.

## Commands

```sh
# One-time setup
cp config.local.sh.example config.local.sh   # fill in REMOTE_HOST etc.
cp install.conf.example install.conf         # edit hostname/ssh key/timezone

# Build (uploads site/ + install.conf to the remote host, builds there,
# copies the ISO back to out/)
./build.sh
```

There is no lint/test suite -- correctness is verified by booting the
resulting ISO in a VM and confirming autoinstall completes.

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

`remote/build-image.sh` does, in order:
1. Fetch the official `install${RELEASE_SHORT}.iso` for
   `RELEASE`/`ARCH` from `MIRROR`.
2. Mount it (`vnconfig` + `mount -t cd9660`) and copy its contents out
   with `pax`.
3. Tar `site/` into `site${RELEASE_SHORT}.tgz`, dropped next to the
   standard sets in `<RELEASE_SHORT>/<ARCH>/` on the extracted tree.
4. Regenerate `SHA256` for that set directory (unsigned -- there's no
   `signify` key for this custom build, so `install.conf` must answer
   "yes" to the resulting "continue without verification?" prompt).
5. Extract `bsd.rd`'s ramdisk image with `rdsetroot -x`, mount it,
   drop in `install.conf` as `/auto_install.conf`, unmount, and write
   it back with `rdsetroot`.
6. Repack everything with `mkhybrid`, using the same flags as
   OpenBSD's own `distrib/${ARCH}/iso/Makefile`.

Config layering: `config.sh` (committed defaults: release/arch/mirror)
is sourced first, then `config.local.sh` (gitignored: `REMOTE_HOST` and
friends) overrides it. `install.conf` is also gitignored by default
since it may end up carrying host-specific or sensitive answers --
`install.conf.example` is the tracked template.

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

- `remote/build-image.sh` has not been run end-to-end against a real
  OpenBSD host yet -- it's a documented first draft, not a tested
  pipeline. See the script's header comment for the specific risk
  points (device name collisions on `vnd1`, whether `mkhybrid` is on
  `PATH`, `rdsetroot`'s fixed reserved-space budget in `bsd.rd`).
- Exact installer prompt wording in `install.conf` can drift between
  OpenBSD releases -- if autoinstall stalls, it's waiting on a prompt
  whose text doesn't match; run the installer interactively once
  against the target release to get exact wording.
