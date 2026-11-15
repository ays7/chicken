#!/usr/bin/env python3
"""
scripts/generate_dmg_background.py
Generates the Retina-ready Finder background (cotvnc/Resources/dmg/background.tiff)
for Chicken Fork's DMG installer window using macOS AppKit/CoreGraphics + tiffutil.
"""

import os
import shutil
import subprocess
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO_ROOT, "cotvnc", "Resources", "dmg")
OUT_TIFF = os.path.join(OUT_DIR, "background.tiff")

SWIFT_RENDERER = r"""
import AppKit
import Foundation

func renderBackground(scale: Int, outputPath: String) throws {
    let width = 600
    let height = 360
    let pxW = width * scale
    let pxH = height * scale

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pxW,
        pixelsHigh: pxH,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Failed to create bitmap rep")
    }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Failed to create graphics context")
    }
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Clean white window canvas
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // Top banner (#0066CC, matching Chicken Fork site accent)
    let bannerHeight: CGFloat = 68
    let bannerRect = NSRect(x: 0, y: CGFloat(height) - bannerHeight, width: CGFloat(width), height: bannerHeight)
    NSColor(calibratedRed: 0.0, green: 0.40, blue: 0.80, alpha: 1.0).setFill()
    bannerRect.fill()

    // Subtle bottom hairline under banner
    NSColor(calibratedRed: 0.0, green: 0.31, blue: 0.64, alpha: 1.0).setFill()
    NSRect(x: 0, y: CGFloat(height) - bannerHeight, width: CGFloat(width), height: 1).fill()

    // Banner text: "Drag Chicken Fork to your Applications folder."
    let text = "Drag Chicken Fork to your Applications folder." as NSString
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .medium),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    let textSize = text.size(withAttributes: attrs)
    let textY = bannerRect.origin.y + (bannerHeight - textSize.height) / 2.0 + 1.0
    text.draw(
        in: NSRect(x: 0, y: textY, width: CGFloat(width), height: textSize.height),
        withAttributes: attrs
    )

    // Progressive >>> chevrons centered between Chicken Fork.app (165) and Applications (435)
    // Finder icon center is y=195 from top => AppKit y = 360 - 195 = 165
    let centerY: CGFloat = 172
    let chevronOffsets: [(CGFloat, CGFloat)] = [
        (276, 0.28),
        (294, 0.45),
        (312, 0.65)
    ]
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.setLineWidth(3.2)

    for (cx, alpha) in chevronOffsets {
        cg.setStrokeColor(NSColor(calibratedWhite: 0.35, alpha: alpha).cgColor)
        cg.beginPath()
        cg.move(to: CGPoint(x: cx - 6, y: centerY + 12))
        cg.addLine(to: CGPoint(x: cx + 6, y: centerY))
        cg.addLine(to: CGPoint(x: cx - 6, y: centerY - 12))
        cg.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG")
    }
    try pngData.write(to: URL(fileURLWithPath: outputPath))
}

let args = CommandLine.arguments
try renderBackground(scale: 1, outputPath: args[1])
try renderBackground(scale: 2, outputPath: args[2])
"""

def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory(dir="/tmp") as tmpdir:
        png_1x = os.path.join(tmpdir, "background.png")
        png_2x = os.path.join(tmpdir, "background@2x.png")
        swift_file = os.path.join(tmpdir, "render.swift")
        modcache = os.path.join(tmpdir, "modcache")
        with open(swift_file, "w", encoding="utf-8") as f:
            f.write(SWIFT_RENDERER)

        subprocess.run(
            ["swift", "-module-cache-path", modcache, swift_file, png_1x, png_2x],
            check=True,
        )
        tmp_tiff = os.path.join(tmpdir, "background.tiff")
        subprocess.run(
            ["tiffutil", "-cathidpicheck", png_1x, png_2x, "-out", tmp_tiff],
            check=True,
        )
        shutil.copyfile(tmp_tiff, OUT_TIFF)
    print(f"Generated {OUT_TIFF}")

if __name__ == "__main__":
    main()
