import AppKit
import ImageIO

/// Derives a readable Signal accent from a local wallpaper image.
enum QuickTerminalWallpaperAccent {
    static func color(from url: URL) -> NSColor? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let rowBytes = image.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * image.height)
        return pixels.withUnsafeMutableBytes { buffer in
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var totalWeight = 0.0
            for index in stride(from: 0, to: buffer.count, by: 4) {
                guard buffer[index + 3] >= 230 else { continue }
                let r = Double(buffer[index]) / 255
                let g = Double(buffer[index + 1]) / 255
                let b = Double(buffer[index + 2]) / 255
                let brightness = max(r, g, b)
                let chroma = brightness - min(r, g, b)
                // Favor colorful, lit areas over shadows and nearly neutral details.
                guard brightness >= 0.12, chroma >= 0.08 else { continue }
                let weight = chroma * brightness
                red += r * weight
                green += g * weight
                blue += b * weight
                totalWeight += weight
            }
            guard totalWeight > 0 else { return nil }
            let sample = NSColor(srgbRed: red / totalWeight, green: green / totalWeight,
                                 blue: blue / totalWeight, alpha: 1)
            guard sample.saturationComponent >= 0.18 else { return nil }
            return NSColor(hue: sample.hueComponent,
                           saturation: min(max(sample.saturationComponent, 0.55), 0.85),
                           brightness: 0.95, alpha: 1)
        }
    }
}
