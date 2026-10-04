#!/usr/bin/env node
// Signs one App Store Connect GET with the repository key and reports what came back.
//
//   node asc-get.mjs <path> <output-file>
//
// Reads APPSTORE_KEY_PATH, APPSTORE_KEY_ID and APPSTORE_ISSUER_ID from the environment. Prints only
// "HTTP <code>" to stdout and writes the response body to <output-file>, so the caller decides what
// the body means and the key and the token never reach the log.
import { createPrivateKey, createSign, createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const [, , path, outFile] = process.argv;
const keyPath = process.env.APPSTORE_KEY_PATH;
const keyId = process.env.APPSTORE_KEY_ID;
const issuerId = process.env.APPSTORE_ISSUER_ID;

if (!path || !outFile) {
  process.stderr.write('usage: asc-get.mjs <path> <output-file>\n');
  process.exit(2);
}
if (!keyPath || !keyId || !issuerId) {
  process.stderr.write('APPSTORE_KEY_PATH, APPSTORE_KEY_ID and APPSTORE_ISSUER_ID must all be set.\n');
  process.exit(2);
}

const b64url = (raw) => raw.toString('base64url');
const compact = (value) => JSON.stringify(value);

const issued = Math.floor(Date.now() / 1000);
const header = b64url(Buffer.from(compact({ alg: 'ES256', kid: keyId, typ: 'JWT' })));
const payload = b64url(Buffer.from(compact({
  iss: issuerId,
  iat: issued,
  exp: issued + 1200,
  aud: 'appstoreconnect-v1',
})));
const signingInput = `${header}.${payload}`;

// openssl emits a DER sequence of two integers and ES256 carries the bare r and s, so the pair is
// converted here rather than left for whichever reader tries to verify it.
const key = createPrivateKey({ key: readFileSync(keyPath, 'utf8'), format: 'pem' });
const der = createSign('sha256').update(signingInput).sign(key);
const length = der[1] < 0x80 ? 2 : 2 + (der[1] & 0x7f);
const parts = [];
for (let index = length, taken = 0; taken < 2; taken += 1) {
  const size = der[index + 1];
  parts.push(der.subarray(index + 2, index + 2 + size));
  index += 2 + size;
}
const raw = Buffer.concat(parts.map((part) => {
  const trimmed = part[0] === 0 ? part.subarray(1) : part;
  return Buffer.concat([Buffer.alloc(32 - trimmed.length), trimmed]);
}));

const token = `${signingInput}.${b64url(raw)}`;

// Apple's API sits behind a gateway that answers a raw "[" or "]" in the query with a 404 that reads
// as a missing endpoint rather than a rejected query. Every filter this job sends is written
// filter[name]=value, which is where those two characters come from, so this is done here once for
// every caller instead of in each URL that is built by hand. Node leaves brackets alone when it
// parses a URL, so the encoding has to be explicit. Only the query is touched, and only those two
// characters, so a request that carries no filter reaches the API exactly as it was written.
const target = new URL(`https://api.appstoreconnect.apple.com${path}`);
target.search = target.search.replaceAll('[', '%5B').replaceAll(']', '%5D');

try {
  const response = await fetch(target, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
    },
  });
  const body = await response.text();
  writeFileSync(outFile, body);
  process.stdout.write(`HTTP ${response.status}\n`);
} catch (error) {
  writeFileSync(outFile, '');
  process.stderr.write(`the request did not complete: ${error.cause?.code ?? error.message}\n`);
  process.stdout.write('HTTP none\n');
}

// A fingerprint of the key goes to stderr, so stdout stays only the status line and a caller can
// take the status with a command substitution without having to strip anything.
process.stderr.write(`key sha256 starts ${createHash('sha256').update(readFileSync(keyPath)).digest('hex').slice(0, 16)}\n`);