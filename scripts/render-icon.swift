import AppKit

/// Continuous-corner ("squircle") path like macOS app icons: a superellipse.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    let small = pixels <= 32

    // Apple's grid: an 824pt body centered in a 1024 canvas, leaving room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x4B3BE8))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: indigo (top-left) to violet (bottom-right)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x4F6BFF), color(0x5B3FF0), color(0x8A2FE0)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // Soft top highlight for depth
    let highlight = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(highlight, startCenter: CGPoint(x: 380, y: 900), startRadius: 0, endCenter: CGPoint(x: 380, y: 900), endRadius: 620, options: [])
    ctx.restoreGState()

    // Inner edge stroke so the icon holds up on dark backgrounds
    if !small {
        ctx.saveGState()
        ctx.addPath(squircle(in: body.insetBy(dx: 2, dy: 2)))
        ctx.setStrokeColor(color(0xFFFFFF, 0.18))
        ctx.setLineWidth(4)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Waveform flowing into a text caret
    let heights: [CGFloat] = small ? [250, 470, 330] : [180, 340, 520, 390, 250]
    let barWidth: CGFloat = small ? 96 : 72
    let gap: CGFloat = small ? 58 : 44
    let caretWidth: CGFloat = small ? 64 : 44
    let caretHeight: CGFloat = small ? 520 : 560
    let caretGap: CGFloat = small ? 74 : 74
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap + caretGap + caretWidth
    var x = 512 - total / 2
    let midY: CGFloat = 512

    ctx.saveGState()
    if !small {
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x1A0B5E, 0.35))
    }
    for (index, height) in heights.enumerated() {
        // Bars fade slightly left to right, as if the sound is becoming text.
        let alpha = 1 - CGFloat(index) * (small ? 0.0 : 0.05)
        let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.setFillColor(color(0xFFFFFF, alpha))
        ctx.fillPath()
        x += barWidth + gap
    }
    x += caretGap - gap
    let caret = CGRect(x: x, y: midY - caretHeight / 2, width: caretWidth, height: caretHeight)
    ctx.addPath(CGPath(roundedRect: caret, cornerWidth: caretWidth / 2, cornerHeight: caretWidth / 2, transform: nil))
    ctx.setFillColor(color(0x6FF5D2))
    ctx.fillPath()
    ctx.restoreGState()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

// Usage: swift scripts/render-icon.swift Flowtype/Assets.xcassets/AppIcon.appiconset
let output = CommandLine.arguments[1]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! render(pixels: pixels).write(to: URL(fileURLWithPath: "\(output)/\(name)"))
    }
}
