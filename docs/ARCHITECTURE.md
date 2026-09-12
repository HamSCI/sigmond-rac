# sigmond-rac — Architecture

How a sigmond/DASI2 station behind NAT becomes reachable by the WsprDaemon
admin, without port forwarding, a public IP, or anything new listening on
the open internet.

This component is the sigmond-packaged member of the WsprDaemon **Remote
Access Client** family; the reference implementation of the same
architecture is
[wd-rac-client](https://github.com/rrobinett/wd-rac-client). The model
below is that architecture; the last section records, honestly, where
sigmond-rac currently sits short of it.

## The picture

```
 DASI2 site (behind NAT)                     gw2.wsprdaemon.org               Operators
┌────────────────────────────────┐        ┌────────────────────────────┐
│ Proxmox host                   │        │  frps-secure :35736        │
│  ├ sshd :22                    │outbound│   TLS + fleet token +      │
│  └ frpc  sigmond-rac-host  ────┼───────►│   ssh-key auth plugin      │
│                                │  TLS   │                            │
│ DASI2 VM (guest)               │        │  vm_ssh   35800+RAC  ◄─────┼── ssh -p 35800+RAC user@10.111.220.1
│  ├ sshd :22                    │        │  vm_web   45800+RAC  ◄─────┼── http://10.111.220.1:45800+RAC
│  ├ web  :8081 (ka9q-web)       │        │  host_ssh 50800+RAC  ◄─────┼── ssh -p 50800+RAC root@10.111.220.1
│  └ frpc  wd-rac.service   ─────┼───────►│                            │
│                                │  TLS   │  rac-registrar :35737      │    WireGuard tiers:
│ frpc status UI 127.0.0.1:7500  │        │  rac-dashboard :50080      │     wd-mesh 10.112.0.2   admins
└────────────────────────────────┘        └────────────────────────────┘     wd-rac  10.111.220.1 operators
```

Each `frpc` makes an **outbound** TLS connection to the gateway's
[frp](https://github.com/fatedier/frp) server and holds it open, retrying
forever. The gateway republishes the station's local services at remote
ports that belong to that station alone. Operators reach those ports only
over one of the gateway's WireGuard tiers — the tunnel ports are firewalled
off the open internet.

Nothing on the station starts listening on a new port: frpc's own status UI
is bound to `127.0.0.1:7500`, and sshd is reached through the tunnel (and
however it was already reachable on the site LAN).

## One frpc process per tunnel, driven by systemd

A tunnel is a config file plus a systemd unit that runs
`frpc -c <config>` with `Restart=always`. There is no daemon logic of our
own: recovery is systemd restarting frpc, and frpc reconnecting.

| Tunnel | Unit | Config | Publishes |
|---|---|---|---|
| guest VM | `wd-rac.service` | `/etc/sigmond/frpc.toml` | VM sshd :22, web :8081 |
| Proxmox host | `sigmond-rac-host.service` | `/etc/sigmond/frpc-host.toml` | host sshd :22 |

wd-rac-client uses the same shape with a **templated** unit,
`wd-remote-access@<gateway>.service`, whose instance name selects
`/etc/wd-remote-access/gateways/<gateway>.toml`. That is what makes
multi-gateway cheap: the same identity, the same proxies, one instance per
gateway, none of them aware of the others.

## Identity and registration

- The station's identity **is** an ed25519 keypair generated at install
  (`/etc/sigmond/frpc_id_rsa`; `/etc/wd-remote-access/id_ed25519` in
  wd-rac-client). The gateway's frps auth plugin accepts an frpc login only
  when its `user` field corresponds to a **registered** public key, so an
  unregistered station cannot connect no matter what else it presents.
- The fleet `token` in the config is therefore not the real gate, and
  revocation is the admin removing the key on the gateway — not rotating a
  shared secret.
- sigmond registers the key through `smd admin rac register`, which uploads
  it under the station's **reporter ID** to the gateway's registration drop;
  the gateway auto-provisions the account and `authorized_keys` from there.
  Registration is idempotent (`/etc/sigmond/.rac-registered`), and failure
  is loud but never fails the install.
- wd-rac-client instead POSTs `{site, pubkey, rac?}` to the **RAC registrar**
  (`http://gw2.wsprdaemon.org:35737/register`) and gets back, in one answer:
  the frps address and port, the fleet token, its `user` id, the gateway
  list, and its port in every band. The registrar validates the claimed RAC
  number against every registered and currently-connected client and rejects
  collisions with a 409.
- The proxy name is the station's identity on the gateway, and must be
  fleet-unique. sigmond uses the bare reporter ID — the same string the
  station uploads to wsprnet.org under — resolved from
  `STATION_REPORTER_ID` / `STATION_CALL` in the environment, else
  `/etc/sigmond/coordination.env`. With no identity configured the installer
  renders a `<REPORTER_ID>` placeholder and warns rather than baking in a
  default callsign; that is how wrong accounts end up on the gateway.

## Ports: one number per station, one band per service

A station has a single **RAC number**, and every service it publishes is
that number plus a band base. The ports are derived, never negotiated:

| Band | Remote port | Local service |
|---|---|---|
| `vm_ssh` | 35800 + RAC | sshd :22 |
| `vm_grape` | 40800 + RAC | GRAPE carrier strip charts :8088 |
| `vm_web` | 45800 + RAC | ka9q-web :8081 |
| `vm_web2` / `vm_web3` | 46800 / 47800 + RAC | 2nd / 3rd RX888 web UI |
| `host_ssh` | 50800 + RAC | hypervisor sshd |
| `host_ui` | 55800 + RAC | hypervisor UI |

wd-rac-client receives this whole table from the registrar and builds one
`[[proxies]]` block per band it was asked to expose
(`WD_RAC_PROXIES="vm_ssh=22 vm_web=8081"`), naming each proxy
`<site>-<band>` with dashes — `SITE-vm-ssh`, `SITE-vm-web`, `SITE-host-ssh`
— which is how the station appears on the gateway's **rac-dashboard**
automatically.

sigmond-rac does not compute ports: the `user`, `token`, and each unique
`remotePort` are allocated by the WsprDaemon admin and pasted into the
config. Reusing another station's port collides on the gateway and is the
one allocation invariant an operator can break (`RAC-C-004`); frps is the
final arbiter and rejects the proxy with `port already used`.

## Two tunnels per site — guest and hypervisor

A DASI2 site runs the station as a KVM guest on a Proxmox host. The guest
tunnel covers only the VM, so `install-host.sh` installs a **second,
independent** frpc on the hypervisor: separate config, separate unit,
separate proxy name, and a `remotePort` that must differ from the guest's,
because to the gateway these are two different clients.

That tunnel exists for the case where remote hands matter most — **the VM
is down or being rebuilt** — and it publishes the host's sshd only; the web
UI lives in the guest. It is normally delivered and run by sigmond's proxmox
bootstrap (`install_host_rac`), and runs standalone from a checkout too.

In band terms the host tunnel is `host_ssh` (50800 + RAC): the same station,
its hypervisor port, not a second RAC number. Claiming it that way is what
lets one station's guest and host sit together on the dashboard.

## Inert by design

Every sigmond install carries the full RAC footprint — the per-arch vendored
`frpc` (amd64 / arm64 / armhf, no build step, no download), the pinned frps
CA, the unit, and a station-specific config *template* — and the unit is
**enabled**. It still never starts, because it is gated on
`ConditionPathExists=/etc/sigmond/frpc.toml`. Installing RAC therefore
cannot expose a station, and an unconfigured unit does not fail-loop.

Arming is one deliberate operator action:

```bash
sudo cp /etc/sigmond/frpc.toml.template /etc/sigmond/frpc.toml   # after filling the <...> assignment
sudo systemctl restart wd-rac
```

Re-running `install.sh` afterwards is idempotent and leaves an armed tunnel
running.

This is the deliberate divergence from wd-rac-client, whose installer is
interactive and self-arming: it registers, receives everything it needs, and
proves the tunnel is up (`start proxy success` on the primary) before it
declares victory.

## Reaching a station

| WireGuard tier | gw2 address | Who | Can reach |
|---|---|---|---|
| wd-mesh | 10.112.0.2 | WsprDaemon admins | everything |
| wd-rac | 10.111.220.1 | WD station operators | shareable services in the RAC bands |
| wd-sonde | 10.111.221.1 | Wsprsonde watchers | only the sonde ports — never sigmond stations |

Tiers are enforced with per-interface iptables rules on the gateway. So:

```bash
ssh -p $((35800 + RAC)) <station-user>@10.111.220.1
```

Observability is thin by design and by gap (`RAC-Q-010`):
`systemctl status wd-rac`, frpc's journald log, its local status UI on
`127.0.0.1:7500`, and the gateway's rac-dashboard on `:50080` — the only
view that answers "is this station actually *reachable*", which the station
itself cannot tell you.

## Where sigmond-rac stands relative to wd-rac-client

Both are frpc reverse tunnels to the same gateway with the same identity
model. The differences are real, and each is a config or install change
rather than a redesign:

| | wd-rac-client | sigmond-rac |
|---|---|---|
| Gateways | one instance per gateway (`@gw2` primary, `@gw1` standby), both up always; same identity and ports at each, so no failover logic exists to get wrong | **single gateway** (gw2); if gw2 is down the site is unreachable |
| Provisioning | registrar POST returns gateways, token, user, and the full band table; RAC number auto-assigned (lowest free ≥ 500) and collision-checked | admin allocates `user`/`token`/`remotePort` out of band; operator pastes them in |
| Arming | installer registers and starts the tunnel, confirming it came up | **inert until armed** by an explicit operator action |
| frpc binary | downloaded from the frp release for the local arch | **vendored** per-arch blobs in `bin/` (no network, but unpinned — `RAC-Q-011`) |
| Transport | `transport.tls.enable`, `loginFailExit = false` so an unreachable gateway at boot is retried in-process | TLS with a **pinned CA** (`trustedCaFile`) — stricter — but no `loginFailExit`, so a gateway down at boot costs a 30 s systemd restart cycle |
| Privilege | frpc runs as a dedicated `wd-rac` system user with `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome` | frpc runs as **root** with no sandboxing |
| Proxy names | `<site>-vm-ssh`, `<site>-vm-web`, … — the suffixes the rac-dashboard keys on | `<reporter-id>` and `<reporter-id>-WEB` — the station will not group on the dashboard the way the rest of the fleet does |
| Upgrades | add-before-remove under a 10-minute dead-man rollback timer, because the tunnel being replaced is usually the only way in | re-run `install.sh`; an armed tunnel keeps running, but there is no rollback rail |

Two of these are worth treating as defects rather than choices: the proxy
naming (a station that does not show up correctly on the dashboard is
invisible to the people who watch the fleet) and running frpc as root when
the reference client demonstrates it needs no privileges at all.

## Related repositories

- **sigmond-rac** (this repo): everything installed on the station and on its
  Proxmox host. Spec: [docs/REQUIREMENTS.md](REQUIREMENTS.md).
- **[wd-rac-client](https://github.com/rrobinett/wd-rac-client)**: the
  reference RAC client — registrar-driven, dual-gateway, self-arming.
- **[sigmond](https://github.com/HamSCI/sigmond)**: installs this component
  (`smd install sigmond-rac`), provides `smd admin rac register`, and hosts
  the TUI **RAC** screen used for activation.
- The gateway side — frps, the registrar, the registration drop, the
  rac-dashboard, the WireGuard tiers and their user management — lives in
  WsprDaemon's private server repos and is out of scope here.
