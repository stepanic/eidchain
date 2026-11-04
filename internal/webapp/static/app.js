import { onTrace } from "./webeid-client.js";
import { signPayload, errorText, postJSON } from "./sign.js";
import { setTicker } from "./nav.js";

const $ = (id) => document.getElementById(id);
let maxBytes = 10 * 1024;
let busy = false; // a signature is in progress
let signed = null; // a finished signature that could not be delivered: {text, payload, cms}
let chainId = ""; // the genesis hash: records name their chain, so they cannot be replayed on another

const setStatus = (text, kind = "") => { $("status").textContent = text; $("status").className = kind; };
const utf8 = (s) => new TextEncoder().encode(s);

onTrace((line) => { $("trace").textContent += `${new Date().toISOString().slice(11, 23)}  ${line}\n`; });

function record(text) {
  return JSON.stringify({ type: "message", chain: chainId, text, created: new Date().toISOString() });
}

function updateCount() {
  const bytes = utf8(record($("text").value)).length;
  $("count").textContent = `${bytes} / ${maxBytes} bytes`;
  $("submit").disabled = busy || bytes > maxBytes || !$("text").value.trim() || !chainId;
  $("count").style.color = bytes > maxBytes ? "var(--err)" : "";
}

async function getJSON(path) {
  const r = await fetch(path);
  if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
  return r.json();
}

function fmtTime(unix) { return new Date(unix * 1000).toLocaleString(); }

async function refresh() {
  try {
    const info = await getJSON("api/v1/info");
    maxBytes = info.maxPayloadBytes;
    chainId = info.genesisHash;
    $("chain").textContent = `“${info.message}”`;
    setTicker(info.message);
    const next = info.pending > 0 ? fmtTime(info.nextBlockAt) : `every ${info.blockIntervalSeconds / 60} min`;
    const stats = $("stats");
    stats.replaceChildren();
    for (const [label, value] of [["blocks", info.height], ["pending", info.pending], ["next block", next], ["authorities", info.authorities.length]]) {
      const box = document.createElement("div");
      box.className = "stat";
      const l = document.createElement("span");
      l.className = "label";
      l.textContent = label;
      const b = document.createElement("b");
      b.textContent = value;
      box.append(l, b);
      stats.append(box);
    }
    updateCount();
    const msgs = await getJSON("api/v1/messages?limit=10");
    const ul = $("messages");
    ul.replaceChildren();
    for (const m of msgs) {
      let text = m.payload;
      try { text = JSON.parse(m.payload).text ?? m.payload; } catch { /* show raw */ }
      const li = document.createElement("li");
      const badge = document.createElement("span");
      badge.className = `badge ${m.status}`;
      badge.textContent = m.status === "pending" ? "pending" : `block ${m.height}`;
      const body = document.createElement("div");
      body.className = "text";
      body.textContent = text;
      const meta = document.createElement("div");
      meta.className = "meta";
      const link = document.createElement("a");
      link.href = `explorer.html#/tx/${m.id}`;
      link.textContent = "details";
      meta.append(`${m.subject} · ${fmtTime(m.time)}${m.ocsp ? " · OCSP checked" : ""} · `, link);
      li.append(badge, body, meta);
      ul.append(li);
    }
  } catch (e) {
    $("chain").textContent = `Cannot reach the node: ${e.message}`;
  }
}

/** Reads the card and returns the record and its CAdES signature. */
async function signRecord(text) {
  const payload = record(text);
  return { text, payload, cms: await signPayload(payload, maxBytes, setStatus) };
}

const RETRY = "Your signature is kept: press the button again to retry without the PIN.";

async function run() {
  const text = $("text").value;
  busy = true;
  updateCount();
  $("trace").textContent = "";
  try {
    if (signed?.text !== text) signed = await signRecord(text);
    setStatus("Submitting to the node (it checks the signature and the certificate's revocation status)…");
    let r;
    try {
      r = await postJSON("api/v1/payloads", { payload: signed.payload, signature: signed.cms });
    } catch {
      throw new Error(`The node could not be reached. ${RETRY}`);
    }
    const body = await r.json().catch(() => ({}));
    if (r.status === 503) throw new Error(`${body.error ?? "The node is busy."} ${RETRY}`);
    const accepted = r.ok;
    const reason = body.error ?? `HTTP ${r.status}`;
    signed = null;
    if (!accepted) throw new Error(reason);
    $("text").value = "";
    setStatus(body.status === "known" ? "You have already submitted that exact message." : "Accepted: it will be in the next block.", "ok");
    refresh();
  } catch (e) {
    setStatus(errorText(e), "error");
    $("diagnostics").open = true;
  } finally {
    busy = false;
    updateCount();
  }
}

$("text").addEventListener("input", updateCount);
$("submit").addEventListener("click", run);
updateCount();
refresh();
setInterval(refresh, 15000);
