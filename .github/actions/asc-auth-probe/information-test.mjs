// Does Apple's 401 distinguish anything? It answers the same request three ways:
//
//   with the key stored in the repository secret
//   with a key made here that Apple has never seen
//   with no Authorization header at all
//
// If the three answers are identical, then the status carries no information about which secret is
// wrong, and no further run against Apple from GitHub can settle it. That is the test that stops the
// guessing, rather than another round of the same request.
//
// Usage: probe2.mjs <secretKeyPath> <keyId> <issuerId>

import { generateKeyPairSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { importPKCS8, SignJWT } from 'jose';

const [keyPath, keyId, issuerId] = process.argv.slice(2);

const mint = async (pem) =>
  new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: keyId, typ: 'JWT' })
    .setIssuer(issuerId)
    .setIssuedAt(Math.floor(Date.now() / 1000))
    .setExpirationTime(Math.floor(Date.now() / 1000) + 1200)
    .setAudience('appstoreconnect-v1')
    .sign(await importPKCS8(pem, 'ES256'));

const ask = async (authorization) => {
  const headers = { Accept: 'application/json' };
  if (authorization) headers.Authorization = authorization;
  const response = await fetch('https://api.appstoreconnect.apple.com/v1/apps?limit=1', { headers });
  const body = await response.text();
  return { status: response.status, body: normalise(body) };
};

// Apple's response with its whitespace and request id removed, so two answers can be compared for
// equality rather than by eye.
function normalise(body) {
  try {
    return JSON.stringify(JSON.parse(body));
  } catch {
    return `non-json, ${body.length} characters`;
  }
}

// A key that exists only for the length of this run.
const stranger = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
  .privateKey.export({ type: 'pkcs8', format: 'pem' })
  .toString();

const stored = readFileSync(keyPath, 'utf8');

const answers = {
  'with the key from the repository secret': await ask(`Bearer ${await mint(stored)}`),
  'with a key Apple has never seen': await ask(`Bearer ${await mint(stranger)}`),
  'with no Authorization header at all': await ask(null),
  'with an empty bearer token': await ask('Bearer '),
};

for (const [label, answer] of Object.entries(answers)) {
  console.log(`${label}\n  HTTP ${answer.status}  ${answer.body}`);
}

const distinct = new Set(Object.values(answers).map((a) => `${a.status} ${a.body}`));
console.log('');
console.log(`distinct answers: ${distinct.size}`);
if (distinct.size === 1) {
  console.log('Apple answers identically for a known key, an unknown key and no token.');
  console.log('The 401 therefore names nothing, and no run from GitHub can tell the secrets apart.');
} else {
  console.log('Apple answers differently, so the status does carry information:');
  for (const answer of distinct) console.log(`  ${answer}`);
}