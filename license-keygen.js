#!/usr/bin/env node
/**
 * SUDO STUDIO PACKAGER - license-keygen (PROMPT 11, extended PROMPT 16).
 * Offline Ed25519 license issuer. Split by design:
 *   - THIS tool (packaging repo, vendor side) holds the PRIVATE key.
 *   - The app (Sudo-studio repo) embeds ONLY the public key and verifies.
 * The private key must NEVER be committed (see .gitignore + KEY_MANAGEMENT.md).
 * Key format matches the product exactly: b64u(payloadJSON).b64u(signature64B).
 * Seats: positive integer; 999999 is the documented "unlimited" convention.
 * Usage:
 *   node license-keygen.js generate-keypair --out <dir> [--print-const]
 *   node license-keygen.js init --out <private-key-file> [--print-const]
 *   node license-keygen.js issue (--private <pem> | --keydir <dir>) --client "Acme"
 *       --edition team --seats 10 (--expires YYYY-MM-DD | --days N)
 *       [--license-id ID] [--machine ID] [--allow-expired]
 *   node license-keygen.js verify (<key> | --key <key>) (--public <b64|pem> | --keydir <dir>)
 */
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// MUST match EDITIONS in Sudo-studio (backend/src/license + extension/src/license).
const EDITIONS = {
    community: ['chat', 'doctor', 'sdk'],
    team: ['chat', 'doctor', 'sdk', 'devops', 'environment', 'agent'],
    enterprise: ['chat', 'doctor', 'sdk', 'devops', 'environment', 'agent',
        'security', 'duplication', 'central', 'cicd', 'license'],
};

function b64uEncode(buf) {
    return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function b64uDecode(s) {
    try {
        return Buffer.from(String(s).replace(/-/g, '+').replace(/_/g, '/'), 'base64');
    } catch { return null; }
}
function fail(msg) { console.error('license-keygen: ' + msg); process.exit(2); }
function args() {
    const out = { _: [] };
    const a = process.argv.slice(3);
    for (let i = 0; i < a.length; i++) {
        if (a[i].startsWith('--')) {
            const k = a[i].slice(2);
            out[k] = (i + 1 < a.length && !a[i + 1].startsWith('--')) ? a[++i] : true;
        } else {
            out._.push(a[i]);
        }
    }
    return out;
}
function fingerprint(spkiB64) {
    return crypto.createHash('sha256').update(spkiB64).digest('hex');
}
function loadPrivate(o) {
    const p = o.private || (o.keydir ? path.join(o.keydir, 'license_private.pem') : null);
    if (!p) fail('need --private <pem> or --keydir <dir>');
    try { return crypto.createPrivateKey(fs.readFileSync(p, 'utf8')); }
    catch { fail('cannot read private key ' + p); }
}
function loadPublic(o) {
    if (o.public) {
        const p = String(o.public);
        try {
            return p.indexOf('BEGIN') !== -1
                ? crypto.createPublicKey(p)
                : crypto.createPublicKey({ key: Buffer.from(p, 'base64'), format: 'der', type: 'spki' });
        } catch { fail('bad --public key'); }
    }
    if (o.keydir) {
        const f = path.join(o.keydir, 'license_public.spki.b64');
        try {
            const b64 = fs.readFileSync(f, 'utf8').trim();
            return crypto.createPublicKey({ key: Buffer.from(b64, 'base64'), format: 'der', type: 'spki' });
        } catch { fail('cannot read public key ' + f); }
    }
    fail('need --public <b64|pem> or --keydir <dir>');
}

function cmdGenerateKeypair(o) {
    if (!o.out) fail('generate-keypair needs --out <directory>');
    const dir = o.out;
    const privFile = path.join(dir, 'license_private.pem');
    const pubFile = path.join(dir, 'license_public.spki.b64');
    if (fs.existsSync(privFile) || fs.existsSync(pubFile)) {
        fail('refusing to overwrite existing keys in ' + dir);
    }
    fs.mkdirSync(dir, { recursive: true });
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    fs.writeFileSync(privFile, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
    try { fs.chmodSync(privFile, 0o600); } catch { /* best effort on win32 */ }
    const spkiB64 = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
    fs.writeFileSync(pubFile, spkiB64 + '\n', 'utf8');
    console.log('private key written to ' + privFile + ' (mode 0600, NEVER commit it)');
    console.log('public key written to ' + pubFile + ' (embed in the app build)');
    console.log('public key fingerprint (sha256): ' + fingerprint(spkiB64));
    if (o['print-const']) {
        console.log('const PRODUCT_PUBLIC_KEY_SPKI_B64 = \'' + spkiB64 + '\';');
    }
}

function cmdInit(o) {
    if (!o.out) fail('init needs --out <private-key-file>');
    if (fs.existsSync(o.out)) fail('refusing to overwrite existing ' + o.out);
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    fs.writeFileSync(o.out, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
    const spkiB64 = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
    console.log('private key written to ' + o.out + ' (mode 0600, NEVER commit it)');
    console.log('public key (SPKI DER, base64) -- embed in the app:');
    console.log(spkiB64);
    console.log('public key fingerprint (sha256): ' + fingerprint(spkiB64));
    if (o['print-const']) {
        console.log('const PRODUCT_PUBLIC_KEY_SPKI_B64 = \'' + spkiB64 + '\';');
    }
}

function cmdIssue(o) {
    for (const k of ['client', 'edition', 'seats']) {
        if (!o[k]) fail('issue needs --client --edition --seats plus (--expires | --days) and (--private | --keydir)');
    }
    const edition = String(o.edition).toLowerCase();
    if (!EDITIONS[edition]) fail('unknown edition ' + o.edition + ' (want community|team|enterprise)');
    const seats = Number(o.seats);
    if (!Number.isInteger(seats) || seats < 1) fail('seats must be a positive integer (999999 = unlimited)');
    let exp;
    if (o.days !== undefined) {
        const days = Number(o.days);
        if (!Number.isInteger(days)) fail('bad --days (want an integer)');
        exp = new Date(Date.now() + days * 86400000);
    } else if (o.expires) {
        exp = new Date(String(o.expires) + (String(o.expires).indexOf('T') === -1 ? 'T00:00:00Z' : ''));
        if (!Number.isFinite(exp.getTime())) fail('bad --expires date (want YYYY-MM-DD)');
    } else {
        fail('issue needs --expires YYYY-MM-DD or --days N');
    }
    if (exp.getTime() <= Date.now() && !o['allow-expired']) {
        fail('refusing to issue an already-expired key (pass --allow-expired for tests only)');
    }
    const priv = loadPrivate(o);
    const payload = {
        licenseId: o['license-id'] || ('LIC-' + crypto.randomBytes(4).toString('hex').toUpperCase()),
        client: String(o.client),
        edition,
        seats,
        issuedAt: new Date().toISOString(),
        expiresAt: exp.toISOString(),
        features: EDITIONS[edition].slice(),
    };
    if (o.machine) payload.machineId = String(o.machine);
    const part1 = b64uEncode(Buffer.from(JSON.stringify(payload), 'utf8'));
    const sig = crypto.sign(null, Buffer.from(part1, 'utf8'), priv);
    console.log(part1 + '.' + b64uEncode(sig));
}

function cmdVerify(o) {
    const key = o.key || o._[0];
    if (!key) fail('verify needs a key: verify <key> or verify --key <key>');
    const pub = loadPublic(o);
    const parts = String(key).split('.');
    if (parts.length !== 2 || !parts[0] || !parts[1]) fail('bad key format (want payload.signature)');
    let payload;
    try {
        const raw = b64uDecode(parts[0]);
        payload = JSON.parse(raw.toString('utf8'));
    } catch { fail('payload is not valid JSON'); }
    const sig = b64uDecode(parts[1]);
    const ok = !!sig && sig.length === 64 && crypto.verify(null, Buffer.from(parts[0], 'utf8'), pub, sig);
    const expMs = Date.parse(payload.expiresAt || '');
    const expired = Number.isFinite(expMs) && expMs <= Date.now();
    const expState = !Number.isFinite(expMs) ? 'unknown expiry'
        : expired ? 'EXPIRED on ' + payload.expiresAt : 'valid until ' + payload.expiresAt;
    if (!ok) console.log('INVALID signature');
    else if (expired) console.log('REFUSED: signature valid but key expired');
    else console.log('VALID signature');
    console.log('edition=' + payload.edition + ' client=' + payload.client +
        ' seats=' + payload.seats + ' licenseId=' + payload.licenseId);
    console.log('expiry: ' + expState);
    process.exitCode = (ok && !expired) ? 0 : 1;
}

const cmd = process.argv[2];
if (cmd === 'generate-keypair') cmdGenerateKeypair(args());
else if (cmd === 'init') cmdInit(args());
else if (cmd === 'issue') cmdIssue(args());
else if (cmd === 'verify') cmdVerify(args());
else {
    console.log('Usage: node license-keygen.js <generate-keypair|init|issue|verify> [options]');
    console.log('  generate-keypair --out <dir> [--print-const]');
    console.log('  init             --out <file> [--print-const]');
    console.log('  issue  (--private <pem> | --keydir <dir>) --client <n> --edition <e> --seats <n>');
    console.log('         (--expires YYYY-MM-DD | --days N) [--license-id <id>] [--machine <id>] [--allow-expired]');
    console.log('  verify (<key> | --key <key>) (--public <b64|pem> | --keydir <dir>)');
    process.exit(2);
}
