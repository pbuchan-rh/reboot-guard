# Ansible: `reboot_guard` role

Plain `ansible-core` 2.14+, no collections. RHEL 7 targets need ansible-core 2.16 or older (Python 2.7). Tested with
2.16 against RHEL 7.9, 8.10, 9.6 and 10.2.

| playbook | what |
|---|---|
| `install.yml` | install from the plain files (default) or the RPM |
| `uninstall.yml` | remove whichever is installed; restores the original Ctrl-Alt-Del link |
| `status.yml` | report `guarded` / `unguarded` / `allow_once` |
| `allow-once.yml` | allow the next reboot only (`reboot_guard_reason` required) |
| `cancel.yml` | take a pending allow-once back |
| `patch-window.yml` | status check -> (update) -> allow-once -> `ansible.builtin.reboot` -> guard back |

```sh
cd ansible && cp inventory.example inventory      # edit
ansible-playbook -i inventory install.yml -e target=guarded
ansible-playbook -i inventory install.yml -e reboot_guard_method=rpm -e reboot_guard_rpm_src=/path/reboot-guard-2.0.1-1.noarch.rpm
ansible-playbook -i inventory patch-window.yml -e target=guarded -e "patch_reason='CHG0012345'" -e patch_update=true
```

## Role variables (`roles/reboot_guard/defaults/main.yml`)

| variable | default | |
|---|---|---|
| `reboot_guard_action` | `install` | `install`, `uninstall`, `allow_once`, `cancel`, `status` |
| `reboot_guard_method` | `files` | `files`: copy `files/` to `/etc`, helper to `/usr/sbin`; `rpm`: install the package. Both remove an old `/usr/local/sbin` helper |
| `reboot_guard_rpm_src` | `""` | RPM on the controller to copy and install; empty = `reboot-guard` from the host's repos |
| `reboot_guard_reason` | `""` | required for `allow_once`; logged with `[ansible]` or `[AAP job N]` |
| `reboot_guard_migrate_legacy` | `false` | the KB 1580343 guard makes install fail; `true` disables and removes its two services |
| `reboot_guard_src` / `reboot_guard_helper_src` | this repo's `files/` and `bin/reboot-guard` | change if the role is copied out of the repo |

Every action sets `reboot_guard_state` (`guarded`, `unguarded`, `allow_once`) and `reboot_guard_status_msg`.

## Notes

- `ansible.builtin.reboot` on a guarded host is refused but fails only at `reboot_timeout` (600 s). Put the status
  check in front so it fails in seconds:

  ```yaml
  - name: Reboot-guard status
    ansible.builtin.include_role:
      name: reboot_guard
    vars:
      reboot_guard_action: status
  - name: Refuse fast if the host is guarded and no allow-once is pending
    ansible.builtin.assert:
      that: reboot_guard_state != 'guarded'
      fail_msg: "{{ inventory_hostname }} is GUARDED: run allow-once first (or use patch-window.yml)"
  - name: Reboot
    ansible.builtin.reboot:
  ```
- `patch-window.yml`: `serial: 1` (`-e patch_serial=10%` for batches); no package update unless
  `patch_update=true`. A failure after allow-once cancels the allow and fails the host (guarded, not rebooted);
  `-e patch_test_fail_after_allow=true` forces one to test that.
- Image mode: `install` only reports, `uninstall` fails (the guard belongs in the Containerfile); `allow_once`,
  `cancel`, `status` and `patch-window.yml` with `patch_update=false` work (stage with `bootc upgrade` first). See
  [DESIGN.md](../DESIGN.md#image-mode).
- All tasks run on the managed host. If you add a `delegate_to: localhost` task, set
  `vars: {ansible_connection: local}` on it.
