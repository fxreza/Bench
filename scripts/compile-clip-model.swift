// Compiles Klip's MobileCLIP-S2 encoders (.mlpackage) to .mlmodelc for the
// app bundle. Called by build-app.sh; Xcode's `coremlc` is not on this Mac,
// but Core ML's own compiler is, and it is what `xcrun coremlc` wraps.
//
//   swift scripts/compile-clip-model.swift <dir with the .mlpackages> <output dir>
//
// Why compile at build time rather than on the user's Mac: the app then ships
// only what runs (one ~190 MB copy of the weights, sealed by the code
// signature) and never has to keep a second, compiled copy in ~/Library/Caches
// or compile on first use. The compiled program targets the model's own
// opset (iOS 15 / macOS 12), so it loads on every macOS Bench supports.
// MobileCLIPEncoder still accepts an .mlpackage (compiling it into Caches) for
// dev runs pointed at Models.noindex with KLIP_CLIP_MODEL_DIR.
import CoreML
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: compile-clip-model.swift <source dir> <output dir>\n".utf8))
    exit(2)
}
let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)
let manager = FileManager.default

do {
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    for name in ["mobileclip_s2_image", "mobileclip_s2_text"] {
        let started = Date()
        let compiled = try MLModel.compileModel(at: source.appendingPathComponent("\(name).mlpackage"))
        let target = destination.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        try? manager.removeItem(at: target)
        try manager.moveItem(at: compiled, to: target)
        print("Compiled \(name) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }
} catch {
    FileHandle.standardError.write(Data("compile-clip-model: \(error)\n".utf8))
    exit(1)
}
