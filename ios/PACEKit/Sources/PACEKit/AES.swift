import CommonCrypto
import Foundation

/// The AES primitives secure messaging needs: raw block operations, CBC
/// without padding, and CMAC (RFC 4493). CryptoKit offers none of these.
enum AES {
    static func ecbEncrypt(_ key: Data, _ block: Data) -> Data { crypt(CCOperation(kCCEncrypt), key, block, iv: nil, ecb: true) }
    static func cbcEncrypt(_ key: Data, _ data: Data, iv: Data) -> Data { crypt(CCOperation(kCCEncrypt), key, data, iv: iv, ecb: false) }
    static func cbcDecrypt(_ key: Data, _ data: Data, iv: Data) -> Data { crypt(CCOperation(kCCDecrypt), key, data, iv: iv, ecb: false) }

    private static func crypt(_ op: CCOperation, _ key: Data, _ data: Data, iv: Data?, ecb: Bool) -> Data {
        precondition(data.count % 16 == 0)
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    (iv ?? Data(count: 16)).withUnsafeBytes { v in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(ecb ? kCCOptionECBMode : 0),
                                k.baseAddress, key.count, ecb ? nil : v.baseAddress,
                                d.baseAddress, data.count, o.baseAddress, data.count, &moved)
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return out
    }

    static func cmac(_ key: Data, _ msg: Data) -> Data {
        func shift(_ b: Data) -> Data {
            var r = Data(count: 16)
            for i in 0..<16 { r[i] = (b[i] << 1) | (i < 15 ? b[i + 1] >> 7 : 0) }
            if b[0] & 0x80 != 0 { r[15] ^= 0x87 }
            return r
        }
        let l = ecbEncrypt(key, Data(count: 16))
        let k1 = shift(l), k2 = shift(k1)
        let n = max(1, (msg.count + 15) / 16)
        let complete = msg.count > 0 && msg.count % 16 == 0
        var last = Data(msg.suffix(from: (n - 1) * 16 + msg.startIndex))
        if complete { last = xor(last, k1) } else { last.append(0x80); last += Data(count: 16 - last.count); last = xor(last, k2) }
        var x = Data(count: 16)
        for i in 0..<(n - 1) {
            let s = msg.startIndex + i * 16
            x = ecbEncrypt(key, xor(x, msg[s..<s + 16]))
        }
        return ecbEncrypt(key, xor(x, last))
    }

    static func xor(_ a: Data, _ b: Data) -> Data { Data(zip(a, b).map { $0 ^ $1 }) }
}

/// ISO/IEC 9797-1 padding method 2 to the AES block size.
func pad(_ d: Data) -> Data {
    var r = d; r.append(0x80)
    while r.count % 16 != 0 { r.append(0) }
    return r
}

func unpad(_ d: Data) -> Data? {
    guard let i = d.lastIndex(where: { $0 != 0 }), d[i] == 0x80 else { return nil }
    return d[d.startIndex..<i]
}
