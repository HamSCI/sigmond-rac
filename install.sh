#!/usr/bin/env bash
# sigmond-rac — install the WsprDaemon Remote Access Channel (frpc reverse tunnel).
#
# Provisions the vendored frpc binary (per-arch), the frps TLS CA, the
# wd-rac.service unit, and a station-specific frpc.toml TEMPLATE.  Also
# ensures the station's SSH keypair exists and its public key is registered
# on the gateway (via `smd admin rac register`), so a greenfield install can
# bring the tunnel up without the admin hand-installing keys.  It enables
# the unit so RAC is part of the install footprint, but the unit's
# ConditionPathExists=/etc/sigmond/frpc.toml guard keeps it INERT until the
# operator fills in the remotePort assignment from the WsprDaemon admin.  Idempotent.  Run by `smd install sigmond-rac` (as root via sudo).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FRP_VER="0.64.0"
log() { echo "rac: $*"; }

# 1. resolve + install the vendored frpc binary for this arch
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
install -m 0644 -o root -g root "$SCRIPT_DIR/systemd/wd-rac.service" \
        /etc/systemd/system/wd-rac.service

# 4. render the station-specific frpc.toml template
#    The proxy name IS the station's reporter ID, exactly — the unique
#    identity it uploads to wsprnet.org under — plus the band suffix the
#    rac-dashboard keys on (-vm-ssh, -vm-web), which the template supplies.
#    Resolve from the env (smd install passes the identity bag through),
#    else the station's coordination.env.  When neither defines it, render
#    a placeholder and warn — the operator must configure identity BEFORE
#    the RAC can be activated; baking in a default callsign here is how
#    wrong accounts end up on the gateway.
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
  log "  with a <REPORTER_ID> placeholder.  Configure identity first"
  log "  (smd config identity), then re-run:  smd install sigmond-rac"
fi
#    vpn.hamsci.org's frps admits a login that presents a user id and this
#    station's public key in [metadatas]: the first login to claim a user id
#    files its key, and later logins must present the same one (trust on
#    first use).  So the keypair must exist BEFORE the template is rendered,
#    and the template carries the pubkey, not a secret.
KEY=/etc/sigmond/frpc_id_rsa
if [ ! -f "$KEY.pub" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "wd-rac@$(hostname -s)" -f "$KEY"
  chmod 600 "$KEY"; chmod 644 "$KEY.pub"
  log "generated station keypair $KEY"
fi
pubkey="$(cat "$KEY.pub")"

#    The user id is this tunnel's stable identity on the gateway, and the
#    VM and the hypervisor must not share one (the gateway files a single
#    key per id).  Prefer the assigned DASI number; otherwise derive one
#    from the reporter ID, with the hypervisor's "-host" counterpart
#    rendered by install-host.sh.
dasi="${SIGMOND_DASI_ID:-${DASI_ID:-}}"
[ -n "$dasi" ] || dasi="$(coord_get DASI_ID)"
if [ -n "$dasi" ]; then
  user="$dasi"
elif [ "$proxy" != "<REPORTER_ID>" ]; then
  user="${proxy}-vm"
else
  user="<DASI_ID_OR_STATION_ID>"
fi

tmpl="/etc/sigmond/frpc.toml.template"
sed -e "s|@PROXY@|${proxy}|g" \
    -e "s|@USER@|${user}|g" \
    -e "s|@SITE@|${proxy}|g" \
    -e "s|@DASI@|${dasi}|g" \
    -e "s|@PUBKEY@|${pubkey}|g" \
    "$SCRIPT_DIR/config/frpc.toml.template" > "$tmpl"
chmod 0640 "$tmpl"
log "wrote $tmpl (proxy '${proxy}', gateway id '${user}')"

# 5. gateway key registration — NOT needed on vpn.hamsci.org
#    That gateway authenticates by trust-on-first-use: the station presents
#    its pubkey in the frpc login metadata (rendered into the template in
#    step 4), the first login claims the user id, and no account exists
#    server-side to provision.  gw2's model is the other one — an account +
#    authorized_keys auto-provisioned from a registration drop — and
#    `smd admin rac register` is what files a key there.  Run it only for a
#    station aimed at gw2 rather than at vpn.hamsci.org.
if [ "${SIGMOND_RAC_REGISTER:-no}" = "yes" ]; then
  if command -v smd >/dev/null 2>&1 && [ "$proxy" != "<REPORTER_ID>" ]; then
    smd admin rac register --id "$proxy" \
      || log "WARNING: gateway key registration failed — see messages above;" \
             "re-run  smd admin rac register  when connectivity allows."
  else
    log "SIGMOND_RAC_REGISTER=yes but smd or the reporter ID is missing —"
    log "  run  smd admin rac register  by hand once both are in place."
  fi
else
  log "gateway is vpn.hamsci.org (trust-on-first-use) — no key registration"
  log "  needed.  For a gw2-bound station: SIGMOND_RAC_REGISTER=yes"
fi

# 6. enable (part of the install footprint); inert via ConditionPathExists
systemctl daemon-reload 2>/dev/null || true
systemctl enable wd-rac.service 2>/dev/null || true

if [ -f /etc/sigmond/frpc.toml ]; then
  log "frpc.toml present — (re)starting wd-rac"
  systemctl restart wd-rac.service 2>/dev/null || true
else
  log "NOT configured (no /etc/sigmond/frpc.toml) — RAC stays inert."
  log "  activate: fill $tmpl with the remotePort(s) assigned by the"
  log "  WsprDaemon admin, then:"
  log "    sudo cp $tmpl /etc/sigmond/frpc.toml && sudo systemctl restart wd-rac"
fi
