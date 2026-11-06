#!/bin/bash
# Image mode (bootc, /run/ostree-booted): install refuses without a guard in /usr/lib, writes nothing; reports with one.
set -u
cd "$(dirname "$0")/.." || exit 2
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
bad=0
mkdir -p "$t/run" && touch "$t/run/ostree-booted"
out=$(REBOOT_GUARD_ROOT=$t bin/reboot-guard install 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$out" = "reboot-guard: refused: image mode: install the RPM in the Containerfile" ] \
    || { echo "image: no guard: rc $rc: $out" >&2; bad=1; }
[ ! -e "$t/etc" ] && [ ! -e "$t/usr/sbin" ] || { echo "image: no guard: files written" >&2; bad=1; }
mkdir -p "$t/usr/lib/systemd/system/reboot.target.d" && touch "$t/usr/lib/systemd/system/reboot.target.d/50-reboot-guard.conf"
REBOOT_GUARD_ROOT=$t bin/reboot-guard install >/dev/null 2>&1 || { echo "image: guard in image: install rc $?" >&2; bad=1; }
[ ! -e "$t/etc" ] || { echo "image: guard in image: files written" >&2; bad=1; }
[ "$bad" = 0 ] && echo "image: ok"
exit "$bad"
