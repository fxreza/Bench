#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns. Modelled on Transi's scripts/make-icon.swift.
//
// The mark: a workbench on an amber-to-orange squircle - a thick white slab on
// two short legs, with a wrench lying across it. Four tools on one bench is
// what the app is, and the two shapes are big and plain enough to still read
// at 16 pt: a horizontal bar and a diagonal one, in white on warm orange.
//
// A gradient-coloured gap is knocked between the wrench and the bench (and
// inside the wrench's jaw) rather than relying on a shadow, so the silhouettes
// never merge into one blob when the icon is drawn small.
//
// Run:  swift scripts/make-icon.swift
//

import AppKit

let S: CGFloat = 1024  // master canvas

// MARK: - Palette

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
}

let gradientTop = rgb(0xF59E0B)     // amber
let gradientBottom = rgb(0xEA580C)  // deep orange
let markWhite = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

// MARK: - Canvas

let image = NSImage(size: CGSize(width: S, height: S))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

// Squircle plate. The inset leaves the margin macOS expects around app icons.
let plate = CGRect(x: 88, y: 88, width: S - 176, height: S - 176)
let platePath = CGPath(roundedRect: plate, cornerWidth: 196, cornerHeight: 196, transform: nil)

func fillPlateGradient(clipTo path: CGPath) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [gradientTop, gradientBottom] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: [])
    ctx.restoreGState()
}

fillPlateGradient(clipTo: platePath)

// Soft highlight across the top so the plate doesn't read as flat vinyl.
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(
    sheen,
    startCenter: CGPoint(x: plate.midX, y: plate.maxY), startRadius: 0,
    endCenter: CGPoint(x: plate.midX, y: plate.maxY), endRadius: plate.width * 0.85,
    options: [])
ctx.restoreGState()

func withShadow(_ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12), blur: 28,
        color: CGColor(red: 0.35, green: 0.12, blue: 0, alpha: 0.32))
    body()
    ctx.restoreGState()
}

func fill(_ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

/// Expands an outline outward, used to knock a clean gap into whatever sits
/// beneath a shape so the two never visually merge.
func outlinePath(_ path: CGPath, width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

// MARK: - The bench

/// Slab plus two legs, as one silhouette.
let bench: CGPath = {
    let path = CGMutablePath()
    path.addPath(CGPath(
        roundedRect: CGRect(x: 214, y: 384, width: 596, height: 100),
        cornerWidth: 26, cornerHeight: 26, transform: nil))
    for legX in [CGFloat(276), CGFloat(660)] {
        path.addPath(CGPath(
            roundedRect: CGRect(x: legX, y: 230, width: 88, height: 160),
            cornerWidth: 22, cornerHeight: 22, transform: nil))
    }
    return path
}()

withShadow { fill(bench, markWhite) }

// MARK: - The wrench

// Built in its own frame - handle along +x, jaw at the far end - then rotated
// into place, so every number below is about the tool rather than the canvas.
var wrenchTransform = CGAffineTransform(translationX: 512, y: 600)
    .rotated(by: 18 * .pi / 180)

let wrench: CGPath = {
    let path = CGMutablePath()
    // Handle: a fully rounded bar (radius = half the thickness).
    path.addPath(CGPath(
        roundedRect: CGRect(x: -212, y: -42, width: 362, height: 84),
        cornerWidth: 42, cornerHeight: 42, transform: &wrenchTransform))
    // Head: one big circle, opened into a jaw below.
    path.addPath(CGPath(
        ellipseIn: CGRect(x: 114, y: -86, width: 172, height: 172),
        transform: &wrenchTransform))
    return path
}()

/// The head's outline, used to keep the jaw knockout from spilling past it.
let wrenchHead = CGPath(
    ellipseIn: CGRect(x: 114, y: -86, width: 172, height: 172),
    transform: &wrenchTransform)

/// The bite taken out of the head: the bore plus the slot that opens it.
let wrenchJaw: CGPath = {
    let path = CGMutablePath()
    path.addPath(CGPath(
        ellipseIn: CGRect(x: 154, y: -46, width: 92, height: 92),
        transform: &wrenchTransform))
    path.addPath(CGPath(
        roundedRect: CGRect(x: 188, y: -34, width: 150, height: 68),
        cornerWidth: 14, cornerHeight: 14, transform: &wrenchTransform))
    return path
}()

// Knock a gradient-coloured gap into the bench where the wrench crosses it,
// then lay the wrench in, then open the jaw the same way.
fillPlateGradient(clipTo: outlinePath(wrench, width: 40))
withShadow { fill(wrench, markWhite) }
// Clipped to the head: the slot runs past the circle's edge so the jaw opens
// cleanly, and repainting outside it would rub out the drop shadow there and
// leave a pale stub hanging off the tool.
ctx.saveGState()
ctx.addPath(wrenchHead)
ctx.clip()
fillPlateGradient(clipTo: wrenchJaw)
ctx.restoreGState()

image.unlockFocus()

// MARK: - Write iconset + icns

let root = URL(fileURLWithPath: CommandLine.arguments.first!)
    .deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build.noindex/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func write(_ pixels: Int, _ name: String) {
    let target = NSImage(size: CGSize(width: pixels, height: pixels))
    target.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
        from: CGRect(x: 0, y: 0, width: S, height: S),
        operation: .copy, fraction: 1)
    target.unlockFocus()

    guard let tiff = target.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { fatalError("failed to encode \(name)") }
    try! png.write(to: iconset.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    write(size, "icon_\(size)x\(size).png")
    write(size * 2, "icon_\(size)x\(size)@2x.png")
}

let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }

// A full-size preview, handy for the README and for eyeballing changes.
let previewURL = root.appendingPathComponent("build.noindex/AppIcon-preview.png")
if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try! png.write(to: previewURL)
}

print("Wrote \(icns.path)")
print("Preview: \(previewURL.path)")
