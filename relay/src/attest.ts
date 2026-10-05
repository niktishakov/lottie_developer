// Проверка App Attest при регистрации айфона: регистрироваться может только настоящий Lottie Dev на настоящем устройстве.
// Шаги — по документации Apple «Validating apps that connect to your server».
import "reflect-metadata";
import { decode } from "cbor-x";
import { X509Certificate, cryptoProvider } from "@peculiar/x509";

cryptoProvider.set(crypto);

/// Корень Apple App Attestation (SHA-256 1CB9823B…C932), действует до 2045.
export const APPLE_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

/// Team ID + bundle ID приложения.
export const APP_ID = "LWV5ZRPC43.com.nikapps.lottie.developer";

const NONCE_OID = "1.2.840.113635.100.8.2";
const AAGUID_DEV = "appattestdevelop";
const AAGUID_PROD = "appattest\0\0\0\0\0\0\0";

export type AttestResult = { ok: true; env: "development" | "production" } | { ok: false; reason: string };

/// Копия в собственный ArrayBuffer (CBOR отдаёт срезы общего буфера).
const own = (b: Uint8Array) => new Uint8Array(b) as Uint8Array<ArrayBuffer>;
const sha256 = async (b: Uint8Array) => new Uint8Array(await crypto.subtle.digest("SHA-256", own(b)));
const eq = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((x, i) => x === b[i]);
const concat = (a: Uint8Array, b: Uint8Array) => { const o = new Uint8Array(a.length + b.length); o.set(a); o.set(b, a.length); return o; };
const b64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

/// attestation и keyId — base64 из DCAppAttestService; challenge — строка, которую выдал посредник.
export async function verifyAttestation(attestationB64: string, keyIdB64: string, challenge: string,
                                        opts: { rootPem?: string; appId?: string; now?: Date } = {}): Promise<AttestResult> {
  try {
    const obj = decode(b64(attestationB64)) as { fmt: string; attStmt: { x5c: Uint8Array[] }; authData: Uint8Array };
    if (obj.fmt !== "apple-appattest") return { ok: false, reason: "fmt" };
    const [leafDer, interDer] = obj.attStmt.x5c ?? [];
    if (!leafDer || !interDer) return { ok: false, reason: "x5c" };

    // 1. Цепочка: лист ← промежуточный ← корень Apple, все в сроке.
    const leaf = new X509Certificate(own(leafDer)), inter = new X509Certificate(own(interDer));
    const root = new X509Certificate(opts.rootPem ?? APPLE_ROOT_PEM);
    const now = opts.now ?? new Date();
    for (const c of [leaf, inter, root]) if (now < c.notBefore || now > c.notAfter) return { ok: false, reason: "expired" };
    if (!(await leaf.verify({ publicKey: inter, signatureOnly: true }))) return { ok: false, reason: "leaf signature" };
    if (!(await inter.verify({ publicKey: root, signatureOnly: true }))) return { ok: false, reason: "intermediate signature" };

    // 2–4. nonce = SHA256(authData ‖ SHA256(challenge)) лежит в расширении листа.
    const authData = own(obj.authData);
    const clientDataHash = await sha256(new TextEncoder().encode(challenge));
    const nonce = await sha256(concat(authData, clientDataHash));
    const ext = leaf.getExtension(NONCE_OID);
    if (!ext) return { ok: false, reason: "nonce extension" };
    // DER: SEQUENCE { [1] { OCTET STRING (32) } } — берём последние 32 байта.
    const raw = new Uint8Array(ext.value);
    if (!eq(raw.slice(raw.length - 32), nonce)) return { ok: false, reason: "nonce" };

    // 5. keyId = SHA256(открытого ключа листа, несжатая точка 65 байт).
    const spki = new Uint8Array(leaf.publicKey.rawData);
    const point = spki.slice(spki.length - 65);
    const keyId = b64(keyIdB64);
    if (!eq(await sha256(point), keyId)) return { ok: false, reason: "key id" };

    // 6–9. authData: rpIdHash, счётчик 0, aaguid среды, credentialId = keyId.
    const rpIdHash = authData.slice(0, 32);
    if (!eq(rpIdHash, await sha256(new TextEncoder().encode(opts.appId ?? APP_ID)))) return { ok: false, reason: "app id" };
    const counter = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
    if (counter !== 0) return { ok: false, reason: "counter" };
    const aaguid = new TextDecoder().decode(authData.slice(37, 53));
    const env = aaguid === AAGUID_DEV ? "development" : aaguid === AAGUID_PROD ? "production" : null;
    if (!env) return { ok: false, reason: "aaguid" };
    const credLen = new DataView(authData.buffer, authData.byteOffset + 53, 2).getUint16(0);
    if (!eq(authData.slice(55, 55 + credLen), keyId)) return { ok: false, reason: "credential id" };
    return { ok: true, env };
  } catch (e) {
    return { ok: false, reason: "malformed: " + (e as Error).message };
  }
}

// MARK: - Challenge без хранилища: «время.случайное.подпись», подпись — HMAC секретом посредника. Живёт 5 минут.

const CHALLENGE_TTL_MS = 5 * 60_000;

async function hmac(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data)));
  return btoa(String.fromCharCode(...sig)).replace(/[+/=]/g, (c) => ({ "+": "-", "/": "_", "=": "" })[c]!);
}

export async function makeChallenge(secret: string): Promise<string> {
  const rnd = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
  const body = `${Date.now()}.${rnd}`;
  return `${body}.${await hmac(secret, body)}`;
}

export async function checkChallenge(secret: string, challenge: string): Promise<boolean> {
  const parts = challenge.split(".");
  if (parts.length !== 3) return false;
  const [ts, rnd, sig] = parts;
  if (!(Date.now() - Number(ts) < CHALLENGE_TTL_MS)) return false;
  const want = await hmac(secret, `${ts}.${rnd}`);
  return want.length === sig.length && [...want].every((c, i) => c === sig[i]);
}
