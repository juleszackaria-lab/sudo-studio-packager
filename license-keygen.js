#!/usr/bin/env node
/**
 * SUDO STUDIO PACKAGER - license-keygen (PROMPT 11).
 * Offline Ed25519 license issuer. Split by design:
 *   - THIS tool (packaging repo, vendor side) holds the PRIVATE key.
 *   - The app (Sudo-studio repo) embeds ONLY the public key and verifies.
 * The private key must NEVER be committed (see .gitignore + KEY_MANAGEMENT.md).
 * Usage:
 *   node license-keygen.js init --out license-private.pem [--print-const]
 *   node license-keygen.js issue --private license-private.pem --client "Acme" \
 *       --edition team --seats 10 --expires 2027-10-13 [--license-id ID] [--machine ID]
 *   node license-keygen.js verify --public <base64-SPKI|PEM> --key "<license key>"
 */
'use strict';
const crypto = require('crypto');
const fs = require('fs');

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
function fail(msg) { console.error('license-keygen: ' + msg); process.exit(2); }
function args() {
    const out = {};
    const a = process.argv.slice(3);
    for (let i = 0; i < a.length; i++) {
        if (a[i].startsWith('--')) {
            const k = a[i].slice(2);
            out[k] = (i + 1 < a.length && !a[i + 1].startsWith('--')) ? a[++i] : true;
        }
    }
    return out;
}

function cmdInit(o) {
    if (!o.out) fail('init needs --out <private-key-file>');
    if (fs.existsSync(o.out)) fail('refusing to overwrite existing ' + o.out);
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    fs.writeFileSync(o.out, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
    const spkiB64 = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
    const fp = crypto.createHash('sha256').update(spkiB64).digest('hex');
    console.log('private key written to ' + o.out + ' (mode 0600, NEVER commit it)');
    console.log('public key (SPKI DER, base64) -- embed in the app:');
    console.log(spkiB64);
    console.log('public key fingerprint (sha256): ' + fp);
    if (o['print-const']) {
        console.log('const PRODUCT_PUBLIC_KEY_SPKI_B64 = \'' + spkiB64 + '\';');
    }
}

function cmdIssue(o) {
    for (const k of ['private', 'client', 'edition', 'seats', 'expires']) {
        if (!o[k]) fail('issue needs --private --client --edition --seats --expires');
    }
    const edition = String(o.edition).toLowerCase();
    if (!EDITIONS[edition]) fail('unknown edition ' + o.edition + ' (want community|team|enterprise)');
    const seats = Number(o.seats);
    if (!Number.isInteger(seats) || seats < 1) fail('seats must be a positive integer');
    const exp = new Date(String(o.expires) + (String(o.expires).indexOf('T') === -1 ? 'T00:00:00Z' : ''));
    if (!Number.isFinite(exp.getTime())) fail('bad --expires date (want YYYY-MM-DD)');
    if (exp.getTime() <= Date.now()) fail('refusing to issue an already-expired key');
    let priv;
    try { priv = crypto.createPrivateKey(fs.readFileSync(o.private, 'utf8')); }
    catch { fail('cannot read private key ' + o.private); }
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
    if (!o.public || !o.key) fail('verify needs --public <base64-SPKI|PEM> --key <license>');
    let pub;
    try {
        const p = String(o.public);
        pub = p.indexOf('BEGIN') !== -1
            ? crypto.createPublicKey(p)
            : crypto.createPublicKey({ key: Buffer.from(p, 'base64'), format: 'der', type: 'spki' });
    } catch { fail('bad public key'); }
    const parts = String(o.key).split('.');
    if (parts.length !== 2) fail('bad key format (want payload.signature)');
    let payload;
    try { payload = JSON.parse(Buffer.from(parts[0].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8')); }
    catch { fail('payload is not valid JSON'); }
    const sig = Buffer.from(parts[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64');
    const ok = sig.length === 64 && crypto.verify(null, Buffer.from(parts[0], 'utf8'), pub, sig);
    console.log(ok ? 'VALID' : 'INVALID signature');
    console.log(JSON.stringify(payload, null, 2));
    process.exitCode = ok ? 0 : 1;
}

const cmd = process.argv[2];
if (cmd === 'init') cmdInit(args());
else if (cmd === 'issue') cmdIssue(args());
else if (cmd === 'verify') cmdVerify(args());
else {
    console.log('Usage: node license-keygen.js <init|issue|verify> [options]');
    console.log('  init   --out <file> [--print-const]');
    console.log('  issue  --private <pem> --client <name> --edition <e> --seats <n> --expires <YYYY-MM-DD> [--license-id <id>] [--machine <id>]');
    console.log('  verify --public <b64|pem> --key <key>');
    process.exit(2);
}
