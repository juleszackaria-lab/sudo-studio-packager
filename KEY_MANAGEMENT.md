# License key management (PROMPT 11)

Vendor-side procedure for Sudo Studio offline licenses (Ed25519-signed).

## Roles

- **Vendor** (Sudo Studio team): owns `license-keygen`, generates the product
  keypair, embeds the PUBLIC key in the app, issues customer keys.
- **Acquirer** (customer receiving the product sources): receives the private
  key once, through the handover below, to issue their own keys.

## 1. Ceremony: generate the product keypair (vendor, once)

On an offline machine, inside this repo:

```
node license-keygen.js init --out license-private.pem --print-const
```

- `license-private.pem` is created mode `0600` and is git-ignored (see
  `.gitignore`). Never copy it to a shared drive, chat, or ticket.
- Copy the printed `PRODUCT_PUBLIC_KEY_SPKI_B64` constant into BOTH:
  `backend/src/license/license.js` and `sudo-ai-extension/src/license/license.js`
  (Sudo-studio repo), then build/release.
- Record the printed fingerprint (sha256) next to the release notes so any
  holder can confirm which public key a build embeds.

## 2. Store the private key

- Primary: vendor HSM or encrypted offline vault, named
  `sudo-studio-license-private-<fingerprint8>.pem`.
- Backup: second offline medium in another location. No cloud sync folder.

## 3. Hand over to the acquirer (once per transfer)

1. Export the private PEM to encrypted removable media (or age/gpg-encrypted
   file to the acquirer's known public key - fingerprint verified by phone).
2. Send the public-key fingerprint through a SECOND channel.
3. The acquirer confirms: `node license-keygen.js verify` of a sample key
   issued by the vendor, plus fingerprint match, before the media is wiped.
4. Log the transfer (who, when, fingerprint) in the release register.

## 4. Issue a customer key

```
node license-keygen.js issue --private license-private.pem --client "Acme" \
  --edition team --seats 10 --expires 2027-10-13 --license-id LIC-ACME-001
```

Deliver the printed single-line key (email is fine - it is signed, but treat
it as a bearer credential). `--machine <hostname>` optionally binds the key.

## 5. Revoke

Add the `licenseId` to the revocation list shipped to the customer
(`revoked.json`, imported via the License panel). No reissue needed.

## 6. Rotate (suspected leak or scheduled)

1. `init` a new pair (new fingerprint), embed the new public key, release.
2. Re-issue every active customer key with the new private key.
3. Publish a revocation list with the old `licenseId`s for stragglers.
4. Destroy the old private key material (shred + remove from all media).
