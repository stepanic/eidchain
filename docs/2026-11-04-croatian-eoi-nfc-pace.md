# Croatian eOI over NFC: can a phone replace the USB reader?

Status on 2026-11-04. This is web research only. Nobody has tested a card yet.

## Why this matters

Web eID works with the eOI, but only with a USB reader, on a computer, with Certilia middleware and the Web eID app installed. That is the main barrier to adoption for an eidchain voter. Estonia has solved the same problem on phones. RIA DigiDoc on iOS (since 2024-10) and Android (since 2025-03) authenticates and signs with the ID card over NFC. *Web eID for Mobile* (open to web services from autumn 2026) lets a mobile browser hand the Web eID challenge to that app. The cryptography does not change: the card signs the challenge with a key that never leaves the chip. Only the transport changes. Over NFC the transport is a PACE session keyed by the 6-digit CAN printed on the card, and the same APDUs run inside it. Libraries: `open-eid/nfc-iOS-lib`, `open-eid/nfc-Android-lib` (Estonian card only, and marked not for general use).

If the eOI's eID applet answered over NFC with PACE, the same approach would work for Croatian cards. That would need a driver for the AKD applet and its file layout in those libraries, or an app of our own.

## What is known

| Claim | Confidence | Source |
|---|---|---|
| eOI Gen 2 v2 (issued since 2025-05-12) has a **dual-interface** chip, NXP P71 JCOP4.5 | official | [AKD brochure](https://www.akd.hr/datastore/file/972/brosura-OI_gen-2-v-2.pdf) |
| Chip carries three applets: "AKD eID card 2.0" (SSCD), the MRTD travel applet, and a health applet | official | same brochure |
| Our card's ATR historical bytes read `AKDeID2.0-SSCD` | measured by us | [web-eid doc](2026-11-04-web-eid-newer-croatian-eoi-macos.md) |
| Brochure calls the eID part a "certified **contact** chip", which hints that the SSCD certification covers only the contact interface | inferred | brochure |
| MRTD data (name, photo) is readable over NFC (Airbnb lists Croatian ID cards for NFC verification) | third party | [Airbnb help](https://hr.airbnb.com/help/article/4077) |
| Certilia mobile.ID does **not** use the card over NFC. Activation is by a QR code issued at the police counter, and the signing key is a remote certificate | official / third party | [eid.hr mobilni identitet](https://www.eid.hr/hr/mobilni-identitet), [MUP eOI](https://mup.gov.hr/osobna-iskaznica-eoi/328) |
| In 2021, phone-NFC use of the eID functions was "dependent on a pilot". No follow-up found | third party | [bug.hr 2021](https://www.bug.hr/propisi/stizu-nove-osobne-iskaznice-s-vise-digitalnih-mogucnosti-17757) |
| Nothing from MUP, gov.hr, AKD, Web eID or OpenSC mentions PACE, CAN, or contactless access to the eID applet | absence | MUP, [gov.hr](https://gov.hr/hr/druga-generacija-elektronickih-osobnih-iskaznica/2312), [web-eid-app#347](https://github.com/web-eid/web-eid-app/pull/347) |

For comparison, the Slovenian eOI prints a CAN on the front and works with OpenSC over NFC ([OpenSC wiki](https://www.github.com/OpenSC/OpenSC/wiki/Slovenian-EID)). So the model exists in the region.

## Verdict

**Unknown, and probably not.** The hardware could do it, since the chip is dual-interface. But there is no evidence that AKD exposes the eID/SSCD applet over the contactless interface. The official mobile identity (Certilia) deliberately avoids the card. The only confirmed use of NFC is passport-style MRTD reading, which proves identity data but gives us no signature. That is not enough for eidchain.

## How to settle it

1. **Check the card front for a 6-digit CAN.** If there is none, PACE-CAN is unlikely for any applet. MRTD access would then use BAC/PACE with the MRZ.
2. **Contactless reader test** (any PC/SC NFC reader, e.g. ACR1252U, or Android with an APDU tool): read `EF.CardAccess` (FID `011C`) under the MF. It lists the PACE parameters if PACE is supported. Then try to SELECT the AKD eID applet with the same AID that Certilia middleware uses over the contact interface (capture it with a PC/SC trace). If it is refused, or only answers after PACE, that is the answer.
3. **Authoritative source:** the Common Criteria security target for NSCIB-CC-2300144-01 ([sec-certs](https://sec-certs.org/cc/2fdb7ebde10e8402/target.pdf)). It should state which interfaces the SSCD is certified for. We have not read it yet. Alternatively, ask AKD directly.

If step 2 succeeds, the next step is to port the Estonian NFC library's card layer to the AKD applet. The Web eID token format and server-side validation can stay as they are.
