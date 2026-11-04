import Foundation

/// Minimal BER-TLV for the few objects PACE and secure messaging use.
enum TLV {
    static func len(_ n: Int) -> Data {
        switch n {
        case ..<0x80: return Data([UInt8(n)])
        case ..<0x100: return Data([0x81, UInt8(n)])
        default: return Data([0x82, UInt8(n >> 8), UInt8(n & 0xFF)])
        }
    }

    static func make(_ tag: Data, _ value: Data) -> Data { tag + len(value.count) + value }
    static func make(_ tag: UInt8, _ value: Data) -> Data { make(Data([tag]), value) }

    /// Parses one level. Tags are one byte, or two when the first is xF in the low 5 bits.
    static func parse(_ d: Data) -> [(tag: UInt16, value: Data)] {
        var out: [(UInt16, Data)] = []
        var i = d.startIndex
        while i < d.endIndex {
            var tag = UInt16(d[i]); i += 1
            if tag & 0x1F == 0x1F, i < d.endIndex { tag = tag << 8 | UInt16(d[i]); i += 1 }
            guard i < d.endIndex else { break }
            var n = Int(d[i]); i += 1
            if n & 0x80 != 0 {
                let k = n & 0x7F; n = 0
                for _ in 0..<k { guard i < d.endIndex else { return out }; n = n << 8 | Int(d[i]); i += 1 }
            }
            guard i + n <= d.endIndex else { break }
            out.append((tag, d[i..<i + n])); i += n
        }
        return out
    }

    static func find(_ tag: UInt16, in d: Data) -> Data? { parse(d).first { $0.tag == tag }.map { Data($0.value) } }
}
