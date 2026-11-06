# reboot-guard: one noarch RPM for RHEL 7, 8, 9, 10.
# Built FROM the plain files in files/ and bin/ (no second copy of the guard); see TESTING.md.
#
# RHEL 7 (rpm 4.11) cannot read zstd payloads, RHEL 10 builds zstd by default: force xz.
%define _binary_payload w9.xzdio
%define _source_payload w9.xzdio
# One package for every release: no %%{dist} tag.
%define dist %{nil}
# Hard-coded, not %%{_unitdir}: systemd-rpm-macros is not on every builder / el7.
%define unitdir /usr/lib/systemd/system
# Ship bin/reboot-guard byte-identical (#!/bin/bash; el7-10 bash all provide /bin/bash).
%undefine __brp_mangle_shebangs
%define cad /etc/systemd/system/ctrl-alt-del.target
# Own backup name, so it never collides with the helper's .reboot-guard-orig.
%define cad_backup %{cad}.reboot-guard-rpm-orig
%{!?rel: %define rel 1}

Name:           reboot-guard
Version:        2.0.2
Release:        %{rel}
Summary:        Block accidental reboot and shutdown
License:        MIT
URL:            https://github.com/pbuchan-rh/reboot-guard
# git archive --format=tar.gz --prefix=reboot-guard-VERSION/ HEAD (make tarball)
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch
Requires:       systemd

%description
Refuses accidental reboot, shutdown, poweroff and halt on RHEL 7-10.
"reboot-guard allow-once --reason TEXT" allows the next reboot only.
An accident guard, not a security boundary: "systemctl reboot --force" still works.

%prep
%setup -q

%build

%install
rm -f files.list
# Every <unit>.d/50-reboot-guard.conf in files/ -> /usr/lib/systemd/system/<unit>.d/
for f in files/etc/systemd/system/*.d/50-reboot-guard.conf; do
    d=$(basename "$(dirname "$f")")
    install -D -p -m 0644 "$f" %{buildroot}%{unitdir}/$d/50-reboot-guard.conf
    echo "%dir %{unitdir}/$d" >> files.list
    echo "%{unitdir}/$d/50-reboot-guard.conf" >> files.list
done
install -D -p -m 0644 files/etc/systemd/system.conf.d/50-reboot-guard.conf \
    %{buildroot}/usr/lib/systemd/system.conf.d/50-reboot-guard.conf
# ctrl-alt-del.target is systemd's in /usr/lib: the mask (-> /dev/null) goes in /etc, as in files/.
mkdir -p %{buildroot}/etc/systemd/system
cp -P files/etc/systemd/system/ctrl-alt-del.target %{buildroot}%{cad}
install -D -p -m 0755 bin/reboot-guard %{buildroot}/usr/sbin/reboot-guard

%pre
# Fresh install: keep whatever sits at the Ctrl-Alt-Del path (RHEL's alias -> reboot.target, a STIG
# mask, the helper's mask) so erase can put it back. rpm then replaces it with the packaged mask.
if [ "$1" -eq 1 ] && { [ -e %{cad} ] || [ -L %{cad} ]; } && ! { [ -e %{cad_backup} ] || [ -L %{cad_backup} ]; }; then
    mv -f %{cad} %{cad_backup} || :
fi
exit 0

%post
# No running systemd in a container build: skip the reloads there, never fail.
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || :
    systemctl daemon-reexec >/dev/null 2>&1 || :   # picks up CtrlAltDelBurstAction=none
fi
if [ -e /etc/systemd/system/reboot-guard.service ] || [ -e /etc/systemd/system/shutdown.target.requires/reboot-guard.service ]; then
    echo "reboot-guard: warning: old KB 1580343 guard found; it blocks allow-once too" >&2
fi
if [ -e /etc/systemd/system/reboot.target.d/50-reboot-guard.conf ]; then
    echo "reboot-guard: note: copied guard files in /etc override this package" >&2
fi
exit 0

%preun
# Erase only (not upgrade): drop any pending allow-once.
if [ "$1" -eq 0 ]; then
    for f in /run/systemd/system/*.d/99-reboot-guard-allow.conf; do
        [ -e "$f" ] || continue
        rm -f "$f"; rmdir "$(dirname "$f")" 2>/dev/null
    done
fi
exit 0

%postun
if [ "$1" -eq 0 ]; then
    # rpm removed the packaged mask: restore what was there before install.
    if { [ -e %{cad_backup} ] || [ -L %{cad_backup} ]; } && ! { [ -e %{cad} ] || [ -L %{cad} ]; }; then
        mv -f %{cad_backup} %{cad} || :
    fi
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload >/dev/null 2>&1 || :
        systemctl daemon-reexec >/dev/null 2>&1 || :
    fi
fi
exit 0

%files -f files.list
%license LICENSE
%doc README.md
%dir /usr/lib/systemd/system.conf.d
/usr/lib/systemd/system.conf.d/50-reboot-guard.conf
%{cad}
/usr/sbin/reboot-guard

%changelog
* Thu Nov 05 2026 Peter Buchan <pbuchan@redhat.com> - 2.0.2-1
- 2.0.2: helper install refuses in image mode when the image has no guard

* Thu Nov 05 2026 Peter Buchan <pbuchan@redhat.com> - 2.0.1-1
- 2.0.1: drop dead README links from the KB 1580343 messages (helper, install
  scriptlet); updated README; no guard changes

* Thu Nov 05 2026 Peter Buchan <pbuchan@redhat.com> - 2.0.0-1
- 2.0.0: guard drop-ins in /usr/lib, Ctrl-Alt-Del mask in /etc, helper in /usr/sbin;
  allow-once needs --reason
