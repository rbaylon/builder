# OpenBSD custom installer builder

Builds a self-contained, autoinstall-capable OpenBSD install ISO: your
own `siteXX.tgz` file set plus an embedded `install.conf` response
file, so booting the ISO and choosing `(A)utoinstall` needs no network
at all.

Default target: OpenBSD 7.9 / amd64 (edit `config.sh` to change).

## How it works

- `site/` is a tree rooted at `/` on the target system. It gets tarred
  into `site79.tgz` and installed last, after the standard sets. If it
  contains an executable `install.site`, the installer runs it
  `chroot`'d into the freshly-installed system -- that's the hook for
  package installs, users, service enablement, etc.
- `install.conf` (copy `install.conf.example` to get started) answers
  the installer's interactive prompts non-interactively, per
  `autoinstall(8)`.
- The build patches the official `installXX.iso`'s `bsd.rd` (ramdisk
  kernel) with `rdsetroot(8)` to embed `install.conf` directly, and
  drops `site79.tgz` next to the standard sets on the disc, then
  repacks the ISO with `mkhybrid` (same tool/flags OpenBSD's own
  release build uses).

See [CLAUDE.md](CLAUDE.md) for the full architecture writeup.

## Requirements

Building requires native OpenBSD tools (`rdsetroot`, `vnconfig`,
`mkhybrid`) that only exist on OpenBSD, so `build.sh` must be run
**directly on an OpenBSD host, as root**.

## Quick start

1. `cp install.conf.example install.conf` and edit it (hostname, SSH
   key, timezone, ...).
2. Add whatever files/scripts you want under `site/` (remember: it
   mirrors the target's root filesystem).
3. `doas ./build.sh` -- fetches the official install ISO, builds
   `site79.tgz`, embeds `install.conf` into `bsd.rd`, repacks the ISO,
   and drops the result into `out/`.

## Status

`build.sh` has been run end-to-end on a real OpenBSD 7.9/amd64 host
and produces a structurally correct ISO. Not yet validated: actually
booting the resulting ISO and confirming autoinstall fires and
completes unattended -- do that before trusting a build fully.
