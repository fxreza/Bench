import Foundation

/// Paging state for the detail pane's chunked text preview (large / file-backed
/// text items are loaded 2,000 characters at a time).
struct ChunkedTextState {
    var visibleText: String = ""
    var totalBytes: Int = 0
    var loadedCharCount: Int = 0
    var reachedEOF: Bool = true
    var isLoadingMore: Bool = false
    // Read from the detached chunk-loading task, hence `nonisolated`.
    nonisolated static let chunkSize = 2_000
    nonisolated static let initialChars = 2_000
    var hasMore: Bool { !reachedEOF && loadedCharCount >= Self.initialChars }
}
