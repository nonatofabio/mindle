# Release signing & notarization

One-time setup to make the GitHub Actions release workflow produce a
signed, notarized `Mindle.dmg` that opens cleanly on any Mac without
Gatekeeper warnings.

Until these secrets are configured the workflow falls back to the
unsigned `Mindle.app.zip` path, so the repo keeps building either way.

## What you need

An **Apple Developer Program** membership ($99 / year):
<https://developer.apple.com/programs/>.

## 1. Developer ID Application certificate

1. Sign in to <https://developer.apple.com/account> → **Certificates, IDs & Profiles**.
2. **Certificates** → **+** → pick **Developer ID Application** → Continue.
3. Generate a CSR from **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority…** (save to disk, leave the CA email blank). Upload the `.certSigningRequest` file.
4. Download the issued `.cer` and double-click it to import into your login keychain.
5. In Keychain Access, find the `Developer ID Application: <Your Name> (<TEAMID>)` entry. Right-click → **Export…** → save as `MindleDev.p12` with a password you'll remember.
6. Base64-encode it:

   ```bash
   base64 -i MindleDev.p12 | pbcopy
   ```

## 2. App Store Connect API key (for notarytool)

1. <https://appstoreconnect.apple.com> → **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys**.
2. **Generate API Key** → name it e.g. `mindle-notary`, role **Developer**.
3. **Download** the `.p8` file (you get one chance).
4. Note the **Key ID** (10 chars) and the **Issuer ID** (UUID at the top of the page).
5. Base64-encode the `.p8`:

   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```

## 3. Configure GitHub repository secrets

Repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

| Name | Value |
|------|-------|
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` — exact string from Keychain Access |
| `MACOS_CERTIFICATE_P12` | base64 of `MindleDev.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | password used when exporting the `.p12` |
| `MACOS_NOTARY_API_KEY_P8` | base64 of `AuthKey_XXXXXXXXXX.p8` |
| `MACOS_NOTARY_API_KEY_ID` | the 10-char Key ID |
| `MACOS_NOTARY_ISSUER_ID` | the Issuer UUID |

## 4. Cut a release

```bash
git tag v1.1.0
git push origin v1.1.0
```

The workflow will build, codesign, create the DMG, submit to the
notary service, staple the ticket, and attach `Mindle.dmg` to the
release. Notarization typically takes 2–10 minutes.

## Verifying locally

After downloading `Mindle.dmg` from a release:

```bash
# The staple is embedded — spctl should accept it offline.
spctl --assess --type open --context context:primary-signature -v Mindle.dmg

# Mount and check the app itself.
hdiutil attach Mindle.dmg
codesign --verify --strict --verbose=2 /Volumes/Mindle/Mindle.app
spctl --assess --type execute -vv /Volumes/Mindle/Mindle.app
hdiutil detach /Volumes/Mindle
```

All three should report `accepted`.

## Troubleshooting

- **`errSecInternalComponent` during codesign** — the keychain isn't
  unlocked or the partition list wasn't set. The workflow handles this
  via `security set-key-partition-list`; if it recurs, rerun the
  import step.
- **Notarization rejected** — download the log:

  ```bash
  xcrun notarytool log <submission-id> --key AuthKey_XXXX.p8 \
    --key-id XXXX --issuer <issuer-uuid>
  ```

  Most rejections are missing hardened runtime (`--options runtime`)
  or a missing secure timestamp (`--timestamp`). Both are already in
  the workflow.
- **Gatekeeper still warns after install** — check that `stapler
  validate` passed in CI. An unstapled DMG requires the user to be
  online for first-launch verification.
