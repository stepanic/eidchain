#!/usr/bin/env python3
"""Draw the live chain: which nodes exist, which keys sign from which node, and
whose vote each key is. Writes docs/chain-map.md (Mermaid) and, with --pdf, a
PDF next to it.

    python3 -I scripts/chain-map.py [--pdf] [--seed URL ...]

Why a script and not a hand-written document: the set of nodes and keys changes
whenever someone joins, registers a key or a key goes idle, so a picture drawn
by hand is wrong within days. Every run reflects the moment it ran.

What it can and cannot know: nodes are found by following GET /api/v1/peers
from the seeds, so only nodes with a public address appear (a node behind NAT
without --advertise is invisible to everyone, this script included). Which
keys a node holds comes from `signingKeys` in its /api/v1/info. A node does
not say which machine it runs on, so scripts/chain-map-hints.json names those
("host"); it can also list "keys" for a node built before `signingKeys`.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from collections import deque
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEEDS = ["https://eidchain.domovina.ai/chain", "https://eidchain-mini.domovina.ai/chain"]
TZ = ZoneInfo("Europe/Zagreb")
MERMAID = "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"


def get(url, timeout=8):
    req = urllib.request.Request(url, headers={"User-Agent": "eidchain-chain-map"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def crawl(seeds):
    """Breadth-first over the peer lists; a node that does not answer is kept as down."""
    nodes, queue, seen = {}, deque(seeds), set(seeds)
    while queue and len(nodes) < 64:
        url = queue.popleft()
        n = {"url": url, "up": False, "peers": []}
        try:
            n["info"] = get(url + "/api/v1/info")
            n["up"] = True
            pl = get(url + "/api/v1/peers")
            # A node reached through an alias (eidchain.domovina.ai) names itself
            # by its advertised address; draw it once, under that name.
            n["url"] = pl.get("self") or url
            n["peers"] = [p for p in pl.get("peers", []) if p not in (url, n["url"])]
        except Exception as e:  # noqa: BLE001 - any failure means "down" here
            n["error"] = str(e)[:120]
        seen.add(n["url"])
        if n["url"] in nodes:
            continue
        nodes[n["url"]] = n
        for p in n["peers"]:
            if p not in seen:
                seen.add(p)
                queue.append(p)
    return nodes


def key_id(spki_b64):
    return hashlib.sha256(base64.b64decode(spki_b64)).hexdigest()


def short(k):
    return k[:8]


def host(url):
    return re.sub(r"^https?://", "", url).split("/")[0]


def mid(s):
    return re.sub(r"[^A-Za-z0-9]", "_", s)


def build(nodes, hints):
    up = [n for n in nodes.values() if n["up"]]
    if not up:
        sys.exit("no node answered")
    best = max(up, key=lambda n: n["info"]["height"])
    base = best["url"]
    auth = get(base + "/api/v1/explorer/authorities")
    blocks = get(base + "/api/v1/explorer/blocks?limit=100").get("blocks", [])

    last_signed = {}
    for b in blocks:
        last_signed.setdefault(b["signer"], b["height"])
    genesis_names = {key_id(g["publicKey"]): g["name"] for g in auth.get("genesis", [])}
    validators = auth.get("validators", {})
    active = set(auth.get("current", []))
    candidates = set(auth.get("candidates", []))
    all_keys = list(dict.fromkeys(auth.get("current", []) + auth.get("candidates", []) + auth.get("canSign", [])))

    # key -> node, from the node itself when it says, else from the hints.
    holder, from_hint = {}, set()
    for n in nodes.values():
        keys = (n.get("info") or {}).get("signingKeys")
        if keys is None:
            keys = hints.get(n["url"], {}).get("keys", [])
            if keys:
                from_hint.add(n["url"])
        for k in keys:
            match = [full for full in all_keys if full.startswith(k)]
            for full in match or [k]:
                holder[full] = n["url"]
    # A key a node holds that the chain does not know yet: generated, not
    # registered (or its record still waits for a block).
    unregistered = [k for k in holder if k not in all_keys]
    all_keys = all_keys + unregistered

    def owner(k):
        if k in unregistered:
            return "još nije na lancu", "none"
        if k in validators:
            return validators[k], "eid"
        return genesis_names.get(k, "genesis/rotation key " + short(k)), "key"

    voters = {}
    for k in active:
        name, kind = owner(k)
        voters[(name if kind == "eid" else k)] = name
    return dict(best=best, auth=auth, blocks=blocks, last_signed=last_signed, active=active,
                candidates=candidates, all_keys=all_keys, unregistered=unregistered, holder=holder, from_hint=from_hint,
                owner=owner, voters=voters)


def label(n, hints):
    h = hints.get(n["url"], {}).get("host")
    return host(n["url"]) + (f"<br/>{h}" if h else "")


def render_md(nodes, d, hints, now):
    best = d["best"]["info"]
    out = []
    w = out.append
    w("# eidchain: čvorovi i ključevi")
    w("")
    w(f"Generirano **{now:%d.%m.%Y. %H:%M} ({now.tzname()})** skriptom `scripts/chain-map.py`. "
      "Ne uređivati ručno: svako pokretanje prepisuje dokument stanjem lanca u tom trenutku.")
    w("")
    w(f"- Lanac `{best['genesisHash'][:12]}`, visina **{best['height']}**, head `{best['head'][:12]}`")
    w(f"- Javnih čvorova: **{sum(n['up'] for n in nodes.values())}** od {len(nodes)} poznatih")
    w(f"- Glasača (N): **{len(d['voters'])}**, signer window {d['auth'].get('window')}, "
      f"kvorum za rotaciju {d['auth'].get('quorum')}")
    w(f"- Ključeva koji smiju potpisivati: {len(d['all_keys'])} "
      f"(aktivnih {len(d['active'])}, kandidata {len(d['candidates'])})")
    w(f"- Poruka na čekanju: {best['pending']}")
    w("")

    w("## Čvorovi i tko koga zna")
    w("")
    w("Strelica A → B: A ima B na popisu peerova, pa gura blokove prema B i povlači s njega. "
      "Vidljivi su samo čvorovi s javnom adresom.")
    w("")
    w("```mermaid")
    w("flowchart LR")
    for n in nodes.values():
        i = n.get("info") or {}
        state = f"visina {i['height']}, head {i['head'][:8]}" if n["up"] else "ne odgovara"
        w(f'  {mid(n["url"])}["{label(n, hints)}<br/>{state}"]')
        if not n["up"]:
            w(f"  style {mid(n['url'])} fill:#fdd,stroke:#c33")
    for n in nodes.values():
        for p in n["peers"]:
            if p in nodes:
                w(f"  {mid(n['url'])} --> {mid(p)}")
    w("```")
    w("")

    w("## Ključevi, osobe i čvorovi")
    w("")
    w("Glas ima osoba (eID) ili ključ bez osobe (genesis). Svi ključevi jedne osobe su jedan glas. "
      "Puna linija: aktivan ključ. Isprekidana: kandidat, koji počinje vrijediti kad potpiše blok.")
    w("")
    w("```mermaid")
    w("flowchart LR")
    for n in nodes.values():
        w(f'  subgraph {mid(n["url"])}["{hints.get(n["url"], {}).get("host") or host(n["url"])}"]')
        for k in d["all_keys"]:
            if d["holder"].get(k) == n["url"]:
                w(f'    k{short(k)}(["{short(k)}"])')
        w("  end")
    loose = [k for k in d["all_keys"] if k not in d["holder"]]
    if loose:
        w('  subgraph unknown["čvor nepoznat"]')
        for k in loose:
            w(f'    k{short(k)}(["{short(k)}"])')
        w("  end")
    people = {}
    for k in d["all_keys"]:
        name, kind = d["owner"](k)
        if kind == "none":
            continue
        pid = mid("p_" + (name if kind == "eid" else k))
        if pid not in people:
            people[pid] = True
            shape = f'{pid}{{{{"{name}<br/>eID, 1 glas"}}}}' if kind == "eid" else f'{pid}["{name}<br/>1 glas"]'
            w(f"  {shape}")
        if kind == "none":
            continue
        arrow = "-->" if k in d["active"] else "-.->"
        w(f"  {pid} {arrow} k{short(k)}")
    w("```")
    w("")

    w("## Ključevi")
    w("")
    w("| ključ | čiji | stanje | čvor | zadnji potpisani blok |")
    w("|---|---|---|---|---|")
    for k in d["all_keys"]:
        name, _ = d["owner"](k)
        state = ("aktivan" if k in d["active"] else "kandidat" if k in d["candidates"]
                 else "nije registriran" if k in d["unregistered"] else "smije potpisivati")
        node = d["holder"].get(k)
        where = (host(node) + (" (iz hints)" if node in d["from_hint"] else "")) if node else "nepoznat"
        w(f"| `{short(k)}` | {name} | {state} | {where} | {d['last_signed'].get(k, '—')} |")
    w("")

    w("## Čvorovi")
    w("")
    w("| čvor | stanje | visina | čeka | potpisuje | radi od |")
    w("|---|---|---|---|---|---|")
    for n in nodes.values():
        i = n.get("info")
        if not i:
            w(f"| {host(n['url'])} | ne odgovara | | | | |")
            continue
        started = datetime.fromtimestamp(i["startedAt"], TZ).strftime("%d.%m. %H:%M")
        w(f"| {host(n['url'])} | {'može rezati blok' if i['canProduce'] else 'čeka svoj red'} | "
          f"{i['height']} | {i['pending']} | {len(i.get('signingKeys') or hints.get(n['url'], {}).get('keys', []))} | {started} |")
    w("")
    w("## Zadnji blokovi")
    w("")
    w("| visina | vrijeme | potpisao | poruka |")
    w("|---|---|---|---|")
    for b in d["blocks"][:10]:
        t = datetime.fromtimestamp(b["time"], TZ).strftime("%d.%m. %H:%M")
        w(f"| {b['height']} | {t} | `{short(b['signer'])}` {d['owner'](b['signer'])[0]} | {b['payloads']} |")
    w("")
    return "\n".join(out)


def render_pdf(md_path, pdf_path):
    pandoc = shutil.which("pandoc")
    if not pandoc:
        sys.exit("--pdf needs pandoc")
    body = subprocess.run([pandoc, "--from", "gfm", "--to", "html", md_path],
                          check=True, capture_output=True, text=True).stdout
    # pandoc keeps ```mermaid as <pre class="mermaid"><code>; mermaid wants the text directly.
    body = re.sub(r'<pre class="mermaid"><code>(.*?)</code></pre>',
                  lambda m: '<pre class="mermaid">' + m.group(1) + "</pre>", body, flags=re.S)
    page = f"""<!doctype html><html><head><meta charset="utf-8"><title>eidchain</title>
<style>
body{{font:11pt -apple-system,Helvetica,Arial,sans-serif;margin:24px;color:#111}}
table{{border-collapse:collapse;margin:8px 0}} td,th{{border:1px solid #bbb;padding:3px 8px;font-size:9.5pt}}
code{{font-size:9pt}} pre.mermaid{{text-align:center;page-break-inside:avoid}} h2{{margin-top:22px}}
</style>
<script src="{MERMAID}"></script>
<script>mermaid.initialize({{startOnLoad:true, theme:"neutral", flowchart:{{htmlLabels:true}}}});</script>
</head><body>{body}</body></html>"""
    chrome = next((p for p in ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                               "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"]
                   if os.path.exists(p)), None)
    if not chrome:
        sys.exit("--pdf needs Chrome or Brave")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "chain-map.html")
        with open(src, "w") as f:
            f.write(page)
        subprocess.run([chrome, "--headless=new", "--disable-gpu", f"--user-data-dir={tmp}/profile",
                        "--no-pdf-header-footer", "--virtual-time-budget=15000",
                        f"--print-to-pdf={pdf_path}", "file://" + src],
                       check=True, capture_output=True, timeout=120)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seed", action="append", help="node base URL to start from (repeatable)")
    ap.add_argument("--out", default=os.path.join(REPO, "docs", "chain-map.md"))
    ap.add_argument("--pdf", action="store_true", help="also write the .pdf next to --out")
    a = ap.parse_args()
    hints_path = os.path.join(REPO, "scripts", "chain-map-hints.json")
    hints = json.load(open(hints_path)) if os.path.exists(hints_path) else {}
    nodes = crawl(a.seed or SEEDS)
    d = build(nodes, hints)
    md = render_md(nodes, d, hints, datetime.now(timezone.utc).astimezone(TZ))
    with open(a.out, "w") as f:
        f.write(md)
    print(a.out)
    if a.pdf:
        pdf = os.path.splitext(a.out)[0] + ".pdf"
        render_pdf(a.out, pdf)
        print(pdf)


if __name__ == "__main__":
    main()
