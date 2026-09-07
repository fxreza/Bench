# Lingo attribution

Lingo is a port of the standalone [Transi](../../../Transi) app into Bench.
It links the following open-source packages, all MIT-licensed:

| Package | Author | Where it comes from |
|---|---|---|
| SelectedTextKit | tisfeng | https://github.com/tisfeng/SelectedTextKit |
| AXSwift | Tyler Mandry | https://github.com/tmandry/AXSwift (via SelectedTextKit) |
| KeySender | Jordan Baird | https://github.com/jordanbaird/KeySender (via SelectedTextKit) |

Full license text for each is in Transi's `THIRD-PARTY-LICENSES.md`; Bench's
own build should reproduce the same file (or fold Lingo's entries into a
combined one) so it ships inside `Bench.app` the way Transi shipped it inside
`Transi.app`.

Transi itself was inspired by the Windows tool QTranslate, but is an
independent project with no code from it and no affiliation with its authors.

## Google / Bing endpoint caveat

The Google and Bing translation engines (`Engines/GoogleEngine.swift`,
`Engines/BingEngine.swift`, `Engines/BingConfigStore.swift`) use those
services' free, keyless web endpoints — the same ones their own translator
pages call, not supported or documented APIs. Using them is contrary to
Google's and Microsoft's Terms of Service; either can be rate-limited,
changed, or removed without notice, in which case the affected card degrades
to an error while the other engines keep working. Text sent through these
engines (and through Gemini, when enabled) leaves the machine and goes to
Google and/or Microsoft — see Transi's `README.md` § "How translation works"
for the full disclosure, which still applies unchanged to Lingo. The 🔊
speech feature similarly uses Google Translate's unofficial `translate_tts`
endpoint (`SpeechService.swift`), falling back to the on-device macOS voice
on any failure.

Lingo is not affiliated with, sponsored by, or endorsed by Google or
Microsoft; their names are used only to say where the text goes.
