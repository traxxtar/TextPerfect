// Builds the app icon from Icon.png:  cd ~/TextPerfect && swift make_icon.swift
//
// Icon.png is a rounded tile drawn on a flat off-white background with a soft shadow, and has no
// transparency, so used as-is it would show as a pale square in the Dock and on the splash screen.
// This cuts the tile out just inside its rim and places it on Apple's standard icon canvas
// (1024 px, tile 824 px at 100,100, transparent around it), then writes:
//   AppIcon_1024.png   the icon itself, also shown on the launch splash
//   AppIcon.icns       every size macOS needs, made with iconutil
//
// The tile's position in Icon.png was measured from the image (its bright one-pixel rim).
// A different source image needs these four numbers re-measured.
import AppKit

let tileInSource = CGRect(x: 110, y: 95, width: 1032, height: 1018)   // pixels, top-left origin
let rimInset: CGFloat = 3        // cut just inside the rim, leaving the shadow and rim behind
let canvas = 1024
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185  // Apple's corner radius for an 824 px tile

let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let src = NSImage(contentsOf: dir.appendingPathComponent("Icon.png")),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Icon.png not found in \(dir.path)")
}
guard let cropped = srcCG.cropping(to: tileInSource.insetBy(dx: rimInset, dy: rimInset)) else {
    fatalError("tile rectangle falls outside Icon.png")
}

func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size) / CGFloat(canvas)
    let r = CGRect(x: tileRect.minX * s, y: tileRect.minY * s, width: tileRect.width * s, height: tileRect.height * s)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: cornerRadius * s, cornerHeight: cornerRadius * s, transform: nil))
    ctx.clip()
    ctx.draw(cropped, in: r)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

writePNG(render(canvas), dir.appendingPathComponent("AppIcon_1024.png"))

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote AppIcon_1024.png and AppIcon.icns")
