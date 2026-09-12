#!/usr/bin/env bash
# sigmond-rac — install the Remote Access Channel on the PROXMOX HOST.
#
# The guest install (install.sh) tunnels the DASI2 VM; this installs a
# SECOND, independent frpc on the hypervisor so the site stays reachable
# even when the VM is down or being rebuilt.  Publishes the host's own
# services: its sshd (host-ssh) and the Proxmox VE web UI (host-ui).  Same inert-until-configured model: the unit's
# ConditionPathExists keeps it dormant until the operator fills
# /etc/sigmond/frpc-host.toml with the admin-assigned remotePorts (which
# must be distinct from the guest's).
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

# 2. frps TLS CA
install -d -m 0755 /etc/sigmond
install -m 0644 -o root -g root "$SCRIPT_DIR/frps-ca.crt" /etc/sigmond/frps-ca.crt

# 3. systemd unit
install -m 0644 -o root -g root "$SCRIPT_DIR/systemd/sigmond-rac-host.service" \
        /etc/systemd/system/sigmond-rac-host.service

# 4. render the host-specific template (proxy name from identity)
#    Same identity as the guest: the proxy name is the station's reporter ID
#    with the band suffix the rac-dashboard keys on ("-host-ssh" is
#    added by the template).  Resolve from the env (the proxmox bootstrap
#    passes the identity bag through), else the station's coordination.env.
#    No default callsign: a wrong one here books this hypervisor onto
#    someone else's account on the gateway.
coord_get() {
  sed -n "s/^$1=//p" /etc/sigmond/coordination.env 2>/dev/null \
    | head -1 | tr -d "\"'"
}
call="${STATION_REPORTER_ID:-${STATION_CALL:-}}"
if [ -z "$call" ]; then
  call="$(coord_get STATION_REPORTER_ID)"
  [ -n "$call" ] || call="$(coord_get STATION_CALL)"
fi
if [ -n "$call" ]; then
  proxy="$call"
else
  proxy="<REPORTER_ID>"
  log "WARNING: station reporter ID not configured — rendering the template"
  log "  with a <REPORTER_ID> placeholder.  Fill it in with the station's"
  log "  reporter ID (the same one the guest VM registers under) before"
  log "  activating the host tunnel."
fi
#    The hypervisor logs in to vpn.hamsci.org separately from the VM, and
#    the gateway files ONE pubkey per user id — so this tunnel needs its own
#    keypair and its own id, or it would collide with the VM's claim and be
#    refused.  Prefer an assigned DASI number for the host; otherwise derive
#    the "-host" counterpart of the VM's id.
KEY=/etc/sigmond/frpc-host_id_ed25519
if [ ! -f "$KEY.pub" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "sigmond-rac-host@$(hostname -s)" -f "$KEY"
  chmod 600 "$KEY"; chmod 644 "$KEY.pub"
  log "generated hypervisor keypair $KEY"
fi
pubkey="$(cat "$KEY.pub")"

dasi="${SIGMOND_DASI_HOST_ID:-${DASI_HOST_ID:-}}"
[ -n "$dasi" ] || dasi="$(coord_get DASI_HOST_ID)"
if [ -n "$dasi" ]; then
  user="$dasi"
elif [ "$proxy" != "<REPORTER_ID>" ]; then
  user="${proxy}-host"
else
  user="<DASI_ID_OR_STATION_ID>"
fi

tmpl="/etc/sigmond/frpc-host.toml.template"
sed -e "s|@PROXY@|${proxy}|g" \
    -e "s|@USER@|${user}|g" \
    -e "s|@SITE@|${proxy}|g" \
    -e "s|@DASI@|${dasi}|g" \
    -e "s|@PUBKEY@|${pubkey}|g" \
    "$SCRIPT_DIR/config/frpc-host.toml.template" > "$tmpl"
chmod 0640 "$tmpl"
log "wrote $tmpl (proxy '${proxy}', gateway id '${user}')"

# 5. enable (inert via ConditionPathExists until configured)
systemctl daemon-reload 2>/dev/null || true
systemctl enable sigmond-rac-host.service 2>/dev/null || true

if [ -f /etc/sigmond/frpc-host.toml ]; then
  log "frpc-host.toml present — (re)starting sigmond-rac-host"
  systemctl restart sigmond-rac-host.service 2>/dev/null || true
else
  log "NOT configured (no /etc/sigmond/frpc-host.toml) — host RAC stays inert."
  log "  activate: fill $tmpl with the remotePorts assigned by the"
  log "  WsprDaemon admin (remotePort distinct from the guest VM's), then:"
  log "    cp $tmpl /etc/sigmond/frpc-host.toml && systemctl restart sigmond-rac-host"
fi
