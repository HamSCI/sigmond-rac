# sigmond-rac — Remote Access Channel

A sigmond infrastructure component that gives the WsprDaemon admin SSH/web
access to a NAT'd station via an **frpc reverse tunnel** to
`gw2.wsprdaemon.org`.  Derived from the legacy wsprdaemon-client's `wd-rac`,
repackaged so every sigmond install can carry it.

## What it installs
- `/usr/local/sbin/frpc` — vendored frp client (per-arch, under `bin/`)
- `/etc/sigmond/frps-ca.crt` — frps TLS CA
- `/etc/systemd/system/wd-rac.service` — the tunnel unit (enabled, but inert
  via `ConditionPathExists=/etc/sigmond/frpc.toml`)
- `/etc/sigmond/frpc.toml.template` — station-specific, with the proxy name
  filled from `STATION_CALL`/instance; `<...>` placeholders for the gw2
  assignment

## Activating
The per-station `user`, `token`, and **unique** `remotePort`(s) are assigned on
`gw2` by the WsprDaemon admin.  Fill them into the template, then:

```bash
sudo cp /etc/sigmond/frpc.toml.template /etc/sigmond/frpc.toml
sudo systemctl restart wd-rac
```

Until `/etc/sigmond/frpc.toml` exists the unit never starts (no fail-loop).

## Adding an arch
Drop `frpc-<arch>-v<ver>` into `bin/` (from the frp release for that arch) and
bump `FRP_VER` in `install.sh`.
