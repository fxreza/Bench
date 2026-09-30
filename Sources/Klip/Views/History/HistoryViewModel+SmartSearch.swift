import Foundation

/// Smart image search in the history list: *when* the engine
/// (`SemanticImageSearching`) is asked, and how its answer joins the text
/// results. What counts as a match is the engine's business; the ordering
/// of the list is `FilterState.apply`'s (see its **Ordering** note).
///
/// One query, start to finish:
/// 1. `debouncedSearchText` changes and `applyFilters` draws the text
///    results at once, exactly as before smart search existed. Nothing
///    waits for the engine.
/// 2. `refreshSemanticSearch` asks the engine in a background task.
/// 3. `receiveSemanticMatches` takes the answer - only if the query it
///    answers is still the one on screen - and runs `applyFilters` again
///    with it. Image matches are appended below the text hits, so the rows
///    already drawn never move.
///
/// The next keystroke cancels step 2 (`searchText`'s didSet), and an answer
/// that lands anyway is dropped at step 3, so a slow answer to "wom" can
/// never overwrite the list for "woman".
extension HistoryViewModel {

    /// The question the query on screen puts to the engine, or nil when it
    /// asks none (empty, `#…`, one character - see
    /// `FilterState.semanticQuery`).
    var semanticQueryKey: String? {
        FilterState.semanticQuery(debouncedSearchText)
    }

    /// The engine's matches for the query on screen, or none: an answer to
    /// any other query is never shown, however it got here.
    var activeSemanticMatches: [UUID: Float] {
        guard let answer = semanticAnswer, answer.query == semanticQueryKey else { return [:] }
        return answer.matches
    }

    /// Whether the list may still gain image matches for the query on
    /// screen: the engine is working on it, and the chip lets images through
    /// at all. Under the Text or Link chip an answer can add nothing, so an
    /// empty list there is "No matches" straight away rather than a wait for
    /// pictures that could never be shown.
    var mayStillShowImageMatches: Bool {
        guard isSemanticSearchPending else { return false }
        switch chipFilter {
        case .all, .tagged, .kind(.image): return true
        case .kind: return false
        }
    }

    /// Ask the engine about the query on screen, unless it has already
    /// answered it or is answering it now. `force` asks again anyway (the
    /// window reopening on a kept query: images copied since may match),
    /// leaving the current answer on screen until the new one replaces it.
    func refreshSemanticSearch(force: Bool = false) {
        guard let query = semanticQueryKey else {
            // Nothing to ask: nothing may keep running, and an answer to an
            // earlier query is no use to the next one.
            cancelSemanticSearch()
            semanticAnswer = nil
            return
        }
        if !force {
            if semanticAnswer?.query == query {
                // Already answered, so nothing to wait for - a keystroke that
                // was typed and deleted again may have left the flag up.
                setSemanticSearchPending(false)
                return
            }
            if semanticTask != nil, semanticTaskQuery == query { return }
        }
        cancelSemanticSearch()

        // An engine without its model answers nothing, so do not even start
        // a task: with smart search unavailable, search is exactly the text
        // search it always was - no pending state, no second pass.
        guard semanticSearch.isAvailable else { return }

        let engine = semanticSearch
        semanticTaskQuery = query
        // Pending only while there is nothing to show for this query yet; a
        // forced refresh keeps showing the answer it is refreshing.
        setSemanticSearchPending(semanticAnswer?.query != query)
        semanticTask = Task { [weak self] in
            // The engine promises to work off the main thread; the detached
            // task makes sure of it whatever the engine's own isolation turns
            // out to be, so the main actor only ever waits here. Cancelling
            // this task (the next keystroke) cancels that one too, so an
            // engine that checks for cancellation can stop early.
            let work = Task.detached(priority: .userInitiated) {
                await engine.matches(for: query)
            }
            let matches = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.receiveSemanticMatches(matches, for: query)
        }
    }

    /// Stop waiting for the engine. The answer on screen, if any, stays.
    ///
    /// `keepPending` is for a keystroke: the query is being typed over and
    /// the debounce will ask about the new one in a moment, so an empty list
    /// keeps waiting instead of flashing "No matches" in between. Every path
    /// that follows a keystroke ends in `refreshSemanticSearch`, which
    /// settles the flag either way.
    func cancelSemanticSearch(keepPending: Bool = false) {
        semanticTask?.cancel()
        semanticTask = nil
        semanticTaskQuery = nil
        if !keepPending { setSemanticSearchPending(false) }
    }

    /// The engine answered `query`. Shown only if it is still the request in
    /// flight *and* the query on screen; anything else is a stale answer to a
    /// query the user has already moved past, and is dropped.
    ///
    /// **Selection.** The answer only ever adds rows below the literal hits,
    /// so:
    /// - If a row is selected, it stays selected, whether the text pass
    ///   picked it (the first unpinned hit, still the first) or the user
    ///   moved there since. Re-running the default rule instead could move
    ///   the highlight from a pinned literal hit to a newly arrived image a
    ///   moment before ↩ - the one thing that must not happen.
    /// - If nothing is selected, the text pass found nothing, and there is no
    ///   choice of the user's to keep: the default rule picks from the list
    ///   the answer produced, i.e. the best unpinned match.
    ///
    /// **Scrolling.** Rows appended under a selection must not scroll the
    /// list back to it (the user may have scrolled away on purpose), so this
    /// raises `semanticRowsAppended` for `ClipList`.
    func receiveSemanticMatches(_ matches: [UUID: Float], for query: String) {
        guard query == semanticTaskQuery, query == semanticQueryKey else { return }
        semanticTask = nil
        semanticTaskQuery = nil
        setSemanticSearchPending(false)

        let previous = activeSemanticMatches
        semanticAnswer = (query: query, matches: matches)
        // Nothing new to show - the usual answer for a query with no picture
        // behind it - so leave the list alone rather than re-filter it.
        guard matches != previous else { return }

        if selectedID == nil {
            applyFilters(resetSelection: .defaultItem)
        } else {
            let rowsBefore = filteredItems.count
            applyFilters(resetSelection: .preserve)
            semanticRowsAppended = filteredItems.count != rowsBefore
        }
    }

    /// `semanticSearch` was replaced (the app handing over the real engine).
    /// The old engine's answer says nothing about what the new one knows, so
    /// it goes - off the screen too, if it was showing - and the new engine
    /// is asked about the query on screen.
    func semanticSearchDidChange() {
        cancelSemanticSearch()
        let wasShowingMatches = !activeSemanticMatches.isEmpty
        semanticAnswer = nil
        if wasShowingMatches { applyFilters(resetSelection: .preserve) }
        refreshSemanticSearch()
    }

    /// Publishes only real changes: this flips on every query, and each
    /// publish is a body pass for every view observing the model.
    private func setSemanticSearchPending(_ pending: Bool) {
        if isSemanticSearchPending != pending { isSemanticSearchPending = pending }
    }
}
