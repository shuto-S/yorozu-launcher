# Yorozu Release Guide

Yorozu releases are built from stable `vX.Y.Z` tags by
`.github/workflows/release.yml`. The workflow creates an Apple Silicon Release build,
signs it with Developer ID, notarizes and staples it, publishes `Yorozu.app.zip` to a
GitHub Release, signs the archive with Sparkle EdDSA, and deploys `appcast.xml` to
GitHub Pages.

Do not run the release workflow until all required credentials are configured. Never
commit certificates, private keys, passwords, exported Keychain items, or local signing
configuration.

## One-time setup

### Apple signing and notarization

Create a Developer ID Application certificate for the Apple Developer team that owns
`com.yorozu.app`, export it as a password-protected PKCS#12 file, and configure these
GitHub Actions secrets:

| Name | Value |
|---|---|
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_ID` | Apple ID used by `notarytool` |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded PKCS#12 certificate and private key |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | PKCS#12 export password |

The workflow imports the certificate into a temporary Keychain and deletes that
Keychain in an `always()` cleanup step. Release builds use Hardened Runtime and keep App
Sandbox disabled.

### Sparkle signing

Download the Sparkle 2.9.6 binary distribution and generate an EdDSA key pair with the
official tool:

```bash
./bin/generate_keys --account com.yorozu.app
./bin/generate_keys --account com.yorozu.app -x yorozu-sparkle-private-key
```

The first command prints the public key and saves the private key in the login Keychain.
The second exports the private key for transfer to GitHub. Treat the exported file like a
password and delete it securely after the GitHub secret is configured.

Configure:

| Kind | Name | Value |
|---|---|---|
| GitHub Actions secret | `SPARKLE_PRIVATE_KEY` | Exact exported private-key contents |
| GitHub Actions variable | `SPARKLE_PUBLIC_KEY` | Base64 public key printed by `generate_keys` |

The public key is injected into the Release app as `SUPublicEDKey`. The private key is
piped directly to `generate_appcast --ed-key-file -`; the workflow does not write it to
disk. The workflow requires the public key to decode to a 32-byte Ed25519 key and fails
if the embedded key differs from the configured variable. After generating the appcast,
it verifies the archive with Sparkle's official `sign_update` tool and also confirms that
a modified signature is rejected. Both tools come from the Sparkle binary artifact that
Swift Package Manager resolved for the build; the workflow does not download a second,
unrelated copy after the app has been compiled.

### GitHub Pages

In the repository settings, select **GitHub Actions** as the Pages source. The release
workflow deploys only `appcast.xml`. The application feed URL is:

```text
https://shuto-s.github.io/yorozu-launcher/appcast.xml
```

## Publish a release

1. Confirm `main` is clean and CI is green.
2. Update `MARKETING_VERSION` if the project version has not already been updated.
3. Create and push an annotated stable tag matching the version:

```bash
git tag -a v0.1.0 -m "Yorozu 0.1.0"
git push origin v0.1.0
```

The workflow uses `GITHUB_RUN_NUMBER` as the initial `CFBundleVersion`. Before building,
it reads the currently published appcast and raises the build number above the previous
`sparkle:version` when necessary. A failure other than a first-release 404 stops the
release instead of publishing an update whose monotonic version cannot be proven.
All release tags share one concurrency group so a later workflow cannot publish an older
appcast after a newer one. Release notes are generated from commit subjects since the
previous tag and embedded in the appcast.

## Verification gate

Before announcing a release, verify all of the following from the workflow artifacts and
a clean Mac user account:

- `codesign --verify --deep --strict` succeeds;
- the signed identifier is `com.yorozu.app`, the TeamIdentifier matches `APPLE_TEAM_ID`,
  and the designated requirement contains both without depending on a build-specific
  cdhash;
- `spctl --assess --type execute` accepts the app;
- `stapler validate` succeeds;
- the GitHub Release contains `Yorozu.app.zip`;
- the published appcast contains the expected version, download URL, and
  `sparkle:edSignature`;
- the current release reports no update;
- the previous signed release shows the new version and release notes;
- canceling a download leaves the installed application untouched;
- an archive signed by another EdDSA key is rejected;
- installing and restarting preserves Settings, SQLite, and Keychain data.
- Accessibility and Input Monitoring grants from the previous published build remain
  granted after updating in place, and automatic paste plus Command input-mode switching
  still work without a second authorization.

The workflow enforces the stable bundle ID, Developer ID team, and designated-requirement
shape before notarization. Do not replace Developer ID signing with Apple Development or
ad hoc signing in a published archive; that would create a different TCC identity even if
the app name and bundle ID look unchanged.

An update path has not been validated until two real Developer ID signed and notarized
versions have been tested. Debug and UI-test builds never start Sparkle and do not contain
the Release feed or public-key Info.plist entries.
