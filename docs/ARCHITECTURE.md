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

## What rides the tunnel, and how it grows

A site publishes a **set of services**, not a fixed list. Each one gets a
*band*: a name whose prefix says which machine it lives on, and whose
fleet-wide *base* fixes its remote port.

| Band | Remote port | Target | Service |
|---|---|---|---|
| `vm_ssh` | 35800 + n | VM | the station's shell |
| `vm_grape` | 40800 + n | VM | PSWS/GRAPE WWV carrier charts (:8088) |
| `vm_web` | 45800 + n | VM | ka9q-web (:8081) |
| `vm_web2` / `vm_web3` | 46800 / 47800 + n | VM | 2nd / 3rd RX888 web UI |
| `host_ssh` | 50800 + n | hypervisor | the hypervisor's shell |
| `host_ui` | 55800 + n | hypervisor | Proxmox VE web UI (:8006) |

Two rules do the work:

- **One number per site.** Every port is `base + n`, so a site's whole port
  set follows from its single RAC/DASI number and nothing is picked by hand.
  Ports stay unique fleet-wide as long as the site number is.
- **The band prefix picks the target.** `host_*` proxies point at
  `127.0.0.1` — the hypervisor the frpc runs on; `vm_*` proxies point at the
  VM's address across the bridge. That is what lets one login serve both
  machines.

The set itself lives in `SIGMOND_RAC_PROXIES` (or `RAC_PROXIES` in
`coordination.env`) as `band=localport` entries, defaulting to
`host_ssh=22 host_ui=8006 vm_ssh=22 vm_web=8081`. A site that also serves the
GRAPE charts and a magnetometer page sets:

```
SIGMOND_RAC_PROXIES="host_ssh=22 host_ui=8006 vm_ssh=22 vm_web=8081 vm_grape=8088 vm_mag:41800=8090"
```

and gets six tunnels instead of four. A band already in the table needs only
`band=localport`; a band that is **not** in the table yet must carry its base
inline (`vm_mag:41800=8090`), because a base is a fleet-wide allocation and
guessing one would collide with that service at every other site. The
installer refuses an unknown bare band rather than inventing a number. Once
the admin allocates the base it belongs in
[config/rac-bands.sh](../config/rac-bands.sh) — the one place the table
lives, and the only edit a new service needs.

The VM's address must be fixed — a static address or a DHCP reservation. The
proxies forward to an address, not to a VM: if the guest moves, every `vm_*`
proxy publishes whoever now answers there. `install-host.sh` takes it from
`SIGMOND_VM_IP` (or `DASI_VM_IP` in `coordination.env`) and renders a
`<VM_IP>` placeholder with a warning when it is not configured.

The band suffixes are not decoration: the rac-dashboard keys on them to group
a site's proxies. The gateway prefixes each with the login id, so a site
appears there as `DASI-099.AI6VN-vm-ssh` and friends.

Nothing starts listening on a new port as a result: frpc's own status UI is
bound to `127.0.0.1:7500`, and every proxied service is reached through the
tunnel (and however it was already reachable on the site LAN).

## Inert by design

Every sigmond install carries the full RAC footprint — the per-arch vendored
`frpc` (amd64 / arm64 / armhf, no build step, no download), the unit, and a
rendered config *template* — and the unit is **enabled**. It still never
starts, because it is gated on `ConditionPathExists` over its config file.
Installing RAC therefore cannot expose a site, and an unconfigured unit does
not fail-loop.

Given the site number, the installer renders a *complete* config: proxy
names, keypair and pubkey metadata, login id, the VM's address, and every
band's port. Nothing is left to fill in — but arming is still a deliberate
act, so the rendered file is a template until someone copies it into place.
On a DASI2 site, on the hypervisor:

```bash
cp /etc/sigmond/frpc-host.toml.template /etc/sigmond/frpc-host.toml
systemctl restart sigmond-rac-host
```

Without a site number the ports render as `<PORT_band>` placeholders, so an
unconfigured file is obviously incomplete rather than quietly wrong.

A sigmond station with no hypervisor arms the guest unit instead
(`/etc/sigmond/frpc.toml`, `systemctl restart wd-rac`) — same identity rules,
same bands, with the `vm_*` services on `127.0.0.1`.

Re-running either installer is idempotent, rewrites only the *template*, and
leaves an armed tunnel running.

## Reaching a service

Every tunnel port is reachable **only** at the gateway's VPN address,
`10.3.2.1`, and only by someone holding a WireGuard configuration for that
server. There is no public path to a station: the gateway's firewall accepts
everything arriving on `wg0` and, from the internet, only :22, :51820 and the
two frps control ports — the ports stations dial *out* to. A service is
therefore a port on the server's VPN tunnel address, nothing more.

```bash
ssh -p $((35800 + n)) <station-user>@10.3.2.1     # the DASI2 VM
ssh -p $((50800 + n)) root@10.3.2.1               # the Proxmox host
https://10.3.2.1:$((55800 + n))                   # the Proxmox VE UI
```

Reusing another site's port collides on the gateway (`RAC-C-004`); frps is
the final arbiter and rejects the proxy with `port already used`.

One deviation from that rule exists today and is worth knowing about while
it lasts: the gateway's persisted ruleset also accepts **46000–46999** from
the internet (`# web tunnels`), which currently exposes a handful of legacy
HamSCI stations' web UIs directly — and is the range `vm_web2` (46800 + n)
would land in. The intent is that this closes, leaving every port VPN-only;
until it does, treat that band as public.

On the WsprDaemon side the same role is played by that gateway's tiers
(`wd-mesh` 10.112.0.2 for admins, `wd-rac` 10.111.220.1 for station
operators), enforced with per-interface firewall rules.

## Observability

Thin, by design and by gap (`RAC-Q-010`):
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
