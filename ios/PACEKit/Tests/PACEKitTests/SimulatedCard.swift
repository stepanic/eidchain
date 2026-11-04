import BigInt
import Foundation
@testable import PACEKit

/// Card side of PACE-CAN and SM, written from the same spec, to exercise the
/// terminal code end to end. It cannot catch a misreading of the spec that both
/// sides share; only the real card can.
actor SimulatedCard {
    let can: String, file: Data
    let c = Curve.p384
    var nonce = BigUInt(0), skMap = BigUInt(0), g2 = Curve.p384.g, sk = BigUInt(0)
    var pkPCD = Data(), pkIC = Data()
    var sm: SecureMessaging?
    var smCard: (kEnc: Data, kMac: Data, ssc: Data)?

    init(can: String, file: Data) { self.can = can; self.file = file }

    func handle(_ apdu: Data) -> (Data, UInt16) {
        let b = [UInt8](apdu)
        if smCard != nil { return handleSM(b) }
        switch b[1] {
        case 0x22: return (Data(), 0x9000)
        case 0x86:
            let inner = TLV.find(0x7C, in: Data(b[5..<5 + Int(b[4])]))!
            if inner.isEmpty {
                var r = [UInt8](repeating: 0, count: 16); _ = SecRandomCopyBytes(kSecRandomDefault, 16, &r)
                nonce = BigUInt(Data(r))
                let z = AES.cbcEncrypt(PACE.kdf(Data(can.utf8), 3), Data(r), iv: Data(count: 16))
                return (TLV.make(0x7C, TLV.make(0x80, z)), 0x9000)
            }
            if let m = TLV.find(0x81, in: inner) {
                skMap = c.randomScalar()
                g2 = c.add(c.mul(nonce, c.g), c.mul(skMap, c.decode(m)!))
                return (TLV.make(0x7C, TLV.make(0x82, c.encode(c.mul(skMap, c.g)))), 0x9000)
            }
            if let k = TLV.find(0x83, in: inner) {
                pkPCD = k; sk = c.randomScalar(); pkIC = c.encode(c.mul(sk, g2))
                return (TLV.make(0x7C, TLV.make(0x84, pkIC)), 0x9000)
            }
            if let t = TLV.find(0x85, in: inner) {
                let shared = c.pad(c.mul(sk, c.decode(pkPCD)!).x)
                let kEnc = PACE.kdf(shared, 1), kMac = PACE.kdf(shared, 2)
                func token(_ key: Data) -> Data {
                    AES.cmac(kMac, TLV.make(Data([0x7F, 0x49]), TLV.make(0x06, PACE.oid) + TLV.make(0x86, key))).prefix(8)
                }
                guard t == token(pkIC) else { return (Data(), 0x6300) }
                smCard = (kEnc, kMac, Data(count: 16))
                return (TLV.make(0x7C, TLV.make(0x86, token(pkPCD))), 0x9000)
            }
        default: break
        }
        return (Data(), 0x6D00)
    }

    private func inc(_ s: inout Data) { for i in (0..<16).reversed() { s[i] &+= 1; if s[i] != 0 { break } } }

    private func handleSM(_ b: [UInt8]) -> (Data, UInt16) {
        var (kEnc, kMac, ssc) = smCard!
        inc(&ssc)
        let objs = TLV.parse(Data(b[5..<5 + Int(b[4])]))
        var macIn = Data()
        for o in objs where o.tag == 0x87 || o.tag == 0x97 { macIn += TLV.make(UInt8(o.tag), Data(o.value)) }
        let mac = objs.first { $0.tag == 0x8E }!.value
        guard AES.cmac(kMac, pad(ssc + pad(Data(b[0..<4])) + macIn)).prefix(8) == Data(mac) else { return (Data(), 0x6988) }
        // READ BINARY only: P1/P2 offset, or SFI in P1 with offset in P2.
        let off = b[2] & 0x80 != 0 ? Int(b[3]) : Int(b[2]) << 8 | Int(b[3])
        let le = Int(objs.first { $0.tag == 0x97 }!.value.first!)
        let chunk = file.dropFirst(off).prefix(le == 0 ? 256 : le)
        inc(&ssc)
        let iv = AES.ecbEncrypt(kEnc, ssc)
        let do87 = TLV.make(0x87, Data([0x01]) + AES.cbcEncrypt(kEnc, pad(Data(chunk)), iv: iv))
        let do99 = TLV.make(0x99, Data([0x90, 0x00]))
        let rmac = AES.cmac(kMac, pad(ssc + do87 + do99)).prefix(8)
        smCard = (kEnc, kMac, ssc)
        return (do87 + do99 + TLV.make(0x8E, rmac), 0x9000)
    }
}
