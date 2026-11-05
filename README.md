# reboot-guard

Refuses `reboot`, `shutdown`, `poweroff` and `halt` on RHEL 7-10 until you allow one. It also masks Ctrl-Alt-Del and
turns off the 7-press burst reboot. Plain systemd drop-ins (`RefuseManualStart=yes`), no daemon; optional helper script
and RPM built from the same files. **An accident guard, not a security boundary:** it stops a script or admin rebooting
the wrong host or too many hosts; root can still reboot on purpose ([Known gaps](#known-gaps)). Design:
[DESIGN.md](DESIGN.md); results: [TESTING.md](TESTING.md).

## Platforms

| RHEL | systemd | units guarded |
|---|---|---|
| 7.9 | 219 | 8: reboot, poweroff, halt, kexec (`.target` + `systemd-*.service`) |
| 8.10 | 239 | 10: + exit |
| 9.6 | 252 | 10 |
| 10.2 | 257 | 12: + soft-reboot |
| 10.2 image mode (bootc) | 257 | 12, RPM in the Containerfile ([Image mode](#image-mode)) |

## Install
Pick one per host; do not mix the RPM and copied files.
### RPM
```sh
# noarch, RHEL 7-10. Drop-ins in /usr/lib; rpm -V shows edits. Build it yourself: make rpm sums
u=https://github.com/pbuchan-rh/reboot-guard/releases/download/v2.0.1
curl -fsSL -O $u/reboot-guard-2.0.1-1.noarch.rpm -O $u/SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS
sudo dnf install ./reboot-guard-2.0.1-1.noarch.rpm   # RHEL 7: yum; hash with: grep noarch SHA256SUMS | sha256sum -c
# localpkg_gpgcheck=1 (STIG): add --nogpgcheck; the RPM is unsigned, the hash check is the integrity check
```
### Image mode
```dockerfile
FROM registry.redhat.io/rhel10/rhel-bootc
COPY reboot-guard-2.0.1-1.noarch.rpm /tmp/
RUN dnf -y install /tmp/reboot-guard-2.0.1-1.noarch.rpm && rm -f /tmp/*.rpm && dnf clean all
```
Update: `bootc upgrade` (stage), allow-once, reboot. `--apply` and the auto-update timer wait forever on a guarded
host: `systemctl mask --now bootc-fetch-apply-updates.timer`. See [DESIGN.md](DESIGN.md#image-mode).
### Helper only
```sh
curl -fsSLO https://raw.githubusercontent.com/pbuchan-rh/reboot-guard/main/bin/reboot-guard
chmod +x reboot-guard && sudo ./reboot-guard install   # copies itself to /usr/sbin, writes the drop-ins to /etc
```
### Copy the files
```sh
git clone https://github.com/pbuchan-rh/reboot-guard.git && cd reboot-guard
sudo cp -r files/etc/systemd/system.conf.d /etc/systemd/ && sudo cp -r files/etc/systemd/system/*.d /etc/systemd/system/
sudo install -m 0755 bin/reboot-guard /usr/sbin/reboot-guard    # optional
c=/etc/systemd/system/ctrl-alt-del.target b=$c.reboot-guard-orig   # mask Ctrl-Alt-Del, back up once
[ "$(readlink $c)" != /dev/null ] && [ ! -e $b ] && [ ! -L $b ] && { [ -e $c ] || [ -L $c ]; } && sudo mv $c $b
sudo ln -sfn /dev/null $c && sudo systemctl daemon-reload && sudo systemctl daemon-reexec
```

## Patch window: allow one reboot

```sh
sudo reboot-guard allow-once --reason "CHG0012345 patching"   # reason required, logged with the user
sudo dnf -y update && sudo systemctl reboot     # allowed once; guarded again after boot
sudo reboot-guard cancel                        # or take the allow back
```

## Status and removal

```sh
sudo reboot-guard status       # exit 0 GUARDED, 1 NOT GUARDED, 2 ALLOW-ONCE; others 0 ok, 1 refused, 2 usage, 3 not root
journalctl -t reboot-guard     # install / uninstall / allow-once, with user and reason
sudo reboot-guard uninstall    # RPM: sudo dnf remove reboot-guard (uninstall refuses)
```
### Without the helper
```sh
systemctl show reboot.target -p RefuseManualStart     # yes = guarded
# allow once (use a full reboot: on RHEL 10 a soft-reboot keeps /run and the allow)
for u in reboot poweroff halt kexec soft-reboot exit; do for d in /run/systemd/system/{$u.target,systemd-$u.service}.d; do
  sudo mkdir -p $d && printf '[Unit]\nRefuseManualStart=no\n' | sudo tee $d/99-reboot-guard-allow.conf >/dev/null
done; done; sudo systemctl daemon-reload
# remove (no backup = the Ctrl-Alt-Del mask stays)
sudo rm -f /etc/systemd/system/*.d/50-reboot-guard.conf /etc/systemd/system.conf.d/50-reboot-guard.conf
c=/etc/systemd/system/ctrl-alt-del.target; { [ -e $c.reboot-guard-orig ] || [ -L $c.reboot-guard-orig ]; } && sudo mv -f $c.reboot-guard-orig $c
sudo systemctl daemon-reload && sudo systemctl daemon-reexec
```

## Known gaps

- Still reboot: `systemctl reboot --force`/`-ff`, `reboot -f`, `kexec -e`, signals to PID 1, `/proc/sysrq-trigger`,
  hypervisor/BMC power off or reset, kernel panic auto-reboot, watchdogs. Fix with account design (no full root).
- Refused: ACPI shutdown (power button) and qemu-guest-agent `guest-shutdown` (tested on RHEL 10; not verified on 7-9).
- Legacy `reboot`, `shutdown -r now`, `halt`, `poweroff`, `init 6` are refused but **exit 0** (RHEL 8: silently).
  Scripts: use `systemctl reboot` (exit 4) or `reboot-guard status`.
- `shutdown -r +N` is refused when it fires, but `/run/nologin` blocks non-root logins during the countdown.

## Automation

- `ansible.builtin.reboot` on a guarded host fails only at `reboot_timeout` (600 s). Check status first.
- `ansible/` role: install (files or RPM), uninstall, status, allow-once, patch-window play.
- `tests/matrix.sh host` checks a host over ssh. See [ansible/README.md](ansible/README.md).

## License and credits

MIT ([LICENSE](LICENSE)). Inspired by [ryran/reboot-guard](https://github.com/ryran/reboot-guard) (GPL-3) and
Red Hat [KB 1580343](https://access.redhat.com/solutions/1580343); no code copied.
