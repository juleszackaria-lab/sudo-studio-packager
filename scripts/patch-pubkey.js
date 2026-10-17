#!/usr/bin/env node
/**
 * SUDO STUDIO PACKAGER - patch-pubkey (PROMPT 16).
 * Build-time substitution of the embedded license public key.
 * Operates on BUILD COPIES only (never on a git checkout): dev builds run this
 * with dev-pubkey/license_public.spki.b64 so test keys work; production builds
 * keep the production constant untouched.
 * There is deliberately NO runtime switch: exactly one key per build.
 * Usage: node scripts/patch-pubkey.js <spki-b64-file> <file...>
 * ASCII-only.
 */
'use strict';
const crypto = require('crypto');
const fs = require('fs');

const args = process.argv.slice(2);
if (args.length < 2) {
    console.error('Usage: node scripts/patch-pubkey.js <spki-b64-file> <file...>');
    process.exit(2);
}
let spki;
try {
    spki = fs.readFileSync(args[0], 'utf8').trim();
    crypto.createPublicKey({ key: Buffer.from(spki, 'base64'), format: 'der', type: 'spki' });
} catch {
    console.error('patch-pubkey: bad SPKI file ' + args[0]);
    process.exit(2);
}
const needle = /const PRODUCT_PUBLIC_KEY_SPKI_B64 = '[^']+';/;
for (const f of args.slice(1)) {
    let t;
    try { t = fs.readFileSync(f, 'utf8'); }
    catch { console.error('patch-pubkey: cannot read ' + f); process.exit(2); }
    const n = (t.match(needle) || []).length;
    if (n !== 1) {
        console.error('patch-pubkey: expected exactly 1 key constant in ' + f + ', found ' + n);
        process.exit(2);
    }
    t = t.replace(needle, 'const PRODUCT_PUBLIC_KEY_SPKI_B64 = \'' + spki + '\';');
    fs.writeFileSync(f, t, 'utf8');
    console.log('patched ' + f);
}
console.log('embedded fingerprint (sha256): ' + crypto.createHash('sha256').update(spki).digest('hex'));
