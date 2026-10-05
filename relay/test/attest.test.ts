// Синтетическая цепочка «как у Apple» (свой корень): проверяем все шаги verifyAttestation и отказы.
import "reflect-metadata";
import { test } from "node:test";
import assert from "node:assert/strict";
import { encode } from "cbor-x";
import { X509CertificateGenerator, Extension, BasicConstraintsExtension } from "@peculiar/x509";
import { verifyAttestation, makeChallenge, checkChallenge } from "../src/attest.ts";

const alg = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as const;
const sha = async (b: Uint8Array) => new Uint8Array(await crypto.subtle.digest("SHA-256", b));
const cat = (...p: Uint8Array[]) => { const o = new Uint8Array(p.reduce((n, x) => n + x.length, 0)); let i = 0; for (const x of p) { o.set(x, i); i += x.length; } return o; };
const b64 = (b: Uint8Array) => Buffer.from(b).toString("base64");
const APP = "TEAM123456.com.example.app";

async function build(opts: { challenge: string; aaguid?: string; counter?: number; appId?: string; badNonce?: boolean }) {
  const rootKeys = await crypto.subtle.generateKey(alg, true, ["sign", "verify"]);
  const interKeys = await crypto.subtle.generateKey(alg, true, ["sign", "verify"]);
  const leafKeys = await crypto.subtle.generateKey(alg, true, ["sign", "verify"]);
  const nb = new Date(Date.now() - 3600_000), na = new Date(Date.now() + 86400_000);
  const root = await X509CertificateGenerator.createSelfSigned({ serialNumber: "01", name: "CN=Test Root", notBefore: nb, notAfter: na, keys: rootKeys, signingAlgorithm: alg, extensions: [new BasicConstraintsExtension(true, 1, true)] });
  const inter = await X509CertificateGenerator.create({ serialNumber: "02", subject: "CN=Test Inter", issuer: root.subject, notBefore: nb, notAfter: na, publicKey: interKeys.publicKey, signingKey: rootKeys.privateKey, signingAlgorithm: alg, extensions: [new BasicConstraintsExtension(true, 0, true)] });

  const point = new Uint8Array(await crypto.subtle.exportKey("raw", leafKeys.publicKey));
  const keyId = await sha(point);
  const rp = await sha(new TextEncoder().encode(opts.appId ?? APP));
  const counter = new Uint8Array(4); new DataView(counter.buffer).setUint32(0, opts.counter ?? 0);
  const aaguid = new TextEncoder().encode(opts.aaguid ?? "appattestdevelop");
  const credLen = new Uint8Array([0, keyId.length]);
  const authData = cat(rp, new Uint8Array([0x40]), counter, aaguid, credLen, keyId);
  let nonce = await sha(cat(authData, await sha(new TextEncoder().encode(opts.challenge))));
  if (opts.badNonce) nonce = await sha(nonce);
  // SEQUENCE { [1] { OCTET STRING nonce } }
  const ext = cat(new Uint8Array([0x30, 36, 0xa1, 34, 0x04, 32]), nonce);
  const leaf = await X509CertificateGenerator.create({ serialNumber: "03", subject: "CN=Leaf", issuer: inter.subject, notBefore: nb, notAfter: na, publicKey: leafKeys.publicKey, signingKey: interKeys.privateKey, signingAlgorithm: alg, extensions: [new Extension("1.2.840.113635.100.8.2", false, ext)] });

  const att = encode({ fmt: "apple-appattest", attStmt: { x5c: [new Uint8Array(leaf.rawData), new Uint8Array(inter.rawData)], receipt: new Uint8Array(0) }, authData });
  return { attestation: b64(att), keyId: b64(keyId), rootPem: root.toString("pem") };
}

test("valid development attestation passes", async () => {
  const a = await build({ challenge: "c1" });
  assert.deepEqual(await verifyAttestation(a.attestation, a.keyId, "c1", { rootPem: a.rootPem, appId: APP }), { ok: true, env: "development" });
});

test("production aaguid is recognized", async () => {
  const a = await build({ challenge: "c1", aaguid: "appattest\0\0\0\0\0\0\0" });
  assert.deepEqual(await verifyAttestation(a.attestation, a.keyId, "c1", { rootPem: a.rootPem, appId: APP }), { ok: true, env: "production" });
});

test("rejects: other challenge, other app, wrong root, counter, nonce, key id", async () => {
  const a = await build({ challenge: "c1" });
  const v = (o: object, ch = "c1", key = a.keyId) => verifyAttestation(a.attestation, key, ch, { rootPem: a.rootPem, appId: APP, ...o });
  assert.equal((await v({}, "c2")).ok, false);
  assert.equal((await v({ appId: "OTHER.com.x" })).ok, false);
  assert.equal((await verifyAttestation(a.attestation, a.keyId, "c1", { appId: APP })).ok, false); // корень Apple
  const other = await build({ challenge: "c1" });
  assert.equal((await v({ rootPem: other.rootPem })).ok, false);
  assert.equal((await v({}, "c1", other.keyId)).ok, false);
  const c = await build({ challenge: "c1", counter: 1 });
  assert.equal((await verifyAttestation(c.attestation, c.keyId, "c1", { rootPem: c.rootPem, appId: APP })).ok, false);
  const n = await build({ challenge: "c1", badNonce: true });
  assert.equal((await verifyAttestation(n.attestation, n.keyId, "c1", { rootPem: n.rootPem, appId: APP })).ok, false);
});

test("challenge: signed, expires, tamper-proof", async () => {
  const ch = await makeChallenge("s3cret");
  assert.equal(await checkChallenge("s3cret", ch), true);
  assert.equal(await checkChallenge("other", ch), false);
  assert.equal(await checkChallenge("s3cret", ch.replace(/^\d+/, String(Date.now() - 10 * 60_000))), false);
});
