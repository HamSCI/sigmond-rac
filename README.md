# sigmond-rac — Remote Access Channel

A sigmond infrastructure component that gives the admins SSH/web access to a
NAT'd station via **frpc reverse tunnels** to HamSCI's gateway,
`vpn.hamsci.org:35736`.  Derived from the legacy wsprdaemon-client's
`wd-rac`, repackaged so every sigmond install can carry it.

A DASI2 site holds **two** tunnels: the Proxmox host publishes its sshd and
the PVE web UI (`-host-ssh`, `-host-ui`), and the VM publishes the station's
sshd and web (`-vm-ssh`, `-vm-web`).

Docs: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the tunnels, the
gateway, and the access tiers fit together · [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)
— the `RAC-*` spec.

## What it installs
- `/usr/local/sbin/frpc` — vendored frp client (per-arch, under `bin/`)
- `/etc/sigmond/frpc_id_rsa[.pub]` — the station's identity keypair; the
  public half goes into the config's `[metadatas]`, and the gateway files it
  against this station's login id on first use
- `/etc/sigmond/frps-ca.crt` — frps TLS CA (for a gw2-bound config; the
  HamSCI gateway's certificate is self-signed and pins nothing)
- `/etc/systemd/system/wd-rac.service` — the tunnel unit (enabled, but inert
  via `ConditionPathExists=/etc/sigmond/frpc.toml`)
- `/etc/sigmond/frpc.toml.template` — station-specific, with the proxy names
  filled in as `<reporter ID>-vm-ssh` / `-vm-web` (the band suffixes the
  rac-dashboard groups on); `<...>` placeholders for the assigned ports

## Activating
The installer fills in everything it can know: proxy names, the station's
pubkey metadata, and its login id.  What it cannot know is the **unique**
`remotePort`(s), which the WsprDaemon admin assigns.  Fill those into the
template, then:

```bash
sudo cp /etc/sigmond/frpc.toml.template /etc/sigmond/frpc.toml
sudo systemctl restart wd-rac
```

Until `/etc/sigmond/frpc.toml` exists the unit never starts (no fail-loop).

## Proxmox HOST tunnel (install-host.sh)

A DASI2 site runs the station as a VM on a Proxmox host.  The guest RAC
above covers only the VM — `install-host.sh` installs a SECOND,
independent frpc **on the hypervisor** so the site stays reachable even
when the VM is down or being rebuilt.  It publishes the host's own sshd
and Proxmox VE web UI (`-host-ssh` / `-host-ui`), as unit
`sigmond-rac-host.service`, gated on
`/etc/sigmond/frpc-host.toml` (same inert-until-configured model; its
remotePort must be distinct from the guest's).  Normally delivered and
run by sigmond's proxmox bootstrap (`install_host_rac`); standalone:

```bash
# on the Proxmox host, from a sigmond-rac checkout:
sudo bash install-host.sh
# activate: fill /etc/sigmond/frpc-host.toml.template ->
#   cp ... /etc/sigmond/frpc-host.toml && systemctl restart sigmond-rac-host
```

## Adding an arch
Drop `frpc-<arch>-v<ver>` into `bin/` (from the frp release for that arch) and
bump `FRP_VER` in `install.sh`.
