#!/usr/bin/env bash
set -e
zig build lib && bun run test/ffi/test.ts
