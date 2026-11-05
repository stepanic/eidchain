# A Windows node, and what hardware a fleet of nodes needs

Status on 2026-11-04. These are plans, nothing is built yet. They are written down so the next pass doesn't have to work them out again.

Related: [eidchain.domovina.ai and eID validators](2026-11-04-eidchain-domovina-and-eid-validators.md).

## Third node: Windows, Matija's card again

What exists: `deploy/macos/` (install.sh, join.sh) and Linux (`deploy/install.sh` + `eidchain.service`). Windows has nothing yet.

Planned `deploy/windows/join.ps1`, the counterpart of `join.sh`. It needs one elevated PowerShell run, then one card signature to register the key.
- The node and cloudflared each run as a Windows service. The node binary comes from `GOOS=windows go build`.
- Hostname `eidchain-win.domovina.ai`. Never a two-level name, see the cloudflared trap in the related doc.
- Caddy instead of nginx. nginx for Windows is not a fully supported build. The rate limits and body caps of `deploy/nginx-eidchain.conf` have to be carried over by hand.
- Official Web eID won't sign with the newer eOI on Windows either. The real blocker is the unknown ATR, which libelectronic-id checks the same way on every platform, so Windows needs the fork too. See [Web eID for Windows, built from WSL](2026-11-05-web-eid-windows-build-from-wsl.md).

The key becomes Matija's third key. It adds no vote, only another place the chain keeps running from.

### Update 2026-11-05: the machine is a Lenovo with WSL2

The third node goes on a Lenovo running Windows 11 and WSL2 (Ubuntu 26.04, WSL 3.0.3). The hostname changes to `eidchain-lenovo.domovina.ai`, following `-i9` and `-mini`. Choosing where the node runs is still open:

- **In WSL (recommended).** `/etc/wsl.conf` already has `systemd=true`, so the work is a Linux counterpart of `deploy/macos/install.sh`: systemd units instead of LaunchDaemons, nginx and cloudflared from apt, the same `eidchain.env`, ports 8095/8096. `deploy/install.sh` doesn't fit, because it is the ivoras.net host (`/srv/eidchain`, `User=ivoras`). The risk is lifecycle. WSL doesn't start at Windows boot and can stop when no terminal is open. That needs a boot-time Scheduled Task that keeps the distro alive (e.g. `wsl.exe -d Ubuntu -- sleep infinity`) and possibly `.wslconfig` settings. It is untested whether this survives a reboot.
- **Native Windows services.** `eidchain.exe` cross-compiles from WSL (pure Go, no cgo). It's more reliable at boot, but everything is new: Caddy config, service registration, `join.ps1`.

**Decided 2026-11-05: WSL.** `deploy/linux/install.sh` (systemd units, nginx from Ubuntu, cloudflared from Cloudflare's apt repo, the nginx and tunnel configs shared with macOS through `deploy/tunnel-node.sh`) and `deploy/wsl/keep-alive.ps1` (boot-time Scheduled Task as S4U holding `wsl.exe -d Ubuntu --exec /bin/sleep infinity`, repeated every 5 minutes with IgnoreNew; `vmIdleTimeout=-1`; no sleep, no hibernation and lid does nothing on AC). Node key `1b646745…`, seed in `~/eidchain-data`. Whether it survives a reboot with nobody logged on is still to be checked.

The longer-term answer for people who aren't server admins is a desktop app, not either of these: [A node as a desktop app](2026-11-05-one-click-desktop-node.md).

Both ways need a person: sudo or an admin prompt, `cloudflared tunnel login` while someone is at the screen (delete `cert.pem` afterwards), and the card signature on `validator.html`. A laptop also has to be kept from sleeping. Peers: configure i9 and mini on the Lenovo. They learn the Lenovo from its announcement.

## 20+ machines: one person's card gives one vote

- All keys of one person are one voter, and `MaxKeysPerPerson = 16`. So 20 boxes with one card cannot all be registered. The 16 that can still count as a single vote, which buys redundancy, not decentralisation.
- A real network is 20 people, each with their own card and box, ideally at 20 different addresses. Boxes in one house share one uplink and one power failure.

## Hardware

Measured on i9: the node uses about 21 MB RSS and practically 0% CPU, and the chain is a few blocks. Any small x86 box is plenty. A faster CPU only costs money and power.

- Recommendation: Minisforum UN150P (Intel N150, 16 GB, 512 GB). It launched at about $219 in 2025; the N100 UN100P at $179, about $192 in the official store later. EU prices need checking at purchase.
- The CPU is rated at 6 W. About 10 W per box is an estimate, not a measurement. At that, 20 boxes draw about 200 W, which is about 1,750 kWh a year.
- Rejected: UM760 and similar Ryzen boxes, about $630. The power is useless for this load.
- OS for a fleet: Linux (Ubuntu Server) with the existing `deploy/install.sh`. No licences, unattended updates, one way to manage them all. Windows is only for a machine that already runs Windows.
