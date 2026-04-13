#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../.."
npm install --silent
zig build lib -Doptimize=ReleaseFast
npx tsx test/ffi/test.node.ts
