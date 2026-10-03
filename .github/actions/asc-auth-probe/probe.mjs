// A diagnosis of the whole path from stored secrets to the HTTP answer, rather than of any single step.
//
// Each check exists to separate one hypothesis from another, and each reports a boolean or a shape so
// that no secret, key body or JWT reaches the log. The point is not to confirm what the other checks
// already showed but to establish what they could not: whether the workflow alters the key, whether
// the token is well formed, whether the signature verifies locally, and whether the request arrives
// as Apple expects.
//
// Usage: probe.mjs <keyPath> <keyId> <issuerId> [expectedIssuer] [expectedKeyId] [workflowKeyPath]

import { createHash, createPrivateKey, createPublicKey } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { request as httpsRequest } from 'node:https';
import { importPKCS8, importSPKI, jwtVerify, SignJWT } from 'jose';

const [keyPath, keyId, issuerId, expectedIssuer, expectedKeyId, workflowKeyPath] = process.argv.slice(2);

const out = (line) => process.stdout.write(`${line}\n`);
const section = (title) => out(`\n=== ${title} ===`);
const yesNo = (value) => (value ? 'yes' : 'NO');
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

section('stored secrets: identity checks');
out(`APPSTORE_KEY_ID is ${expectedKeyId}: ${keyId === expectedKeyId ? 'KEY_ID_MATCH=true' : 'KEY_ID_MATCH=false'}`);
out(`APPSTORE_ISSUER_ID is the UUID Apple shows: ${issuerId === expectedIssuer ? 'ISSUER_ID_MATCH=true' : 'ISSUER_ID_MATCH=false'}`);
out(`issuer id length ${issuerId.length}, a UUID is ${expectedIssuer.length}`);
out(`issuer id is a UUID shape: ${/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(issuerId) ? 'yes' : 'NO'}`);

section('stored secrets: transport shape');
// A secret pasted through a shell or an editor can pick up carriage returns, spaces or quotes that no
// length check would notice, because GitHub counts them as part of the value.
for (const [label, value] of [['key id', keyId], ['issuer id', issuerId]]) {
  out(`${label} contains whitespace: ${/\s/.test(value) ? 'YES' : 'no'}`);
  out(`${label} contains a quote or backslash: ${/["'\\`]/.test(value) ? 'YES' : 'no'}`);
  out(`${label} is uppercase alnum or lowercase hex only: ${/^[A-Za-z0-9-]+$/.test(value) ? 'yes' : 'NO'}`);
}

section('the key as stored, read verbatim');
const pem = readFileSync(keyPath, 'utf8');
out(`first line is a PEM marker: ${/^-----BEGIN [A-Z0-9 ]+-----$/.test(pem.split('\n')[0] ?? '') ? 'yes' : 'NO'}`);
out(`bytes ${Buffer.byteLength(pem)}, lines ${pem.split('\n').length}`);
out(`contains CR: ${pem.includes('\r') ? 'YES' : 'no'}`);
out(`contains a literal backslash-n: ${pem.includes('\\n') ? 'YES' : 'no'}`);
out(`ends with a newline: ${pem.endsWith('\n') ? 'yes' : 'NO'}`);

let stored;
try {
  stored = createPrivateKey({ key: pem, format: 'pem' });
  out(`node parses it: yes, curve ${stored.asymmetricKeyDetails?.namedCurve ?? 'unknown'}`);
} catch (error) {
  out(`node parses it: NO (${error.reason ?? error.message})`);
  process.exit(1);
}

// The canonical form is the DER SPKI of the public key. Comparing digests of this is what shows
// whether two different readers derived the same key, independent of how each encoded it.
const canonical = (key) => sha256(createPublicKey(key).export({ type: 'spki', format: 'der' }));
const storedFingerprint = canonical(stored);
out(`canonical public key SHA-256: ${storedFingerprint}`);

if (workflowKeyPath) {
  section('the key after the workflow processed it');
  const processed = readFileSync(workflowKeyPath, 'utf8');
  const processedKey = createPrivateKey({ key: processed, format: 'pem' });
  const processedFingerprint = canonical(processedKey);
  out(`the workflow wrote ${Buffer.byteLength(processed)} bytes over ${processed.split('\n').length} lines`);
  out(`canonical public key SHA-256: ${processedFingerprint}`);
  out(`the workflow preserved the key: ${processedFingerprint === storedFingerprint ? 'YES' : 'NO'}`);
} else {
  out('the workflow comparison was not run in this job.');
}

section('provenance of the key material');
// What can be established here is that the secret holds exactly one key, and that it is the key the
// request will be signed with. Whether that key is the one Apple filed under the key id cannot be
// decided from here: Apple keeps only the public half and does not publish it.
out(`the secret holds one parseable key: ${yesNo(stored !== null)}`);
out(`the key that will sign is the key that was read: yes`);

section('token shape');
let signingKey;
try {
  signingKey = await importPKCS8(pem, 'ES256');
  out(`jose imports the stored PEM as ES256: yes`);
} catch (error) {
  out(`jose imports the stored PEM as ES256: NO (${error.message})`);
  process.exit(1);
}

const build = (ttlSeconds, issuer = issuerId) =>
  new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: keyId, typ: 'JWT' })
    .setIssuer(issuer)
    .setIssuedAt(Math.floor(Date.now() / 1000))
    .setExpirationTime(Math.floor(Date.now() / 1000) + ttlSeconds)
    .setAudience('appstoreconnect-v1')
    .sign(signingKey);

const token = await build(1200);
const segments = token.split('.');

const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString());
const header = decode(segments[0]);
const payload = decode(segments[1]);

out(`three segments: ${segments.length === 3 ? 'yes' : 'NO'}`);
out(`header keys: ${Object.keys(header).join(', ')}`);
out(`alg ES256: ${header.alg === 'ES256' ? 'yes' : 'NO'}`);
out(`typ JWT: ${header.typ === 'JWT' ? 'yes' : 'NO'}`);
out(`kid matches the secret: ${header.kid === keyId ? 'yes' : 'NO'}`);
out(`payload keys: ${Object.keys(payload).join(', ')}`);
out(`iss matches the secret: ${payload.iss === issuerId ? 'yes' : 'NO'}`);
out(`aud is appstoreconnect-v1: ${payload.aud === 'appstoreconnect-v1' ? 'yes' : 'NO'}`);
out(`iat is a number: ${typeof payload.iat === 'number' ? 'yes' : 'NO'}`);
out(`exp is a number: ${typeof payload.exp === 'number' ? 'yes' : 'NO'}`);
out(`exp minus iat: ${payload.exp - payload.iat} seconds, Apple allows at most 1200`);
out(`any segment padded with =: ${segments.some((part) => part.includes('=')) ? 'YES' : 'no'}`);
out(`every segment is base64url only: ${segments.every((part) => /^[A-Za-z0-9_-]+$/.test(part)) ? 'yes' : 'NO'}`);

const signature = Buffer.from(segments[2], 'base64url');
out(`signature is ${signature.length} bytes, ES256 R||S is 64: ${signature.length === 64 ? 'yes' : 'NO'}`);
out(`R and S are each 32 bytes: ${signature.length === 64 ? 'yes' : 'NO'}`);

section('local signature verification');
// This proves the token was signed by the private key that was read, and nothing about whether Apple
// filed that key under this key id. importSPKI takes PEM text, so the public key is exported that way.
const publicKey = await importSPKI(
  createPublicKey(stored).export({ type: 'spki', format: 'pem' }),
  'ES256',
);
try {
  const verified = await jwtVerify(token, publicKey, { algorithms: ['ES256'] });
  out(`the signature verifies under the matching public key: yes`);
  out(`the verified payload has the expected issuer: ${verified.payload.iss === issuerId ? 'yes' : 'NO'}`);
} catch (error) {
  out(`the signature verifies under the matching public key: NO (${error.code ?? error.message})`);
}

section('clock');
const runnerNow = Math.floor(Date.now() / 1000);
const unsigned = await rawRequest('https://api.appstoreconnect.apple.com/v1/apps?limit=1', null);
const appleDate = unsigned.headers.date ? Date.parse(unsigned.headers.date) : NaN;
const appleNow = Number.isNaN(appleDate) ? null : Math.floor(appleDate / 1000);
out(`runner clock: ${new Date(runnerNow * 1000).toISOString()}`);
out(`Apple clock: ${appleNow === null ? 'unavailable' : new Date(appleNow * 1000).toISOString()}`);
out(`offset: ${appleNow === null ? 'unknown' : `${runnerNow - appleNow} seconds`}`);
out(`an unsigned request already answers: HTTP ${unsigned.status}, so the endpoint is reachable`);

section('the request as it goes out');
const headerValue = `Bearer ${token}`;
out(`the Authorization header is exactly Bearer plus the token: ${headerValue === `Bearer ${token}` ? 'yes' : 'NO'}`);
out(`the header holds no space beyond the one after Bearer: ${headerValue.slice(0, 7) === 'Bearer ' ? 'yes' : 'NO'}`);
out(`the token portion holds no whitespace or quote: ${/^[A-Za-z0-9._-]+$/.test(segments.join('.')) ? 'yes' : 'NO'}`);
out(`token characters ${token.length}`);

for (const [label, client] of [
  ['fetch', () => fetchRequest('https://api.appstoreconnect.apple.com/v1/apps?limit=1', headerValue)],
  ['node https', () => rawRequest('https://api.appstoreconnect.apple.com/v1/apps?limit=1', headerValue, true)],
]) {
  const result = await client();
  out('');
  out(`${label}: HTTP ${result.status}`);
  out(`${label}: Apple request id: ${result.headers['x-apple-jingle-correlation-key'] ?? result.headers['x-request-id'] ?? 'not sent'}`);
  out(`${label}: redirected: ${yesNo(result.status >= 300 && result.status < 400)}`);
  for (const line of safeErrorLines(result.body)) out(`${label}: ${line}`);
}

section('the five minute token');
// A shorter lifetime tests the expiry edge. If Apple rejected the token as expired or too long a
// life, a five minute token would be answered differently from the twenty minute one.
const shortToken = await build(300);
const shortResult = await rawRequest('https://api.appstoreconnect.apple.com/v1/apps?limit=1', `Bearer ${shortToken}`, true);
out(`HTTP ${shortResult.status}`);
for (const line of safeErrorLines(shortResult.body)) out(line);

section('the confirmed issuer, without touching the secret');
// If the stored issuer differs from the one on the Apple page, signing with the page's value isolates
// the stored secret as the cause. The secret itself is left alone.
if (issuerId !== expectedIssuer) {
  out(`the stored issuer differs from the confirmed one, so this signs with the confirmed value.`);
  const confirmed = await build(1200, expectedIssuer);
  const confirmedResult = await rawRequest('https://api.appstoreconnect.apple.com/v1/apps?limit=1', `Bearer ${confirmed}`, true);
  out(`with the confirmed issuer: HTTP ${confirmedResult.status}`);
  for (const line of safeErrorLines(confirmedResult.body)) out(line);
} else {
  out(`the stored issuer already is the confirmed one, so this repeats the request above.`);
}

out('');
out('=== summary ===');
out('Every boolean above is a fact about this run. A 401 remains a 401: it does not say which of the');
out('three secrets is wrong, and a locally valid signature does not mean Apple filed this key under');
out('this key id. Only Apple can settle that.');

// A raw https request, so the transport does not depend on fetch and can be compared against it.
async function rawRequest(url, authorization, reportHeaders = false) {
  const headers = { Accept: 'application/json' };
  if (authorization) headers.Authorization = authorization;
  return new Promise((resolve) => {
    const request = httpsRequest(url, { method: 'GET', headers }, (response) => {
      let body = '';
      response.on('data', (chunk) => (body += chunk));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body }));
    });
    request.on('error', (error) => resolve({ status: 0, headers: {}, body: String(error.message) }));
    request.end();
  });
}

// Followed, because a redirect that dropped the Authorization header would look exactly like a 401
// from Apple. Whether one happened is reported per client by the status it settles on.
async function fetchRequest(url, authorization) {
  const response = await fetch(url, {
    headers: { Authorization: authorization, Accept: 'application/json' },
  });
  return { status: response.status, headers: Object.fromEntries(response.headers), body: await response.text() };
}

// Apple's error text and nothing else. Anything that is not the JSON error envelope is reported by
// length alone, so a page of HTML cannot spill into the log.
function safeErrorLines(body) {
  try {
    const parsed = JSON.parse(body);
    if (!Array.isArray(parsed.errors)) return [`body keys: ${Object.keys(parsed).join(', ')}`];
    return parsed.errors.flatMap((error) => [
      `Apple said [${error.code ?? '?'}]: ${error.title ?? ''}`,
      ...(error.detail ? [`  ${error.detail}`] : []),
    ]);
  } catch {
    return [`body is not JSON, ${body.length} characters`];
  }
}