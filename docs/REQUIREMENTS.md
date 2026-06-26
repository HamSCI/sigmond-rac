# sigmond-rac — Requirements Specification

**Status:** v0.1 baseline (retroactive). **Owner:** Michael Hauan (AC0G).
**Last reconciled against code:** sigmond-rac (renamed from `rac`) frpc `v0.64.0` (2026-06-25).
**Prefix:** `RAC`.

> Application of [sigmond/docs/REQUIREMENTS-TEMPLATE.md](https://github.com/HamSCI/sigmond/blob/main/docs/REQUIREMENTS-TEMPLATE.md)
> to a **Stub/Infra** component at the minimal end of the maturity range: a
> vendored frpc reverse-tunnel client + a systemd unit + a config template, with
> **no Python package and no contract self-description surface**. The
> sigmond↔component client contract therefore does **not** apply here (§8.3); the
> doc records that explicitly rather than inventing a surface that does not exist.
> Provenance tags: `[DOC]` documented · `[CODE]` implicit-in-code · `[NEW]`
> surfaced by this review. Status: ✅ implemented · 🟡 partial/unverified · ⬜ planned.
>
> **Naming constraint (read first):** the *component* is **sigmond-rac** (the
> repo dir, catalog entry, and `deploy.toml` name, just renamed from `rac`). The
> *systemd service it provisions* is **`wd-rac.service`** — an entirely separate,
> historically-named artefact carried over from the legacy wsprdaemon-client. Do
> not conflate the two (constraint `RAC-C-005`).

## 1. Context & problem statement

A DASI2/PSWS station typically runs as a KVM guest behind NAT with no inbound
reachability, which makes remote support impossible: when a station misbehaves
the operator cannot always be on-site, and the suite admin (WsprDaemon's Rob
Robinett) has no route in. sigmond-rac is the **Remote Access Channel** — it
provisions an [frp](https://github.com/fatedier/frp) reverse-tunnel client
(`frpc`) that dials *out* from the NAT'd station to `gw2.wsprdaemon.org` and
publishes the station's SSH (and an optional web port) at a unique remote port on
that gateway, so an admin can reach in for support.

It is deliberately **minimal infrastructure**: a per-arch vendored frpc binary, a
TLS CA, a systemd unit, and a per-station config *template*. There is no Python,
no daemon logic of our own, no science. The component is **inert by design** — it
is enabled at install but never starts until an operator pastes the gw2
assignment (user / token / unique remotePort) into `/etc/sigmond/frpc.toml`. This
component delivers the PSWS charette item #39, "Centralized Remote Admin."

## 2. Goals & objectives

- Give the suite admin authenticated, TLS-protected SSH (and optional web) reach
  into a NAT'd station, on demand.
- Ship as a **drop-in install footprint** on every sigmond host (binary + CA +
  unit + template) without requiring activation.
- Be **safe-by-default**: present but inert; one explicit operator action arms it;
  no fail-loop while unconfigured.
- Be **arch-portable** (amd64 / arm64 / armhf) from vendored binaries with no
  build step.
- Keep per-station credentials and the unique remote port off the repo and in
  operator-filled local config.

## 3. Non-goals / out of scope

- **Provisioning the gw2 side.** Server (`frps`), the user/token issuance, and the
  unique remotePort allocation are owned by the WsprDaemon admin / gateway, not by
  this component.
- **Inventory / validation / self-description.** This is infra; it does not
  participate in the client contract (`inventory --json` / `validate --json`),
  has no `data_sinks`, and is not a radiod client. (§8.3.)
- **Credential management / secret rotation.** The template carries placeholders;
  filling, securing, and rotating them is operator/admin scope.
- **Being the only access path.** It is a support channel, not the station's
  primary management plane.
- **Renaming the service.** `wd-rac.service` keeps its legacy name; this doc does
  not require aligning the unit name to the new component name (§12 open question).

## 4. Stakeholders & actors

Station operator (fills the assignment, arms the tunnel) · WsprDaemon suite admin
(Rob Robinett, AI6VN — issues the gw2 user/token/remotePort, reaches in) ·
`gw2.wsprdaemon.org` frps gateway (the rendezvous server) · the vendored `frpc`
binary (the tunnel client) · systemd (lifecycle, restart, ConditionPathExists
gate) · sigmond `smd install` (runs `install.sh`) and the sigmond TUI **RAC**
screen (operator UX) · the station's local sshd (port 22) and optional web
(8081) as tunnelled targets.

## 5. Assumptions & constraints

- `RAC-C-001` `[CODE]` ✅ Root SHALL be available at install (writes
  `/usr/local/sbin`, `/etc/sigmond`, `/etc/systemd/system`); `install.sh` is run
  via sudo by `smd install`.
- `RAC-C-002` `[CODE]` ✅ The host arch SHALL be one of amd64/arm64/armhf with a
  matching vendored `frpc-<arch>-v<ver>` binary; unsupported arch is a hard fail.
- `RAC-C-003` `[DOC]` ✅ The station SHALL have outbound reachability to
  `gw2.wsprdaemon.org:35736`; there is no inbound requirement (that is the point).
- `RAC-C-004` `[DOC]` ✅ Each station's `remotePort`(s) SHALL be **unique on gw2**;
  reuse collides with another station and is an admin-allocation invariant.
- `RAC-C-005` `[NEW]` ✅ **Component vs service identity:** the component is
  `sigmond-rac`; the provisioned unit is `wd-rac.service`. The two names are
  distinct and SHALL NOT be conflated in catalog, docs, or tooling.
- `RAC-C-006` `[CODE]` ✅ The component SHALL carry **no Python package and no
  runtime deps of its own** beyond the vendored frpc binary; it is stdlib-shell
  install only.

## 6. Functional requirements

### 6.1 Provisioning (install.sh)
- `RAC-F-001` `[DOC]` ✅ SHALL select and install the vendored `frpc` for the host
  arch to `/usr/local/sbin/frpc` (mode 0755, root:root).
- `RAC-F-002` `[DOC]` ✅ SHALL install the frps TLS CA to `/etc/sigmond/frps-ca.crt`
  (0644) and the unit to `/etc/systemd/system/wd-rac.service` (0644).
- `RAC-F-003` `[CODE]` ✅ SHALL render the config template to
  `/etc/sigmond/frpc.toml.template` (0640) with the per-station proxy name
  substituted (`@PROXY@` → `STATION_CALL/<INSTANCE-UPPER>`).
- `RAC-F-004` `[DOC]` ✅ SHALL `daemon-reload` and `enable wd-rac.service` so RAC is
  part of the install footprint, without starting it.
- `RAC-F-005` `[CODE]` ✅ SHALL (re)start `wd-rac.service` **iff**
  `/etc/sigmond/frpc.toml` already exists; otherwise SHALL print the activation
  instructions and leave the unit inert.
- `RAC-F-006` `[DOC]` ✅ SHALL be **idempotent** — re-running re-installs binary,
  CA, unit, and template without side effects on an armed tunnel.

### 6.2 Tunnel runtime (wd-rac.service)
- `RAC-F-010` `[DOC]` ✅ The unit SHALL run `frpc -c /etc/sigmond/frpc.toml` and
  SHALL stay **inert until configured** via
  `ConditionPathExists=/etc/sigmond/frpc.toml` (no fail-loop while unconfigured).
- `RAC-F-011` `[CODE]` ✅ The unit SHALL `Restart=always` (`RestartSec=30`) after
  `network-online.target`, so a dropped tunnel re-dials gw2.
- `RAC-F-012` `[DOC]` ✅ Once armed, SHALL publish local SSH (127.0.0.1:22) and an
  optional web port (127.0.0.1:8081) as TCP proxies on gw2 at the
  admin-assigned unique `remotePort`(s), over TLS using the trusted CA.

### 6.3 Activation
- `RAC-F-020` `[DOC]` ✅ The operator SHALL arm RAC by filling the template's gw2
  `user`/`token`/`remotePort`(s), copying it to `/etc/sigmond/frpc.toml`, and
  restarting the unit; this is the single explicit arming action.
- `RAC-F-021` `[CODE]` ✅ A new supported arch SHALL be addable by dropping a
  vendored `frpc-<arch>-v<ver>` binary in `bin/` and bumping `FRP_VER` — no other
  code change.

## 7. Quality / non-functional requirements

- `RAC-Q-001` `[DOC]` ✅ **Safe-by-default:** the component SHALL be present and
  enabled yet inert, so installing it can never expose a station until an operator
  deliberately arms it.
- `RAC-Q-002` `[CODE]` ✅ **Secrets hygiene:** the repo SHALL carry only
  `<...>` placeholders; the rendered template SHALL be 0640 and real
  user/token/port SHALL live only in operator-filled `/etc/sigmond/frpc.toml`,
  never committed.
- `RAC-Q-003` `[CODE]` ✅ Transport SHALL be TLS with a pinned trusted CA
  (`trustedCaFile`), not plaintext.
- `RAC-Q-004` `[CODE]` 🟡 Resilience: the tunnel SHALL self-heal via systemd
  restart; there is **no liveness/health surface** beyond `systemctl status`
  (no watchdog, no inventory health). *(gap — `RAC-Q-010`.)*
- `RAC-Q-005` `[NEW]` 🟡 **Supply-chain provenance:** the vendored frpc binaries
  SHOULD be pinned/verified against an upstream frp release checksum; today they
  are committed blobs with no recorded hash. *(gap — `RAC-Q-011`.)*

## 8. External interfaces

### 8.1 Inputs
- **Vendored binaries:** `bin/frpc-{amd64,arm64,armhf}-v0.64.0` (selected by
  `dpkg --print-architecture`).
- **TLS CA:** `frps-ca.crt` → `/etc/sigmond/frps-ca.crt`.
- **Config template:** `config/frpc.toml.template` → rendered to
  `/etc/sigmond/frpc.toml.template`; operator copies to
  `/etc/sigmond/frpc.toml` after filling the gw2 assignment.
- **Identity env (render-time):** `STATION_CALL` (default `AC0G`),
  `SIGMOND_INSTANCE` (default hostname) → the `@PROXY@` proxy name.
- **gw2 assignment (operator-supplied):** `user`, `token` (method=token), and
  unique `remotePort`(s) — from the WsprDaemon admin. Fixed shared values:
  `serverAddr=gw2.wsprdaemon.org`, `serverPort=35736`.

### 8.2 Outputs
- **The reverse tunnel:** outbound frpc connection to gw2 publishing
  SSH(:22)/web(:8081) at the assigned remote ports — the product.
- **Provisioned files:** `/usr/local/sbin/frpc`,
  `/etc/sigmond/{frps-ca.crt,frpc.toml.template}`,
  `/etc/systemd/system/wd-rac.service`.
- **Local frpc webServer** at `127.0.0.1:7500` (status UI).
- **Logs:** frpc to journald via the unit; no per-component log file or
  status/inventory JSON.

### 8.3 Contracts / APIs — **does not apply**
- `RAC-I-001` `[NEW]` ✅ The sigmond **client contract does NOT apply** to this
  component. sigmond-rac is `kind="infra"`: `install.sh` provisions frpc as real
  files and a systemd unit; it has **no `inventory --json`, no `validate --json`,
  no `config init/edit`, no `data_path`, and no `data_sinks`**. sigmond's contract
  adapter is not invoked for it. Its only sigmond-facing surface is the
  `deploy.toml` `[component] kind="infra"` + `[systemd] units=["wd-rac.service"]`
  declaration (lifecycle/catalog only) and the TUI **RAC** screen for activation.
  Per the template's two-kinds rule, this component has no integration "seam"
  beyond install + unit lifecycle, so there is nothing to reference from
  CLIENT-CONTRACT.md.

## 9. Data requirements

No measurement data, no sink, no schema, no retention. The only persistent state
is configuration: the rendered template (no secrets) and, once armed, the
operator-filled `/etc/sigmond/frpc.toml` (carries the bearer token + unique
ports — sensitive, 0640, local-only). Volume: negligible (a tunnel control
channel; SSH/web traffic is interactive and not stored).

## 10. Dependencies & development sequence

**Deps:** the vendored `frpc` binary (frp v0.64.0) is the sole runtime dep;
systemd for lifecycle; outbound network to gw2. No Python, no sibling libs, no
radiod. Provisioned by sigmond's catalog-driven installer (`smd install
sigmond-rac` → this repo's `install.sh`).

**Development sequence (intended, recovered):** lifted from the legacy
wsprdaemon-client `wd-rac` → repackaged as a standalone sigmond infra component
so every install can carry it → **renamed `rac` → `sigmond-rac`** (dir + catalog
+ deploy.toml; service name unchanged) on 2026-06-25. Forward work is hardening
(checksum-pinned binaries, optional health surface, possible unit rename), not
new capability.

## 11. Acceptance criteria & verification

- Provisioning → after `install.sh`: `/usr/local/sbin/frpc --version` reports the
  vendored version; CA/unit/template present with correct modes; the unit is
  `enabled` but `inactive` while `/etc/sigmond/frpc.toml` is absent
  (`systemctl status wd-rac` shows the `ConditionPathExists` gate).
- Inertness → with no `frpc.toml`, the unit SHALL NOT enter a fail-loop.
- Activation → after filling + copying `frpc.toml` and `restart wd-rac`, the unit
  is `active (running)` and the admin can SSH to the station via the assigned
  gw2 remotePort.
- Idempotency → a second `install.sh` run leaves an armed tunnel functioning.
- Contract → **N/A by design** (`RAC-I-001`); sigmond enriches it only as an
  infra unit in `smd status`, not via `inventory`/`validate`.

## 12. Risks & open questions

- `RAC-Q-010` `[NEW]` 🟡 **No health/liveness surface:** tunnel state is only
  visible via `systemctl status` / the local frpc webServer; there is no signal to
  sigmond that the tunnel is *up and reachable from gw2*. SHALL decide whether to
  add a minimal health probe or accept the systemd-only view.
- `RAC-Q-011` `[NEW]` ⬜ **Unverified vendored binaries:** the per-arch frpc blobs
  carry no recorded upstream checksum/signature. SHALL pin + verify against the
  frp release to close the supply-chain gap.
- `RAC-F-030` `[NEW]` ⬜ **Component/service name mismatch:** the unit, its
  `Documentation=` URL (`github.com/HamSCI/rac`), and several log strings still say
  `rac`/`wd-rac` after the `sigmond-rac` rename. Decide: keep `wd-rac.service` as a
  deliberate legacy name (per `RAC-C-005`) and fix only the stale `Documentation`
  URL + README title, OR rename the unit (migration cost on armed hosts). *(open —
  candidate #18 issue.)*
- `RAC-F-031` `[NEW]` ⬜ **Manual activation only:** arming is a copy+edit+restart
  by hand; the TUI RAC screen exists but end-to-end assisted activation (paste
  assignment → write `frpc.toml` → restart) is unverified here.

## 13. Traceability

| Requirement | #18 issue | Verification | PSWS #6 |
|---|---|---|---|
| RAC-F-012 (reverse tunnel) | INFRA: sigmond-rac | admin SSH via gw2 remotePort | **#6:39 (Centralized Remote Admin)** |
| RAC-F-010 (inert-until-configured) | — | `systemctl status` ConditionPathExists | #6:39 |
| RAC-Q-001 (safe-by-default) | — | install → enabled+inactive | #6:39 |
| RAC-I-001 (contract N/A) | — | no `inventory`/`validate` surface | — |
| RAC-Q-011 (binary checksums) | *(new — file)* | pinned hash verify | — |
| RAC-F-030 (name mismatch) | *(new — file)* | doc/unit audit | — |
| RAC-F-031 (assisted activation) | *(new — file)* | TUI RAC screen e2e | #6:39 |

*This component delivers PSWS #6:39 "Centralized Remote Admin." New rows
(RAC-Q-010/011, RAC-F-030/031) are this review's surfaced gaps; promote to a #18
INFRA issue.*
