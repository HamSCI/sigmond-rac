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
# operator fills in the gw2 user/token/remotePort assignment from the
# WsprDaemon admin.  Idempotent.  Run by `smd install sigmond-rac` (as root via sudo).
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

# 4. render the station-specific frpc.toml template (proxy = reporter ID)
#    The proxy name IS the station's reporter ID, exactly — the unique
#    identity it uploads to wsprnet.org under.  No host/instance suffix:
#    reporter IDs are already fleet-unique, and the gw2 entries must match
#    them.  Resolve from the env (smd install passes the identity bag
#    through), else the station's coordination.env.  When neither defines
#    it, render a placeholder and warn — the operator must configure
#    identity BEFORE the RAC can be activated or registered; baking in a
#    default callsign here is how wrong accounts end up on the gateway.
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
tmpl="/etc/sigmond/frpc.toml.template"
sed "s|@PROXY@|${proxy}|g" "$SCRIPT_DIR/config/frpc.toml.template" > "$tmpl"
chmod 0640 "$tmpl"
log "wrote $tmpl (proxy '${proxy}')"

# 5. station SSH identity + gateway registration
#    The gw2 auth plugin only accepts a station whose SSH public key is
#    registered on the gateway (account + authorized_keys, auto-provisioned
#    server-side from the registration drop).  A greenfield host has neither
#    key nor account, so RAC could never come up until someone mailed the
#    key to the admin and he installed it by hand.  Delegate to
#    `smd admin rac register` — the one implementation of keypair creation
#    + gateway registration (idempotent via /etc/sigmond/.rac-registered).
if command -v smd >/dev/null 2>&1; then
  if [ "$proxy" != "<REPORTER_ID>" ]; then
    smd admin rac register --id "$proxy" \
      || log "WARNING: gateway key registration failed — see messages above;" \
             "re-run  smd admin rac register  when connectivity allows."
  else
    log "station reporter ID not configured — skipping gateway key registration."
    log "  run  smd admin rac register  after  smd config identity"
  fi
else
  # standalone run (no smd on PATH): still guarantee the station keypair,
  # and tell the operator how to finish registration.
  KEY=/etc/sigmond/frpc_id_rsa
  if [ ! -f "$KEY.pub" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "wd-rac@$(hostname -s)" -f "$KEY"
    chmod 600 "$KEY"; chmod 644 "$KEY.pub"
    log "generated station SSH keypair $KEY"
  fi
  log "smd not found — run  smd admin rac register  once sigmond is"
  log "  installed, or send this public key to the WsprDaemon admin:"
  log "    $(cat "$KEY.pub")"
fi

# 6. enable (part of the install footprint); inert via ConditionPathExists
systemctl daemon-reload 2>/dev/null || true
systemctl enable wd-rac.service 2>/dev/null || true

if [ -f /etc/sigmond/frpc.toml ]; then
  log "frpc.toml present — (re)starting wd-rac"
  systemctl restart wd-rac.service 2>/dev/null || true
else
  log "NOT configured (no /etc/sigmond/frpc.toml) — RAC stays inert."
  log "  activate: fill $tmpl with the gw2 user/token/remotePort(s) from the"
  log "  WsprDaemon admin, then:"
  log "    sudo cp $tmpl /etc/sigmond/frpc.toml && sudo systemctl restart wd-rac"
fi
