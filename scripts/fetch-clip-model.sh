#!/bin/bash
# Downloads Apple's MobileCLIP-S2 Core ML encoders and the CLIP tokenizer
# files Klip's image search uses. They are ~200 MB, so they live outside git
# in Models.noindex/MobileCLIP; build-app.sh bundles them into Bench.app.
#
# Sources (Apple sample code / weights licenses, see ATTRIBUTION.md):
#   https://huggingface.co/apple/coreml-mobileclip
#   https://github.com/apple/ml-mobileclip (ios_app/MobileCLIPExplore/Resources)
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="Models.noindex/MobileCLIP"
HF="https://huggingface.co/apple/coreml-mobileclip/resolve/main"
GH="https://raw.githubusercontent.com/apple/ml-mobileclip/main/ios_app/MobileCLIPExplore/Resources"
mkdir -p "$DEST"

for enc in image text; do
    pkg="mobileclip_s2_${enc}.mlpackage"
    for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
        out="$DEST/$pkg/$f"
        [ -s "$out" ] && continue
        mkdir -p "$(dirname "$out")"
        echo "Fetching $pkg/$f"
        curl -fL --retry 3 -o "$out" "$HF/$pkg/$f"
    done
done

for f in clip-vocab.json clip-merges.txt; do
    [ -s "$DEST/$f" ] && continue
    echo "Fetching $f"
    curl -fL --retry 3 -o "$DEST/$f" "$GH/$f"
done

du -sh "$DEST"
