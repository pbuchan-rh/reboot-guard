#!/bin/bash
# shellcheck disable=SC2015  # `test && r PASS ... || r FAIL ...`: r/add only printf and return 0, so the
#                            FAIL branch never runs after a PASS.
# reboot-guard test matrix: run against one host over ssh (needs passwordless sudo there).
#
# Usage: tests/matrix.sh [options] [user@]host
#   (default)              non-destructive: local drift check (tests/drift.sh); guard source, status, every
#                          plain reboot/shutdown path refused
#                          (systemctl verbs, legacy commands, direct service/target starts), Ctrl-Alt-Del mask +
#                          burst conf, allow-once create/cancel (plain files and helper). The host is NOT rebooted:
#                          refusal checks only run when every guarded unit reads RefuseManualStart=yes.
#   --expect-unguarded     check the guard is absent instead (after uninstall / rpm erase)
#   --destructive          ALSO: allow-once -> real reboot -> guard back; on RHEL 10 package mode allow-once ->
#                          soft-reboot -> guard back. REBOOTS THE HOST.
#   --virsh HV DOMAIN      with --destructive: Ctrl-Alt-Del single + burst x8 via `ssh HV sudo virsh send-key DOMAIN`
#   --wait SECONDS         how long to wait for the host after a reboot (default 600)
#
# Environment: SSH_OPTS (extra ssh options, e.g. "-o UserKnownHostsFile=/path").
# Exit: 0 all PASS (SKIP/INFO allowed), 1 any FAIL, 2 bad usage.
# MIT, part of reboot-guard.

set -u
DESTRUCTIVE=0 EXPECT=guarded HV="" DOMAIN="" WAIT=600 HOST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --destructive) DESTRUCTIVE=1 ;;
        --expect-unguarded) EXPECT=unguarded ;;
        --virsh) HV="${2:?}"; DOMAIN="${3:?}"; shift 2 ;;
        --wait) WAIT="${2:?}"; shift ;;
        -h|--help) sed -n '/^# reboot-guard test matrix/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) HOST="$1" ;;
    esac
    shift
done
[ -n "$HOST" ] || { echo "usage: $0 [--expect-unguarded] [--destructive [--virsh HV DOMAIN]] [user@]host" >&2; exit 2; }
[ "$DESTRUCTIVE" = 1 ] && [ "$EXPECT" = unguarded ] && { echo "--destructive needs a guarded host" >&2; exit 2; }
# shellcheck disable=SC2086
SSH() { ssh -o BatchMode=yes -o ConnectTimeout=10 ${SSH_OPTS:-} "$@"; }

# ---------------------------------------------------------------------------------------------------------------
# Remote part: shipped with `declare -f`, runs as root on the host. Prints "R<TAB>check<TAB>PASS|FAIL|SKIP|INFO<TAB>detail".
# ---------------------------------------------------------------------------------------------------------------
UNITS_ALL="reboot.target poweroff.target halt.target kexec.target soft-reboot.target exit.target
 systemd-reboot.service systemd-poweroff.service systemd-halt.service systemd-kexec.service systemd-soft-reboot.service
 systemd-exit.service"

r() { printf 'R\t%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "${3:-}" | tr '\n\t' '  ' | cut -c1-150)"; }
loaded() { systemctl show -p LoadState "$1" 2>/dev/null | grep -q '=loaded$'; }
refuse() { systemctl show -p RefuseManualStart "$1" 2>/dev/null | sed 's/.*=//'; }
helper() { local h; for h in /usr/sbin/reboot-guard /usr/bin/reboot-guard /usr/local/sbin/reboot-guard; do [ -x "$h" ] && { echo "$h"; return 0; }; done; return 1; }
units() { local u; for u in $UNITS_ALL; do loaded "$u" && echo "$u"; done; }
count() { local n=0 f; for f in "$@"; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }   # existing files among args
allow_files() { count /run/systemd/system/*.d/99-reboot-guard-allow.conf; }
shutdown_jobs() { systemctl list-jobs --no-legend 2>/dev/null | grep -E '(reboot|poweroff|halt|kexec|soft-reboot|exit|shutdown)\.(target|service)' ; }
kb_enabled() { [ -e /etc/systemd/system/shutdown.target.requires/reboot-guard.service ]; }

all_armed() {   # every loaded guarded unit refuses manual start, no allow-once pending
    local u; for u in $(units); do [ "$(refuse "$u")" = yes ] || return 1; done
    [ "$(allow_files)" -eq 0 ]
}

# Run one plain path that must be refused. $1 label, $2 unit that must be guarded first, $3 expected rc ("4" or "0"), rest = command.
try_refused() {
    local label=$1 unit=$2 want=$3; shift 3
    if [ "$(refuse "$unit")" != yes ] || [ "$(refuse reboot.target)" != yes ]; then
        r "refuse: $label" FAIL "not run: $unit not guarded (would really do it)"; return
    fi
    local out rc
    out=$(timeout 30 "$@" 2>&1); rc=$?
    sleep 1
    local jobs; jobs=$(shutdown_jobs)
    # A legacy `shutdown` can leave a schedule behind: cancel it.
    [ -e /run/systemd/shutdown/scheduled ] && shutdown -c >/dev/null 2>&1
    if [ -n "$jobs" ]; then
        r "refuse: $label" FAIL "shutdown job queued: $jobs"
    elif [ "$rc" = "$want" ] && { printf '%s' "$out" | grep -qE 'refused|Access denied' || [ "$want" = 0 ]; }; then
        local msg; msg=$(printf '%s' "$out" | grep -m1 -oE '(Operation refused|Access denied)[^,]*')
        r "refuse: $label" PASS "rc $rc, ${msg:-${out:-no output}}"
    else
        r "refuse: $label" FAIL "rc $rc (want $want): $out"
    fi
}

remote_info() {
    # shellcheck source=/dev/null  # target host file, not in this repo
    . /etc/os-release
    r "host" INFO "$(hostname) $PRETTY_NAME, systemd $(systemctl --version | sed -n '1s/systemd \([0-9]*\).*/\1/p')$([ -e /run/ostree-booted ] && echo ', image mode (bootc)')"
    local src=none
    [ -f /etc/systemd/system/reboot.target.d/50-reboot-guard.conf ] && src="/etc (copied files / helper)"
    if [ -f /usr/lib/systemd/system/reboot.target.d/50-reboot-guard.conf ]; then
        if rpm -qf /usr/lib/systemd/system/reboot.target.d/50-reboot-guard.conf >/dev/null 2>&1; then src="/usr/lib (RPM $(rpm -q reboot-guard))"
        else src="/usr/lib (image / copied)"; fi
        [ -e /run/ostree-booted ] && src="$src, image mode"
    fi
    r "guard source" INFO "$src; helper: $(helper || echo none)"
    if kb_enabled; then
        local en; en="reboot-guard.service $(systemctl is-enabled reboot-guard.service 2>&1), start-reboot-guard.service $(systemctl is-enabled start-reboot-guard.service 2>&1)"
        if systemctl show -p Requires shutdown.target 2>/dev/null | grep -q reboot-guard.service; then
            r "legacy KB 1580343 guard" INFO "PRESENT and armed ($en); migrate: see README"
        else
            r "legacy KB 1580343 guard" INFO "enabled but not in shutdown.target Requires ($en)"
        fi
    elif [ -e /etc/systemd/system/reboot-guard.service ]; then
        r "legacy KB 1580343 guard" INFO "unit file present, not enabled"
    fi
}

# Helper CLI: help, version, usage errors and exit codes (no state change).
cli_checks() {
    local h=$1 out rc v
    v=$("$h" --version 2>&1); rc=$?
    out=$("$h" --help 2>&1)
    [ "$rc" = 0 ] && printf '%s' "$out" | head -1 | grep -qF "$v:" && [ "$(printf '%s\n' "$out" | wc -l)" -le 9 ] \
        && r "helper: --version, --help" PASS "$v; help $(printf '%s\n' "$out" | wc -l) lines" || r "helper: --version, --help" FAIL "rc $rc: $v"
    out=$("$h" bogus 2>&1 >/dev/null); rc=$?
    [ "$rc" = 2 ] && r "helper: bad usage rc 2" PASS "$out" || r "helper: bad usage rc 2" FAIL "rc $rc: $out"
    out=$("$h" allow-once 2>&1 >/dev/null); rc=$?
    [ "$rc" = 2 ] && [ "$(allow_files)" -eq 0 ] && r "helper: allow-once without --reason rc 2" PASS "$out" || r "helper: allow-once without --reason rc 2" FAIL "rc $rc: $out"
    out=$(runuser -u nobody -- "$h" cancel 2>&1); rc=$?
    [ "$rc" = 3 ] && r "helper: not root rc 3" PASS "$out" || r "helper: not root rc 3" FAIL "rc $rc: $out"
}

remote_guarded() {
    local u n=0 bad=""
    for u in $(units); do n=$((n + 1)); [ "$(refuse "$u")" = yes ] || bad="$bad $u"; done
    local v2=1
    [ -f /etc/systemd/system/reboot.target.d/50-reboot-guard.conf ] || [ -f /usr/lib/systemd/system/reboot.target.d/50-reboot-guard.conf ] || v2=0
    if [ "$v2" = 0 ]; then
        if kb_enabled; then
            r "status: v2 guard" SKIP "not installed; host has the legacy KB guard only. Refusal/allow-once checks not run"
            return 0
        fi
        r "status: v2 guard" FAIL "not installed (no 50-reboot-guard.conf in /etc or /usr/lib)"; return 0
    fi
    if [ -z "$bad" ]; then r "status: units guarded" PASS "$n/$n RefuseManualStart=yes"
    else r "status: units guarded" FAIL "open:$bad"; fi
    local a; a=$(allow_files)
    [ "$a" -eq 0 ] && r "status: no allow-once pending" PASS "0 files in /run" || r "status: no allow-once pending" FAIL "$a allow files in /run"
    local h; if h=$(helper); then
        local out rc; out=$("$h" status 2>&1); rc=$?
        [ "$rc" = 0 ] && r "status: helper rc 0" PASS "$out" || r "status: helper rc 0" FAIL "rc $rc: $out"
        out=$(sudo -n reboot-guard status 2>&1); rc=$?
        [ "$rc" = 0 ] && r "helper: on sudo secure_path" PASS "sudo reboot-guard status: $out" || r "helper: on sudo secure_path" FAIL "rc $rc: $out"
        [ "$h" != /usr/local/sbin/reboot-guard ] && [ -e /usr/local/sbin/reboot-guard ] \
            && r "helper: no old /usr/local/sbin copy" FAIL "$h and /usr/local/sbin/reboot-guard" || r "helper: no old /usr/local/sbin copy" PASS "$h"
        cli_checks "$h"
    else r "status: helper rc 0" SKIP "no helper installed"; fi

    # Ctrl-Alt-Del
    local cad; cad=$(systemctl is-enabled ctrl-alt-del.target 2>/dev/null)
    [ "$cad" = masked ] && r "Ctrl-Alt-Del masked" PASS "$(for f in /etc/systemd/system/ctrl-alt-del.target /usr/lib/systemd/system/ctrl-alt-del.target; do [ "$(readlink "$f")" = /dev/null ] && echo "$f -> /dev/null" && break; done)" \
        || r "Ctrl-Alt-Del masked" FAIL "is-enabled: $cad"
    local conf; conf=$(grep -ls '^CtrlAltDelBurstAction=none' /etc/systemd/system.conf.d/*.conf /usr/lib/systemd/system.conf.d/*.conf /run/systemd/system.conf.d/*.conf 2>/dev/null | head -1)
    local live; live=$(systemctl show -p CtrlAltDelBurstAction 2>/dev/null | sed 's/.*=//')
    if [ -z "$conf" ]; then r "Ctrl-Alt-Del burst conf" FAIL "no CtrlAltDelBurstAction=none in system.conf.d"
    elif [ -n "$live" ] && [ "$live" != none ]; then r "Ctrl-Alt-Del burst conf" FAIL "$conf present but PID 1 has $live (daemon-reexec needed)"
    else r "Ctrl-Alt-Del burst conf" PASS "$conf, PID 1: ${live:-not shown on this systemd}"; fi

    all_armed || { r "refusal checks" FAIL "not run: guard not fully armed"; return 0; }

    # Plain paths. Expected rc: systemctl verbs/starts 4, legacy commands 0 (documented gap).
    try_refused "systemctl reboot" reboot.target 4 systemctl reboot
    try_refused "systemctl poweroff" poweroff.target 4 systemctl poweroff
    try_refused "systemctl halt" halt.target 4 systemctl halt
    if [ "$(cat /sys/kernel/kexec_loaded 2>/dev/null)" = 1 ]; then try_refused "systemctl kexec" kexec.target 4 systemctl kexec
    else r "refuse: systemctl kexec" SKIP "no kexec kernel loaded (fails before the guard); start kexec.target covered below"; fi
    loaded soft-reboot.target && try_refused "systemctl soft-reboot" soft-reboot.target 4 systemctl soft-reboot
    loaded exit.target && try_refused "systemctl exit" exit.target 4 systemctl exit
    try_refused "systemctl isolate reboot.target" reboot.target 4 systemctl isolate reboot.target
    local u; for u in $(units); do try_refused "systemctl start $u" "$u" 4 systemctl start "$u"; done
    try_refused "reboot" reboot.target 0 reboot
    try_refused "shutdown -r now" reboot.target 0 shutdown -r now
    try_refused "init 6" reboot.target 0 init 6
    try_refused "halt" halt.target 0 halt
    try_refused "poweroff" poweroff.target 0 poweroff
    try_refused "shutdown -h now" poweroff.target 0 shutdown -h now

    # Allow-once by hand (plain files), then cancel.
    trap 'rm -f /run/systemd/system/*.d/99-reboot-guard-allow.conf; systemctl daemon-reload' EXIT
    for u in $(units); do mkdir -p "/run/systemd/system/$u.d"; printf '[Unit]\nRefuseManualStart=no\n' > "/run/systemd/system/$u.d/99-reboot-guard-allow.conf"; done
    systemctl daemon-reload
    local open=0; for u in $(units); do [ "$(refuse "$u")" = no ] && open=$((open + 1)); done
    [ "$open" = "$n" ] && r "allow-once (plain files): opens" PASS "$open/$n RefuseManualStart=no" || r "allow-once (plain files): opens" FAIL "$open/$n open"
    rm -f /run/systemd/system/*.d/99-reboot-guard-allow.conf; systemctl daemon-reload
    all_armed && r "allow-once (plain files): cancel" PASS "re-armed, 0 files" || r "allow-once (plain files): cancel" FAIL "not re-armed"

    # Allow-once with the helper, then cancel.
    if h=$(helper); then
        local reason since; reason="tests/matrix.sh $$ $(date +%s)"; since=$(date '+%Y-%m-%d %H:%M:%S')
        "$h" allow-once --reason "$reason" >/dev/null 2>&1
        local st; st=$("$h" status 2>&1); rc=$?
        local open2=0; for u in $(units); do [ "$(refuse "$u")" = no ] && open2=$((open2 + 1)); done
        [ "$rc" = 2 ] && [ "$open2" = "$n" ] && r "allow-once (helper): status rc 2" PASS "$open2/$n open; $st" || r "allow-once (helper): status rc 2" FAIL "rc $rc, $open2/$n open"
        sleep 1
        journalctl -t reboot-guard --since "$since" --no-pager 2>/dev/null | grep -qF "$reason" \
            && r "allow-once (helper): journal reason" PASS "journalctl -t reboot-guard has the reason" \
            || r "allow-once (helper): journal reason" FAIL "reason not in journal"
        "$h" cancel >/dev/null 2>&1; rc=$?
        "$h" status >/dev/null 2>&1; local rc2=$?
        [ "$rc" = 0 ] && [ "$rc2" = 0 ] && all_armed && r "allow-once (helper): cancel" PASS "cancel rc 0, status rc 0" || r "allow-once (helper): cancel" FAIL "cancel rc $rc, status rc $rc2"
    else
        r "allow-once (helper)" SKIP "no helper installed"
    fi
    trap - EXIT
}

remote_unguarded() {
    local u open=0 n=0 left
    for u in $(units); do n=$((n + 1)); [ "$(refuse "$u")" = no ] && open=$((open + 1)); done
    [ "$open" = "$n" ] && r "unguarded: units open" PASS "$n/$n RefuseManualStart=no" || r "unguarded: units open" FAIL "$open/$n open"
    left=$(count /etc/systemd/system/*.d/50-reboot-guard.conf /usr/lib/systemd/system/*.d/50-reboot-guard.conf \
        /run/systemd/system/*.d/99-reboot-guard-allow.conf /etc/systemd/system.conf.d/50-reboot-guard.conf \
        /usr/lib/systemd/system.conf.d/50-reboot-guard.conf)
    [ "$left" = 0 ] && r "unguarded: no guard files" PASS "none in /etc, /usr/lib, /run" || r "unguarded: no guard files" FAIL "$left files left"
    rpm -q reboot-guard >/dev/null 2>&1 && r "unguarded: no RPM" FAIL "$(rpm -q reboot-guard)" || r "unguarded: no RPM" PASS "not installed"
    local cad; cad=$(readlink /etc/systemd/system/ctrl-alt-del.target 2>/dev/null)
    [ "$cad" = /dev/null ] && r "unguarded: Ctrl-Alt-Del" FAIL "still masked in /etc" || r "unguarded: Ctrl-Alt-Del" PASS "/etc link: ${cad:-none} ($(systemctl is-enabled ctrl-alt-del.target 2>&1))"
    ls /etc/systemd/system/ctrl-alt-del.target.reboot-guard*orig >/dev/null 2>&1 && r "unguarded: no CAD backup left" FAIL "backup file still there" || r "unguarded: no CAD backup left" PASS ""
    local live; live=$(systemctl show -p CtrlAltDelBurstAction 2>/dev/null | sed 's/.*=//')
    r "unguarded: burst action" INFO "${live:-not shown on this systemd}"
    kb_enabled && r "legacy KB 1580343 guard" INFO "PRESENT (still blocks reboots)"
    return 0
}

remote_allow() {   # used by --destructive: allow once with the helper if there is one, else plain files
    local h; if h=$(helper); then "$h" allow-once --reason "tests/matrix.sh --destructive" >/dev/null; "$h" status; return 0; fi
    local u; for u in $(units); do mkdir -p "/run/systemd/system/$u.d"; printf '[Unit]\nRefuseManualStart=no\n' > "/run/systemd/system/$u.d/99-reboot-guard-allow.conf"; done
    systemctl daemon-reload; echo "allow-once by plain files"
}

# SoftRebootsCount is empty before systemd 254 (RHEL 7/8/9): print 0, or `read` shifts the fields.
remote_state() { local sr; sr=$(systemctl show -p SoftRebootsCount 2>/dev/null | sed 's/.*=//')
    printf '%s %s %s %s\n' "$(cat /proc/sys/kernel/random/boot_id)" "${sr:-0}" \
    "$(all_armed && echo armed || echo open)" "$( { [ -e /run/ostree-booted ] && echo bootc; } || { loaded soft-reboot.target && echo soft; } || echo plain)"; }

FUNCS="$(declare -f cli_checks r count loaded refuse helper units allow_files shutdown_jobs kb_enabled all_armed try_refused remote_info remote_guarded remote_unguarded remote_allow remote_state)"
remote() { SSH "$HOST" "sudo -n bash -s" <<EOF
UNITS_ALL="$UNITS_ALL"
$FUNCS
$*
EOF
}

# ---------------------------------------------------------------------------------------------------------------
# Local part
# ---------------------------------------------------------------------------------------------------------------
RESULTS=$(mktemp); trap 'rm -f "$RESULTS"' EXIT
add() { printf 'R\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; }
out=$("$(dirname "$0")/drift.sh" 2>&1) && add "drift: helper vs files/ (local repo)" PASS "$out" || add "drift: helper vs files/ (local repo)" FAIL "$out"

wait_back() {   # $1 old boot_id, $2 old SoftRebootsCount -> waits until either changed
    local t=0 st
    while [ "$t" -lt "$WAIT" ]; do
        sleep 10; t=$((t + 10))
        st=$(remote remote_state 2>/dev/null) || continue
        local b s; read -r b s _ _ <<< "$st"
        if [ "$b" != "$1" ] || [ "${s:-0}" != "${2:-0}" ]; then echo "$st"; return 0; fi
    done
    return 1
}

state=$(remote remote_state) || { echo "cannot reach $HOST with sudo -n" >&2; exit 1; }
read -r BOOT0 SOFT0 ARMED0 KIND <<< "$state"
remote remote_info >> "$RESULTS"
if [ "$EXPECT" = unguarded ]; then remote remote_unguarded >> "$RESULTS"; else remote remote_guarded >> "$RESULTS"; fi
read -r BOOT1 _ _ _ <<< "$(remote remote_state)"
[ "$BOOT0" = "$BOOT1" ] && add "host not rebooted by the checks" PASS "boot_id unchanged" || add "host not rebooted by the checks" FAIL "boot_id changed"

if [ "$DESTRUCTIVE" = 1 ]; then
    if [ "$ARMED0" != armed ]; then
        add "destructive" SKIP "guard not armed, not rebooting"
    else
        # D1: allow-once -> reboot -> guard back
        remote remote_allow >/dev/null
        SSH "$HOST" "sudo -n systemd-run --on-active=2 /bin/systemctl reboot" >/dev/null 2>&1
        if st=$(wait_back "$BOOT0" "$SOFT0"); then
            read -r b s a _ <<< "$st"
            [ "$a" = armed ] && add "D1 allow-once -> reboot -> re-armed" PASS "new boot_id, guard back, 0 allow files" \
                || add "D1 allow-once -> reboot -> re-armed" FAIL "rebooted but guard: $a"
            out=$(SSH "$HOST" "sudo -n timeout 30 systemctl reboot" 2>&1); rc=$?
            [ "$rc" = 4 ] && add "D1 systemctl reboot after re-arm" PASS "rc 4" || add "D1 systemctl reboot after re-arm" FAIL "rc $rc $out"
            BOOT0=$b SOFT0=$s
        else
            add "D1 allow-once -> reboot -> re-armed" FAIL "host not back (or not rebooted) within ${WAIT}s"
        fi
        # D2: soft-reboot (RHEL 10 package mode only; on bootc plain soft-reboot -> emergency mode, see DESIGN.md)
        if [ "$KIND" = soft ] && remote 'helper >/dev/null' ; then
            sleep 5; read -r BOOT0 SOFT0 _ _ <<< "$(remote remote_state)"
            remote remote_allow >/dev/null
            SSH "$HOST" "sudo -n systemd-run --on-active=2 /bin/systemctl soft-reboot" >/dev/null 2>&1
            if st=$(wait_back "$BOOT0" "$SOFT0"); then
                read -r b s a _ <<< "$st"
                [ "$a" = armed ] && [ "$b" = "$BOOT0" ] && add "D2 allow-once -> soft-reboot -> re-armed" PASS "SoftRebootsCount $SOFT0 -> $s, guard back" \
                    || add "D2 allow-once -> soft-reboot -> re-armed" FAIL "boot_id $([ "$b" = "$BOOT0" ] && echo same || echo changed), guard: $a"
            else add "D2 allow-once -> soft-reboot -> re-armed" FAIL "not back within ${WAIT}s"; fi
        else
            add "D2 soft-reboot" SKIP "only on RHEL 10 package mode with the helper (kind: $KIND)"
        fi
        # D3: Ctrl-Alt-Del via the hypervisor
        if [ -n "$HV" ]; then
            read -r BOOT0 _ _ _ <<< "$(remote remote_state)"
            since=$(SSH "$HOST" "date '+%Y-%m-%d %H:%M:%S'")
            SSH "$HV" "sudo -n virsh send-key $DOMAIN KEY_LEFTCTRL KEY_LEFTALT KEY_DELETE" >/dev/null 2>&1; sleep 15
            read -r b _ _ _ <<< "$(remote remote_state 2>/dev/null)"
            [ "$b" = "$BOOT0" ] && add "D3 Ctrl-Alt-Del single" PASS "held" || add "D3 Ctrl-Alt-Del single" FAIL "host rebooted or unreachable"
            for _ in 1 2 3 4 5 6 7 8; do SSH "$HV" "sudo -n virsh send-key $DOMAIN KEY_LEFTCTRL KEY_LEFTALT KEY_DELETE" >/dev/null 2>&1; done; sleep 20
            read -r b _ _ _ <<< "$(remote remote_state 2>/dev/null)"
            n=$(SSH "$HOST" "sudo -n journalctl -b --since '$since' --no-pager | grep -cE 'ctrl-alt-del.target is masked|ctrl-alt-del.target job: Unit is masked'" 2>/dev/null)
            # RHEL 8+: "... ctrl-alt-del.target: Unit ctrl-alt-del.target is masked."; RHEL 7: "... ctrl-alt-del.target job: Unit is masked."
            # No such line = the keys never reached systemd, so "held" would prove nothing.
            if [ "$b" != "$BOOT0" ]; then add "D3 Ctrl-Alt-Del burst x8" FAIL "host rebooted or unreachable"
            elif [ "${n:-0}" -gt 0 ]; then add "D3 Ctrl-Alt-Del burst x8" PASS "held, $n 'is masked' log lines (single + burst)"
            else add "D3 Ctrl-Alt-Del burst x8" FAIL "no 'is masked' log line: keys did not reach the guest?"; fi
        else
            add "D3 Ctrl-Alt-Del" SKIP "no --virsh HV DOMAIN given"
        fi
    fi
fi

# Table
printf '\nreboot-guard matrix: %s (%s%s)\n\n' "$HOST" "$EXPECT" "$([ "$DESTRUCTIVE" = 1 ] && echo ', destructive')"
printf '%-52s %-5s %s\n' CHECK RESULT DETAIL
printf '%-52s %-5s %s\n' "----------------------------------------------------" "-----" "------"
grep '^R' "$RESULTS" | while IFS=$'\t' read -r _ c res d; do printf '%-52s %-5s %s\n' "$c" "$res" "$d"; done
p=$(grep -c $'\tPASS\t' "$RESULTS"); f=$(grep -c $'\tFAIL\t' "$RESULTS"); s=$(grep -c $'\tSKIP\t' "$RESULTS")
printf '\n%s PASS, %s FAIL, %s SKIP\n' "$p" "$f" "$s"
[ "$f" = 0 ]
