/// platform/wasm.zig — WebAssembly / Edge 環境
///
/// 制約: 128 MB, シングルスレッド, SIMD は wasm128 のみ
/// platform.zig が comptime でこのファイルを選択する。

const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// アロケータ
// ─────────────────────────────────────────────────────────────────────────────

/// Edge の 128MB 制約に合わせた固定バッファ
/// 実際の静的バッファは root.zig 側で確保し、ここは設定値のみ定義する。
pub const HEAP_BUDGET_BYTES: usize = 96 * 1024 * 1024; // 128MB中の処理用予算: 96MB

// ─────────────────────────────────────────────────────────────────────────────
// SIMD (Phase 3 以降)
// ─────────────────────────────────────────────────────────────────────────────

pub const CpuFeatures = struct {
    has_avx2: bool = false,
    has_neon: bool = false,
    has_sse41: bool = false,
    // Wasm SIMD128 は Phase 3 で追加
};

pub fn detectCpuFeatures() CpuFeatures {
    return .{}; // Wasm: 全て false (SIMD128 は別途対応)
}

// ─────────────────────────────────────────────────────────────────────────────
// スレッド設定
// ─────────────────────────────────────────────────────────────────────────────

/// Wasm はシングルスレッド (SharedArrayBuffer なしの WASI)
pub const MAX_WORKER_THREADS: u32 = 1;

/// Edge 向け: 小さいタイルで最大メモリピークを抑制
pub const DEFAULT_TILE_HEIGHT: u32 = 64;
