# sigmond-rac — Remote Access Channel

A sigmond infrastructure component that gives the admins SSH/web access to a
NAT'd station via **frpc reverse tunnels** to HamSCI's gateway,
`vpn.hamsci.org:35736`.  Derived from the legacy wsprdaemon-client's
`wd-rac`, repackaged so every sigmond install can carry it.

A DASI2 site holds **one** login, and it runs on the Proxmox host — the
machine that is up when the VM is not.  It publishes the host's own sshd and
PVE web UI over 127.0.0.1, plus the VM's services forwarded across the bridge
to the VM's address.  How many tunnels that is depends on what the site
serves: each service gets a *band*, and its remote port is the band's
fleet-wide base plus the site's one RAC/DASI number —

    vm_ssh 35800+n · vm_grape 40800+n · vm_web 45800+n · vm_web2/3 46800/47800+n
    host_ssh 50800+n · host_ui 55800+n

Adding the magnetometer page or a GRAPE page is an entry in
`SIGMOND_RAC_PROXIES`, not a code change:

```sh
SIGMOND_RAC_PROXIES="host_ssh=22 host_ui=8006 vm_ssh=22 vm_web=8081 vm_grape=8088"
```

The band table lives in [config/rac-bands.sh](config/rac-bands.sh); a band
that is not in it yet must carry its base inline (`vm_mag:41800=8090`) —
bases are fleet-wide allocations, so the installer refuses to guess one.
A sigmond station with no hypervisor beneath it arms the guest unit instead.

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
- `/etc/sigmond/frpc.toml.template` — station-specific, with one
  `[[proxies]]` block per published service, named `<reporter ID>-<band>`
  (the suffixes the rac-dashboard groups on) and ported from the site
  number

## Activating
Given the site number (`SIGMOND_RAC_NUMBER`, or `RAC` in
`coordination.env`), the installer renders a complete config — every band's
port included.  Arming it is still deliberate:

```bash
sudo cp /etc/sigmond/frpc.toml.template /etc/sigmond/frpc.toml
sudo systemctl restart wd-rac
```

Until `/etc/sigmond/frpc.toml` exists the unit never starts (no fail-loop).

## DASI2 site tunnel (install-host.sh)

A DASI2 site runs the station as a VM on a Proxmox host, so the site's one
frpc belongs on the **hypervisor**: a tunnel inside the guest would vanish
exactly when it is most needed, while the VM is down or being rebuilt.
`install-host.sh` installs it as unit `sigmond-rac-host.service`, gated on
`/etc/sigmond/frpc-host.toml` (same inert-until-configured model).  Its four
proxies reach the host over 127.0.0.1 and the VM over the bridge, so set
`SIGMOND_VM_IP` (or `DASI_VM_IP` in `coordination.env`) to the VM's fixed
address.  On such a site the guest tunnel stays unarmed — both claim the same
login id, and the gateway refuses whichever connects second.  Normally
delivered and run by sigmond's proxmox bootstrap (`install_host_rac`);
standalone:

```bash
# on the Proxmox host, from a sigmond-rac checkout:
sudo bash install-host.sh
# activate: fill the <...> remote ports into
#   /etc/sigmond/frpc-host.toml.template ->
#   cp ... /etc/sigmond/frpc-host.toml && systemctl restart sigmond-rac-host
```

## Adding an arch
Drop `frpc-<arch>-v<ver>` into `bin/` (from the frp release for that arch) and
bump `FRP_VER` in `install.sh`.
