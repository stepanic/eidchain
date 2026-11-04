import Foundation

public enum PACEError: Error, CustomStringConvertible {
    case status(String, UInt16)
    case malformed(String)
    case mac
    public var description: String {
        switch self {
        case let .status(step, sw): return "\(step): SW \(String(format: "%04X", sw))"
        case let .malformed(s): return "malformed: \(s)"
        case .mac: return "response MAC mismatch"
        }
    }
}

/// Raw APDU in, response data and status word out. The app maps this onto Core NFC.
public typealias Transmit = (Data) async throws -> (Data, UInt16)

/// AES secure messaging per EN 419212-2 clause 9 / ICAO 9303 part 11:
/// DO87 encrypted data, DO97 Le, DO8E CMAC over SSC and padded header.
public final class SecureMessaging {
    let kEnc: Data, kMac: Data
    var ssc = Data(count: 16)

    init(kEnc: Data, kMac: Data) { self.kEnc = kEnc; self.kMac = kMac }

    private func increment() {
        for i in (0..<16).reversed() { ssc[i] &+= 1; if ssc[i] != 0 { break } }
    }

    /// `apdu` is a plain short APDU: CLA INS P1 P2 [Lc data] [Le].
    public func transmit(_ apdu: Data, over send: Transmit) async throws -> (Data, UInt16) {
        let b = [UInt8](apdu)
        let header = Data([b[0] | 0x0C, b[1], b[2], b[3]])
        var data = Data(), le: UInt8? = nil
        if b.count == 5 { le = b[4] }
        else if b.count > 5 {
            let lc = Int(b[4]); data = Data(b[5..<5 + lc])
            if b.count > 5 + lc { le = b[5 + lc] }
        }
        increment()
        var body = Data()
        if !data.isEmpty {
            let iv = AES.ecbEncrypt(kEnc, ssc)
            body += TLV.make(0x87, Data([0x01]) + AES.cbcEncrypt(kEnc, pad(data), iv: iv))
        }
        if let le { body += TLV.make(0x97, Data([le])) }
        let mac = AES.cmac(kMac, pad(ssc + pad(header) + body)).prefix(8)
        body += TLV.make(0x8E, mac)
        let protected = header + Data([UInt8(body.count)]) + body + Data([0x00])

        let (resp, sw) = try await send(protected)
        increment()
        let objs = TLV.parse(resp)
        guard let rmac = objs.first(where: { $0.tag == 0x8E })?.value else {
            // The card answers in plain when it rejects the SM APDU itself.
            return (Data(), sw)
        }
        var macInput = Data()
        for o in objs where o.tag == 0x87 || o.tag == 0x99 { macInput += TLV.make(UInt8(o.tag), Data(o.value)) }
        guard AES.cmac(kMac, pad(ssc + macInput)).prefix(8) == Data(rmac) else { throw PACEError.mac }
        var plain = Data()
        if let enc = objs.first(where: { $0.tag == 0x87 })?.value {
            let iv = AES.ecbEncrypt(kEnc, ssc)
            guard let p = unpad(AES.cbcDecrypt(kEnc, Data(enc.dropFirst()), iv: iv)) else { throw PACEError.malformed("DO87 padding") }
            plain = p
        }
        var inner = sw
        if let do99 = objs.first(where: { $0.tag == 0x99 })?.value, do99.count == 2 {
            inner = UInt16(do99[do99.startIndex]) << 8 | UInt16(do99[do99.startIndex + 1])
        }
        return (plain, inner)
    }
}
