# A Windows node, and what hardware a fleet of nodes needs

Status on 2026-11-04. These are plans, nothing is built yet. They are written down so the next pass doesn't have to work them out again.

Related: [eidchain.domovina.ai and eID validators](2026-11-04-eidchain-domovina-and-eid-validators.md).

## Third node: Windows, Matija's card again

What exists: `deploy/macos/` (install.sh, join.sh) and Linux (`deploy/install.sh` + `eidchain.service`). Windows has nothing yet.

Planned `deploy/windows/join.ps1`, the counterpart of `join.sh`. It needs one elevated PowerShell run, then one card signature to register the key.
- The node and cloudflared each run as a Windows service. The node binary comes from `GOOS=windows go build`.
- Hostname `eidchain-win.domovina.ai`. Never a two-level name, see the cloudflared trap in the related doc.
- Caddy instead of nginx. nginx for Windows is not a fully supported build. The rate limits and body caps of `deploy/nginx-eidchain.conf` have to be carried over by hand.
- Web eID with the newer eOI is expected to work on Windows: the failure we hit is macOS-specific. This is not tested yet.

The key becomes Matija's third key. It adds no vote, only another place the chain keeps running from.

## 20+ machines: one person's card gives one vote

- All keys of one person are one voter, and `MaxKeysPerPerson = 16`. So 20 boxes with one card cannot all be registered. The 16 that can still count as a single vote, which buys redundancy, not decentralisation.
- A real network is 20 people, each with their own card and box, ideally at 20 different addresses. Boxes in one house share one uplink and one power failure.

## Hardware

Measured on i9: the node uses about 21 MB RSS and practically 0% CPU, and the chain is a few blocks. Any small x86 box is plenty. A faster CPU only costs money and power.

- Recommendation: Minisforum UN150P (Intel N150, 16 GB, 512 GB). It launched at about $219 in 2025; the N100 UN100P at $179, about $192 in the official store later. EU prices need checking at purchase.
- The CPU is rated at 6 W. About 10 W per box is an estimate, not a measurement. At that, 20 boxes draw about 200 W, which is about 1,750 kWh a year.
- Rejected: UM760 and similar Ryzen boxes, about $630. The power is useless for this load.
- OS for a fleet: Linux (Ubuntu Server) with the existing `deploy/install.sh`. No licences, unattended updates, one way to manage them all. Windows is only for a machine that already runs Windows.
