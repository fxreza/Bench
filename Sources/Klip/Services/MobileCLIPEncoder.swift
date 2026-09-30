import Foundation
import CoreML
import CoreGraphics
import CoreVideo
import Accelerate

/// Where the MobileCLIP-S2 files live: the two Core ML encoders (compiled
/// `.mlmodelc`, or `.mlpackage` which is compiled on first use) and the
/// tokenizer's `clip-merges.txt` (`clip-vocab.json`, which
/// `fetch-clip-model.sh` also downloads, is not needed at runtime: the
/// tokenizer derives the vocabulary from the merges, see `CLIPTokenizer`).
///
/// - Shipped app: `Bench.app/Contents/Resources/MobileCLIP`, filled by
///   `scripts/build-app.sh` from `Models.noindex/MobileCLIP`
///   (`scripts/fetch-clip-model.sh`), with the encoders precompiled.
/// - Dev builds and tests: `KLIP_CLIP_MODEL_DIR` points anywhere else,
///   typically at `Models.noindex/MobileCLIP` itself (`.mlpackage`s).
///
/// Nothing found means smart image search is simply unavailable: a build
/// made without the ~190 MB of model files still works, it just searches
/// images by their text and Vision labels only.
nonisolated struct MobileCLIPFiles: Equatable, Sendable {
    let imageEncoder: URL
    let textEncoder: URL
    let merges: URL

    static let directoryName = "MobileCLIP"
    static let overrideEnvironmentKey = "KLIP_CLIP_MODEL_DIR"
    static let imageEncoderName = "mobileclip_s2_image"
    static let textEncoderName = "mobileclip_s2_text"

    /// `KLIP_CLIP_MODEL_DIR` when set, else the app bundle's
    /// `Resources/MobileCLIP`.
    static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return bundle.resourceURL?.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The three files in `directory`, preferring a compiled encoder over a
    /// package; `nil` if any is missing.
    static func locate(in directory: URL?) -> MobileCLIPFiles? {
        guard let directory else { return nil }
        let manager = FileManager.default
        func encoder(_ name: String) -> URL? {
            for ext in ["mlmodelc", "mlpackage"] {
                let url = directory.appendingPathComponent("\(name).\(ext)", isDirectory: true)
                if manager.fileExists(atPath: url.path) { return url }
            }
            return nil
        }
        let merges = directory.appendingPathComponent("clip-merges.txt")
        guard let image = encoder(imageEncoderName),
              let text = encoder(textEncoderName),
              manager.fileExists(atPath: merges.path)
        else { return nil }
        return MobileCLIPFiles(imageEncoder: image, textEncoder: text, merges: merges)
    }
}

/// Apple's MobileCLIP-S2 (image and text encoders into one 512-d space),
/// loaded lazily and released again when idle.
///
/// **Compute units, measured on this Mac (M5 Pro, macOS 27):**
/// - Image encoder on `.cpuAndNeuralEngine`: 1-3 ms per image, ~0.95 s
///   for the first load in a process (0.23 s of it CPU; the rest is the
///   Neural Engine service), ~20 ms for any reload after that. On `.cpuOnly`
///   it is 15-20 ms per image. The image encoder only runs in the
///   background (`ImageAnalysisQueue`), so the one slow load is invisible
///   and the Neural Engine's 10x cheaper inference wins for a backfill.
/// - Text encoder on `.cpuOnly`: ~75 ms first load, ~3 ms per prompt. On
///   the Neural Engine it is ~1 ms per prompt but ~1.25 s to load, and that
///   load would land on the user's first search of the session. A query
///   encodes a handful of prompts, so CPU costs ~10 ms and never stalls.
/// - `.all` was the worst of both here: Core ML put part of the text model
///   on the GPU, which added ~50 MB of footprint and a 1 s first
///   prediction (shader compilation).
///
/// **Idle release.** A menu-bar app lives for weeks, so neither model is
/// kept forever: the image encoder is released `imageIdleRelease` after its
/// last use (a backfill keeps it busy; a lone capture loads it, embeds, and
/// lets it go), the text encoder and tokenizer `textIdleRelease` after the
/// last query. Reloading is cheap once the process has loaded a model
/// (Core ML keeps its compiled program: ~25 ms image, ~30 ms text), so a
/// short timeout costs little.
///
/// **Memory, measured** (fresh process, `phys_footprint` / resident): the
/// tokenizer ~4 MB; the text encoder plus a query ~+6 MB footprint and
/// ~+85 MB resident, which is its memory-mapped weights (clean pages the
/// system can drop at will); the image encoder on the Neural Engine ~+13 MB
/// footprint. Releasing both returns the ~75 MB of mapped weight pages;
/// the ~20 MB of heap Core ML allocated stays with the process, as freed
/// malloc memory does.
///
/// Threading: every entry point blocks its caller; call from background
/// queues only. Each model has its own lock, so a long image load never
/// holds up a query, and predictions on one model are serialized.
nonisolated final class MobileCLIPEncoder: @unchecked Sendable {
    static let dimension = 512
    /// The image encoder's input side, and the center-crop it expects
    /// (MobileCLIP's own transform is resize-short-side-to-256 + center
    /// crop; Apple's demo app crops to a square, then resizes).
    static let imageSide = 256
    /// Short side the embedding-only decode aims for: twice the input side,
    /// so the final resample to 256 still has real pixels to average.
    static let decodeShortSide = 512

    var imageIdleRelease: TimeInterval = 120
    var textIdleRelease: TimeInterval = 300

    let files: MobileCLIPFiles
    private let compiledCache: URL

    private let imageLock = NSLock()
    private var imageModel: MLModel?
    private var imageLastUsed = Date.distantPast

    private let textLock = NSLock()
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var textLastUsed = Date.distantPast

    private let idleQueue = DispatchQueue(label: "com.fxreza.bench.klip.clip-idle", qos: .utility)
    private var idleCheckScheduled = false   // idleQueue only

    /// Diagnostics for the tests and the report: last load durations.
    private(set) var lastImageLoadSeconds: Double?
    private(set) var lastTextLoadSeconds: Double?

    enum EncoderError: Error, CustomStringConvertible {
        /// A model or the tokenizer could not be loaded. Permanent for these
        /// files: the engine switches smart search off for the session.
        case loadFailed(String)
        case noOutput
        case badShape(Int)
        case pixelBuffer

        var description: String {
            switch self {
            case .loadFailed(let reason): return "could not load MobileCLIP: \(reason)"
            case .noOutput: return "the model returned no embedding"
            case .badShape(let count): return "embedding has \(count) values, expected \(MobileCLIPEncoder.dimension)"
            case .pixelBuffer: return "could not build the 256x256 input image"
            }
        }
    }

    /// `compiledCache` is where an `.mlpackage` is compiled to (not used for
    /// the shipped app, whose encoders are compiled at build time).
    init(files: MobileCLIPFiles, compiledCache: URL = MobileCLIPEncoder.defaultCompiledCache) {
        self.files = files
        self.compiledCache = compiledCache
    }

    static var defaultCompiledCache: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches
            .appendingPathComponent("com.fxreza.bench", isDirectory: true)
            .appendingPathComponent("Klip", isDirectory: true)
            .appendingPathComponent("MobileCLIP", isDirectory: true)
    }

    // MARK: - Text

    /// Embeddings of `texts`, each L2-normalized, in order. Loads the text
    /// encoder and tokenizer if needed. Blocking.
    func embed(texts: [String]) throws -> [[Float]] {
        textLock.lock()
        defer { textLock.unlock() }
        let (model, tokenizer) = try loadedTextModel()
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        let input = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32)
        for text in texts {
            let ids = tokenizer.tokenIDs(for: text)
            let pointer = input.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
            for (index, id) in ids.enumerated() { pointer[index] = id }
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": input]))
            result.append(try Self.normalizedEmbedding(output))
        }
        textLastUsed = Date()
        scheduleIdleCheck()
        return result
    }

    /// Loads the text encoder and tokenizer now (if released) and counts as
    /// a use, so they stay for `textIdleRelease`. Blocking.
    func prepareText() throws {
        textLock.lock()
        defer { textLock.unlock() }
        _ = try loadedTextModel()
        textLastUsed = Date()
        scheduleIdleCheck()
    }

    /// The token ids the text encoder would get for `text` (tests).
    func tokenIDs(for text: String) throws -> [Int32] {
        textLock.lock()
        defer { textLock.unlock() }
        return try loadedTextModel().tokenizer.tokenIDs(for: text)
    }

    private func loadedTextModel() throws -> (model: MLModel, tokenizer: CLIPTokenizer) {
        if let textModel, let tokenizer { return (textModel, tokenizer) }
        let started = Date()
        let tokenizer: CLIPTokenizer
        do {
            tokenizer = try self.tokenizer ?? CLIPTokenizer(mergesURL: files.merges)
        } catch {
            throw EncoderError.loadFailed("\(error)")
        }
        let model = try loadModel(at: files.textEncoder, units: .cpuOnly)
        self.tokenizer = tokenizer
        self.textModel = model
        lastTextLoadSeconds = Date().timeIntervalSince(started)
        print("[Klip] Smart search: text encoder loaded in \(Int(lastTextLoadSeconds! * 1000)) ms")
        return (model, tokenizer)
    }

    // MARK: - Image

    /// The L2-normalized embedding of `image` (any size; center-cropped to
    /// a square and resampled to 256x256 here). Loads the image encoder if
    /// needed. Blocking.
    func embed(image: CGImage) throws -> [Float] {
        guard let buffer = Self.inputPixelBuffer(for: image) else { throw EncoderError.pixelBuffer }
        imageLock.lock()
        defer { imageLock.unlock() }
        let model = try loadedImageModel()
        let output = try model.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]
        ))
        imageLastUsed = Date()
        scheduleIdleCheck()
        return try Self.normalizedEmbedding(output)
    }

    private func loadedImageModel() throws -> MLModel {
        if let imageModel { return imageModel }
        let started = Date()
        let model = try loadModel(at: files.imageEncoder, units: .cpuAndNeuralEngine)
        imageModel = model
        lastImageLoadSeconds = Date().timeIntervalSince(started)
        print("[Klip] Smart search: image encoder loaded in \(Int(lastImageLoadSeconds! * 1000)) ms")
        return model
    }

    /// The encoder's input: `image` center-cropped to a square, drawn at
    /// 256x256 with high-quality resampling into a 32BGRA buffer.
    ///
    /// Matches MobileCLIP's own preprocessing (short side to 256, center
    /// crop, `ToTensor`): the Core ML image input multiplies by 1/255 itself
    /// (the model's first op, `image__scaled__`, with no bias), which is all
    /// the normalization MobileCLIP uses, so raw sRGB bytes go in.
    /// Transparent pixels are composited over white rather than left black,
    /// the way a window screenshot's shadow or a logo looks on a page.
    static func inputPixelBuffer(for image: CGImage) -> CVPixelBuffer? {
        let side = imageSide
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side, height: side,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let crop = centerSquare(width: image.width, height: image.height)
        guard let square = image.cropping(to: crop) else { return nil }
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }

    /// The largest centered square inside a `width` x `height` image.
    static func centerSquare(width: Int, height: Int) -> CGRect {
        let side = min(width, height)
        return CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
    }

    // MARK: - Loading

    private func loadModel(at url: URL, units: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        do {
            let compiled = url.pathExtension == "mlmodelc" ? url : try compiledModel(for: url)
            return try MLModel(contentsOf: compiled, configuration: configuration)
        } catch {
            throw EncoderError.loadFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// `package` compiled to `.mlmodelc`, cached under `compiledCache` and
    /// keyed by the package's total size and newest modification date, so a
    /// re-fetched model is recompiled and an unchanged one is not.
    /// Compiling takes ~0.1 s (the weights file is cloned on APFS, not
    /// copied). Older compilations of the same model are removed.
    private func compiledModel(for package: URL) throws -> URL {
        let name = package.deletingPathExtension().lastPathComponent
        let destination = compiledCache.appendingPathComponent("\(name)-\(Self.packageKey(package)).mlmodelc", isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.appendingPathComponent("coremldata.bin").path) {
            return destination
        }
        try manager.createDirectory(at: compiledCache, withIntermediateDirectories: true)
        let temporary = try MLModel.compileModel(at: package)
        for stale in (try? manager.contentsOfDirectory(atPath: compiledCache.path)) ?? [] where stale.hasPrefix(name + "-") {
            try? manager.removeItem(at: compiledCache.appendingPathComponent(stale))
        }
        try manager.moveItem(at: temporary, to: destination)
        return destination
    }

    static func packageKey(_ package: URL) -> String {
        var size: Int64 = 0
        var newest: TimeInterval = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        if let walker = FileManager.default.enumerator(at: package, includingPropertiesForKeys: keys) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                size += Int64(values.fileSize ?? 0)
                newest = max(newest, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return "\(size)-\(Int64(newest))"
    }

    // MARK: - Idle release

    /// Whether each model is currently in memory (tests, diagnostics).
    var loadedModels: (image: Bool, text: Bool) {
        imageLock.lock()
        let image = imageModel != nil
        imageLock.unlock()
        textLock.lock()
        let text = textModel != nil
        textLock.unlock()
        return (image, text)
    }

    /// Releases whichever model has been idle for its timeout (or both, with
    /// `force`). Returns what is still loaded.
    @discardableResult
    func releaseIdleModels(now: Date = Date(), force: Bool = false) -> (image: Bool, text: Bool) {
        // `try` rather than `lock`: a model that is busy is not idle, and
        // the idle check must never wait behind a 1 s load.
        if imageLock.try() {
            if imageModel != nil, force || now.timeIntervalSince(imageLastUsed) >= imageIdleRelease {
                imageModel = nil
                print("[Klip] Smart search: image encoder released (idle)")
            }
            imageLock.unlock()
        }
        if textLock.try() {
            if textModel != nil, force || now.timeIntervalSince(textLastUsed) >= textIdleRelease {
                textModel = nil
                tokenizer = nil
                print("[Klip] Smart search: text encoder released (idle)")
            }
            textLock.unlock()
        }
        return loadedModels
    }

    /// One pending check at a time; it re-arms itself while anything is
    /// still loaded.
    private func scheduleIdleCheck() {
        idleQueue.async { [weak self] in
            guard let self, !self.idleCheckScheduled else { return }
            self.idleCheckScheduled = true
            let delay = max(5, min(self.imageIdleRelease, self.textIdleRelease) / 2)
            self.idleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.idleCheckScheduled = false
                let still = self.releaseIdleModels()
                if still.image || still.text { self.scheduleIdleCheck() }
            }
        }
    }

    // MARK: - Output

    /// `final_emb_1` as a unit-length `[Float]`. MobileCLIP's projection is
    /// not normalized (norms are ~10), and cosine similarity is what CLIP's
    /// embeddings are compared by, so every stored and query vector is
    /// normalized once here and a dot product is a cosine everywhere else.
    static func normalizedEmbedding(_ output: MLFeatureProvider) throws -> [Float] {
        guard let array = output.featureValue(for: "final_emb_1")?.multiArrayValue else { throw EncoderError.noOutput }
        guard array.count == dimension else { throw EncoderError.badShape(array.count) }
        var vector = [Float](repeating: 0, count: dimension)
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: dimension)
            for index in 0..<dimension { vector[index] = pointer[index] }
        default:
            for index in 0..<dimension { vector[index] = array[index].floatValue }
        }
        return normalized(vector)
    }

    /// `vector` scaled to unit length; a zero vector stays zero.
    static func normalized(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        guard sumOfSquares > 0, sumOfSquares.isFinite else { return [Float](repeating: 0, count: vector.count) }
        var scale = 1 / sumOfSquares.squareRoot()
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }
}
