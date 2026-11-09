# Web eID for Windows: a signed MSI from ITalk d.o.o.

Status on 2026-11-09. The fork builds an x64 MSI (`web-eid_2.11.0.3_x64.msi`, unsigned: the files and registry keys inside it are checked, but it hasn't been installed yet) with `scripts/release-windows-italk.ps1` in [stepanic/web-eid-app](https://github.com/stepanic/web-eid-app). Code signing waits for ITalk's Azure Artifact Signing account. Until then the script makes an unsigned MSI, which is fine for tests on our own machines. It is not for release.

**On hold since 2026-11-09:** nothing gets paid for now, neither Azure nor the WiX fee, and nothing is released. The free alternatives below are the plan for when this is picked up again.

## Why an MSI at all

Without one, every machine needs the native host registered by hand in the registry ([build doc](2026-11-05-web-eid-windows-build-from-wsl.md)). The MSI keeps upstream's UpgradeCode, so it installs over the official Web eID, and it writes the browser keys for all users. That's the same approach as the macOS DMG ([macOS doc](2026-11-04-web-eid-newer-croatian-eoi-macos.md)).

## Decisions

- **x64 only, the plain `.qt.msi` and no bundle.** Upstream's `.exe` bundle exists only to pick between x64 and ARM64. The `.qt.msi` carries Qt, OpenSSL and the VC runtime. Certilia Middleware remains a separate install because the PKCS#11 module comes from it, and the release notes have to say so.
- **The MSI also covers Brave**, which upstream doesn't. It adds the native host key and the extension key under `BraveSoftware\Brave-Browser`. The first eOI signature on Windows came from Brave.
- **Azure Artifact Signing** (the former Trusted Signing) and not an OV certificate. The key lives in Azure's HSM, so there's no token, and the same signing step works from GitHub Actions. It costs about $10 a month. EV no longer skips SmartScreen. Even signed builds get a SmartScreen warning until the certificate builds reputation through downloads.
- **WiX 7 needs the OSMF EULA.** A company with more than $10k a year in revenue pays a maintenance fee: $10 a month for under 20 employees, through [GitHub Sponsors](https://github.com/sponsors/wixtoolset), Maintenance Fee tier. The EULA is accepted on this machine, but ITalk doesn't pay while it doesn't use WiX. The fee is per company, not per product.
- What gets signed: `web-eid.exe`, OpenSSL from vcpkg, and the MSI. Windows 11 Smart App Control also blocks unsigned DLLs. Qt from qt.io is already signed.

## Free alternatives, the plan for later

Unsigned code runs on Windows. Without a signature there is only a warning ("More info" → "Run anyway"). So paying isn't required for a first release, and these options cost nothing:

1. **Build in GitHub Actions, unsigned, with build provenance.** `cmake-windows.yml` in the fork already builds the MSI, free because the repo is public. Add `actions/attest-build-provenance`, so anyone can check with `gh attestation verify <msi> -R stepanic/web-eid-app` that the file came from that commit on GitHub's runner. A signature says who signed, while provenance says what went into the build. SmartScreen still warns.
2. **A ZIP with a registration script instead of an MSI.** It unpacks into `%LOCALAPPDATA%` and writes the HKCU keys from the [build doc](2026-11-05-web-eid-windows-build-from-wsl.md). It needs no admin rights and no WiX, so no WiX fee either. The browser starts `web-eid.exe` as a native host, not from Explorer, so SmartScreen doesn't step in. The one warning is on the script. Windows 11 with Smart App Control turned on, usually only on clean installs, does block the unsigned exe.
3. **[SignPath Foundation](https://signpath.org/).** It offers free Authenticode signing for OSI-licensed projects built in CI. The publisher shown is then "SignPath Foundation", not ITalk. Applying takes time. It fits option 1.
4. **Upstream** merges [web-eid/libelectronic-id#176](https://github.com/web-eid/libelectronic-id/pull/176), still open on 2026-11-09. RIA's official, RIA-signed release would then work with the newer eOI on every OS, and the fork could go. This is the real fix, and worth pushing for, for example by offering a test with a real card.
5. Building it yourself is possible (Visual Studio, Qt, vcpkg, about an hour), but only for technical people.

The way WiX can be avoided: a ZIP (2), WiX 5 (which has no OSMF), or a build by a person or an organization without revenue.

Plan: 1 and 4 first, SignPath (3) alongside them. Azure stays for the [desktop node app](2026-11-05-one-click-desktop-node.md), which will need its own signature and signed updates.

## Steps for ITalk in Azure (once)

1. An Azure subscription in ITalk's name, then register the resource provider `Microsoft.CodeSigning`.
2. An Artifact Signing account, Basic SKU, region West Europe. The endpoint is `https://weu.codesigning.azure.net`.
3. On the account, give yourself the *Identity Verifier* role. Then create an Identity validation: Organization, Public Trust, ITalk d.o.o. as in the court register. Microsoft checks it, which can take several days and ask for documents. Eligibility rules for the company (country, age) are checked here, so this step decides whether Azure is an option at all.
4. A Certificate profile of type Public Trust, linked to that validation. Its subject will be `CN=ITalk d.o.o.`.
5. Give the *Certificate Profile Signer* role to whoever signs: you for local signing, and later an app registration with OIDC for GitHub Actions.

## Signing on this machine

On the Windows side, install the Azure CLI and the Artifact Signing Client Tools (they bring `Azure.CodeSigning.Dlib.dll`, which the script finds by itself). Then run `az login`, and from WSL:

```
powershell.exe -ExecutionPolicy Bypass -File C:\src\web-eid-app\scripts\release-windows-italk.ps1 `
  -buildNumber 3 -signingAccount <account> -certificateProfile <profile>
```

The script verifies every signature with `signtool verify /pa`. It prints the MSI's SHA256 for the release notes. The release is `gh release create v2.11.0-hrN` with the MSI.

## Traps

- **`d3dcompiler_47.dll` and `opengl32sw.dll` must be in Qt's `bin\`.** Their archives have no `bin/` prefix, unlike `qtbase`. With the hand-made Qt install they ended up in `msvc2022_64\`, and WiX failed with WIX0103. The dev build didn't need them, so nobody noticed.
- **The EULA comes before the WiX extensions.** `wix extension add` also fails with WIX7015 until `wix eula accept wix7` is run. The script does this in that order when given `-acceptWixEula`. That's needed once per user.

## Open

- The Azure account and identity validation for ITalk: on hold, see the free alternatives.
- Signing from GitHub Actions instead of this machine: reproducible, and it doesn't depend on one laptop. The [desktop node plan](2026-11-05-one-click-desktop-node.md) needs this for updates anyway.
- An install test of the MSI with the card in Chrome, Edge, Firefox and Brave. Remove the manual HKCU keys first, because HKCU takes precedence.
