# Croatian eOI over NFC: can a phone replace the USB reader?

Status on 2026-11-04. Web research, the security target, and a first NFC probe of a real card from an iPhone (`ios/`).

## Why this matters

Web eID works with the eOI, but only with a USB reader, on a computer, with Certilia middleware and the Web eID app installed. That is the main barrier to adoption for an eidchain voter. Estonia has solved the same problem on phones. RIA DigiDoc on iOS (since 2024-10) and Android (since 2025-03) authenticates and signs with the ID card over NFC. *Web eID for Mobile* (open to web services from autumn 2026) lets a mobile browser hand the Web eID challenge to that app. The cryptography does not change: the card signs the challenge with a key that never leaves the chip. Only the transport changes. Over NFC the transport is a PACE session keyed by the 6-digit CAN printed on the card, and the same APDUs run inside it. Libraries: `open-eid/nfc-iOS-lib`, `open-eid/nfc-Android-lib` (Estonian card only, and marked not for general use).

If the eOI's eID applet answered over NFC with PACE, the same approach would work for Croatian cards. That would need a driver for the AKD applet and its file layout in those libraries, or an app of our own.

## What is known

| Claim | Confidence | Source |
|---|---|---|
| eOI Gen 2 v2 (issued since 2025-05-12) has a **dual-interface** chip, NXP P71 JCOP4.5 | official | [AKD brochure](https://www.akd.hr/datastore/file/972/brosura-OI_gen-2-v-2.pdf) |
| Chip carries three applets: "AKD eID card 2.0" (SSCD), the MRTD travel applet, and a health applet | official | same brochure |
| Our card's ATR historical bytes read `AKDeID2.0-SSCD` | measured by us | [web-eid doc](2026-11-04-web-eid-newer-croatian-eoi-macos.md) |
| Brochure calls the eID part a "certified **contact** chip". The security target below contradicts the reading that the SSCD is contact-only | superseded | brochure |
| The SSCD applet is certified as a "contact/contactless/dual interface" product and supports T=1 (ISO 7816-3) **and T=CL (ISO 14443)** | official, CC certified | [ST Lite AKD eID 2.0 SSCD v2.4](https://sec-certs.org/cc/5a7ffad9f27b5ca5/target.pdf), NSCIB-CC-2300144-01, EAL4+ AVA_VAN.5, valid to 2029-09-30 |
| The applet implements **PACE with CAN or MRZ** (generic mapping, ECDH on Brainpool/NIST P-256/384) followed by AES secure messaging (CBC + CMAC), per EN 419212-2 clauses 8 and 9 | official, CC certified | same ST |
| Which authentication methods are active (PIN, PACE-CAN, ...) is chosen at **personalisation**. The ST certifies the capability, not the Croatian profile | official | same ST, "During the personalization of the TOE, knowledge, biometric and PACE authentication can be configured" |
| Applet interfaces follow EN 419212 (the same standard family as other EU eID cards), not a proprietary protocol | official | same ST |
| A 6-digit CAN is printed on the front of our card (bottom right) | observed by us | the card |
| MRTD data (name, photo) is readable over NFC (Airbnb lists Croatian ID cards for NFC verification) | third party | [Airbnb help](https://hr.airbnb.com/help/article/4077) |
| Certilia mobile.ID does **not** use the card over NFC. Activation is by a QR code issued at the police counter, and the signing key is a remote certificate | official / third party | [eid.hr mobilni identitet](https://www.eid.hr/hr/mobilni-identitet), [MUP eOI](https://mup.gov.hr/osobna-iskaznica-eoi/328) |
| In 2021, phone-NFC use of the eID functions was "dependent on a pilot". No follow-up found | third party | [bug.hr 2021](https://www.bug.hr/propisi/stizu-nove-osobne-iskaznice-s-vise-digitalnih-mogucnosti-17757) |
| Nothing from MUP, gov.hr, AKD, Web eID or OpenSC mentions PACE, CAN, or contactless access to the eID applet | absence | MUP, [gov.hr](https://gov.hr/hr/druga-generacija-elektronickih-osobnih-iskaznica/2312), [web-eid-app#347](https://github.com/web-eid/web-eid-app/pull/347) |

For comparison, the Slovenian eOI prints a CAN on the front and works with OpenSC over NFC ([OpenSC wiki](https://www.github.com/OpenSC/OpenSC/wiki/Slovenian-EID)). So the model exists in the region.

## Measured over NFC (iPhone 15 Pro, iOS 26.6, 2026-11-04)

Probe app `ios/EOINFC` (Core NFC), no PACE, no PIN. Two runs gave identical results.

| Command | Result | Meaning |
|---|---|---|
| Card discovered via MRTD AID `A0000002471001` | ok | Core NFC needs one declared AID to answer before it reports the card |
| Historical bytes | `AKDeID2.0-SSCD` | same applet banner as over contact |
| SELECT MF, then EF.CardAccess `011C` | `9000`, 22 bytes | PACE is offered (below) |
| EF.DIR `2F00`, `2F01` | `6A82` | no application directory, so AIDs have to be known |
| SELECT `A000000167455349474E` ("ESIGN", EN 419212 eSign application) | **`9000`** | the signing application answers over the contactless interface |
| SELECT `E80704007F00070302` (German-style eID) | `6A82` | not present |
| SELECT `E828BD080FA000000167455349474E`, PKCS#15 `A000000063504B43532D3135` | `6A86` | not present in this form |

EF.CardAccess `31143012060A04007F00070202040204020102020111` decodes to a single PACEInfo:

- protocol `0.4.0.127.0.7.2.2.4.2.4` = **id-PACE-ECDH-GM-AES-CBC-CMAC-256**
- version 2
- parameterId 17. In the TR-03110 standardised domain parameter table this is brainpoolP512r1. The ST names only 256 and 384 bit curves, so confirm when PACE is implemented (a wrong curve fails at the first General Authenticate).

Second probe, inside the eSign application (SELECT by AID, then only SELECT/READ BINARY):

| Probe | Result | Meaning |
|---|---|---|
| SELECT by FID of 27 usual EN 419212 / PKCS#15 / CardOS file ids (C000, C500, 5031, 4401, ...) | all `6A82` | AKD uses its own file ids, so we address files by short EF id instead |
| READ BINARY SFI 1, SFI 2 | `6982` | files exist and are **protected**: security status not satisfied, PACE (and maybe PIN) needed |
| READ BINARY SFI 3 | `6282`, 12 bytes, tag `5A` | open file with the card serial number (ASCII prefix `CRO`) |
| READ BINARY SFI 28 (`0x1C`, EF.CardAccess of the application) | `6282`, 22 bytes | PACEInfo: id-PACE-ECDH-GM-AES-CBC-CMAC-256, version 2, **parameterId 15 = NIST P-384** |

So the eSign application has its own PACE configuration, on NIST P-384, which matches the ST ("256 and 384 bits"). The parameterId 17 under the MF is likely the MRTD applet's.

Consequences: CryptoKit has P-384 ECDH, but PACE generic mapping needs the full shared point and point addition (G' = s·G + H), which CryptoKit does not expose. So PACE still needs OpenSSL or a small EC implementation, though a NIST curve keeps it simple. The protected SFIs 1 and 2 show that data in the eSign application sits behind PACE. Earlier note on the MF parameter follows.

Earlier conclusion, MF level: a Brainpool curve rules out CryptoKit for PACE on iOS, so PACE needs OpenSSL or a small pure-Swift EC implementation. The CAN is the PACE password. We have not yet checked whether the eSign application requires PACE for reading certificates or signing, or whether SELECT works only because it is unprotected.

## Verdict

**Very likely yes. The signing application answers over NFC.** The earlier verdict ("probably not") rested on the brochure's word "contact". The CC security target says otherwise: the signing applet itself is certified for the contactless interface and for PACE-CAN with secure messaging, which is exactly the Estonian model. The card also carries a printed CAN. What remains open is whether Croatia's personalisation profile enables the applet over NFC, and with which PACE parameters. Only a card test answers that.

The official mobile identity (Certilia) still avoids the card, so there is no Croatian app to copy. We would write the card layer ourselves on top of EN 419212.

## How to settle it

1. ~~Check the card front for a 6-digit CAN.~~ Done: it is there.
2. **Contactless test.** We have no PC/SC NFC reader, so it runs on an Android phone: read `EF.CardAccess` (FID `011C`) under the MF. It lists the PACE parameters if PACE is supported. Then try to SELECT the AKD eID applet with the same AID that Certilia middleware uses over the contact interface (capture it with a PC/SC trace). If it is refused, or only answers after PACE, that is the answer.
3. ~~Read the security target.~~ Done, see above. Note: the sec-certs link previously given here (`2fdb7ebde10e8402`) is NXP's ChipDoc v4 ICAO/MRTD target (ANSSI-CC-2023/11-R01), not the AKD SSCD. The correct one is `5a7ffad9f27b5ca5`.

Do not guess PINs while testing. The PIN retry counters are real, and a blocked PIN means a trip to the police counter. Use the CAN for PACE, and only VERIFY the PIN once the applet and its key references are known.

If step 2 succeeds, the next step is to port the Estonian NFC library's card layer to the AKD applet. The Web eID token format and server-side validation can stay as they are.
