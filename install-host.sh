#!/usr/bin/env bash
# sigmond-rac — install the Remote Access Channel on the PROXMOX HOST.
#
# The guest install (install.sh) tunnels the DASI2 VM; this installs a
# SECOND, independent frpc on the hypervisor so the site stays reachable
# even when the VM is down or being rebuilt.  Publishes the host's own
# sshd only.  Same inert-until-configured model: the unit's
# ConditionPathExists keeps it dormant until the operator fills
# /etc/sigmond/frpc-host.toml with the admin-assigned user/token/
# remotePort (which must be distinct from the guest's).
#
# Self-contained: expects its payload beside it (bin/frpc-<arch>,
# frps-ca.crt, config/frpc-host.toml.template,
# systemd/sigmond-rac-host.service).  Normally delivered + run by
# sigmond's proxmox bootstrap (which scp's the payload to /tmp/rac-host/),
# but runs standalone from a sigmond-rac checkout too.  Idempotent.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FRP_VER="0.64.0"
log() { echo "rac-host: $*"; }

[ "$(id -u)" = 0 ] || { log "run as root on the Proxmox host"; exit 1; }

# 1. vendored frpc binary for this arch
arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$arch" in
  amd64|x86_64)   binfile="frpc-amd64-v${FRP_VER}" ;;
  arm64|aarch64)  binfile="frpc-arm64-v${FRP_VER}" ;;
  armhf|armv7l)   binfile="frpc-armhf-v${FRP_VER}" ;;
  *) log "unsupported arch '$arch' — add a vendored frpc binary for it"; exit 1 ;;
esac
src="$SCRIPT_DIR/bin/$binfile"
[ -x "$src" ] || { log "vendored frpc missing for $arch ($src)"; exit 1; }
install -m 0755 -o root -g root "$src" /usr/local/sbin/frpc
log "installed /usr/local/sbin/frpc ($($src --version 2>/dev/null || echo "$FRP_VER"))"

# 2. frps TLS CAs — ONE PER GATEWAY.
#
# ⛔ There is no single "the" frps CA, and pretending there is broke every
# HamSCI station.  gw2.wsprdaemon.org presents CN=GW2.WSPRDAEMON.ORG; vpn1 and
# vpn2.hamsci.org present CN=vpn.hamsci.org.  Until 2026-10-24 this script
# installed gw2's cert over /etc/sigmond/frps-ca.crt unconditionally, so a
# HamSCI station pinned the wrong CA, could not complete a TLS login to either
# HamSCI gateway, and fell silently down its tier ladder to the legacy OPEN
# port 35735.  Measured on AI6VN that day: pinned EC:71:A9:00:17:77:28:4E:...,
# gateways presenting 7A:F8:BF:F8:E4:3D:C1:F4:...
#
# Worse, it re-clobbered the file on every run, so correcting the cert on the
# station did not hold.  Each gateway's CA now lands at its OWN path and the
# config names the one it needs.
install -d -m 0755 /etc/sigmond
install -m 0644 -o root -g root "$SCRIPT_DIR/frps-ca-gw2.crt"    /etc/sigmond/frps-ca-gw2.crt
install -m 0644 -o root -g root "$SCRIPT_DIR/frps-ca-hamsci.crt" /etc/sigmond/frps-ca-hamsci.crt
# The legacy path, for a station still running a config that names it.  Seeded
# once and NEVER overwritten: a station whose cert was corrected by hand keeps
# the correction.
[ -e /etc/sigmond/frps-ca.crt ] || \
    install -m 0644 -o root -g root "$SCRIPT_DIR/frps-ca-gw2.crt" /etc/sigmond/frps-ca.crt

# 3. systemd units — the legacy single-tunnel unit, and the per-gateway
#    template (`sigmond-rac-host@vpn1`, `@vpn2`) that replaces it.
install -m 0644 -o root -g root "$SCRIPT_DIR/systemd/sigmond-rac-host.service" \
        /etc/systemd/system/sigmond-rac-host.service
install -m 0644 -o root -g root "$SCRIPT_DIR/systemd/sigmond-rac-host@.service" \
        /etc/systemd/system/sigmond-rac-host@.service

# 4. render the host-specific template (proxy name from identity)
call="${STATION_CALL:-AC0G}"
site="${SIGMOND_SITE:-$(hostname -s 2>/dev/null || echo host)}"
proxy="${call}/$(printf '%s' "$site" | tr '[:lower:]' '[:upper:]')-HOST"
tmpl="/etc/sigmond/frpc-host.toml.template"
sed "s|@PROXY@|${proxy}|g" "$SCRIPT_DIR/config/frpc-host.toml.template" > "$tmpl"
chmod 0640 "$tmpl"
log "wrote $tmpl (proxy '${proxy}')"

# 5. enable (inert via ConditionPathExists until configured)
systemctl daemon-reload 2>/dev/null || true
systemctl enable sigmond-rac-host.service 2>/dev/null || true

if [ -f /etc/sigmond/frpc-host.toml ]; then
  log "frpc-host.toml present — (re)starting sigmond-rac-host"
  systemctl restart sigmond-rac-host.service 2>/dev/null || true
else
  log "NOT configured (no /etc/sigmond/frpc-host.toml) — host RAC stays inert."
  log "  activate: fill $tmpl with the gw2 user/token/remotePort from the"
  log "  WsprDaemon admin (remotePort distinct from the guest VM's), then:"
  log "    cp $tmpl /etc/sigmond/frpc-host.toml && systemctl restart sigmond-rac-host"
fi
