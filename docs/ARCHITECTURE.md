# sigmond-rac — Architecture

How a sigmond/DASI2 station behind NAT becomes reachable by its
administrators, without port forwarding, a public IP, or anything new
listening on the open internet.

Every Remote Access Channel in the WsprDaemon/HamSCI world is the same
trick: an `frpc` process on the station dials **out** to a gateway's `frps`
and holds the connection open, and the gateway republishes the station's
local services at remote ports. What differs between deployments is *which
gateway*, *how the station proves who it is*, and *how many connections a
site holds*.

## Two deployments, two shapes

| | WsprDaemon station | sigmond / DASI2 station (this repo) |
|---|---|---|
| Client | [wd-rac-client](https://github.com/rrobinett/wd-rac-client) | sigmond-rac |
| Gateway | `gw2.wsprdaemon.org` (+ `gw1` standby) | `vpn.hamsci.org` |
| Admission | registrar assigns the RAC number and ports; frps auth plugin checks the key against a registered account | trust-on-first-use: the pubkey in the login metadata claims a user id; **no registrar, no accounts** |
| Connections per site | **one** | **two** |
| What rides them | ssh, ka9q-web, and — where configured — the PSWS/GRAPE WWV carrier charts, all on the single connection | hypervisor: ssh + Proxmox UI · VM: ssh, web, and whatever the station grows |

There is no host/hypervisor in the WsprDaemon case — the station *is* the
machine, so one frpc with several proxies covers it. A DASI2 site is a
Proxmox host running the station as a VM, so it holds two independent
tunnels: one for the hypervisor, one for the guest.

## The picture

```
 DASI2 site (behind NAT)                    vpn.hamsci.org                     Admins
┌────────────────────────────────┐      ┌─────────────────────────────┐
│ Proxmox host                   │      │  frps-secure :35736         │
│  ├ sshd  :22       ──host-ssh──┼──┐   │   TLS forced + TOFU plugin  │
│  ├ PVE UI:8006     ──host-ui───┼──┤   │                             │
│  └ frpc  sigmond-rac-host      │  └──►│  frps (legacy open) :35735  │
│                                │ TLS  │   older HamSCI stations     │
│ DASI2 VM (guest)               │      │                             │
│  ├ sshd  :22       ──vm-ssh────┼──┐   │  tunnel ports 35800–49999 ◄─┼── admins, over WireGuard
│  ├ ka9q-web :8081  ──vm-web────┼──┤   │                             │
│  └ frpc  wd-rac.service        │  └──►│  WireGuard :51820           │
│                                │ TLS  │   admins only — 10.3.2.1    │
└────────────────────────────────┘      └─────────────────────────────┘
```

Two frpc processes, two logins, two identities — but one station: both
tunnels carry the **same reporter ID** in their proxy names, so the gateway
and its dashboard show a site's hypervisor and VM together.

Volunteers' stations never run WireGuard; admins never run frpc. The
gateway is the only place the two meet, and its tunnel ports are reachable
only from the admin VPN.

## Identity: trust on first use

`vpn.hamsci.org` runs **two** frps instances. `:35735` is the original open
one that older HamSCI volunteer stations still use. `:35736` is
`frps-secure`, which forces TLS and gates every login through a TOFU auth
plugin — this is the one sigmond stations use, and it needs no registrar
and creates no accounts.

An frpc login is admitted when:

1. it carries a **user id** and a **pubkey** in `[metadatas]`; and
2. either that user id has never been seen — the gateway **files** the key
   against it, first come first served — or the presented key **matches**
   the one already on file.

A different key claiming a taken id is refused. So the pubkey is the
identity, and the frps `token` is not the gate at all: it is empty by
design. Nothing secret goes into `frpc.toml` — a stolen config lets nobody
in, because the private key never leaves the station.

Two consequences worth knowing before they bite:

- **The hypervisor and the VM need separate ids.** One key is filed per user
  id, so two tunnels sharing an id would see the second refused as an
  impersonation attempt. sigmond-rac gives each its own keypair and its own
  id: the assigned DASI number when there is one
  (`SIGMOND_DASI_ID` / `SIGMOND_DASI_HOST_ID`, or `DASI_ID` / `DASI_HOST_ID`
  in `coordination.env`), otherwise `<reporter ID>-vm` and
  `<reporter ID>-host`.
- **Re-keying needs an admin.** Reinstall a station from scratch and it
  generates a new keypair; the gateway still holds the old one against that
  id and refuses the new key. The admin deletes the registry entry — which
  is also how access is revoked.

TLS is forced by the server, but its certificate is self-signed and no CA
is published, so the client enables TLS without pinning a `trustedCaFile`.
Encryption comes from TLS; identity comes from the key.

## What rides each connection

| Tunnel | Unit | Config | Proxy | Local |
|---|---|---|---|---|
| hypervisor | `sigmond-rac-host.service` | `/etc/sigmond/frpc-host.toml` | `<reporter ID>-host-ssh` | sshd :22 |
| | | | `<reporter ID>-host-ui` | Proxmox VE web UI :8006 |
| VM | `wd-rac.service` | `/etc/sigmond/frpc.toml` | `<reporter ID>-vm-ssh` | sshd :22 |
| | | | `<reporter ID>-vm-web` | ka9q-web :8081 |

The hypervisor tunnel exists for the case where remote hands matter most —
**the VM is down or being rebuilt** — which is why it carries the Proxmox UI
as well as ssh: a browser onto the hypervisor can rebuild what ssh cannot.

The VM tunnel carries whatever the station serves, and that list is open:
a further service gets one more `[[proxies]]` block named for its band, in
`frpc.toml`. WsprDaemon stations already do this for the PSWS/GRAPE WWV
carrier charts (`vm-grape`, local :8088); a DASI2 station that grows one
follows the same pattern.

The band suffixes (`-vm-ssh`, `-vm-web`, `-host-ssh`, `-host-ui`) are not
decoration: the rac-dashboard keys on them to group a site's tunnels. The
gateway prefixes each with the login id, so a site shows up there as
`DASI-099.AI6VN-vm-ssh` and friends.

Nothing on the station starts listening on a new port as a result: frpc's
own status UI is bound to `127.0.0.1:7500`, and sshd is reached through the
tunnel (and however it was already reachable on the site LAN).

## Ports

Remote ports are assigned by the WsprDaemon admin and pasted into the
config; this component never picks one. The gateway accepts tunnel ports in
**35800–49999**, and the fleet convention is one number per station with a
base per band — `35800 + n` for ssh, `45800 + n` for web, and so on, the
scheme wd-rac-client's registrar hands out automatically. A site's two
tunnels must not share a port: to the gateway they are two clients.

Reusing another station's port collides on the gateway (`RAC-C-004`); frps
is the final arbiter and rejects the proxy with `port already used`.

## Inert by design

Every sigmond install carries the full RAC footprint — the per-arch vendored
`frpc` (amd64 / arm64 / armhf, no build step, no download), the unit, and a
rendered config *template* — and the unit is **enabled**. It still never
starts, because it is gated on
`ConditionPathExists=/etc/sigmond/frpc.toml`. Installing RAC therefore
cannot expose a station, and an unconfigured unit does not fail-loop.

The installer fills in everything it can know by itself: the proxy names,
the station's keypair and pubkey metadata, and the login id. What it cannot
know is the port assignment, so arming stays one deliberate operator action:

```bash
sudo cp /etc/sigmond/frpc.toml.template /etc/sigmond/frpc.toml   # after filling the <...> ports
sudo systemctl restart wd-rac
```

Re-running the installer is idempotent, rewrites only the *template*, and
leaves an armed tunnel running.

## Reaching a station

Admins reach the tunnel ports over WireGuard to the gateway — never from
the open internet:

```bash
ssh -p <assigned vm-ssh port> <station-user>@10.3.2.1
```

On the WsprDaemon side the same role is played by that gateway's tiers
(`wd-mesh` 10.112.0.2 for admins, `wd-rac` 10.111.220.1 for station
operators), enforced with per-interface firewall rules.

Observability is thin, by design and by gap (`RAC-Q-010`):
`systemctl status wd-rac` or `sigmond-rac-host`, frpc's journald log, its
local status UI on `127.0.0.1:7500`, and the gateway's dashboard — the only
view that answers "is this station actually *reachable*", which the station
itself cannot tell you.

## Deliberate differences from wd-rac-client

Both are frpc reverse tunnels; these are the places sigmond-rac diverges,
and why.

| | wd-rac-client | sigmond-rac |
|---|---|---|
| Gateways | one frpc instance per gateway (`@gw2` primary, `@gw1` standby), same identity at each, so failover is a property rather than a procedure | one gateway; if `vpn.hamsci.org` is down the site is unreachable |
| Provisioning | registrar returns gateways, token, user id and the whole port table | TOFU needs no registration; the admin still allocates remote ports out of band |
| Arming | the installer registers and starts the tunnel, confirming it came up | inert until an operator arms it |
| frpc binary | downloaded from the frp release for the local arch | vendored per-arch blobs in `bin/` — no network at install, but unpinned (`RAC-Q-011`) |
| Privilege | runs as a dedicated `wd-rac` system user with `NoNewPrivileges`, `ProtectSystem=strict` | runs as root: a Proxmox host is administered as root and has no ordinary accounts, and an account per hypervisor is not worth the sandboxing. systemd's own confinement on the existing unit is the cheaper route if it is ever wanted |
| Upgrades | add-before-remove under a dead-man rollback timer, because the tunnel being replaced is usually the only way in | re-run the installer; an armed tunnel keeps running, but there is no rollback rail |

## Open items

- **Single gateway.** Adopting the per-gateway instance model would need a
  second HamSCI frps; the client side is a templated unit away.
- **Port allocation is manual.** There is no registrar in the TOFU model, so
  nothing stops two sites being handed the same port except the admin's
  records and frps rejecting the second one.
- **`smd admin rac register` is a gw2 mechanism.** It files a key with
  gw2's registration drop, which the HamSCI gateway does not use, so
  `install.sh` skips it unless `SIGMOND_RAC_REGISTER=yes`.
- **DASI numbering.** Who assigns `DASI-NNN`, and whether a site's
  hypervisor and VM get two numbers or one number plus a suffix, is a
  convention this component follows rather than defines.

## Related repositories

- **sigmond-rac** (this repo): everything installed on the station and on its
  Proxmox host. Spec: [docs/REQUIREMENTS.md](REQUIREMENTS.md).
- **[wd-rac-client](https://github.com/rrobinett/wd-rac-client)**: the
  WsprDaemon RAC client — registrar-driven, dual-gateway, self-arming.
- **[sigmond](https://github.com/HamSCI/sigmond)**: installs this component
  (`smd install sigmond-rac`) and hosts the TUI **RAC** screen.
- The gateway side — frps, the TOFU plugin and its registry, the dashboard,
  WireGuard and its user management — lives on the servers themselves and in
  WsprDaemon's private repos.
