import BigInt
import CryptoKit
import XCTest
@testable import PACEKit

final class PACEKitTests: XCTestCase {
    func hex(_ s: String) -> Data { var d = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }; return d }

    func testCMACRFC4493() {
        let k = hex("2b7e151628aed2a6abf7158809cf4f3c")
        XCTAssertEqual(AES.cmac(k, Data()), hex("bb1d6929e95937287fa37d129b756746"))
        XCTAssertEqual(AES.cmac(k, hex("6bc1bee22e409f96e93d7e117393172a")), hex("070a16b46b4d4144f79bdd9dd04a287c"))
        XCTAssertEqual(AES.cmac(k, hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411")),
                       hex("dfa66747de9ae63030ca32611497c827"))
    }

    func testCMACAES256() {
        // NIST SP 800-38B example, AES-256, 16-byte message.
        let k = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        XCTAssertEqual(AES.cmac(k, hex("6bc1bee22e409f96e93d7e117393172a")), hex("28a7023f452e8f82bd4bf28d8c37c35c"))
    }

    func testScalarMulAgainstCryptoKit() throws {
        let c = Curve.p384
        for _ in 0..<3 {
            let k = P384.KeyAgreement.PrivateKey()
            let ours = c.encode(c.mul(BigUInt(k.rawRepresentation), c.g))
            XCTAssertEqual(ours, k.publicKey.x963Representation)
            let other = P384.KeyAgreement.PrivateKey()
            let shared = try k.sharedSecretFromKeyAgreement(with: other.publicKey).withUnsafeBytes { Data($0) }
            let q = try XCTUnwrap(c.decode(other.publicKey.x963Representation))
            XCTAssertEqual(c.pad(c.mul(BigUInt(k.rawRepresentation), q).x), shared)
        }
    }

    func testAddIsConsistent() {
        let c = Curve.p384
        let a = c.mul(5, c.g), b = c.mul(7, c.g)
        XCTAssertEqual(c.add(a, b), c.mul(12, c.g))
        XCTAssertTrue(c.isOnCurve(c.add(a, b)))
        XCTAssertTrue(c.mul(c.n, c.g).infinity)
    }

    func testPadding() {
        XCTAssertEqual(pad(Data([1, 2])).count, 16)
        XCTAssertEqual(unpad(pad(Data([1, 2]))), Data([1, 2]))
        XCTAssertEqual(pad(Data(count: 16)).count, 32)
    }
}

final class PACEFlowTests: XCTestCase {
    func testPACEAndSecureRead() async throws {
        let file = Data((0..<500).map { UInt8($0 & 0xFF) })
        let card = SimulatedCard(can: "123456", file: file)
        let send: Transmit = { await card.handle($0) }
        let sm = try await PACE.establish(can: "123456", send: send)
        var got = Data()
        let (first, sw) = try await sm.transmit(Data([0x00, 0xB0, 0x81, 0x00, 0xC0]), over: send)
        XCTAssertEqual(sw, 0x9000); got += first
        while got.count < file.count {
            let (d, _) = try await sm.transmit(Data([0x00, 0xB0, UInt8(got.count >> 8), UInt8(got.count & 0xFF), 0xC0]), over: send)
            if d.isEmpty { break }; got += d
        }
        XCTAssertEqual(got, file)
    }

    func testWrongCANFails() async {
        let card = SimulatedCard(can: "123456", file: Data())
        do { _ = try await PACE.establish(can: "654321", send: { await card.handle($0) }); XCTFail() } catch {}
    }
}
