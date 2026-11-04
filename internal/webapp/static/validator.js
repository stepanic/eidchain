// Signs a validator registration (written by `eidchain validator request`) with
// the eID card and submits it. The record is signed exactly as pasted: the key's
// proof inside it covers the chain and the key, not the formatting.
import { onTrace } from "./webeid-client.js";
import { b64ToBytes, bytesToHex } from "./der.js";
import { signPayload, errorText, postJSON } from "./sign.js";
import { setTicker } from "./nav.js";

const $ = (id) => document.getElementById(id);
let info = null;
let busy = false;

const setStatus = (text, kind = "") => { $("status").textContent = text; $("status").className = kind; };
onTrace((line) => { $("trace").textContent += `${new Date().toISOString().slice(11, 23)}  ${line}\n`; });


/** Checks the pasted record; returns what it does, or throws. */
async function inspect(text) {
  let r;
  try { r = JSON.parse(text); } catch { throw new Error("That is not the JSON record that `eidchain validator request` prints."); }
  if (r?.type !== "validator" || !(r.key && r.proof) && !r.retire) throw new Error("That is not a validator registration.");
  if (r.chain !== info.genesisHash) throw new Error(`The record is for another chain (${String(r.chain).slice(0, 12)}…); this node runs ${info.genesisHash.slice(0, 12)}….`);
  if (!info.features?.["eid-validators"]) throw new Error("This chain does not take validator registrations.");
  const parts = [];
  if (r.key) parts.push(`registers key ${bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", b64ToBytes(r.key))))}`);
  if (r.retire) parts.push(`retires key ${r.retire}`);
  return parts.join(" and ");
}

async function update() {
  const text = $("record").value.trim();
  $("about").textContent = "";
  $("submit").disabled = true;
  if (!text || !info || busy) return;
  try {
    const what = await inspect(text);
    $("about").textContent = `This record ${what}.`;
    $("submit").disabled = false;
  } catch (e) {
    $("about").textContent = e.message;
  }
}

async function run() {
  const payload = $("record").value.trim();
  busy = true;
  $("submit").disabled = true;
  $("trace").textContent = "";
  try {
    await inspect(payload);
    const cms = await signPayload(payload, info.maxPayloadBytes, setStatus);
    setStatus("Submitting to the node…");
    const r = await postJSON("api/v1/payloads", { payload, signature: cms });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error ?? `HTTP ${r.status}`);
    setStatus(body.status === "known" ? "This record was already submitted." : "Accepted: it takes effect in the next block.", "ok");
  } catch (e) {
    setStatus(errorText(e), "error");
    $("diagnostics").open = true;
  } finally {
    busy = false;
    update();
  }
}

async function load() {
  try {
    info = await (await fetch("api/v1/info")).json();
    $("chain").textContent = `“${info.message}”`;
    setTicker(info.message);
    $("server").textContent = new URL(".", location.href).href.replace(/\/$/, "");
  } catch (e) {
    $("chain").textContent = `Cannot reach the node: ${e.message}`;
  }
  update();
}

$("record").addEventListener("input", update);
$("submit").addEventListener("click", run);
load();
