#!/usr/bin/env swift
//
// generate-rbf-runtime-icons.swift — draw the channel banner onto the two
// RUNTIME app-icon assets, `AppIconLight` and `AppIconDark`.
//
//   swift rbf/scripts/generate-rbf-runtime-icons.swift
//
// WHY THIS EXISTS SEPARATELY FROM generate_rbf_icon.py.
// That script owns the *bundle* icon (`AppIcon-RBF.appiconset`) and works by
// recoloring the Debug icon's orange banner. These two are different assets
// with no Debug equivalent to recolor — `AppIconLight`/`AppIconDark` are plain
// single-image sets — so there is nothing to remap; the banner has to be drawn.
//
// WHY SWIFT AND NOT PYTHON. The Python generator needs Pillow, and Pillow is
// installed for no interpreter on this machine — the repo declares it nowhere
// (no requirements.txt, no pyproject.toml). That is a recorded finding, not a
// local accident. CoreGraphics ships with the OS, so this has no setup step and
// cannot rot the same way. Both generators read their identity from the same
// record, `rbf/scripts/lib/rbf-channel.env`, so the channel is still stated once.
//
// WHY THESE ASSETS MATTER. The Dock, the app switcher and the Settings picker
// all set their image from code at runtime and look these names up directly.
// `ASSETCATALOG_COMPILER_APPICON_NAME` does not reach them, so without these
// variants `cmux RBF` shows upstream's icon in the Dock while showing its own
// in Finder — which is exactly the bug that sent us here.

import AppKit
import Foundation

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = repoRoot.appendingPathComponent("Assets.xcassets")
let channelRecord = repoRoot.appendingPathComponent("rbf/scripts/lib/rbf-channel.env")

// ---- channel identity, from the one record -------------------------------
func readChannel() -> (text: String, rgb: (Double, Double, Double), suffix: String) {
    guard let raw = try? String(contentsOf: channelRecord, encoding: .utf8) else {
        FileHandle.standardError.write(Data("error: cannot read \(channelRecord.path)\n".utf8))
        exit(1)
    }
    var values: [String: String] = [:]
    for line in raw.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
        let k = String(t[t.startIndex..<eq])
        var v = String(t[t.index(after: eq)...])
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        values[k] = v
    }
    guard let text = values["RBF_ICON_BANNER_TEXT"],
          let rgbRaw = values["RBF_ICON_BANNER_RGB"],
          let iconSet = values["RBF_ICON_SET"]
    else {
        FileHandle.standardError.write(Data("error: channel record lacks RBF_ICON_BANNER_TEXT/RGB/RBF_ICON_SET\n".utf8))
        exit(1)
    }
    // The variant suffix is DERIVED from RBF_ICON_SET exactly as
    // CmuxFoundation.ChannelAppIconName.channelSuffix does at runtime
    // ("AppIcon-RBF" -> "-RBF"). Hardcoding "-RBF" here would let the record
    // name one channel while this generator wrote another channel's assets --
    // and the app looks the variant up by the derived name, so the mismatch
    // shows as "the Dock icon is upstream's again", not as an error.
    guard iconSet.hasPrefix("AppIcon") else {
        FileHandle.standardError.write(Data("error: RBF_ICON_SET must start with AppIcon, got \(iconSet)\n".utf8))
        exit(1)
    }
    let suffix = String(iconSet.dropFirst("AppIcon".count))
    guard !suffix.isEmpty else {
        FileHandle.standardError.write(Data("error: RBF_ICON_SET is plain \"AppIcon\" — no channel variant to draw\n".utf8))
        exit(1)
    }
    let parts = rgbRaw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 3 else {
        FileHandle.standardError.write(Data("error: RBF_ICON_BANNER_RGB must be 3 ints, got \(rgbRaw)\n".utf8))
        exit(1)
    }
    return (text, (parts[0] / 255.0, parts[1] / 255.0, parts[2] / 255.0), suffix)
}

let channel = readChannel()

// Banner band geometry, matched to the bundle icon the Python generator makes
// (it treats the banner as the bottom 18% of the canvas) so the two icons read
// as one family rather than two near-misses.
let bandTopFraction = 0.82

func banner(onto source: URL, to destination: URL) {
    guard let image = NSImage(contentsOf: source),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else {
        FileHandle.standardError.write(Data("error: cannot read \(source.path)\n".utf8))
        exit(1)
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let cg = rep.cgImage else {
        FileHandle.standardError.write(Data("error: cannot make context for \(source.path)\n".utf8))
        exit(1)
    }

    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    // CoreGraphics origin is bottom-left, so the bottom band is y in [0, bandH).
    let bandH = CGFloat(h) * (1.0 - bandTopFraction)
    ctx.setFillColor(red: channel.rgb.0, green: channel.rgb.1, blue: channel.rgb.2, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: bandH))

    let fontSize = bandH * 0.62
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let line = NSAttributedString(string: channel.text, attributes: attrs)
    let size = line.size()

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    line.draw(at: NSPoint(x: (CGFloat(w) - size.width) / 2.0,
                          y: (bandH - size.height) / 2.0))
    NSGraphicsContext.restoreGraphicsState()

    guard let out = ctx.makeImage() else { exit(1) }
    let outRep = NSBitmapImageRep(cgImage: out)
    outRep.size = NSSize(width: w, height: h)
    guard let png = outRep.representation(using: .png, properties: [:]) else { exit(1) }
    try? FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try png.write(to: destination) } catch {
        FileHandle.standardError.write(Data("error: cannot write \(destination.path): \(error)\n".utf8))
        exit(1)
    }
    print("  wrote \(destination.lastPathComponent) (\(w)x\(h))")
}

func contentsJSON(filename: String) -> String {
    """
    {
      "images" : [
        {
          "filename" : "\(filename)",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

for base in ["AppIconLight", "AppIconDark"] {
    let src = assets.appendingPathComponent("\(base).imageset/\(base).png")
    let setName = "\(base)\(channel.suffix)"
    let dstSet = assets.appendingPathComponent("\(setName).imageset")
    let dstPNG = dstSet.appendingPathComponent("\(setName).png")
    print("\(base) -> \(setName)")
    banner(onto: src, to: dstPNG)
    // The Nightly generator wrote PNGs and no Contents.json, and its .appiconset
    // was hand-finished afterwards -- a step nobody repeats from reading the
    // script. Write the catalog entry here so the output is usable as-is.
    try? contentsJSON(filename: "\(setName).png")
        .write(to: dstSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("  wrote Contents.json")
}
print("done")
