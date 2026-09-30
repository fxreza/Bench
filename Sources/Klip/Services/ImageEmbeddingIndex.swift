import Foundation
import Accelerate
import CryptoKit

/// Identifies the exact image bytes an embedding was computed from: the
/// file's name, size and modification time. A clip's `imageFilename` never
/// changes, but its bytes can (a sync repair rewriting a partial file, a
/// dedupe fold keeping one payload under another id), and an embedding of
/// different bytes would be silently wrong.
nonisolated struct ImageFingerprint: Equatable, Hashable, Sendable {
    var nameHash: UInt64
    var size: Int64
    var modifiedMilliseconds: Int64

    /// The fingerprint of the file at `url` now, or `nil` when it is missing
    /// (not synced down yet, or gone).
    static func of(fileAt url: URL) -> ImageFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return ImageFingerprint(
            nameHash: nameHash(url.lastPathComponent),
            size: size,
            modifiedMilliseconds: Int64((modified * 1000).rounded())
        )
    }

    /// FNV-1a (64-bit) of the file name: stable across launches, which
    /// Swift's per-process seeded `Hasher` is not.
    static func nameHash(_ name: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

/// One L2-normalized MobileCLIP image embedding per image clip, kept in
/// `image-embeddings.bin` in Klip's data folder.
///
/// **Local only.** Not in `history.json` and not in iCloud Drive: each Mac
/// computes its own (a few ms per image), `CloudDriveSync` mirrors only the
/// history and the asset folders, and the orphan sweep only looks inside
/// those folders, so this file is never shipped or swept.
///
/// **Memory and disk.** In memory the vectors are one contiguous row-major
/// `Float` matrix (2 KB per image; 20 MB at 10,000 images), because the
/// query scan is a single matrix-vector product over it. On disk each is
/// stored as `Float16` (1 KB), halving the file; the precision lost
/// (~1e-3 on a cosine) is far below any threshold that matters.
///
/// **File format** (little-endian): 48-byte header (`magic`, version,
/// dimension, a model tag, count), `count` records of
/// `id (16) | nameHash (8) | size (8) | modified ms (8) | 512 x Float16`,
/// and a checksum (SHA-256 prefix) of everything before it. Anything that does not
/// check out - wrong magic, version, dimension or model tag, a truncated or
/// corrupt file - is discarded and the index starts empty: it is derived
/// data, and the background queue rebuilds it.
///
/// **Saving** is coalesced on a utility queue (`saveDelay` after the last
/// change, at most `saveMaxDelay` after the first) and atomic;
/// `flush()` writes synchronously (quit).
///
/// A zero vector records an image that could not be decoded, so it is not
/// retried until its file changes; it scores 0 against every query.
///
/// Thread-safe: everything goes through `lock`; the file is loaded lazily
/// on first use, from whichever (background) thread gets there first.
nonisolated final class ImageEmbeddingIndex: @unchecked Sendable {
    static let fileName = "image-embeddings.bin"
    static let dimension = MobileCLIPEncoder.dimension
    static let magic: UInt32 = 0x4543_4C4B   // "KLCE"
    static let version: UInt16 = 1
    /// Names the model *and* the preprocessing. Change it whenever either
    /// changes, and every stored embedding is recomputed.
    static let modelTag = "mobileclip-s2/crop256-white/1"
    static let tagSize = 32
    /// magic (4), version (2), reserved (2), dimension (4), tag (32), count (4)
    static let headerSize = 48
    static let recordSize = 16 + 8 + 8 + 8 + dimension * 2

    let fileURL: URL
    var saveDelay: TimeInterval = 3
    var saveMaxDelay: TimeInterval = 20

    private let lock = NSLock()
    private var isLoaded = false
    private var ids: [UUID] = []
    private var rowForID: [UUID: Int] = [:]
    private var fingerprints: [ImageFingerprint] = []
    private var matrix: [Float] = []

    private let saveQueue = DispatchQueue(label: "com.fxreza.bench.klip.embedding-index", qos: .utility)
    private var isDirty = false          // lock
    private var firstDirtyAt: Date?      // lock
    private var pendingSave: DispatchWorkItem?   // saveQueue

    /// Why the last load discarded the file (tests, logs); `nil` when it
    /// loaded or there was no file.
    private(set) var lastLoadProblem: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    convenience init(directory: URL) {
        self.init(fileURL: directory.appendingPathComponent(Self.fileName))
    }

    // MARK: - Reading

    var count: Int {
        withLoaded { ids.count }
    }

    func contains(_ id: UUID) -> Bool {
        withLoaded { rowForID[id] != nil }
    }

    func fingerprint(for id: UUID) -> ImageFingerprint? {
        withLoaded { rowForID[id].map { fingerprints[$0] } }
    }

    func embedding(for id: UUID) -> [Float]? {
        withLoaded {
            guard let row = rowForID[id] else { return nil }
            return Array(matrix[(row * Self.dimension)..<((row + 1) * Self.dimension)])
        }
    }

    /// Ids among `candidates` with no entry at all.
    func missing(among candidates: [UUID]) -> Set<UUID> {
        withLoaded { Set(candidates.filter { rowForID[$0] == nil }) }
    }

    /// Cosine similarity of every stored embedding with each of `queries`
    /// (unit vectors), as `scores[q][row]`, plus the ids by row. One
    /// matrix product (`vDSP_mmul`): ~1 ms for 10,000 images and a few
    /// queries.
    func scores(for queries: [[Float]]) -> (ids: [UUID], scores: [[Float]]) {
        withLoaded {
            let rows = ids.count
            guard rows > 0, !queries.isEmpty else { return (ids, queries.map { _ in [] }) }
            let dimension = Self.dimension
            // Queries as columns: Q is dimension x q.
            var queryMatrix = [Float](repeating: 0, count: dimension * queries.count)
            for (column, query) in queries.enumerated() {
                precondition(query.count == dimension, "query vectors must have \(dimension) values")
                for index in 0..<dimension { queryMatrix[index * queries.count + column] = query[index] }
            }
            var product = [Float](repeating: 0, count: rows * queries.count)
            vDSP_mmul(matrix, 1, queryMatrix, 1, &product, 1,
                      vDSP_Length(rows), vDSP_Length(queries.count), vDSP_Length(dimension))
            var result = [[Float]](repeating: [Float](repeating: 0, count: rows), count: queries.count)
            for row in 0..<rows {
                for column in 0..<queries.count {
                    result[column][row] = product[row * queries.count + column]
                }
            }
            return (ids, result)
        }
    }

    // MARK: - Writing

    /// Stores (or replaces) the embedding for `id`. `nil` stores the
    /// "could not decode" marker (a zero vector). The vector must already
    /// be unit length.
    func set(_ embedding: [Float]?, fingerprint: ImageFingerprint, for id: UUID) {
        let vector = embedding ?? [Float](repeating: 0, count: Self.dimension)
        precondition(vector.count == Self.dimension, "embeddings must have \(Self.dimension) values")
        withLoaded {
            if let row = rowForID[id] {
                fingerprints[row] = fingerprint
                matrix.replaceSubrange((row * Self.dimension)..<((row + 1) * Self.dimension), with: vector)
            } else {
                rowForID[id] = ids.count
                ids.append(id)
                fingerprints.append(fingerprint)
                matrix.append(contentsOf: vector)
            }
            markDirty()
        }
        scheduleSave()
    }

    /// Drops every entry whose id is not in `liveIDs`; returns how many.
    @discardableResult
    func retainOnly(_ liveIDs: Set<UUID>) -> Int {
        let removed: Int = withLoaded {
            let doomed = ids.filter { !liveIDs.contains($0) }
            for id in doomed { removeRow(for: id) }
            if !doomed.isEmpty { markDirty() }
            return doomed.count
        }
        if removed > 0 { scheduleSave() }
        return removed
    }

    /// Swap-remove: the last row moves into the hole, so a removal is one
    /// 2 KB copy regardless of the index size. Caller holds `lock`.
    private func removeRow(for id: UUID) {
        guard let row = rowForID.removeValue(forKey: id) else { return }
        let last = ids.count - 1
        if row != last {
            let moved = ids[last]
            ids[row] = moved
            fingerprints[row] = fingerprints[last]
            let dimension = Self.dimension
            for index in 0..<dimension { matrix[row * dimension + index] = matrix[last * dimension + index] }
            rowForID[moved] = row
        }
        ids.removeLast()
        fingerprints.removeLast()
        matrix.removeLast(Self.dimension)
    }

    // MARK: - Persistence

    private func withLoaded<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if !isLoaded {
            isLoaded = true
            loadFromDisk()
        }
        return body()
    }

    private func markDirty() {
        isDirty = true
        if firstDirtyAt == nil { firstDirtyAt = Date() }
    }

    /// Caller holds `lock`.
    private func loadFromDisk() {
        lastLoadProblem = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            discard("unreadable")
            return
        }
        guard let decoded = Self.decode(data) else {
            discard("corrupt or from another model")
            return
        }
        ids = decoded.ids
        fingerprints = decoded.fingerprints
        matrix = decoded.matrix
        rowForID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        print("[Klip] Smart search: loaded \(ids.count) image embedding(s)")
    }

    /// Caller holds `lock`. The next save overwrites the file; until then
    /// the queue is already re-embedding.
    private func discard(_ reason: String) {
        lastLoadProblem = reason
        print("[Klip] Smart search: \(Self.fileName) \(reason), rebuilding the index")
        ids = []
        rowForID = [:]
        fingerprints = []
        matrix = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func scheduleSave() {
        let delay: TimeInterval = {
            lock.lock()
            defer { lock.unlock() }
            let first = firstDirtyAt ?? Date()
            let deadline = min(Date().addingTimeInterval(saveDelay), first.addingTimeInterval(saveMaxDelay))
            return max(0, deadline.timeIntervalSinceNow)
        }()
        saveQueue.async { [weak self] in
            guard let self else { return }
            self.pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.saveIfDirty() }
            self.pendingSave = work
            self.saveQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Writes now if anything changed since the last write, and waits for
    /// it. Called when Klip stops (and by tests).
    func flush() {
        saveQueue.sync {
            pendingSave?.cancel()
            pendingSave = nil
        }
        saveIfDirty()
    }

    private func saveIfDirty() {
        lock.lock()
        guard isDirty else {
            lock.unlock()
            return
        }
        let data = Self.encode(ids: ids, fingerprints: fingerprints, matrix: matrix)
        isDirty = false
        firstDirtyAt = nil
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[Klip] Smart search: could not save \(Self.fileName): \(error.localizedDescription)")
            lock.lock()
            markDirty()   // try again with the next change or flush
            lock.unlock()
        }
    }

    // MARK: - Encoding
    //
    // Written and read through raw buffers and vImage (not byte by byte), so
    // a 10,000-image file (~10 MB) encodes or decodes in a few ms, and stays
    // fast in the debug builds the tests run. The host is little-endian on
    // every Mac Bench builds for, so the Float16 bits are copied as they are.

    static func paddedTag() -> [UInt8] {
        var tag = Array(modelTag.utf8)
        precondition(tag.count <= tagSize, "modelTag must fit in \(tagSize) bytes")
        tag.append(contentsOf: repeatElement(0, count: tagSize - tag.count))
        return tag
    }

    /// First 8 bytes of SHA-256: hardware-fast, and far more than enough to
    /// tell a torn or bit-rotted file from a good one.
    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        SHA256.hash(data: bytes).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }

    static func encode(ids: [UUID], fingerprints: [ImageFingerprint], matrix: [Float]) -> Data {
        let count = ids.count
        let total = headerSize + count * recordSize + 8
        var data = Data(count: total)
        data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            out.storeBytes(of: magic.littleEndian, toByteOffset: 0, as: UInt32.self)
            out.storeBytes(of: version.littleEndian, toByteOffset: 4, as: UInt16.self)
            out.storeBytes(of: UInt32(dimension).littleEndian, toByteOffset: 8, as: UInt32.self)
            for (index, byte) in paddedTag().enumerated() { out[12 + index] = byte }
            out.storeBytes(of: UInt32(count).littleEndian, toByteOffset: 12 + tagSize, as: UInt32.self)

            matrix.withUnsafeBufferPointer { vectors in
                for row in 0..<count {
                    let base = headerSize + row * recordSize
                    withUnsafeBytes(of: ids[row].uuid) { uuid in
                        for index in 0..<16 { out[base + index] = uuid[index] }
                    }
                    let fingerprint = fingerprints[row]
                    out.storeBytes(of: fingerprint.nameHash.littleEndian, toByteOffset: base + 16, as: UInt64.self)
                    out.storeBytes(of: fingerprint.size.littleEndian, toByteOffset: base + 24, as: Int64.self)
                    out.storeBytes(of: fingerprint.modifiedMilliseconds.littleEndian, toByteOffset: base + 32, as: Int64.self)
                    var source = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: vectors.baseAddress! + row * dimension),
                        height: 1, width: vImagePixelCount(dimension), rowBytes: dimension * 4
                    )
                    var destination = vImage_Buffer(
                        data: out.baseAddress! + base + 40,
                        height: 1, width: vImagePixelCount(dimension), rowBytes: dimension * 2
                    )
                    vImageConvert_PlanarFtoPlanar16F(&source, &destination, 0)
                }
            }
            let sum = checksum(UnsafeRawBufferPointer(rebasing: out[0..<(total - 8)]))
            out.storeBytes(of: sum.littleEndian, toByteOffset: total - 8, as: UInt64.self)
        }
        return data
    }

    static func decode(_ data: Data) -> (ids: [UUID], fingerprints: [ImageFingerprint], matrix: [Float])? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (ids: [UUID], fingerprints: [ImageFingerprint], matrix: [Float])? in
            guard raw.count >= headerSize + 8,
                  UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) == magic,
                  UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self)) == version,
                  UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) == UInt32(dimension),
                  Array(raw[12..<(12 + tagSize)]) == paddedTag()
            else { return nil }
            let count = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12 + tagSize, as: UInt32.self)))
            guard raw.count == headerSize + count * recordSize + 8 else { return nil }
            let stored = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: raw.count - 8, as: UInt64.self))
            guard stored == checksum(UnsafeRawBufferPointer(rebasing: raw[0..<(raw.count - 8)])) else { return nil }

            var ids: [UUID] = []
            var fingerprints: [ImageFingerprint] = []
            ids.reserveCapacity(count)
            fingerprints.reserveCapacity(count)
            var matrix = [Float](repeating: 0, count: count * dimension)
            // vImage wants the Float16 source 2-byte aligned; copy each
            // record's vector out first rather than rely on `Data`'s buffer
            // alignment.
            var halves = [UInt16](repeating: 0, count: dimension)
            var seen = Set<UUID>()
            for row in 0..<count {
                let base = headerSize + row * recordSize
                let id = UUID(uuid: raw.loadUnaligned(fromByteOffset: base, as: uuid_t.self))
                guard seen.insert(id).inserted else { return nil }
                ids.append(id)
                fingerprints.append(ImageFingerprint(
                    nameHash: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base + 16, as: UInt64.self)),
                    size: Int64(littleEndian: raw.loadUnaligned(fromByteOffset: base + 24, as: Int64.self)),
                    modifiedMilliseconds: Int64(littleEndian: raw.loadUnaligned(fromByteOffset: base + 32, as: Int64.self))
                ))
                halves.withUnsafeMutableBytes { target in
                    target.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[(base + 40)..<(base + 40 + dimension * 2)]))
                }
                halves.withUnsafeMutableBufferPointer { input in
                    matrix.withUnsafeMutableBufferPointer { output in
                        var source = vImage_Buffer(
                            data: input.baseAddress!, height: 1, width: vImagePixelCount(dimension), rowBytes: dimension * 2
                        )
                        var destination = vImage_Buffer(
                            data: output.baseAddress! + row * dimension,
                            height: 1, width: vImagePixelCount(dimension), rowBytes: dimension * 4
                        )
                        vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
                    }
                }
            }
            var finite = true
            matrix.withUnsafeBufferPointer { values in
                var sum: Float = 0
                vDSP_sve(values.baseAddress!, 1, &sum, vDSP_Length(values.count))
                finite = sum.isFinite
            }
            return finite ? (ids, fingerprints, matrix) : nil
        }
    }
}
