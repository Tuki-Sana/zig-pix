/// decode.zig — Decoder 抽象化レイヤー
///
/// 設計方針 (Q1 決定事項):
///   - 実装は libjpeg-turbo (C) を採用するが、呼び出し元はこの Decoder インタフェースのみを使う。
///   - 将来 zigimg 等に差し替える場合は Decoder.init() の実装を差し替えるだけでよい。
///   - vtable パターンにより、コンパイル時に実装を選択できる (Wasm では軽量実装を選択可能)。

const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// 型定義
// ─────────────────────────────────────────────────────────────────────────────

pub const PixelFormat = enum {
    /// 8-bit RGBA (デフォルト: PNG/JPEG → RGBA 変換後)
    rgba8,
    /// 8-bit RGB (アルファなし)
    rgb8,
    // Phase 7: rgba16, yuv444_10bit
};

/// デコード済み画像バッファ。
/// `deinit()` で allocator に返却する。zero-copy を守るため raw data を直接保持。
pub const ImageBuffer = struct {
    width: u32,
    height: u32,
    channels: u8,
    format: PixelFormat,
    /// 生ピクセルデータ: [height * stride] bytes, row-major, top-left origin
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ImageBuffer) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    /// 1行あたりのバイト数
    pub inline fn stride(self: ImageBuffer) usize {
        return @as(usize, self.width) * self.channels;
    }

    /// 行 y のスライスを返す (bounds check あり)
    pub fn rowSlice(self: ImageBuffer, y: usize) []u8 {
        std.debug.assert(y < self.height);
        const s = self.stride();
        return self.data[y * s .. (y + 1) * s];
    }

    pub fn rowSliceConst(self: ImageBuffer, y: usize) []const u8 {
        std.debug.assert(y < self.height);
        const s = self.stride();
        return self.data[y * s .. (y + 1) * s];
    }

    pub fn totalBytes(self: ImageBuffer) usize {
        return @as(usize, self.height) * self.stride();
    }
};

pub const DecodeError = error{
    UnsupportedFormat,
    CorruptData,
    InvalidDimensions,
    OutOfMemory,
};

// ─────────────────────────────────────────────────────────────────────────────
// Decoder vtable インタフェース
// ─────────────────────────────────────────────────────────────────────────────

/// 呼び出し元が触る唯一の型。
/// 実装 (JpegDecoder / PngDecoder / ...) とは vtable 経由で疎結合。
pub const Decoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `data`: ファイル全体のバイト列。
        /// 返り値 ImageBuffer の `data` は `allocator` から確保される。
        decode: *const fn (
            ptr: *anyopaque,
            data: []const u8,
            allocator: std.mem.Allocator,
        ) DecodeError!ImageBuffer,

        /// デコーダ自身が確保したリソースを解放する。
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn decode(
        self: Decoder,
        data: []const u8,
        allocator: std.mem.Allocator,
    ) DecodeError!ImageBuffer {
        return self.vtable.decode(self.ptr, data, allocator);
    }

    pub fn deinit(self: Decoder) void {
        self.vtable.deinit(self.ptr);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// フォーマット判定ユーティリティ
// ─────────────────────────────────────────────────────────────────────────────

pub const Format = enum { jpeg, png, unknown };

/// magic bytes によるフォーマット検出 (拡張子に依存しない)
pub fn detectFormat(data: []const u8) Format {
    if (data.len < 4) return .unknown;
    // JPEG: FF D8 FF
    if (data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) return .jpeg;
    // PNG: 89 50 4E 47
    if (data[0] == 0x89 and data[1] == 0x50 and data[2] == 0x4E and data[3] == 0x47) return .png;
    return .unknown;
}

// ─────────────────────────────────────────────────────────────────────────────
// テスト
// ─────────────────────────────────────────────────────────────────────────────

test "detectFormat: JPEG magic" {
    const jpeg_header = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 };
    try std.testing.expectEqual(Format.jpeg, detectFormat(&jpeg_header));
}

test "detectFormat: PNG magic" {
    const png_header = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expectEqual(Format.png, detectFormat(&png_header));
}

test "detectFormat: unknown" {
    const garbage = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    try std.testing.expectEqual(Format.unknown, detectFormat(&garbage));
}

test "ImageBuffer: stride and rowSlice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data = try alloc.alloc(u8, 4 * 2 * 4); // 4x2 RGBA
    for (data, 0..) |*b, i| b.* = @intCast(i % 256);

    var buf = ImageBuffer{
        .width = 4,
        .height = 2,
        .channels = 4,
        .format = .rgba8,
        .data = data,
        .allocator = alloc,
    };
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 16), buf.stride()); // 4px * 4ch
    try std.testing.expectEqual(@as(usize, 16), buf.rowSlice(0).len);
    try std.testing.expectEqual(@as(usize, 16), buf.rowSlice(1).len);
}
