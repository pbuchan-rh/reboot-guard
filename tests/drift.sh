#!/bin/bash
# Drift check: bin/reboot-guard install (into a scratch root) must write the same files as files/.
# Compares the unit set, file contents without comment lines, and the Ctrl-Alt-Del link. Exit 1 on drift.
set -u
cd "$(dirname "$0")/.." || exit 2
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
REBOOT_GUARD_ROOT=$t bin/reboot-guard install >/dev/null || { echo "drift: helper install failed" >&2; exit 1; }
list() { (cd "$1" && find etc \( -type f -o -type l \) | sort); }
bad=0
d=$(diff <(list files) <(list "$t")) || { printf 'drift: file set differs (< files/, > helper):\n%s\n' "$d" >&2; bad=1; }
for f in $(list files); do
    if [ -L "files/$f" ]; then
        [ "$(readlink "files/$f")" = "$(readlink "$t/$f" 2>/dev/null)" ] || { echo "drift: $f link differs" >&2; bad=1; }
    elif [ -f "$t/$f" ]; then
        d=$(diff <(grep -v '^#' "files/$f") <(grep -v '^#' "$t/$f")) || { printf 'drift: %s\n%s\n' "$f" "$d" >&2; bad=1; }
    fi
done
{ [ -x "$t/usr/sbin/reboot-guard" ] && cmp -s bin/reboot-guard "$t/usr/sbin/reboot-guard"; } || { echo "drift: helper self-copy missing" >&2; bad=1; }
[ "$bad" = 0 ] && echo "drift: none ($(list files | wc -l) files)"
exit "$bad"
