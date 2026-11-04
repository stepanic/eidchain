import CoreNFC
import Foundation

/// First milestone: learn what the card exposes over NFC *without* PACE or PIN.
/// Reads EF.DIR (application list with AIDs) and EF.CardAccess (PACE parameters),
/// then tries SELECT on every AID declared in Info.plist. Nothing here touches
/// a retry counter.
@MainActor
final class Probe: NSObject, ObservableObject {
    @Published var log = ""
    private var session: NFCTagReaderSession?

    func start() {
        guard NFCTagReaderSession.readingAvailable else { log = "NFC nije dostupan."; return }
        log = ""
        session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: nil)
        session?.alertMessage = "Prisloni osobnu na vrh iPhonea."
        session?.begin()
    }

    fileprivate func add(_ s: String) { log += s + "\n" }
}

extension Probe: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            let e = error as? NFCReaderError
            if e?.code != .readerSessionInvalidationErrorUserCanceled { self.add("session: \(error.localizedDescription)") }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first else { return }
        guard case let .iso7816(tag) = first else {
            Task { @MainActor in self.add("tag nije ISO 7816: \(first)") }
            session.invalidate(errorMessage: "Nepoznata kartica")
            return
        }
        Task {
            do {
                try await session.connect(to: first)
                await self.run(tag)
                session.alertMessage = "Gotovo"
                session.invalidate()
            } catch {
                await self.add("connect: \(error.localizedDescription)")
                session.invalidate(errorMessage: "Greška")
            }
        }
    }
}

extension Probe {
    func run(_ tag: NFCISO7816Tag) async {
        add("initialSelectedAID: \(tag.initialSelectedAID)")
        add("historicalBytes: \(tag.historicalBytes.map(hex) ?? "-") \(tag.historicalBytes.map(ascii) ?? "")")
        add("applicationData: \(tag.applicationData.map(hex) ?? "-")")
        add("proprietaryAppDataCoding: \(tag.proprietaryApplicationDataCoding)")

        _ = await tx(tag, "SELECT MF", "00A4000C023F00")
        await readEF(tag, "EF.DIR", fid: "2F00")
        await readEF(tag, "EF.CardAccess", fid: "011C")
        await readEF(tag, "EF.ATR/INFO", fid: "2F01")

        let aids = Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.nfc.readersession.iso7816.select-identifiers") as? [String] ?? []
        for aid in aids {
            let lc = String(format: "%02X", aid.count / 2)
            _ = await tx(tag, "SELECT \(aid)", "00A40400" + lc + aid + "00")
        }
    }

    private func readEF(_ tag: NFCISO7816Tag, _ name: String, fid: String) async {
        _ = await tx(tag, "SELECT MF", "00A4000C023F00")
        guard let sw = await tx(tag, "SELECT \(name)", "00A4020C02" + fid), sw == 0x9000 else { return }
        var offset = 0
        var all = Data()
        while offset < 4096 {
            let p = String(format: "%04X", offset)
            guard let (data, sw) = await raw(tag, "00B0" + p + "00") else { break }
            all += data
            if sw != 0x9000 || data.count < 0xE0 { if sw != 0x9000 { add("  READ @\(offset): \(String(format: "%04X", sw))") }; break }
            offset += data.count
        }
        add("  \(name) (\(all.count) B): \(hex(all))")
    }

    @discardableResult
    private func tx(_ tag: NFCISO7816Tag, _ label: String, _ apdu: String) async -> UInt16? {
        guard let (data, sw) = await raw(tag, apdu) else { add("\(label): APDU odbijen"); return nil }
        add("\(label): \(String(format: "%04X", sw))\(data.isEmpty ? "" : " " + hex(data))")
        return sw
    }

    private func raw(_ tag: NFCISO7816Tag, _ apdu: String) async -> (Data, UInt16)? {
        guard let cmd = NFCISO7816APDU(data: bytes(apdu)) else { return nil }
        do {
            let (d, s1, s2) = try await tag.sendCommand(apdu: cmd)
            return (d, UInt16(s1) << 8 | UInt16(s2))
        } catch {
            add("  \(apdu): \(error.localizedDescription)")
            return nil
        }
    }
}

func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined() }
func ascii(_ d: Data) -> String { String(d.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." }) }
func bytes(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}
