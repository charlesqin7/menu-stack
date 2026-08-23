#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun --sdk macosx clang \
  -fobjc-arc \
  -fblocks \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-deprecated-declarations \
  -Wno-unused-function \
  -Wno-unused-parameter \
  -Wno-unused-variable \
  -I"$ROOT_DIR" \
  -framework Foundation \
  -framework CoreGraphics \
  "$ROOT_DIR/VLMMenuRules.m" \
  "$ROOT_DIR/VLMMenuGeometry.m" \
  "$ROOT_DIR/VLMMenuOrder.m" \
  "$ROOT_DIR/Tests/VLMTestStubs.m" \
  "$ROOT_DIR/Tests/VLMMenuRulesTests.m" \
  -o "$BUILD_DIR/vlm-menu-rules-tests"

"$BUILD_DIR/vlm-menu-rules-tests"
