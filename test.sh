#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
mkdir -p "$project_dir/build"
xcrun clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    -framework AppKit -framework Carbon -framework CoreGraphics \
    "$project_dir/Tests/RecoveryTests.m" -o "$project_dir/build/RecoveryTests"
"$project_dir/build/RecoveryTests"
