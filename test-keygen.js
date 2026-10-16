/**
 * SUDO STUDIO PACKAGER - license-keygen self-test (PROMPT 16).
 * Hermetic (temp dirs). No network, no repo writes.
 * ASCII-only.
 */
'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const KG = path.join(__dirname, 'license-keygen.js');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'p16-kg-'));
let n = 0;
function check(name, fn) {
    fn();
    n++;
    console.log('PASS ' + name);
}
function run(...a) {
    return execFileSync('node', [KG, ...a], { encoding: 'utf8' }).trim();
}
function runFail(...a) {
    try {
        execFileSync('node', [KG, ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) { return e.status; }
    return 0;
}
function payloadOf(key) {
    const p1 = key.split('.')[0];
    return JSON.parse(Buffer.from(p1.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
}

const KD = path.join(TMP, 'keys');
check('K1: generate-keypair writes private (0600) + public', () => {
    run('generate-keypair', '--out', KD);
    assert.ok(fs.existsSync(path.join(KD, 'license_private.pem')));
    assert.ok(fs.existsSync(path.join(KD, 'license_public.spki.b64')));
    if (process.platform !== 'win32') {
        assert.strictEqual(fs.statSync(path.join(KD, 'license_private.pem')).mode & 0o777, 0o600);
    }
});
check('K2: generate-keypair refuses to overwrite', () => {
    assert.notStrictEqual(runFail('generate-keypair', '--out', KD), 0);
});
const PUB = fs.readFileSync(path.join(KD, 'license_public.spki.b64'), 'utf8').trim();

let teamKey, entKey, expKey;
check('K3: issue --days team key', () => {
    teamKey = run('issue', '--keydir', KD, '--client', 'Acme', '--edition', 'team',
        '--seats', '10', '--days', '30', '--license-id', 'LIC-T1');
    const p = payloadOf(teamKey);
    assert.strictEqual(p.edition, 'team');
    assert.strictEqual(p.seats, 10);
    assert.deepStrictEqual(p.features, ['chat', 'doctor', 'sdk', 'devops', 'environment', 'agent']);
    assert.ok(Date.parse(p.expiresAt) > Date.now() + 29 * 86400000);
});
check('K4: issue --expires --machine enterprise key', () => {
    entKey = run('issue', '--keydir', KD, '--client', 'Globex', '--edition', 'enterprise',
        '--seats', '999999', '--expires', '2027-01-01', '--machine', 'PC-01');
    const p = payloadOf(entKey);
    assert.strictEqual(p.machineId, 'PC-01');
    assert.strictEqual(p.features.length, 11);
});
check('K5: issue refuses bad edition/seats', () => {
    assert.notStrictEqual(runFail('issue', '--keydir', KD, '--client', 'x', '--edition', 'gold',
        '--seats', '1', '--days', '1'), 0);
    assert.notStrictEqual(runFail('issue', '--keydir', KD, '--client', 'x', '--edition', 'team',
        '--seats', '0', '--days', '1'), 0);
});
check('K6: issue refuses expired without --allow-expired', () => {
    assert.notStrictEqual(runFail('issue', '--keydir', KD, '--client', 'x', '--edition', 'team',
        '--seats', '1', '--days', '-2'), 0);
    expKey = run('issue', '--keydir', KD, '--client', 'x', '--edition', 'team',
        '--seats', '1', '--days', '-2', '--allow-expired');
    assert.ok(payloadOf(expKey).expiresAt);
});
check('K7: verify accepts good keys (positional + --keydir)', () => {
    const out = run('verify', teamKey, '--keydir', KD);
    assert.ok(out.indexOf('VALID signature') === 0);
});
check('K8: verify refuses expired key (exit 1)', () => {
    assert.strictEqual(runFail('verify', '--key', expKey, '--keydir', KD), 1);
});
check('K9: verify refuses tampered key', () => {
    const bad = teamKey.slice(0, -2) + (teamKey.slice(-2) === 'AA' ? 'BB' : 'AA');
    assert.strictEqual(runFail('verify', bad, '--keydir', KD), 1);
});
check('K10: key from another pair is INVALID here', () => {
    const other = path.join(TMP, 'other');
    run('generate-keypair', '--out', other);
    const foreign = run('issue', '--keydir', other, '--client', 'Z', '--edition', 'team',
        '--seats', '1', '--days', '5');
    assert.strictEqual(runFail('verify', foreign, '--public', PUB), 1);
    assert.ok(run('verify', foreign, '--keydir', other).indexOf('VALID') === 0);
});
check('K11: patch-pubkey rewrites exactly one constant per file', () => {
    const f1 = path.join(TMP, 'a.js');
    const f2 = path.join(TMP, 'b.js');
    fs.writeFileSync(f1, 'const PRODUCT_PUBLIC_KEY_SPKI_B64 = \'OLD1\';\n');
    fs.writeFileSync(f2, 'x=1;\nconst PRODUCT_PUBLIC_KEY_SPKI_B64 = \'OLD2\';\ny=2;\n');
    execFileSync('node', [path.join(__dirname, 'scripts', 'patch-pubkey.js'),
        path.join(KD, 'license_public.spki.b64'), f1, f2], { encoding: 'utf8' });
    assert.ok(fs.readFileSync(f1, 'utf8').includes(PUB));
    assert.ok(fs.readFileSync(f2, 'utf8').includes(PUB));
    fs.writeFileSync(f1, 'no constant here\n');
    try {
        execFileSync('node', [path.join(__dirname, 'scripts', 'patch-pubkey.js'),
            path.join(KD, 'license_public.spki.b64'), f1], { stdio: 'pipe' });
        assert.fail('should have failed');
    } catch (e) { assert.notStrictEqual(e.status, 0); }
});

console.log('\nkeygen self-test: ' + n + ' checks passed (all green)');
