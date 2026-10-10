import CoreGraphics

/// CGRect を PRD §7 の `[x, y, w, h]` 配列で読み書きするための内部ラッパ。
struct RectArray: Codable, Equatable {
    var rect: CGRect

    init(_ rect: CGRect) { self.rect = rect }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let x = try c.decode(Double.self)
        let y = try c.decode(Double.self)
        let w = try c.decode(Double.self)
        let h = try c.decode(Double.self)
        guard c.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "rect は [x, y, w, h] の 4 要素")
        }
        rect = CGRect(x: x, y: y, width: w, height: h)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(Double(rect.origin.x))
        try c.encode(Double(rect.origin.y))
        try c.encode(Double(rect.size.width))
        try c.encode(Double(rect.size.height))
    }
}
