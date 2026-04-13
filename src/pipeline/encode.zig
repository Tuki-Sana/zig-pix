/// encode.zig — Encoder 抽象化レイヤー
///
/// decode.zig と対称的な vtable 設計。
/// Phase 2 で libwebp C 実装を差し込む。

const std = @import("std");
const decode = @import("decode.zig");

// ─────────────────────────────────────────────────────────────────────────────
// 型定義
// ─────────────────────────────────────────────────────────────────────────────

pub const OutputFormat = enum {
    webp,
    // Phase 7: avif
};

pub const WebPOptions = struct {
    /// 品質 0..100 (100 = lossless に近い。イラスト向けデフォルト: 92)
    quality: f32 = 92.0,
    /// true = ロスレス (ファイルサイズは大きくなる)
    lossless: bool = false,
    /// エンコーダ内スレッド数 (0 = 自動)
    thread_level: u8 = 0,
};

pub const EncodeOptions = union(OutputFormat) {
    webp: WebPOptions,
};

pub const EncodeError = error{
    EncodingFailed,
    UnsupportedFormat,
    InvalidInput,
    OutOfMemory,
};

/// エンコード結果。`data` は allocator 管理。`deinit()` で解放。
pub const EncodedBuffer = struct {
    format: OutputFormat,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncodedBuffer) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Encoder vtable インタフェース
// ─────────────────────────────────────────────────────────────────────────────

pub const Encoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        encode: *const fn (
            ptr: *anyopaque,
            image: decode.ImageBuffer,
            options: EncodeOptions,
            allocator: std.mem.Allocator,
        ) EncodeError!EncodedBuffer,

        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn encode(
        self: Encoder,
        image: decode.ImageBuffer,
        options: EncodeOptions,
        allocator: std.mem.Allocator,
    ) EncodeError!EncodedBuffer {
        return self.vtable.encode(self.ptr, image, options, allocator);
    }

    pub fn deinit(self: Encoder) void {
        self.vtable.deinit(self.ptr);
    }
};
