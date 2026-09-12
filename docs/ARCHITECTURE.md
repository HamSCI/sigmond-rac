# sigmond-rac — Architecture

How a sigmond/DASI2 station behind NAT becomes reachable by its
administrators, without port forwarding, a public IP, or anything new
listening on the open internet.

Every Remote Access Channel in the WsprDaemon/HamSCI world is the same
trick: an `frpc` process dials **out** to a gateway's `frps` and holds the
connection open, and the gateway republishes local services at remote ports.
What differs between deployments is *which gateway*, *how the client proves
who it is*, and *which machine holds the connection*.

## One login per site

A site has **one** RAC login, whatever its shape. That login carries every
service the site publishes, as one `[[proxies]]` block each.

| | WsprDaemon station | sigmond / DASI2 site (this repo) |
|---|---|---|
| Client | [wd-rac-client](https://github.com/rrobinett/wd-rac-client) | sigmond-rac |
| Gateway | `gw2.wsprdaemon.org` (+ `gw1` standby) | `vpn.hamsci.org` |
| Admission | registrar assigns the RAC number and ports; the frps auth plugin checks the key against a registered account | trust-on-first-use: the pubkey in the login metadata claims a user id — **no registrar, no accounts** |
| frpc runs on | the station itself — there is no hypervisor | the **Proxmox host**, the machine that is up when the VM is not |
| Proxies | ssh, ka9q-web, and where configured the PSWS/GRAPE WWV carrier charts | host: ssh + Proxmox UI · VM: ssh, web, and whatever the station grows |
| Targets | all `127.0.0.1` | host services `127.0.0.1`; VM services **forwarded across the bridge** to the VM's address |

The DASI2 case is the interesting one. The station runs as a KVM guest, so
putting the tunnel *in* the guest would lose the site exactly when it is most
needed — while the VM is down or being rebuilt. Putting it on the hypervisor
and forwarding the guest's ports keeps one identity, one dashboard entry, and
one thing to arm, and the hypervisor's own sshd and Proxmox UI come along for
free.

## The picture

```
 DASI2 site (behind NAT)                    vpn.hamsci.org                     Admins
┌────────────────────────────────┐      ┌─────────────────────────────┐
│ Proxmox host                   │      │  frps-secure :35736         │
│  ├ sshd   :22   ───host-ssh────┼──┐   │   TLS forced + TOFU plugin  │
│  ├ PVE UI :8006 ───host-ui─────┼──┤   │                             │
│  └ frpc  sigmond-rac-host ─────┼──┴──►│  frps (legacy open) :35735  │
│        │                       │ TLS  │   older HamSCI stations     │
│        │  vmbr0                │      │                             │
│ DASI2 VM (guest)               │      │  tunnel ports 35800–49999 ◄─┼── admins, over WireGuard
│  ├ sshd     :22 ───vm-ssh──────┤      │                             │
│  └ ka9q-web :8081 ─vm-web──────┘      │  WireGuard :51820           │
│                                │      │   admins only — 10.3.2.1    │
└────────────────────────────────┘      └─────────────────────────────┘
```

One frpc. One login. Four proxies — two reaching services on the hypervisor
itself, two reaching the VM over the bridge.

Volunteers' machines never run WireGuard; admins never run frpc. The gateway
is the only place the two meet, and its tunnel ports are reachable only from
the admin VPN.

## Identity: trust on first use

`vpn.hamsci.org` runs **two** frps instances. `:35735` is the original open
one that older HamSCI volunteer stations still use. `:35736` is
`frps-secure`, which forces TLS and gates every login through a TOFU auth
plugin — the one sigmond sites use. It needs no registrar and creates no
accounts.

A login is admitted when:

1. it carries a **user id** and a **pubkey** in `[metadatas]`; and
2. either that user id has never been seen — the gateway **files** the key
   against it, first come first served — or the presented key **matches** the
   one already on file.

A different key claiming a taken id is refused. So the pubkey is the
identity, and the frps `token` is not the gate at all: it is empty by design.
Nothing secret goes into the config — a stolen `frpc-host.toml` lets nobody
in, because the private key never leaves the hypervisor.

The site's id is its assigned DASI number when it has one
(`SIGMOND_DASI_ID`, or `DASI_ID` in `coordination.env`), else its reporter ID
— the same string it uploads to wsprnet.org under.

Two consequences worth knowing before they bite:

- **Arming a site twice is refused, by design.** The guest unit exists for
  sigmond stations that run on bare metal, and it claims the same site id. On
  a DASI2 site, arm the hypervisor's tunnel and leave the guest's inert: if
  both were armed, whichever connected second would be rejected as an
  impersonation attempt. That is the guard working, not a fault.
- **Re-keying needs an admin.** Rebuild a hypervisor from scratch and it
  generates a new keypair; the gateway still holds the old key against that
  id and refuses the new one. The admin deletes the registry entry — which is
  also how access is revoked.

TLS is forced by the server, but its certificate is self-signed and no CA is
published, so the client enables TLS without pinning a `trustedCaFile`.
Encryption comes from TLS; identity comes from the key.

## What rides the tunnel

| Proxy | Target | Why |
|---|---|---|
| `<id>-host-ssh` | `127.0.0.1:22` | the hypervisor's own shell |
| `<id>-host-ui` | `127.0.0.1:8006` | Proxmox VE web UI — a browser onto the hypervisor can rebuild what ssh cannot |
| `<id>-vm-ssh` | `<VM address>:22` | the station's shell |
| `<id>-vm-web` | `<VM address>:8081` | ka9q-web |

The VM's address must be fixed — a static address or a DHCP reservation. The
proxies forward to an address, not to a VM: if the guest moves, those two
proxies publish whoever now answers there. `install-host.sh` takes it from
`SIGMOND_VM_IP` (or `DASI_VM_IP` in `coordination.env`) and renders a
`<VM_IP>` placeholder with a warning when it is not configured.

The list is open. A further service gets one more `[[proxies]]` block named
for its band — WsprDaemon stations already do this for the PSWS/GRAPE WWV
carrier charts (`vm-grape`, the VM's :8088), and a DASI2 site that grows one
follows the same pattern.

The band suffixes (`-vm-ssh`, `-vm-web`, `-host-ssh`, `-host-ui`) are not
decoration: the rac-dashboard keys on them to group a site's proxies. The
gateway prefixes each with the login id, so a site appears there as
`DASI-099.AI6VN-vm-ssh` and friends.

Nothing starts listening on a new port as a result: frpc's own status UI is
bound to `127.0.0.1:7500`, and every proxied service is reached through the
tunnel (and however it was already reachable on the site LAN).

## Ports

Remote ports are assigned by the WsprDaemon admin and pasted into the config;
this component never picks one. The gateway accepts tunnel ports in
**35800–49999**, and the fleet convention is one number per site with a base
per band — `35800 + n` for ssh, `45800 + n` for web, and so on, the scheme
wd-rac-client's registrar hands out automatically.

Reusing another site's port collides on the gateway (`RAC-C-004`); frps is
the final arbiter and rejects the proxy with `port already used`.

## Inert by design

Every sigmond install carries the full RAC footprint — the per-arch vendored
`frpc` (amd64 / arm64 / armhf, no build step, no download), the unit, and a
rendered config *template* — and the unit is **enabled**. It still never
starts, because it is gated on `ConditionPathExists` over its config file.
Installing RAC therefore cannot expose a site, and an unconfigured unit does
not fail-loop.

The installer fills in everything it can know by itself: the proxy names, the
keypair and pubkey metadata, the login id, and the VM's address. What it
cannot know is the port assignment, so arming stays one deliberate action —
on a DASI2 site, on the hypervisor:

```bash
cp /etc/sigmond/frpc-host.toml.template /etc/sigmond/frpc-host.toml   # after filling the <...> ports
systemctl restart sigmond-rac-host
```

A sigmond station with no hypervisor arms the guest unit instead
(`/etc/sigmond/frpc.toml`, `systemctl restart wd-rac`) — same identity rules,
`vm-ssh` and `vm-web` on `127.0.0.1`.

Re-running either installer is idempotent, rewrites only the *template*, and
leaves an armed tunnel running.

## Reaching a site

Admins reach the tunnel ports over WireGuard to the gateway — never from the
open internet:

```bash
ssh -p <assigned vm-ssh port> <station-user>@10.3.2.1
```

On the WsprDaemon side the same role is played by that gateway's tiers
(`wd-mesh` 10.112.0.2 for admins, `wd-rac` 10.111.220.1 for station
operators), enforced with per-interface firewall rules.

Observability is thin, by design and by gap (`RAC-Q-010`):
`systemctl status sigmond-rac-host`, frpc's journald log, its local status UI
on `127.0.0.1:7500`, and the gateway's dashboard — the only view that answers
"is this site actually *reachable*", which the site itself cannot tell you.

## Deliberate differences from wd-rac-client

Both are frpc reverse tunnels; these are the places sigmond-rac diverges, and
why.

| | wd-rac-client | sigmond-rac |
|---|---|---|
| Gateways | one frpc instance per gateway (`@gw2` primary, `@gw1` standby), same identity at each, so failover is a property rather than a procedure | one gateway; if `vpn.hamsci.org` is down the site is unreachable |
| Provisioning | the registrar returns gateways, token, user id and the whole port table | TOFU needs no registration; the admin still allocates remote ports out of band |
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
- **`smd admin rac register` is a gw2 mechanism.** It files a key with gw2's
  registration drop, which this gateway does not use, so `install.sh` skips
  it unless `SIGMOND_RAC_REGISTER=yes`.
- **DASI numbering.** Who assigns `DASI-NNN` is a convention this component
  follows rather than defines; it falls back to the reporter ID.
- **A VM that moves.** The `vm-*` proxies trust the configured address. A
  guest-agent lookup at start-up would remove that footgun.

## Related repositories

- **sigmond-rac** (this repo): everything installed on the hypervisor and on
  a hypervisor-less station. Spec: [docs/REQUIREMENTS.md](REQUIREMENTS.md).
- **[wd-rac-client](https://github.com/rrobinett/wd-rac-client)**: the
  WsprDaemon RAC client — registrar-driven, dual-gateway, self-arming.
- **[sigmond](https://github.com/HamSCI/sigmond)**: installs this component
  (`smd install sigmond-rac`) and hosts the TUI **RAC** screen.
- The gateway side — frps, the TOFU plugin and its registry, the dashboard,
  WireGuard and its user management — lives on the servers themselves and in
  WsprDaemon's private repos.
