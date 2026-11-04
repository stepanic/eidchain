import BigInt
import Foundation

/// Affine short-Weierstrass arithmetic over a prime field.
///
/// PACE generic mapping needs point addition with a custom generator
/// (G' = s·G + H), which CryptoKit does not expose. The values are ephemeral
/// and the password is the CAN printed on the card, so constant time is not a
/// goal here; correctness and readability are.
public struct Curve {
    public let p: BigUInt, a: BigUInt, b: BigUInt, n: BigUInt
    public let g: Point
    public var byteCount: Int { (p.bitWidth + 7) / 8 }

    public struct Point: Equatable {
        public let x: BigUInt, y: BigUInt
        public let infinity: Bool
        public static let zero = Point(x: 0, y: 0, infinity: true)
        public init(x: BigUInt, y: BigUInt, infinity: Bool = false) { self.x = x; self.y = y; self.infinity = infinity }
    }

    public static let p384 = Curve(
        p: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff",
        a: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000fffffffc",
        b: "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
        gx: "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7",
        gy: "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f",
        n: "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973")

    init(p: String, a: String, b: String, gx: String, gy: String, n: String) {
        self.p = BigUInt(p, radix: 16)!; self.a = BigUInt(a, radix: 16)!; self.b = BigUInt(b, radix: 16)!
        self.n = BigUInt(n, radix: 16)!
        self.g = Point(x: BigUInt(gx, radix: 16)!, y: BigUInt(gy, radix: 16)!)
    }

    private func sub(_ x: BigUInt, _ y: BigUInt) -> BigUInt { x >= y ? (x - y) % p : p - ((y - x) % p) }
    private func inv(_ x: BigUInt) -> BigUInt { x.inverse(p)! }

    public func isOnCurve(_ q: Point) -> Bool {
        if q.infinity { return true }
        return (q.y * q.y) % p == (q.x.power(3, modulus: p) + a * q.x + b) % p
    }

    public func add(_ q: Point, _ r: Point) -> Point {
        if q.infinity { return r }
        if r.infinity { return q }
        let l: BigUInt
        if q.x == r.x {
            if (q.y + r.y) % p == 0 { return .zero }
            l = ((3 * q.x * q.x + a) % p) * inv((2 * q.y) % p) % p
        } else {
            l = sub(r.y, q.y) * inv(sub(r.x, q.x)) % p
        }
        let x = sub(l * l % p, (q.x + r.x) % p)
        let y = sub(l * sub(q.x, x) % p, q.y)
        return Point(x: x, y: y)
    }

    public func mul(_ k: BigUInt, _ q: Point) -> Point {
        var result = Point.zero, addend = q, k = k
        while k > 0 {
            if k & 1 == 1 { result = add(result, addend) }
            addend = add(addend, addend)
            k >>= 1
        }
        return result
    }

    public func encode(_ q: Point) -> Data { Data([0x04]) + pad(q.x) + pad(q.y) }

    public func decode(_ d: Data) -> Point? {
        let c = byteCount
        guard d.count == 1 + 2 * c, d.first == 0x04 else { return nil }
        let q = Point(x: BigUInt(d.dropFirst().prefix(c)), y: BigUInt(d.suffix(c)))
        return isOnCurve(q) ? q : nil
    }

    public func pad(_ v: BigUInt) -> Data {
        let raw = v.serialize()
        return Data(repeating: 0, count: max(0, byteCount - raw.count)) + raw
    }

    public func randomScalar() -> BigUInt {
        var bytes = [UInt8](repeating: 0, count: byteCount + 8)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return BigUInt(Data(bytes)) % (n - 1) + 1
    }
}
