# Testing

## Results

RHEL 10.2 = package mode. refused = host stayed up (boot_id and `SoftRebootsCount` unchanged). n/a = unit or verb
does not exist on that release. - = not tested. `tests/matrix.sh`, RPM install and `patch-window.yml` rows: the
v2.0.0 RPM (release or release candidate, same files), 2026-11-05; KB 1580343 migration: re-tested on 10.2 for the
current role; other rows: earlier rounds, same guard files.

| check | 7.9 | 8.10 | 9.6 | 10.2 |
|---|---|---|---|---|
| `systemctl reboot` / `poweroff` / `halt` / `isolate reboot.target` (exit 4) | refused | refused | refused | refused |
| `systemctl start` of each guarded `.target` and `systemd-*.service` | refused | refused | refused | refused |
| `systemctl kexec` | refused | - | - | refused |
| `systemctl exit` | n/a | refused | refused | refused |
| `systemctl soft-reboot` | n/a | n/a | n/a | refused |
| `reboot`, `shutdown -r now`, `init 6`, `halt`, `poweroff` (exit 0) | refused | refused | refused | refused |
| `shutdown -r +1` (when it fires) | - | - | refused | refused |
| ACPI shutdown (`virsh shutdown --mode acpi`) | - | - | refused | refused |
| qemu-guest-agent `guest-shutdown` | - | - | - | refused |
| Ctrl-Alt-Del single press | refused | refused | refused | refused |
| Ctrl-Alt-Del burst x8 | refused | refused | refused | refused |
| `ansible.builtin.reboot`, no allow-once (fails at `reboot_timeout`) | - | - | refused | refused |
| allow-once -> reboot -> guarded again | pass | pass | pass | pass |
| allow-once -> soft-reboot -> guarded again | n/a | n/a | n/a | pass |
| `cancel`, `status` exit codes, journal reason | pass | pass | pass | pass |
| `systemctl reboot --force` | - | - | gap | gap |
| `kill -s SIGRTMIN+5 1` | - | - | - | gap |
| RPM: `sha256sum -c` (README form), helper uninstall -> install, `rpm -V` clean | pass | pass | pass | pass |
| RPM upgrade / reinstall / erase | pass | pass | pass | pass |
| RPM erase restores original Ctrl-Alt-Del link | pass | pass | pass | pass |
| role: install (files, RPM), re-run `changed=0`, uninstall | pass | pass | pass | pass |
| role: KB 1580343 migration (refuses without the flag) | pass | pass | pass | pass |
| `patch-window.yml` on the RPM (`GUARDED (rpm)` -> reboot -> guarded, 0 allow files) | pass | pass | pass | pass |
| `patch-window.yml` rescue after a forced failure | pass | pass | pass | pass |
| `tests/matrix.sh` (PASS/FAIL/SKIP) | 36/0/1 | 39/0/1 | 39/0/1 | 42/0/1 |
| `tests/matrix.sh --destructive` | 40/0/2 | 43/0/2 | 43/0/2 | 47/0/1 |

Image mode (RHEL 10.2 bootc): preliminary, TBD. See [DESIGN.md](DESIGN.md#image-mode-tbd).

## Running the tests

```sh
make check                              # helper writes the same drop-ins as files/ (tests/drift.sh)
shellcheck bin/reboot-guard tests/*.sh
tests/matrix.sh user@host               # non-destructive: every refusal, allow-once create/cancel
tests/matrix.sh --expect-unguarded user@host               # after uninstall / rpm erase
tests/matrix.sh --destructive --virsh HV DOMAIN user@host  # REBOOTS: allow-once reboot, soft-reboot, Ctrl-Alt-Del
```

Needs ssh with passwordless sudo on the host. `SSH_OPTS` adds ssh options. Exit 0 = all PASS (SKIP allowed).
SKIP = `systemctl kexec` with no kernel loaded (`start kexec.target` is checked instead) and soft-reboot before
systemd 254.
