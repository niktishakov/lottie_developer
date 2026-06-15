#!/bin/bash
# Standalone-проверка LottieCompiler без iOS-симулятора.
# Компилирует Sources/AI/Spec/*.swift + bin/lottie_compiler_check_main.swift через хостовый swiftc и запускает.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT/Sources/AI/Spec"
MAIN="$ROOT/bin/lottie_compiler_check_main.swift"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun swiftc -O \
    "$SPEC/AnimationSpec.swift" \
    "$SPEC/AnimationSpecSchema.swift" \
    "$SPEC/LottieCompiler.swift" \
    "$MAIN" \
    -o "$TMP/check"

"$TMP/check" "$ROOT"
