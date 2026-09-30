# Attribution

Bench is assembled from four apps by the same author, plus the projects those
apps were themselves built on. Everything below is MIT-licensed except
mediaremote-adapter (BSD-3-Clause), Apple's MobileCLIP model weights (Apple's
"ML-MobileCLIP Model Weights and Data" license) and the Hugging Face tokenizer
code Apple's MobileCLIP demo was adapted from (Apache-2.0); the notices those
licenses require to travel with a distribution are reproduced at the end, and
this file ships inside the built `.app` as well as in the repo.

## The four apps Bench is made of

| Module | Comes from | Copyright | Where |
|---|---|---|---|
| Shot | Snapper | 2026 Sam Reza | https://github.com/fxreza/Snapper |
| Klip | Klip | 2026 Sam Reza | https://github.com/fxreza/Klip |
| Lingo | Transi | 2026 Sam Reza | https://github.com/fxreza/Transi |
| Piko | Piko | 2026 Sam Reza | https://github.com/fxreza/Piko |

Snap is new in Bench; it replaces a set of BetterTouchTool window-management
triggers and borrows no code.

Piko bundles [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
by ungive (BSD-3-Clause; notice below and in `Sources/Piko/ATTRIBUTION.md`)
to read now-playing information, which macOS 15.4+ gates for third-party
apps. Its geometry and timing were measured from Alcove, a closed-source app;
no code of it was used.

The app shell also carries pieces of all four: the updater and changelog
parser from Snapper (which took them from Klip), the hotkey registration,
shortcut store, permissions polling, appearance settings and hotkey recorder
that all three shared, and Transi's build, icon and launch scripts.

## What those three were built on

### Buffer

Copyright (c) 2026 Samir Patil - MIT.

Klip is a fork of Buffer: the core clipboard manager architecture, pasteboard
monitoring and history management came from it, and reach Bench through Klip.

### Clipfield

Copyright (c) 2026 Alex Jolley - MIT.

Klip ported and adapted design tokens and UI components from Clipfield, several
of which are now in `BenchCore`:

- theme tokens and light/dark + accent handling (`Appearance.swift`)
- the keyboard shortcut recorder (`HotkeyRecorder.swift`)
- Accessibility permission polling (`PermissionsState.swift`)
- the first-launch permission request, now Bench's Permissions pane
- rich text format detection, link/email/phone/color/code detection heuristics
- the sidebar resize control

### Pesty

Copyright (c) 2026 Moamen Basel - MIT.

Klip's iCloud Drive file sync approach - per-device snapshot files,
content-hash deduplication, tombstone-based deletion tracking and
`NSFileCoordinator` coordination - came from Pesty and is used by the Klip
module.

### SelectedTextKit, AXSwift, KeySender

Linked by the Lingo module for selected-text capture, exactly as Transi linked
them.

| Package | Author | Where |
|---|---|---|
| SelectedTextKit | tisfeng | https://github.com/tisfeng/SelectedTextKit |
| AXSwift | Tyler Mandry | https://github.com/tmandry/AXSwift (via SelectedTextKit) |
| KeySender | Jordan Baird | https://github.com/jordanbaird/KeySender (via SelectedTextKit) |

Translation results come from Google Translate, Bing and Gemini. None of those
companies is affiliated with Bench or endorses it.

## Klip's smart image search: MobileCLIP

Klip finds image clips by what they show with Apple's MobileCLIP-S2, run
on-device through Core ML. Apple does not endorse Bench.

| Component | Author | License | Where |
|---|---|---|---|
| MobileCLIP-S2 Core ML image and text encoders (weights) | Apple Inc. | ML-MobileCLIP Model Weights and Data (notice below; `apple-ascl` on Hugging Face) | https://huggingface.co/apple/coreml-mobileclip |
| CLIP tokenizer, ported to `Sources/Klip/Services/CLIPTokenizer.swift` from the MobileCLIPExplore demo app | Apple Inc. | MIT | https://github.com/apple/ml-mobileclip (`ios_app/MobileCLIPExplore/Tokenizer`) |
| ...which Apple adapted from swift-coreml-transformers | Hugging Face | Apache-2.0 | https://github.com/huggingface/swift-coreml-transformers |
| CLIP's BPE algorithm, text cleanup and merges file (`clip-merges.txt`, bundled) | OpenAI | MIT | https://github.com/openai/CLIP |

The weights are the MobileCLIP (2024) S2 encoders, whose license permits
redistribution with this notice. The later MobileCLIP2 models are under a
different, research-only license and are not used. The encoders are fetched
by `scripts/fetch-clip-model.sh` and compiled from `.mlpackage` to
`.mlmodelc` by `scripts/compile-clip-model.swift`; the weights themselves are
unmodified. The Swift tokenizer is a rewrite of Apple's port (it runs BPE on
token ids and derives the vocabulary from the merges, and fixes the port's
use of all 262,144 merges instead of CLIP's 48,894); its header lists the
changes.

## Studied for behaviour only - no code copied

Read to understand how they behave, not for their source. Nothing in Bench is
derived from their code:

- **MacShot** (GPLv3)
- **Capso** (Business Source License 1.1 - forbids screenshot-app derivatives)
- **Shottr** (closed source; behaviour reverse-engineered from screenshots,
  UserDefaults keys and binary strings only)

--------------------------------------------------------------------------------
## SelectedTextKit

MIT License

Copyright (c) 2024 tisfeng

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--------------------------------------------------------------------------------
## AXSwift

MIT License

Copyright (c) 2017 Tyler Mandry

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--------------------------------------------------------------------------------
## KeySender

MIT License

Copyright (c) 2022 Jordan Baird - https://github.com/jordanbaird/KeySender

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--------------------------------------------------------------------------------
## MobileCLIP model weights (Apple)

The MobileCLIP-S2 Core ML encoders bundled in `Contents/Resources/MobileCLIP`
are the Apple Software this notice refers to.

ML-MobileCLIP Model Weights and Data

Copyright (C) 2024 Apple Inc. All Rights Reserved.

IMPORTANT:  This Apple software is supplied to you by Apple
Inc. ("Apple") in consideration of your agreement to the following
terms, and your use, installation, modification or redistribution of
this Apple software constitutes acceptance of these terms.  If you do
not agree with these terms, please do not use, install, modify or
redistribute this Apple software.

In consideration of your agreement to abide by the following terms, and
subject to these terms, Apple grants you a personal, non-exclusive
license, under Apple's copyrights in this original Apple software (the
"Apple Software"), to use, reproduce, modify and redistribute the Apple
Software, with or without modifications, in source and/or binary forms;
provided that if you redistribute the Apple Software in its entirety and
without modifications, you must retain this notice and the following
text and disclaimers in all such redistributions of the Apple Software.
Neither the name, trademarks, service marks or logos of Apple Inc. may
be used to endorse or promote products derived from the Apple Software
without specific prior written permission from Apple.  Except as
expressly stated in this notice, no other rights or licenses, express or
implied, are granted by Apple herein, including but not limited to any
patent rights that may be infringed by your derivative works or by other
works in which the Apple Software may be incorporated.

The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--------------------------------------------------------------------------------
## ml-mobileclip (Apple sample code: the MobileCLIPExplore tokenizer)

MIT License

Copyright © 2024 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--------------------------------------------------------------------------------
## swift-coreml-transformers (Hugging Face)

Copyright 2019-2023 Hugging Face. The CLIP tokenizer Apple's demo app ships
(`CLIPTokenizer.swift`, `GPT2ByteEncoder.swift`, `Utils.swift`) is a modified
copy of this project's tokenizer; Klip's `CLIPTokenizer.swift` is a further
modified port of it (changes listed in its header).

Licensed under the Apache License, Version 2.0 (the "License"); you may not
use these files except in compliance with the License. You may obtain a copy
of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations under
the License.

--------------------------------------------------------------------------------
## CLIP (OpenAI: BPE tokenizer and merges file)

MIT License

Copyright (c) 2021 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
