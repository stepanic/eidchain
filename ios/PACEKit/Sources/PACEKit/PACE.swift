import CryptoKit
import Foundation
import BigInt

/// PACE with generic mapping over ECDH, AES-256 (id-PACE-ECDH-GM-AES-CBC-CMAC-256),
/// as offered by the eSign application of the Croatian eOI (EF.CardAccess at SFI 0x1C,
/// parameterId 15 = NIST P-384). Password is the CAN.
public enum PACE {
    public static let oid = Data([0x04, 0x00, 0x7F, 0x00, 0x07, 0x02, 0x02, 0x04, 0x02, 0x04])

    public static func kdf(_ secret: Data, _ counter: UInt8) -> Data {
        Data(SHA256.hash(data: secret + Data([0, 0, 0, counter])))
    }

    /// Runs MSE:Set AT and the four General Authenticate steps.
    /// `log` gets one line per step, without secrets.
    public static func establish(can: String, curve: Curve = .p384, send: Transmit,
                                 log: (String) -> Void = { _ in }) async throws -> SecureMessaging {
        // MSE:Set AT, password reference 02 = CAN.
        let mse = TLV.make(0x80, oid) + TLV.make(0x83, Data([0x02]))
        try await check("MSE:Set AT", send(Data([0x00, 0x22, 0xC1, 0xA4, UInt8(mse.count)]) + mse))
        log("MSE:Set AT ok")

        // 1. Encrypted nonce.
        let r1 = try await ga("GA nonce", Data(), last: false, send)
        guard let z = TLV.find(0x80, in: r1) else { throw PACEError.malformed("no nonce") }
        let kPi = kdf(Data(can.utf8), 3)
        let s = BigUInt(AES.cbcDecrypt(kPi, z, iv: Data(count: 16)))
        log("nonce \(z.count) B")

        // 2. Mapping: G' = s·G + H, H = shared point of the mapping keys.
        let skMap = curve.randomScalar()
        let r2 = try await ga("GA map", TLV.make(0x81, curve.encode(curve.mul(skMap, curve.g))), last: false, send)
        guard let pkMapIC = TLV.find(0x82, in: r2).flatMap(curve.decode) else { throw PACEError.malformed("map key") }
        let h = curve.mul(skMap, pkMapIC)
        let gMapped = curve.add(curve.mul(s, curve.g), h)
        log("mapped generator ok")

        // 3. Key agreement on G'.
        let sk = curve.randomScalar()
        let pk = curve.encode(curve.mul(sk, gMapped))
        let r3 = try await ga("GA key agreement", TLV.make(0x83, pk), last: false, send)
        guard let pkICRaw = TLV.find(0x84, in: r3), let pkIC = curve.decode(pkICRaw) else { throw PACEError.malformed("ephemeral key") }
        guard pkICRaw != pk else { throw PACEError.malformed("card echoed our key") }
        let shared = curve.pad(curve.mul(sk, pkIC).x)
        let kEnc = kdf(shared, 1), kMac = kdf(shared, 2)
        log("key agreement ok")

        // 4. Mutual authentication tokens over the other side's ephemeral key.
        func token(_ key: Data) -> Data {
            AES.cmac(kMac, TLV.make(Data([0x7F, 0x49]), TLV.make(0x06, oid) + TLV.make(0x86, key))).prefix(8)
        }
        let r4 = try await ga("GA tokens", TLV.make(0x85, token(pkICRaw)), last: true, send)
        guard TLV.find(0x86, in: r4) == token(pk) else { throw PACEError.malformed("card token mismatch") }
        log("PACE established")
        return SecureMessaging(kEnc: kEnc, kMac: kMac)
    }

    private static func ga(_ step: String, _ inner: Data, last: Bool, _ send: Transmit) async throws -> Data {
        let body = TLV.make(0x7C, inner)
        let apdu = Data([last ? 0x00 : 0x10, 0x86, 0x00, 0x00, UInt8(body.count)]) + body + Data([0x00])
        let (resp, sw) = try await send(apdu)
        guard sw == 0x9000 else { throw PACEError.status(step, sw) }
        guard let dyn = TLV.find(0x7C, in: resp) else { throw PACEError.malformed("\(step) without 7C") }
        return dyn
    }

    @discardableResult
    private static func check(_ step: String, _ r: (Data, UInt16)) throws -> Data {
        guard r.1 == 0x9000 else { throw PACEError.status(step, r.1) }
        return r.0
    }
}
