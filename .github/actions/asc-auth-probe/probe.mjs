// An independent check of whether App Store Connect accepts this API key.
//
// It signs its JWT with jose, a JOSE implementation that does not share code with the Python and
// OpenSSL in ios-build.yml, so a disagreement between the two points at the signing code rather than
// at the credentials. The private key is handed to jose exactly as the secret holds it, so nothing
// here can paper over a key that needed rescuing first.
//
// Nothing secret is printed. Only shapes, lengths, HTTP codes and Apple's own error text.

import { createHash, createPrivateKey, createPublicKey } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { importPKCS8, SignJWT } from 'jose';

const keyPath = process.argv[2];
const keyId = process.argv[3];
const issuerId = process.argv[4];

// The verdict has to reach the workflow as a status, not only as a paragraph. A probe that exits 0
// whatever Apple answers turns a rejected key into a green run, which is the one outcome this file
// exists to prevent. Each outcome gets its own code so the step log says which one it was.
const EXIT_ACCEPTED = 0;
const EXIT_UNAUTHORIZED = 1;
const EXIT_FORBIDDEN = 2;
const EXIT_INCONCLUSIVE = 3;
const EXIT_NETWORK = 4;

const report = (line) => process.stdout.write(`${line}\n`);

report('=== key shape, read verbatim from the secret ===');

const pem = readFileSync(keyPath, 'utf8');

// No trimming, no marker extraction, no base64 juggling: the secret is either a PEM or it is not.
const isPem = /^-----BEGIN [A-Z0-9 ]+-----$/m.test(pem.split('\n')[0] ?? '');
report(`the secret is a PEM armour block: ${isPem ? 'yes' : 'NO'}`);
report(`the PEM holds ${pem.split('\n').length} lines and ${Buffer.byteLength(pem)} bytes`);

const privateKey = readPrivateKey(pem);
const curve = privateKey.asymmetricKeyDetails?.namedCurve ?? 'unknown';
report(`node parsed the private key: yes`);
report(`curve: ${curve}`);

// App Store Connect issues ES256 on prime256v1 and nothing else, so a key of another curve cannot
// authenticate however well it is signed. jose accepts an RSA key at import and only fails later, at
// signing time, so the curve is checked here where the reason is still visible.
if (curve !== 'prime256v1') {
  report(`This key is ${curve}, not prime256v1, so it cannot be used for App Store Connect at all.`);
  process.exit(1);
}

// jose has to be able to import it too, because that is what will sign the request. A key node can
// read but jose cannot would fail differently, and quietly, so it is worth separating the two.
let signingKey;
try {
  signingKey = await importPKCS8(pem, 'ES256');
  report('jose imported the same PEM as an ES256 signing key: yes');
} catch (error) {
  report(`jose imported the same PEM as an ES256 signing key: NO (${error.message})`);
  process.exit(1);
}

const publicKey = createPublicKey(privateKey);
const spki = publicKey.export({ type: 'spki', format: 'der' });
report(`public key fingerprint: sha256:${createHashOf(spki)}`);
report('the fingerprint is a digest of the public key, safe to compare against App Store Connect.');

report('');
report('=== claims ===');

// Shapes only. The values are credentials, so their lengths stand in for them.
report(`key id length: ${keyId.length} (Apple issues 10)`);
report(`issuer id length: ${issuerId.length} (a UUID is 36)`);
report(`issuer id is a UUID: ${/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(issuerId) ? 'yes' : 'NO'}`);

// The runner clock decides iat, and Apple compares it against its own. A runner whose clock has
// drifted produces a token Apple considers expired or not yet valid, which reads exactly like a bad
// signature, so the offset is measured rather than assumed.
const runnerNow = Math.floor(Date.now() / 1000);
const serverNow = await appleEpoch();
report(`runner clock: ${new Date(runnerNow * 1000).toISOString()}`);
report(`Apple clock, from the Date header of an unsigned request: ${serverNow === null ? 'unavailable' : new Date(serverNow * 1000).toISOString()}`);
if (serverNow !== null) {
  const skew = runnerNow - serverNow;
  report(`clock offset: ${skew} seconds`);
  report(`a token Apple would accept needs iat within 60 seconds of its own clock: ${Math.abs(skew) <= 60 ? 'yes' : 'NO'}`);
}

report('');
report('=== signed request ===');

const token = await new SignJWT({})
  .setProtectedHeader({ alg: 'ES256', kid: keyId, typ: 'JWT' })
  .setIssuer(issuerId)
  .setIssuedAt(runnerNow)
  .setExpirationTime(runnerNow + 1200)
  .setAudience('appstoreconnect-v1')
  .sign(signingKey);

// Parsed back, so the log shows what was actually signed without showing the token.
const [rawHeader, rawPayload] = token.split('.').slice(0, 2).map((part) => JSON.parse(Buffer.from(part, 'base64url').toString()));
report(`header claims: ${Object.keys(rawHeader).join(', ')}`);
report(`header alg: ${rawHeader.alg}, kid length ${rawHeader.kid?.length ?? 0}`);
report(`payload claims: ${Object.keys(rawPayload).join(', ')}`);
report(`payload aud: ${rawPayload.aud}, iss length ${rawPayload.iss?.length ?? 0}`);
report(`exp minus iat: ${rawPayload.exp - rawPayload.iat} seconds (Apple allows 1200)`);
report(`token length: ${token.length} characters, not printed`);

const response = await askApple(token);
report('');
report(`HTTP ${response.status} ${response.statusText}`.trim());
report(`Apple clock at the time of this request: ${formatAppleClock(response.headers.get('date'))}`);

const body = await response.text();
if (body.trim() === '') {
  report('body: empty');
} else {
  try {
    const parsed = JSON.parse(body);
    for (const error of parsed.errors ?? []) {
      report(`Apple said [${error.code ?? '?'}]: ${error.title ?? ''}`);
      if (error.detail) report(`  ${error.detail}`);
    }
    if (!parsed.errors) report(`body keys: ${Object.keys(parsed).join(', ')}`);
  } catch {
    // Apple's HTML error pages carry no structured detail. Reporting the length is enough to know
    // it was not the JSON this check expects, without dumping a page into the log.
    report(`body: not JSON, ${body.length} characters`);
  }
}

report('');
report('=== what this result establishes ===');
if (response.status === 200) {
  report('A library independent of the workflow signed a request Apple accepted, so the three secrets are valid.');
  report('A 401 from ios-build.yml is therefore a defect in its signing code, not in the credentials.');
  process.exit(EXIT_ACCEPTED);
}
if (response.status === 401) {
  report('A library independent of the workflow was rejected too, so the credentials are the cause.');
  report('This names no single secret: the issuer may be another team, the key may be revoked or');
  report('not yet active, or the key id may not belong to the uploaded key.');
  report('This probe exits non-zero: Apple refused the request, so the run must not report success.');
  process.exit(EXIT_UNAUTHORIZED);
}
if (response.status === 403) {
  report('The signature was accepted and the request was refused for scope, not for identity.');
  report('Check the role held by this key in Users and Access.');
  report('This probe exits non-zero: the request was refused, so the run must not report success.');
  process.exit(EXIT_FORBIDDEN);
}
report(`Neither accepted nor refused the request (HTTP ${response.status}), so this says nothing about the key.`);
report('This probe exits non-zero: an unexpected status is not a result, and claiming success would be false.');
process.exit(EXIT_INCONCLUSIVE);

// Apple answered, so the caller can read a status. A transport failure is not an answer: it is
// reported as itself and ends the run without a verdict, because a probe that cannot reach Apple has
// neither confirmed nor refuted the credentials.
async function askApple(token) {
  try {
    return await fetch('https://api.appstoreconnect.apple.com/v1/apps?limit=1', {
      headers: { Authorization: `Bearer ${token}` },
    });
  } catch (error) {
    report('');
    report('=== what this result establishes ===');
    report(`No response from App Store Connect: ${error.message}`);
    report('Nothing was established about the credentials: Apple was never reached, so no status exists.');
    report('This probe exits non-zero, and separately from an HTTP status, so a network fault cannot be');
    report('mistaken for a decision by Apple.');
    process.exit(EXIT_NETWORK);
  }
}

function createHashOf(bytes) {
  return createHash('sha256').update(bytes).digest('base64url').slice(0, 16);
}

// A secret that is not a usable key is a finding, not a crash. Node's parser raises a stack trace
// whose "reason" line names the problem only to someone who knows OpenSSL's error codes, so the
// message is reduced to something a log reader can act on.
function readPrivateKey(pem) {
  try {
    return createPrivateKey({ key: pem, format: 'pem' });
  } catch (error) {
    report(`node parsed the private key: NO (${error.reason ?? error.message})`);
    report('APPSTORE_PRIVATE_KEY does not hold a PEM this probe can read. Nothing was sent to Apple.');
    process.exit(1);
  }
}

// The Date header is an RFC 1123 date, not a number, so it has to be parsed rather than cast. Absent
// or unparseable leaves the clock comparison unreported instead of breaking the run after the one
// result that matters, the HTTP code.
function formatAppleClock(header) {
  if (!header) return 'unavailable';
  const parsed = Date.parse(header);
  return Number.isNaN(parsed) ? 'unparseable' : new Date(parsed).toISOString();
}

// An unsigned request still returns a Date header, which is Apple's clock without needing the token
// to be accepted first. Returns null rather than guessing when the header is absent.
async function appleEpoch() {
  try {
    const response = await fetch('https://api.appstoreconnect.apple.com/v1/apps?limit=1', {
      headers: { Accept: 'application/json' },
    });
    const date = response.headers.get('date');
    const parsed = date ? Date.parse(date) : NaN;
    return Number.isNaN(parsed) ? null : Math.floor(parsed / 1000);
  } catch {
    return null;
  }
}