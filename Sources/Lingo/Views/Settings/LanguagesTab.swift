import SwiftUI

/// Default source/target/secondary languages, and which languages appear at
/// all in the popup's pickers and the menu bar.
struct LanguagesTab: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var query = ""

    /// The default pickers only ever offer enabled languages — this is the
    /// list `enabledLanguageCodes` guarantees a superset of.
    private var enabledLanguages: [LanguageCatalog.Language] {
        settings.enabledLanguages.compactMap { LanguageCatalog.byCode[$0] }
    }

    /// Trimmed on purpose: a query of nothing but whitespace used to filter
    /// the list down to nothing, which read as "my enabled languages were
    /// wiped" rather than "there is a space in the search field".
    private var filteredLanguages: [LanguageCatalog.Language] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return LanguageCatalog.all }
        return LanguageCatalog.all.filter {
            $0.englishName.lowercased().contains(needle)
                || $0.nativeName.lowercased().contains(needle)
                || $0.code.lowercased().contains(needle)
        }
    }

    /// Target and secondary must stay enabled — the popup's pickers would
    /// otherwise not be able to offer the very pair they translate between.
    private func isLocked(_ code: String) -> Bool {
        code == settings.targetLanguage || code == settings.secondaryLanguage
    }

    var body: some View {
        // The tab's height is fixed by the Settings window, so this splits it
        // between a self-sizing Defaults form and a list that absorbs whatever
        // is left. Nothing here may force an intrinsic height larger than the
        // window: doing so overflows the enclosing TabView and pushes its tab
        // bar off-screen entirely.
        VStack(spacing: 0) {
            Form {
                Section("Defaults") {
                    Picker("Default source", selection: $settings.sourceLanguage) {
                        Text("Auto").tag(LanguageCatalog.autoCode)
                        ForEach(enabledLanguages) { lang in
                            Text(lang.displayName).tag(lang.code)
                        }
                    }

                    Picker("Translate to", selection: $settings.targetLanguage) {
                        ForEach(enabledLanguages) { lang in
                            Text(lang.displayName).tag(lang.code)
                        }
                    }

                    Picker("Second language", selection: $settings.secondaryLanguage) {
                        ForEach(enabledLanguages) { lang in
                            Text(lang.displayName).tag(lang.code)
                        }
                    }

                    Text(directionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxHeight: 250)

            enabledLanguagesSection
        }
    }

    /// Plain-language statement of what the current pair actually does, so the
    /// English-anchored rule isn't something the user has to discover by
    /// experiment.
    private var directionSummary: String {
        let target = LanguageCatalog.englishName(for: settings.targetLanguage)
        let secondary = LanguageCatalog.englishName(for: settings.secondaryLanguage)
        guard settings.pairIncludesEnglish, let other = settings.nonEnglishOfPair else {
            return "\(target) text is translated to \(secondary); everything else "
                + "is translated to \(target)."
        }
        let otherName = LanguageCatalog.englishName(for: other)
        return "English text is translated to \(otherName); everything else, "
            + "\(otherName) included, is translated to English. Changing the "
            + "language in the popup applies to that popup only."
    }

    // MARK: - Enabled languages

    /// Deliberately outside the `Form`: a `ScrollView` nested inside a grouped
    /// form section gets no scroller and ignores its own height, which is what
    /// left this list unscrollable and its box stretched empty.
    private var enabledLanguagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Enabled Languages")
                    .font(.headline)
                Spacer()
                Text("\(settings.enabledLanguages.count) of \(LanguageCatalog.all.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                LanguageSearchField(text: $query, prompt: "Search languages")
                Button("Select All", action: selectAllFiltered)
                    .disabled(filteredLanguages.allSatisfy { settings.enabledLanguages.contains($0.code) })
                Button("Select None", action: deselectAllFiltered)
                    .disabled(filteredLanguages.allSatisfy {
                        isLocked($0.code) || !settings.enabledLanguages.contains($0.code)
                    })
            }

            List(filteredLanguages) { lang in
                Toggle(lang.displayName, isOn: enabledBinding(for: lang.code))
                    .disabled(isLocked(lang.code))
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            // Absorbs the leftover height rather than demanding its own, so
            // the tab can never outgrow the window.
            .frame(minHeight: 80, maxHeight: .infinity)

            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "The popup's language pickers show only enabled languages."
                 : "Select All / Select None apply to the \(filteredLanguages.count) "
                   + "language\(filteredLanguages.count == 1 ? "" : "s") matching your search.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    /// Both bulk actions act on the current search results only, so "Select
    /// All" after typing "span" can't silently enable all 110 languages.
    private func selectAllFiltered() {
        for lang in filteredLanguages where !settings.enabledLanguageCodes.contains(lang.code) {
            settings.enabledLanguageCodes.append(lang.code)
        }
    }

    private func deselectAllFiltered() {
        let removable = Set(filteredLanguages.map(\.code).filter { !isLocked($0) })
        settings.enabledLanguageCodes.removeAll { removable.contains($0) }
    }

    /// Reads membership through `enabledLanguages` (the target/secondary
    /// superset) so the default pair always shows as "on" even before it has
    /// been explicitly added to the stored `enabledLanguageCodes` list; the
    /// setter still writes that stored list directly.
    private func enabledBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { settings.enabledLanguages.contains(code) },
            set: { include in
                if include {
                    if !settings.enabledLanguageCodes.contains(code) {
                        settings.enabledLanguageCodes.append(code)
                    }
                } else {
                    settings.enabledLanguageCodes.removeAll { $0 == code }
                }
            }
        )
    }
}
