// Signs a record with the eID card through Web eID: a detached CAdES-B-B
// signature over the record's exact bytes. Shared by the message and the
// validator pages.
import { getSigningCertificate, sign, WebEidError } from "./webeid-client.js";
import { b64ToBytes, bytesToB64, parseCertificate, ecdsaToDer } from "./der.js";
import { buildSignedAttributes, buildCms } from "./cades.js";

const HASH_PREFERENCE = ["SHA-256", "SHA-384", "SHA-512"];
const LANG = (navigator.language || "en").slice(0, 2); // for the Web eID dialogs

export const ERRORS = {
  ERR_WEBEID_EXTENSION_UNAVAILABLE: "The Web eID extension did not answer. Check that it is enabled for this site, then reload the page.",
  ERR_WEBEID_NATIVE_UNAVAILABLE: "The Web eID app is not installed (or not reachable). Install it from https://web-eid.eu.",
  ERR_WEBEID_USER_CANCELLED: "Signing was cancelled.",
  ERR_WEBEID_USER_TIMEOUT: "The PIN dialog timed out.",
  ERR_WEBEID_CONTEXT_INSECURE: "Web eID needs an HTTPS page or localhost.",
  ERR_WEBEID_ACTION_PENDING: "A previous request is still running. Wait for it, or reload the page.",
  ERR_WEBEID_VERSION_MISMATCH: "The Web eID extension and app versions do not match. Update both.",
  ERR_WEBEID_VERSION_INVALID: "The Web eID extension or app is too old. Update it.",
};

/** A readable message for an error from signing. */
export const errorText = (e) => e instanceof WebEidError ? (ERRORS[e.code] ?? `${e.code}: ${e.message}`) : e.message;

export const postJSON = (path, body) => fetch(path, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

/** Reads the card and returns the base64 CMS signature over payload. */
export async function signPayload(payload, maxBytes, setStatus) {
  const data = new TextEncoder().encode(payload);
  if (data.length > maxBytes) throw new Error(`The record is ${data.length} bytes; the limit is ${maxBytes}.`);

  setStatus("Reading the signing certificate from the card…");
  const { certificate, supportedSignatureAlgorithms } = await getSigningCertificate({ lang: LANG });
  const certDer = b64ToBytes(certificate);
  const info = parseCertificate(certDer);
  if (info.nonRepudiation === false) throw new Error("This is not the card's signing certificate (no non-repudiation key usage).");

  // Ask the node before the PIN, so nobody signs only to be refused.
  const check = await postJSON("api/v1/check-cert", { certificate });
  if (check.ok) {
    const answer = await check.json();
    if (!answer.ok) throw new Error(answer.problem);
  }

  const supported = new Set((supportedSignatureAlgorithms ?? []).map((a) => a.hashFunction));
  const hashFunction = supported.size ? HASH_PREFERENCE.find((h) => supported.has(h)) : "SHA-256";
  if (!hashFunction) throw new Error("The card supports no usable hash function.");

  const digest = new Uint8Array(await crypto.subtle.digest(hashFunction, data));
  const attrs = await buildSignedAttributes(digest, certDer, info, new Date());
  const attrsHash = new Uint8Array(await crypto.subtle.digest(hashFunction, attrs.toBeSigned));

  setStatus("Enter your signing PIN (PIN2) in the Web eID window…");
  const { signature, signatureAlgorithm } = await sign(certificate, bytesToB64(attrsHash), hashFunction, { lang: LANG });
  if (signatureAlgorithm.paddingScheme === "PSS") throw new Error("The card used RSA-PSS, which is not supported.");
  const sigBytes = b64ToBytes(signature);
  const cms = buildCms({
    certDer, info, hashFunction, cryptoAlgorithm: signatureAlgorithm.cryptoAlgorithm,
    signedAttrs: attrs.embedded,
    signature: signatureAlgorithm.cryptoAlgorithm === "ECC" ? ecdsaToDer(sigBytes) : sigBytes,
  });
  return bytesToB64(cms);
}
