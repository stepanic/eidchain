# Web eID and the newer Croatian eOI on macOS

Status on 2026-11-04. Official Web eID (app 2.10, extension 2.5) can't sign with the newer Croatian eOI, in any browser. A patched, ITalk-signed build fixes it until upstream ships the change.

- Upstream fix: [web-eid/libelectronic-id#176](https://github.com/web-eid/libelectronic-id/pull/176) (fork commit [`513492b`](https://github.com/stepanic/libelectronic-id/commit/513492bc4896eca8fff95b1afeea26e6c28cddb1))
- Signed DMG, universal: [stepanic/web-eid-app v2.11.0-hr2](https://github.com/stepanic/web-eid-app/releases/tag/v2.11.0-hr2). It's built by `scripts/release-macos-italk.sh` in that fork.
- Report: [ivoras/eidchain#1](https://github.com/ivoras/eidchain/issues/1). Block 6 of the live chain holds the first message signed with this card.

## Why "card not supported"

Web eID shows *"Osobna iskaznica u čitaču nije podržana"*. There are two causes:

1. **ATR.** libelectronic-id picks the card driver by exact ATR match (`SUPPORTED_ATRS` in `src/electronic-id.cpp`). Its only Croatian entry is the older card (`3bff1300…`). The newer one answers with `3bdf18ff81b1fe451fc39e414b44654944322e302d53534344d1`, whose historical bytes read `AKDeID2.0-SSCD`. A card with an unknown ATR is rejected before any PKCS#11 module is loaded. **This is the real blocker.** The module path doesn't matter until the ATR is known.
2. **Module path on macOS.** Web eID looks for `/Library/AKD/pkcs11/libEidPkcs11.dylib`. Certilia Middleware 3.9.12 installs `/Applications/CertiliaMiddleware.app/Contents/pkcs11/libCertiliaPkcs11.dylib`, under a new name. Older Certilia versions used `/usr/local/lib/pkcs11/`, which the sandboxed app can't read (upstream #124).

The official app is sandboxed (`app-sandbox`, `smartcard`, `disable-library-validation`). The patched build reads the module straight from the Certilia app bundle inside the sandbox. I verified this with no `/Library/AKD` copy or symlink present. So the fix needs no manual step on the user's machine.

Open question: the README says Ivan's card, under HRIDCA 2025, worked through Web eID. Mine is HRIDCA 2025 too and has the new ATR. So either HRIDCA 2025 certificates are also issued on the older card model, or his platform differs. A second ATR sample would settle it.

## Browser facts that cost time

- **Signing (Web eID) isn't Firefox-only.** Chrome, Brave, Firefox and Safari all work. Brave uses Chrome's system manifest `/Library/Google/Chrome/NativeMessagingHosts/eu.webeid.json`. A user-level manifest in `~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/` did **not** override the system one. Brave kept starting the system app until the system manifest was edited.
- **Card login (TLS client certificate) is effectively Firefox-only.** Firefox loads Certilia's PKCS#11 module itself. Chromium browsers and Safari go through CryptoTokenKit, and Certilia installs no CTK token driver: `system_profiler SPSmartCardsDataType` lists only Apple's `pivtoken`.
- To check Web eID from a page without a card prompt, post `{action: "web-eid:status"}` with `window.postMessage`. The reply carries `extension` and `nativeApp` versions, which shows which binary the browser actually started.
- Read the full ATR through PC/SC (`SCardGetStatusChange`). `system_profiler` truncates it in the middle.

## Building the signed DMG

The defaults and the reasons are in `scripts/release-macos-italk.sh` in stepanic/web-eid-app. The traps:

- **Universal needs non-Homebrew dependencies.** Homebrew's Qt is arm64 only. The script takes Qt 6.11.2 from qt.io through aqtinstall (`clang_64` is universal) and OpenSSL/GTest from vcpkg with the repo's `arm64-x64-osx` triplet, the same as upstream CI. They live in `~/.cache/web-eid-build`. The first run downloads Qt and builds OpenSSL twice, which takes about 15 minutes.
- **`SIGNCERT="ITalk d.o.o."`, without `(6SCK58757K)`.** The parentheses break the shell command that CMake generates for `codesign`.
- **Notarize with the App Store Connect API key** `25KYCN22QD` (ITalk team, the same key as the team's other macOS apps), not an Apple ID and app-specific password.
- `install_name_tool: no LC_RPATH … -delete_rpath` during `cmake --install` is harmless. The signature stays valid, which `codesign --verify --deep --strict` confirms.
- Test the Intel slice on Apple silicon with `arch -x86_64 …/web-eid -c get-signing-certificate '{"origin":"https://…"}'`. Rosetta also loads the x86_64 slice of Certilia's library.

## Open

- Not yet tested on a real Intel Mac (the hr2 x86_64 build was only run under Rosetta).
- PIN2 signing was tested with the arm64 build of the same code (hr1 and a local build), not with hr2.
- Once #176 lands in an official Web eID release, users should reinstall the official DMG and the fork can go.

## Related documents

- [eidchain.domovina.ai and eID validators](2026-11-04-eidchain-domovina-and-eid-validators.md)
- [Croatian eOI over NFC](2026-11-04-croatian-eoi-nfc-pace.md): a phone can reach the signing application over NFC with PACE-CAN (tested on an iPhone).
