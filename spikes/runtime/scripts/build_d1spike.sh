#!/bin/zsh
# D1Spike（d1-swift / embed-swift）をビルドする。
# このマシンには Xcode の Metal Toolchain が無いため、mlx-swift を `swift package edit` で取り出し、
# .metal のコンパイルを除外して、同版（0.32.3）の Python mlx が同梱する mlx.metallib を実行ファイル横に置く。
# Metal Toolchain を入れた環境（xcodebuild -downloadComponent MetalToolchain）ではこの細工は不要。
set -euo pipefail
here=${0:A:h}/..
cd $here/swift/D1Spike
[[ -d Packages/mlx-swift ]] || swift package edit mlx-swift
python3 - <<'PY'
p = "Packages/mlx-swift/Package.swift"
s = open(p).read()
if '"mlx-generated/metal",' not in s:
    old = '''            "mlx/mlx/backend/cpu/gemms/simd_bf16.cpp",
        ] + noCudaCmlxExcludes'''
    assert s.count(old) == 1
    s = s.replace(old, '''            "mlx/mlx/backend/cpu/gemms/simd_bf16.cpp",
            // SPIKE: Metal Toolchain 未導入のため .metal のコンパイルを外す
            "mlx-generated/metal",
        ] + noCudaCmlxExcludes''')
    open(p, "w").write(s)
PY
swift build -c release
cp $here/.venv/lib/python3.12/site-packages/mlx/lib/mlx.metallib .build/release/mlx.metallib
echo "built: $PWD/.build/release/{d1-swift,embed-swift}"
