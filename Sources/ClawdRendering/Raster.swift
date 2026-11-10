import Foundation
import CoreGraphics
import ImageIO

/// One pixel, premultiplied alpha like every bitmap CoreGraphics hands out (an opaque pixel is the colour itself).
public struct Pixel: Equatable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let clear = Pixel(0, 0, 0, 0)
    public var isOpaque: Bool { a == 255 }
    public var isClear: Bool { a == 0 }
}

/// A plain RGBA bitmap that lives on a grid: one raster pixel is one art cell (half a Clawd unit) for Clawd, one bubble
/// pixel for a bubble. Everything is composed here with integer arithmetic only, so a frame is the same on every Mac and
/// every OS build; CoreGraphics only enters when the finished picture is handed to a layer.
public struct Raster: Equatable {
    public let width: Int
    public let height: Int
    public private(set) var data: [UInt8]

    public init(width: Int, height: Int) {
        self.width = max(0, width); self.height = max(0, height)
        data = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }
    public init(width: Int, height: Int, data: [UInt8]) {
        precondition(data.count == width * height * 4, "raster data does not match its size")
        self.width = width; self.height = height; self.data = data
    }

    public func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }
    public subscript(x: Int, y: Int) -> Pixel {
        get {
            guard contains(x, y) else { return .clear }
            let i = (y * width + x) * 4
            return Pixel(data[i], data[i + 1], data[i + 2], data[i + 3])
        }
        set {
            guard contains(x, y) else { return }
            let i = (y * width + x) * 4
            data[i] = newValue.r; data[i + 1] = newValue.g; data[i + 2] = newValue.b; data[i + 3] = newValue.a
        }
    }
    public func isOpaque(_ x: Int, _ y: Int) -> Bool { contains(x, y) && data[(y * width + x) * 4 + 3] != 0 }

    public mutating func fill(x: Int, y: Int, width w: Int, height h: Int, _ pixel: Pixel) {
        let rows = max(0, y)..<max(max(0, y), min(height, y + h)), cols = max(0, x)..<max(max(0, x), min(width, x + w))
        for row in rows { for col in cols { self[col, row] = pixel } }
    }

    /// Source-over: `source` placed with its top-left at (`x`, `y`). Pixels outside this raster are clipped.
    public mutating func blit(_ source: Raster, x: Int, y: Int) {
        for sy in 0..<source.height {
            let dy = y + sy
            guard dy >= 0, dy < height else { continue }
            for sx in 0..<source.width {
                let dx = x + sx
                guard dx >= 0, dx < width else { continue }
                let s = (sy * source.width + sx) * 4
                let sa = Int(source.data[s + 3])
                if sa == 0 { continue }
                let d = (dy * width + dx) * 4
                if sa == 255 {
                    data[d] = source.data[s]; data[d + 1] = source.data[s + 1]; data[d + 2] = source.data[s + 2]; data[d + 3] = 255
                } else {
                    let inverse = 255 - sa
                    for k in 0..<4 { data[d + k] = UInt8(min(255, Int(source.data[s + k]) + (Int(data[d + k]) * inverse + 127) / 255)) }
                }
            }
        }
    }

    public func flippedHorizontally() -> Raster {
        var out = Raster(width: width, height: height)
        for y in 0..<height { for x in 0..<width { out[width - 1 - x, y] = self[x, y] } }
        return out
    }

    /// The same picture on a larger or smaller canvas: `left`, `top` cells are added in front (negative values crop).
    public func padded(left: Int, top: Int, right: Int, bottom: Int) -> Raster {
        var out = Raster(width: width + left + right, height: height + top + bottom)
        out.blit(self, x: left, y: top)
        return out
    }

    public func shifted(dx: Int, dy: Int) -> Raster {
        var out = Raster(width: width, height: height)
        out.blit(self, x: dx, y: dy)
        return out
    }

    /// Exact colour substitution (alpha kept): `map` goes from an opaque source colour to its replacement.
    public func recoloured(_ map: [UInt32: UInt32]) -> Raster {
        guard !map.isEmpty else { return self }
        var out = self
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] == 255 {
            let key = UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])
            if let to = map[key] { out.data[i] = UInt8(to >> 16 & 255); out.data[i + 1] = UInt8(to >> 8 & 255); out.data[i + 2] = UInt8(to & 255) }
        }
        return out
    }

    /// Bounding box of every pixel with any alpha, nil when the raster is empty.
    public var opaqueBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where data[(y * width + x) * 4 + 3] != 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    /// Nearest-neighbour enlargement by a whole factor: every cell becomes a factor x factor block of one colour.
    public func upscaled(by factor: Int) -> Raster {
        guard factor > 1 else { return self }
        var out = Raster(width: width * factor, height: height * factor)
        let rowBytes = out.width * 4
        for y in 0..<height {
            let base = y * factor * rowBytes
            for x in 0..<width {
                let s = (y * width + x) * 4
                if data[s + 3] == 0 { continue }
                for k in 0..<factor {
                    let d = base + (x * factor + k) * 4
                    out.data[d] = data[s]; out.data[d + 1] = data[s + 1]; out.data[d + 2] = data[s + 2]; out.data[d + 3] = data[s + 3]
                }
            }
            for k in 1..<factor { for b in 0..<rowBytes { out.data[base + k * rowBytes + b] = out.data[base + b] } }
        }
        return out
    }

    /// Nearest-neighbour enlargement onto given edges: column x covers pixels columns[x] ..< columns[x + 1] and row y covers rows[y] ..< rows[y + 1]
    /// (each counted from columns[0] and rows[0]). It draws cells that are not a whole number of pixels (`StageLayout.columnEdges`).
    /// The edges must not decrease; edge lists of the wrong length, or that decrease, give the raster back unchanged.
    public func upscaled(columns: [Int], rows: [Int]) -> Raster {
        guard columns.count == width + 1, rows.count == height + 1,
              zip(columns, columns.dropFirst()).allSatisfy({ $0 <= $1 }), zip(rows, rows.dropFirst()).allSatisfy({ $0 <= $1 }) else { return self }
        var out = Raster(width: max(0, columns[width] - columns[0]), height: max(0, rows[height] - rows[0]))
        for y in 0..<height {
            let y0 = rows[y] - rows[0], y1 = rows[y + 1] - rows[0]
            guard y0 < y1 else { continue }
            for x in 0..<width {
                let s = (y * width + x) * 4
                if data[s + 3] == 0 { continue }
                let x0 = columns[x] - columns[0], x1 = columns[x + 1] - columns[0]
                guard x0 < x1 else { continue }
                for py in y0..<y1 {
                    for px in x0..<x1 {
                        let d = (py * out.width + px) * 4
                        out.data[d] = data[s]; out.data[d + 1] = data[s + 1]; out.data[d + 2] = data[s + 2]; out.data[d + 3] = data[s + 3]
                    }
                }
            }
        }
        return out
    }

    /// A raster from a PNG. The PNG is drawn 1:1 into an sRGB premultiplied context, the same path the v1 atlas takes.
    public static func decode(png data: Data) throws -> Raster {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ArtError.encoding }
        return try Raster(image)
    }
    public init(_ image: CGImage) throws {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ArtError.encoding }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = context.data else { throw ArtError.encoding }
        self.init(width: w, height: h, data: Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: w * h * 4)))
    }

    public func cgImage() throws -> CGImage {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(data) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ArtError.encoding }
        return image
    }
}

extension Pixel {
    /// An opaque colour from 0xRRGGBB.
    public init(rgb: UInt32) { self.init(UInt8(rgb >> 16 & 255), UInt8(rgb >> 8 & 255), UInt8(rgb & 255), 255) }
    public var rgb: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }
    /// Relative luminance of an opaque colour (WCAG 2.x).
    public var luminance: Double {
        func channel(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
    /// WCAG contrast ratio between two opaque colours.
    public static func contrast(_ a: Pixel, _ b: Pixel) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
