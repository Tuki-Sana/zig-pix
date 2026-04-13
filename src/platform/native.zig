/// platform/native.zig — ネイティブ環境 (Mac ARM / Linux x86_64)
///
/// スレッドプール、大バッファ向けアロケータ、SIMD 機能検出を提供。
/// platform.zig が comptime でこのファイルを選択する。

const std = @import("std");
const builtin = @import("builtin");

// ─────────────────────────────────────────────────────────────────────────────
// アロケータ
// ─────────────────────────────────────────────────────────────────────────────

/// 開発・テスト用: メモリリーク検出付き GPA
pub fn makeDebugAllocator() std.heap.GeneralPurposeAllocator(.{}) {
    return std.heap.GeneralPurposeAllocator(.{}){};
}

/// リリース用: page_allocator 直接使用 (OS に返却)
pub const release_allocator = std.heap.page_allocator;

// ─────────────────────────────────────────────────────────────────────────────
// SIMD 機能検出 (Phase 3 で使用)
// ─────────────────────────────────────────────────────────────────────────────

pub const CpuFeatures = struct {
    has_avx2: bool,
    has_neon: bool,
    has_sse41: bool,
};

pub fn detectCpuFeatures() CpuFeatures {
    const cpu = builtin.cpu;
    return .{
        .has_avx2 = std.Target.x86.featureSetHas(cpu.features, .avx2),
        .has_neon = std.Target.aarch64.featureSetHas(cpu.features, .neon),
        .has_sse41 = std.Target.x86.featureSetHas(cpu.features, .sse4_1),
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// スレッド設定 (Phase 4 で使用)
// ─────────────────────────────────────────────────────────────────────────────

/// VPS: 2コア → worker 数 2 が上限
pub const MAX_WORKER_THREADS: u32 = 2;

/// 推奨タイル高さ (VPS 向け: 大きいほど V-pass の呼び出し回数が減る)
pub const DEFAULT_TILE_HEIGHT: u32 = 256;

// ─────────────────────────────────────────────────────────────────────────────
// テスト
// ─────────────────────────────────────────────────────────────────────────────

test "detectCpuFeatures: クラッシュしない" {
    const features = detectCpuFeatures();
    _ = features; // ターゲットに依存するので値は検証しない
}
