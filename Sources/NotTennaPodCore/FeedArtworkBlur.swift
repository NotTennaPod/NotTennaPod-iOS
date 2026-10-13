import Foundation

/// The source header's radius-10 separable triangular blur. Integer truncation
/// happens after each axis; transparent areas become opaque, as in the source.
/// Stack Blur Algorithm by Mario Klingemann <mario@quasimondo.com>.
public enum FeedArtworkBlur {
    public static func apply(_ pixels: [UInt32], width: Int, height: Int) -> [UInt32]? {
        guard width > 0, height > 0, width <= Int.max / height, pixels.count == width * height else { return nil }
        let radius = 10, divisor = 121
        var horizontal = [UInt32](repeating: 0, count: pixels.count)
        var output = horizontal
        for y in 0..<height {
            // A superseded render stops instead of finishing a blur nobody sees.
            if Task.isCancelled { return nil }
            for x in 0..<width {
                var red = 0, green = 0, blue = 0
                for delta in -radius...radius {
                    let pixel = pixels[y * width + min(width - 1, max(0, x + delta))]
                    let weight = radius + 1 - abs(delta)
                    red += Int((pixel >> 16) & 255) * weight
                    green += Int((pixel >> 8) & 255) * weight
                    blue += Int(pixel & 255) * weight
                }
                horizontal[y * width + x] = UInt32(red / divisor) << 16 | UInt32(green / divisor) << 8 | UInt32(blue / divisor)
            }
        }
        for y in 0..<height {
            if Task.isCancelled { return nil }
            for x in 0..<width {
                var red = 0, green = 0, blue = 0
                for delta in -radius...radius {
                    let pixel = horizontal[min(height - 1, max(0, y + delta)) * width + x]
                    let weight = radius + 1 - abs(delta)
                    red += Int((pixel >> 16) & 255) * weight
                    green += Int((pixel >> 8) & 255) * weight
                    blue += Int(pixel & 255) * weight
                }
                output[y * width + x] = 0xff000000 | UInt32(red / divisor) << 16 | UInt32(green / divisor) << 8 | UInt32(blue / divisor)
            }
        }
        return output
    }
}
