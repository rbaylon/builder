#!/bin/sh
# Tracks the ISO build version in ./VERSION.
#
# VERSION holds the version the next ISO will be named with. build.sh
# reads it with `show` when naming the ISO, and calls `bump` only after
# mkhybrid succeeds, so a failed build never consumes a version number.
#
# Usage: version.sh show
#        version.sh bump [major|minor|patch]   (default: patch)

set -e

cd "$(dirname "$0")"
VERSION_FILE=VERSION

die() {
	echo "version.sh: $*" >&2
	exit 1
}

read_version() {
	[ -f "$VERSION_FILE" ] || die "$VERSION_FILE missing"
	v=$(cat "$VERSION_FILE")
	echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
		die "malformed version '$v' in $VERSION_FILE"
	echo "$v"
}

case "${1:-}" in
show)
	read_version
	;;
bump)
	part="${2:-patch}"
	cur=$(read_version)
	IFS=. read -r major minor patch <<EOF
$cur
EOF
	case "$part" in
	major) major=$((major + 1)); minor=0; patch=0 ;;
	minor) minor=$((minor + 1)); patch=0 ;;
	patch) patch=$((patch + 1)) ;;
	*) die "unknown part '$part' (use major, minor or patch)" ;;
	esac
	new="$major.$minor.$patch"
	echo "$new" > "$VERSION_FILE"
	echo "$new"
	;;
*)
	die "usage: version.sh show | bump [major|minor|patch]"
	;;
esac
