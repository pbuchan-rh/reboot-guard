# reboot-guard: design

Goal: hosts refuse a normal reboot or shutdown until someone deliberately allows one, without breaking planned
patching. Plain files, no daemon, same file set on RHEL 7-10.

## Guard: `RefuseManualStart=yes` drop-ins

`<unit>.d/50-reboot-guard.conf` (`[Unit]` + `RefuseManualStart=yes`) for every unit that ends the running system.
Units: `reboot`, `poweroff`, `halt`, `kexec`, `soft-reboot`, `exit`, each as `.target` and `systemd-<name>.service`.
The services are guarded because `systemctl start systemd-reboot.service` skips a target-only guard; `exit`
because `systemctl exit` powers off a VM. A target pulling in its service is a dependency, not a manual start, so
allowed reboots work. A drop-in for a unit that does not exist (soft-reboot before RHEL 10, exit on 7) does nothing.

Why not [KB 1580343](https://access.redhat.com/solutions/1580343) (a service `RequiredBy=shutdown.target`): its
"conflicting jobs" message names a different unit each run, and it has no allow-once. `RefuseManualStart` gives one
clear message and `systemctl` exit 4.

## Allow-once via `/run`

`/run/systemd/system/<unit>.d/99-reboot-guard-allow.conf` with `RefuseManualStart=no`. Drop-ins merge in filename
order across `/etc`, `/run` and `/usr/lib`, so `99-` beats `50-` (tested on systemd 219-257). `/run` is a tmpfs: the
guard is back after the reboot with no extra service. A soft-reboot (RHEL 10) keeps `/run`, so the helper also adds
an `ExecStartPre` to `systemd-soft-reboot.service` that deletes the allow files.

## Ctrl-Alt-Del

systemd starts `ctrl-alt-del.target` itself, not as a manual start, so `RefuseManualStart` misses it. The guard:

- masks it (`/etc/systemd/system/ctrl-alt-del.target -> /dev/null`). RHEL ships that path as a link to
  `reboot.target` (its `Alias=`), so it is backed up first and restored on removal.
- sets `CtrlAltDelBurstAction=none` (`system.conf.d/50-reboot-guard.conf` + `daemon-reexec`). Otherwise 7 presses in
  2 s force a reboot even when masked. Works on RHEL 7-10 (backported to 7/8; `systemctl show` hides it there).

## Files vs RPM layout

| | files / helper | RPM |
|---|---|---|
| drop-ins, burst conf | `/etc/systemd/...` | `/usr/lib/systemd/...` (`rpm -V` detects edits; `/etc` free for overrides) |
| Ctrl-Alt-Del mask | `/etc`, backup `.reboot-guard-orig` | `/etc`, backup `.reboot-guard-rpm-orig`, restored on erase |
| helper | `/usr/sbin/reboot-guard` | `/usr/sbin/reboot-guard`; `uninstall` refuses (use `dnf remove`) |
| allow-once | `/run` | `/run` |

## Optional hardening

| gap | fix | cost |
|---|---|---|
| `--force`, signals to PID 1, sysrq | automation without full root: confined SELinux user, narrow sudo rules | account design work |
| `kexec -e` with a loaded kernel | `kernel.kexec_load_disabled=1` after kdump has loaded | set early, it breaks kdump |
| qemu-ga `guest-shutdown` (refused on RHEL 10; not verified on 7-9) | remove it from the agent's allowed RPCs | hypervisor agent shutdown stops |

## Gaps and threat model

Protects against accidents: a normal reboot on the wrong host or too many hosts. Not against root on purpose:
`--force`, `reboot -f`, `kexec -e`, `kill -s SIGRTMIN+5 1`, `/proc/sysrq-trigger` (any `kernel.sysrq`), hypervisor/BMC
power operations, panic auto-reboot, watchdogs. Legacy commands exit 0 while refused; `shutdown -r +N` sets
`/run/nologin` for the countdown.

## Image mode

Tested on RHEL 10.2 bootc with the RPM in the Containerfile. The guard is in `/usr/lib` (read-only on the host); the
Ctrl-Alt-Del mask and its backup are image `/etc` files and follow the `/etc` 3-way merge on upgrades; an image without
the RPM removes all of it. allow-once works through `/run`. The helper and role `install` only report (helper: refuses
if the image has no guard); `uninstall` refuses.

- `bootc upgrade --apply`, `bootc switch --apply`, `bootc rollback --apply` and `bootc-fetch-apply-updates.service`
  stage the update, have their reboot refused, and wait forever; meanwhile every other `bootc` command blocks on the
  lock. Kill it (`systemctl stop bootc-fetch-apply-updates.service`); the staged update stays and boots after
  allow-once + reboot.
- The base image enables the timer in `/usr/lib` (`default.target.wants`), so `systemctl disable` does nothing:
  `systemctl mask --now bootc-fetch-apply-updates.timer`.
- `rpm -V` flags every file `T` (ostree resets mtimes): use `rpm -V --nomtime`.
- Plain `systemctl soft-reboot` with nothing staged lands in emergency mode, guard or not. After allow-once,
  `bootc upgrade --apply --soft-reboot=auto` works.

```dockerfile
FROM registry.redhat.io/rhel10/rhel-bootc
COPY reboot-guard-2.0.2-1.noarch.rpm /tmp/
RUN dnf -y install /tmp/reboot-guard-2.0.2-1.noarch.rpm && rm -f /tmp/*.rpm && dnf clean all
# or, without the RPM (built and linted, not booted):
COPY files/etc/systemd/system/ /usr/lib/systemd/system/
COPY files/etc/systemd/system.conf.d/ /usr/lib/systemd/system.conf.d/
COPY bin/reboot-guard /usr/sbin/reboot-guard
# The base image has /etc/systemd/system/ctrl-alt-del.target -> reboot.target, and /etc beats /usr/lib.
RUN rm -f /etc/systemd/system/ctrl-alt-del.target /usr/lib/systemd/system/ctrl-alt-del.target \
 && ln -s /dev/null /usr/lib/systemd/system/ctrl-alt-del.target
```
