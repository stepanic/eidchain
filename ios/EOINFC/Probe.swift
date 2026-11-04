import CoreNFC
import PACEKit
import Foundation

/// First milestone: learn what the card exposes over NFC *without* PACE or PIN.
/// Reads EF.DIR (application list with AIDs) and EF.CardAccess (PACE parameters),
/// then tries SELECT on every AID declared in Info.plist. Nothing here touches
/// a retry counter.
@MainActor
final class Probe: NSObject, ObservableObject {
    @Published var log = ""
    private var session: NFCTagReaderSession?
    /// Empty: unauthenticated probe. Set: PACE with this CAN, then secure reads.
    private var can = ""

    func start(can: String = "") {
        self.can = can
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
        if !can.isEmpty { await runPACE(tag); return }
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
        await probeESign(tag)
    }

    /// Inside the eSign application: ask for the FCP (sizes and access rules) of
    /// likely EFs and read their first bytes. 6982 means "security status not
    /// satisfied", i.e. PACE or PIN is required. Only SELECT and READ BINARY,
    /// so no retry counter is touched.
    private func probeESign(_ tag: NFCISO7816Tag) async {
        let esign = "A000000167455349474E"
        add("--- eSign")
        _ = await tx(tag, "SELECT eSign FCP", "00A404040A" + esign + "00")
        let fids = ["2F02", "C000", "C001", "C100", "C101", "C200", "C201", "C500", "C501",
                    "C600", "C700", "CE00", "5031", "5032", "5033", "4401", "4402", "4403",
                    "4404", "4405", "0101", "0102", "0103", "D001", "D002", "1001", "1002"]
        for fid in fids {
            guard let sw = await tx(tag, "  FCP \(fid)", "00A4020402" + fid + "00"), sw == 0x9000 else { continue }
            _ = await tx(tag, "    READ \(fid)", "00B0000040")
        }
        add("--- eSign SFI scan (READ BINARY by short EF id)")
        _ = await tx(tag, "SELECT eSign", "00A4040C0A" + esign)
        for sfi in 1...30 {
            let p1 = String(format: "%02X", 0x80 | sfi)
            guard let (data, sw) = await raw(tag, "00B0" + p1 + "0040") else { continue }
            if sw == 0x6A82 { continue }
            add("  SFI \(sfi): \(String(format: "%04X", sw))\(data.isEmpty ? "" : " " + hex(data))")
        }
        add("--- done")
    }

    /// PACE-CAN inside the eSign application, then read its files through
    /// secure messaging. Still no PIN.
    private func runPACE(_ tag: NFCISO7816Tag) async {
        let send: Transmit = { [unowned self] apdu in
            guard let r = await self.raw(tag, hex(apdu)) else { throw PACEError.malformed("transport") }
            return r
        }
        add("historicalBytes: \(tag.historicalBytes.map(ascii) ?? "-")")
        _ = await tx(tag, "SELECT eSign", "00A4040C0AA000000167455349474E")
        let t0 = Date()
        let sm: SecureMessaging
        do {
            sm = try await PACE.establish(can: can, send: send) { [unowned self] in self.add("  " + $0) }
        } catch {
            add("PACE: \(error)")
            return
        }
        add(String(format: "PACE %.2f s", Date().timeIntervalSince(t0)))
        for sfi in 1...6 {
            var all = Data()
            var (d, sw) = (Data(), UInt16(0))
            do {
                (d, sw) = try await sm.transmit(Data([0x00, 0xB0, UInt8(0x80 | sfi), 0x00, 0xC0]), over: send)
                all += d
                while sw == 0x9000 && d.count == 0xC0 && all.count < 8192 {
                    (d, sw) = try await sm.transmit(Data([0x00, 0xB0, UInt8(all.count >> 8), UInt8(all.count & 0xFF), 0xC0]), over: send)
                    all += d
                }
            } catch {
                add("SFI \(sfi): \(error)")
                return
            }
            if sw == 0x6A82 && all.isEmpty { continue }
            add("SFI \(sfi): \(String(format: "%04X", sw)) \(all.count) B \(hex(all))")
        }
        add("--- done")
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

    fileprivate func raw(_ tag: NFCISO7816Tag, _ apdu: String) async -> (Data, UInt16)? {
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
