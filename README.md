# OpenBSD custom installer builder

Builds a self-contained OpenBSD install ISO/USB image carrying your
own `siteXX.tgz` file set. Boots to the standard **interactive**
installer -- the custom site set shows up **pre-selected** on the
set-picker screen (still a normal, de-selectable checkbox), so no
typing is needed to include it. (This project used to also support
unattended autoinstall; that's been removed -- see
[CLAUDE.md](CLAUDE.md) for details and how to bring it back if you
need it.)

Default target: OpenBSD 7.9 / amd64 (edit `config.sh` to change).

## How it works

- `site/` is a tree rooted at `/` on the target system. It gets tarred
  into `site79.tgz` and installed last, after the standard sets. If it
  contains an executable `install.site`, the installer runs it
  `chroot`'d into the freshly-installed system -- that's the hook for
  package installs, users, service enablement, etc.
- `build.sh` drops `site79.tgz` next to the official ISO's standard
  sets, patches `install.sub` (inside `bsd.rd`) so that set is
  pre-selected by default on the installer's set-picker screen,
  refreshes `SHA256` for that directory, and repacks the ISO with
  `mkhybrid` (same tool/flags OpenBSD's own release build uses).
- `build_usb.sh` does the same thing to a raw USB disk image
  (`install79.img`) instead of an ISO, ready to `dd` onto a flash
  drive. It shares `site/` and `config.sh` with the ISO build.

See [CLAUDE.md](CLAUDE.md) for the full architecture writeup.

## Requirements

Building requires native OpenBSD tools (`rdsetroot`, `vnconfig`,
`mkhybrid`) that only exist on OpenBSD, so `build.sh`/`build_usb.sh`
must be run **directly on an OpenBSD host, as root**.

## Quick start

1. Add whatever files/scripts you want under `site/` (remember: it
   mirrors the target's root filesystem).
2. `doas ./build.sh` -- fetches the official install ISO, builds
   `site79.tgz`, repacks the ISO, and drops the result into `out/`.
   For a USB image instead, run `doas ./build_usb.sh`.
3. Boot the result and pick the custom site set when the installer
   offers it.

## Status

`build.sh`'s site-set/SHA256/repack pipeline was validated end-to-end
on a real OpenBSD 7.9/amd64 host, including a real boot test, before
the autoinstall removal -- those parts are unchanged by that removal
but haven't been re-run as the current script. The `install.sub`
pre-selection patch is new: its sed command was tested against a
synthetic copy of the real `install.sub` lines, but not yet run as
part of an actual build on an OpenBSD host. `build_usb.sh` has only
been run far enough to confirm `install79.img`'s on-disk layout.
Validate both the same way: run them, then boot the result and confirm
the custom site set shows pre-selected (and installs correctly) during
a normal interactive install.
