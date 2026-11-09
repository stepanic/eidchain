# Web eID for Windows, built from WSL

Status on 2026-11-05. The fork ([stepanic/web-eid-app](https://github.com/stepanic/web-eid-app) with [stepanic/libelectronic-id](https://github.com/stepanic/libelectronic-id)) builds for Windows x64 and is registered as the native messaging host for Chrome, Edge, Brave and Firefox on one machine. It signs with the newer eOI: block 6 of the domovina chain (`c9201b4e…`) holds a message signed this way, in Brave, on 2026-11-05.

## Why Windows needs the fork

The [macOS doc](2026-11-04-web-eid-newer-croatian-eoi-macos.md) calls the unknown ATR "the real blocker". That check is in shared code (`SUPPORTED_ATRS` in `src/electronic-id.cpp`), so official Web eID rejects the newer card on Windows and Linux too. The fork adds the ATR for every platform. Only the PKCS#11 module path differs per platform. On Windows the fork loads `C:\Program Files\AKD\Certilia Middleware\pkcs11\AkdEidPkcs11_64.dll`, which Certilia Middleware installs.

## Why build from WSL, and where the code lives

- **The node needs no Windows tooling.** eidchain is pure Go with no cgo: `GOOS=windows GOARCH=amd64 go build -o bin/eidchain.exe ./cmd/eidchain` works from WSL. A Linux node in WSL is reachable from Windows browsers as `localhost:8080`, which Web eID accepts without HTTPS.
- **Web eID can't be cross-compiled.** It is C++/Qt and needs MSVC. WSL drives it through `powershell.exe`, so one terminal is enough.
- **The source is cloned a second time, on `C:`.** MSVC and vcpkg are unreliable on `\\wsl.localhost\…` paths. `C:\src\web-eid-app` is a Windows-git clone of the fork, and changes move between the two clones through GitHub.

## Build

`C:\src\build-webeid.ps1` loads `vcvarsall.bat amd64` and runs CMake from Visual Studio 2022. Its arguments are upstream's single-arch dev build, without the MSI target. Qt is in `C:\Qt\6.11.2\msvc2022_64`, vcpkg is in `C:\vcpkg` at the `builtin-baseline` of `libelectronic-id/vcpkg.json`, and the first build compiles OpenSSL and GTest. After a build, run `windeployqt --release --no-translations --no-compiler-runtime` on `web-eid.exe` so it runs outside the build environment.

## Traps

- **aqtinstall 3.3 can't install Qt 6.11.2 for Windows.** qt.io now splits the Windows repository per architecture (`qt6_6112/qt6_6112_msvc2022_64/Updates.xml`), and aqt still asks for `qt6_6112/qt6_6112/Updates.xml`. The fix was a small script that reads the new `Updates.xml`, downloads `qtbase`, `qtsvg`, `qttools`, `qttranslations`, `qtimageformats`, `d3dcompiler_47` and `opengl32sw`, checks each `.sha1`, and extracts them with py7zr. The archives have no `msvc2022_64/` prefix, so extract them into that directory.
- **MSVC 14.40 fails on C4297 in `libpcsc-cpp`.** `SmartCard::Session::~Session()` was a `noexcept` function-try-block. The handler of such a block rethrows when it ends, so a failed `endTransaction()` would call `std::terminate` instead of being ignored. The warning is real, and warnings are errors. The fork moves the `try` into the body. Upstream has the same code, and its CI presumably uses an MSVC that doesn't warn.
- **`web-eid.exe` without `-c` waits on stdin.** That is native messaging mode, so it looks like a hang when run by hand. For a manual test, run `web-eid.exe -c get-signing-certificate '{\"origin\":\"https://localhost\"}'`.

## Registering without the MSI

The MSI needs WiX 7 and .NET, so a dev build is registered by hand. Copy `eu.webeid.json` and `eu.webeid.firefox.json` from `build\src\app\` next to `web-eid.exe`, with `path` made absolute. Then point the default value of these keys at them:

- `HKCU\Software\Google\Chrome\NativeMessagingHosts\eu.webeid`
- `HKCU\Software\Microsoft\Edge\NativeMessagingHosts\eu.webeid`
- `HKCU\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\eu.webeid`
- `HKCU\Software\Mozilla\NativeMessagingHosts\eu.webeid` (Firefox manifest)

The browser extension is the official one from the store. The fork changes only the native app. The MSI installs the extension the way Chromium installs any external extension, so a registry value does the same without it. Each key below gets an `update_url` value, and the browser offers to enable the extension on its next start:

- `HKCU\Software\Google\Chrome\Extensions\ncibgoaomkmdpilpocfeponihegamlic` → `https://clients2.google.com/service/update2/crx`
- `HKCU\Software\BraveSoftware\Brave-Browser\Extensions\ncibgoaomkmdpilpocfeponihegamlic` → the same URL. Brave takes the Chrome Web Store build. Upstream's MSI doesn't cover Brave, but the fork's does.
- `HKCU\Software\Microsoft\Edge\Extensions\gnmckgbandlkacikdndelhfghdejfido` → `https://edge.microsoft.com/extensionwebstorebase/v1/crx`

The MSI writes these keys and the native host keys under HKLM, for all users. HKCU needs no admin rights, which is all a single-user dev build needs. To get logs, set `HKCU\SOFTWARE\RIA\web-eid` `logging` to `"true"`. The log is `%LOCALAPPDATA%\RIA\web-eid\web-eid.log`.

## Open

- Chrome, Edge and Firefox with this build. Only Brave has signed so far.
- A Windows installer (MSI) and code signing: see [the signed MSI doc](2026-11-09-web-eid-windows-msi-signing.md). Neither the ITalk Apple Developer ID nor the eOI signing certificate can sign Windows code. The eOI certificate is for non-repudiation and has no code signing EKU.
- `deploy/windows/join.ps1`, see [the Windows node plan](2026-11-04-windows-node-and-node-hardware.md).
