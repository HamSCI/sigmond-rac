#!/usr/bin/env bash
# sigmond-rac — install the Remote Access Channel on the PROXMOX HOST.
#
# On a DASI2 site this is THE install: one frpc, one login, running on the
# hypervisor — the machine that is up when the VM is not.  It carries the
# host's own sshd (host-ssh) and Proxmox VE web UI (host-ui) over
# 127.0.0.1, plus the DASI2 VM's sshd (vm-ssh) and web (vm-web) forwarded
# across the bridge to the VM's address.  The guest install (install.sh) is
# for a sigmond station with no hypervisor beneath it; on a DASI2 site its
# tunnel is left unarmed, since the gateway files one key per login id and
# the second claimant is refused.  Same inert-until-configured model: the unit's
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
#    This is the site's single login, so it carries the site's identity:
#    the assigned DASI number when there is one, else the reporter ID.  The
#    keypair lives on the hypervisor because that is where the frpc runs.
KEY=/etc/sigmond/frpc-host_id_ed25519
if [ ! -f "$KEY.pub" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "sigmond-rac-host@$(hostname -s)" -f "$KEY"
  chmod 600 "$KEY"; chmod 644 "$KEY.pub"
  log "generated hypervisor keypair $KEY"
fi
pubkey="$(cat "$KEY.pub")"

dasi="${SIGMOND_DASI_ID:-${DASI_ID:-}}"
[ -n "$dasi" ] || dasi="$(coord_get DASI_ID)"
if [ -n "$dasi" ]; then
  user="$dasi"
elif [ "$proxy" != "<REPORTER_ID>" ]; then
  user="$proxy"
else
  user="<DASI_ID_OR_STATION_ID>"
fi

#    The VM's address as the hypervisor sees it — the vm-ssh/vm-web proxies
#    forward there instead of to 127.0.0.1.  It must be fixed (static lease
#    or reservation): if the VM moves, those proxies would publish whoever
#    now answers at the old address.
vm_ip="${SIGMOND_VM_IP:-${DASI_VM_IP:-}}"
[ -n "$vm_ip" ] || vm_ip="$(coord_get DASI_VM_IP)"
if [ -z "$vm_ip" ]; then
  vm_ip="<VM_IP>"
  log "WARNING: the DASI2 VM's address is not configured — rendering the"
  log "  template with a <VM_IP> placeholder.  Set SIGMOND_VM_IP (or"
  log "  DASI_VM_IP in coordination.env), or fill it in before activating."
fi

tmpl="/etc/sigmond/frpc-host.toml.template"
sed -e "s|@PROXY@|${proxy}|g" \
    -e "s|@USER@|${user}|g" \
    -e "s|@SITE@|${proxy}|g" \
    -e "s|@DASI@|${dasi}|g" \
    -e "s|@VM_IP@|${vm_ip}|g" \
    -e "s|@PUBKEY@|${pubkey}|g" \
    "$SCRIPT_DIR/config/frpc-host.toml.template" > "$tmpl"
chmod 0640 "$tmpl"
log "wrote $tmpl (proxy '${proxy}', gateway id '${user}', VM at ${vm_ip})"

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
