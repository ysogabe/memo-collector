#!/bin/zsh
# FluidInference/embeddinggemma-2-coreml を固定 revision で取得する（合計約 1.5GB）
set -eu
REV=${REV:-3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4}
DEST=${1:-models/embeddinggemma-2-coreml}
files=(
  config.json README.md tokenizer.json embeddings.bf16 position_embeddings.f16
  EmbeddingGemma2Text.mlpackage/Manifest.json
  EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel
  EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin
  EmbeddingGemma2Vision.mlpackage/Manifest.json
  EmbeddingGemma2Vision.mlpackage/Data/com.apple.CoreML/model.mlmodel
  EmbeddingGemma2Vision.mlpackage/Data/com.apple.CoreML/weights/weight.bin
  EmbeddingGemma2Audio.mlpackage/Manifest.json
  EmbeddingGemma2Audio.mlpackage/Data/com.apple.CoreML/model.mlmodel
  EmbeddingGemma2Audio.mlpackage/Data/com.apple.CoreML/weights/weight.bin
)
for f in $files; do
  mkdir -p "$DEST/${f:h}"
  [ -s "$DEST/$f" ] || curl -sSfL "https://huggingface.co/FluidInference/embeddinggemma-2-coreml/resolve/$REV/$f" -o "$DEST/$f"
done
echo "$REV" >| "$DEST/REVISION"
du -sh "$DEST"
