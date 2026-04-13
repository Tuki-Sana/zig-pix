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
// libjpeg-turbo C bridge (extern 宣言)
// src/c/jpeg_decode.c で実装。CLI / lib / test 全ターゲットでリンクされる。
// ─────────────────────────────────────────────────────────────────────────────

extern fn pict_jpeg_decode(
    src: [*]const u8,
    src_len: c_ulong,
    out_data: *[*]u8,
    out_width: *c_uint,
    out_height: *c_uint,
    out_channels: *c_uint,
) c_int;

extern fn pict_jpeg_free(data: [*]u8) void;

/// テスト専用エンコーダ。libjpeg-turbo の jpeg_mem_dest を使う。
/// 返り値バッファは pict_jpeg_free() で解放すること。
extern fn pict_jpeg_encode(
    rgb: [*]const u8,
    width: c_uint,
    height: c_uint,
    quality: c_int,
    out_jpeg: *?[*]u8,
    out_len: *c_ulong,
) c_int;

// ─────────────────────────────────────────────────────────────────────────────
// libpng C bridge (extern 宣言)
// src/c/png_decode.c で実装。
// ─────────────────────────────────────────────────────────────────────────────

extern fn pict_png_decode(
    src: [*]const u8,
    src_len: c_ulong,
    out_data: *[*]u8,
    out_width: *c_uint,
    out_height: *c_uint,
    out_channels: *c_uint,
) c_int;

extern fn pict_png_free(data: [*]u8) void;

/// テスト専用エンコーダ。libpng の in-memory write を使う。
/// 返り値バッファは pict_png_free() で解放すること。
extern fn pict_png_encode(
    pixels: [*]const u8,
    width: c_uint,
    height: c_uint,
    channels: c_uint,
    out_png: *?[*]u8,
    out_len: *c_ulong,
) c_int;

// ─────────────────────────────────────────────────────────────────────────────
// JpegDecoder — libjpeg-turbo を使う Decoder 実装
// ─────────────────────────────────────────────────────────────────────────────

/// libjpeg-turbo を使ってメモリ上の JPEG バイト列をデコードする Decoder 実装。
///
/// ステートレスな vtable 実装。`jpegDecoder()` でインスタンスを取得する。
pub const JpegDecoder = struct {
    pub const vtable = Decoder.VTable{
        .decode = decodeImpl,
        .deinit = deinitImpl,
    };

    fn decodeImpl(
        ptr: *anyopaque,
        data: []const u8,
        allocator: std.mem.Allocator,
    ) DecodeError!ImageBuffer {
        _ = ptr;

        var out_data: [*]u8 = undefined;
        var out_width: c_uint = 0;
        var out_height: c_uint = 0;
        var out_channels: c_uint = 0;

        const result = pict_jpeg_decode(
            data.ptr,
            @intCast(data.len),
            &out_data,
            &out_width,
            &out_height,
            &out_channels,
        );

        switch (result) {
            0 => {},
            -2 => return DecodeError.OutOfMemory,
            else => return DecodeError.CorruptData,
        }

        const w: usize = @intCast(out_width);
        const h: usize = @intCast(out_height);
        const ch: usize = @intCast(out_channels);
        const total = h * w * ch;
        const c_slice = out_data[0..total];
        defer pict_jpeg_free(out_data);

        const zig_buf = try allocator.alloc(u8, total);
        errdefer allocator.free(zig_buf);
        @memcpy(zig_buf, c_slice);

        return ImageBuffer{
            .width = @intCast(out_width),
            .height = @intCast(out_height),
            .channels = @intCast(out_channels),
            .format = .rgb8,
            .data = zig_buf,
            .allocator = allocator,
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// libjpeg-turbo でメモリ上の JPEG をデコードする Decoder を返す。
/// JpegDecoder はステートレスなので deinit() は何もしないが、
/// 呼び出し元は必ず Decoder.deinit() を呼ぶこと。
pub fn jpegDecoder() Decoder {
    // ステートレスなので静的ダミーをポインタに使う
    const Anchor = struct {
        var byte: u8 = 0;
    };
    return .{
        .ptr = &Anchor.byte,
        .vtable = &JpegDecoder.vtable,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// PngDecoder — libpng を使う Decoder 実装
// ─────────────────────────────────────────────────────────────────────────────

/// libpng を使ってメモリ上の PNG バイト列をデコードする Decoder 実装。
///
/// 出力カラーフォーマット:
///   - RGB (alpha なし) → channels=3, format=rgb8
///   - RGBA (alpha あり) → channels=4, format=rgba8
/// グレースケールは RGB に変換。16-bit は 8-bit に切り捨て。
pub const PngDecoder = struct {
    pub const vtable = Decoder.VTable{
        .decode = decodeImpl,
        .deinit = deinitImpl,
    };

    fn decodeImpl(
        ptr: *anyopaque,
        data: []const u8,
        allocator: std.mem.Allocator,
    ) DecodeError!ImageBuffer {
        _ = ptr;

        var out_data: [*]u8 = undefined;
        var out_width: c_uint = 0;
        var out_height: c_uint = 0;
        var out_channels: c_uint = 0;

        const result = pict_png_decode(
            data.ptr,
            @intCast(data.len),
            &out_data,
            &out_width,
            &out_height,
            &out_channels,
        );

        switch (result) {
            0 => {},
            -2 => return DecodeError.OutOfMemory,
            else => return DecodeError.CorruptData,
        }

        const w: usize = @intCast(out_width);
        const h: usize = @intCast(out_height);
        const ch: usize = @intCast(out_channels);
        const total = h * w * ch;
        const c_slice = out_data[0..total];
        defer pict_png_free(out_data);

        const zig_buf = try allocator.alloc(u8, total);
        errdefer allocator.free(zig_buf);
        @memcpy(zig_buf, c_slice);

        const fmt: PixelFormat = if (ch == 4) .rgba8 else .rgb8;
        return ImageBuffer{
            .width = @intCast(out_width),
            .height = @intCast(out_height),
            .channels = @intCast(out_channels),
            .format = fmt,
            .data = zig_buf,
            .allocator = allocator,
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// libpng でメモリ上の PNG をデコードする Decoder を返す。
pub fn pngDecoder() Decoder {
    const Anchor = struct {
        var byte: u8 = 0;
    };
    return .{
        .ptr = &Anchor.byte,
        .vtable = &PngDecoder.vtable,
    };
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

// ─────────────────────────────────────────────────────────────────────────────
// JPEG デコードパスのテスト (libjpeg-turbo が必要)
// ─────────────────────────────────────────────────────────────────────────────

// 4×4 グレーの RGB ピクセルを pict_jpeg_encode でエンコードし、
// JpegDecoder でデコードして寸法・チャンネル・フォーマットを検証する。
test "JpegDecoder: decode RGB image dimensions" {
    // 4×4 グレーの RGB 画像 (128, 128, 128)
    const W = 4;
    const H = 4;
    var rgb = [_]u8{128} ** (W * H * 3);

    var jpeg_ptr: ?[*]u8 = null;
    var jpeg_len: c_ulong = 0;
    const enc = pict_jpeg_encode(@as([*]const u8, &rgb), W, H, 75, &jpeg_ptr, &jpeg_len);
    try std.testing.expectEqual(@as(c_int, 0), enc);
    defer if (jpeg_ptr) |p| pict_jpeg_free(p);

    const jpeg_slice = jpeg_ptr.?[0..jpeg_len];

    var dec = jpegDecoder();
    defer dec.deinit();

    var buf = try dec.decode(jpeg_slice, std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, W), buf.width);
    try std.testing.expectEqual(@as(u32, H), buf.height);
    try std.testing.expectEqual(@as(u8, 3), buf.channels);
    try std.testing.expectEqual(PixelFormat.rgb8, buf.format);
    try std.testing.expectEqual(W * H * 3, buf.data.len);
}

// detectFormat が JPEG マジックを返したバイト列を JpegDecoder がデコードできることを確認。
test "JpegDecoder: detectFormat and decode consistency" {
    const W = 2;
    const H = 2;
    var rgb = [_]u8{ 255, 0, 0 } ** (W * H); // 赤

    var jpeg_ptr: ?[*]u8 = null;
    var jpeg_len: c_ulong = 0;
    const enc = pict_jpeg_encode(@as([*]const u8, &rgb), W, H, 90, &jpeg_ptr, &jpeg_len);
    try std.testing.expectEqual(@as(c_int, 0), enc);
    defer if (jpeg_ptr) |p| pict_jpeg_free(p);

    const jpeg_slice = jpeg_ptr.?[0..jpeg_len];

    // マジックが .jpeg を返すこと
    try std.testing.expectEqual(Format.jpeg, detectFormat(jpeg_slice));

    // デコードが成功すること
    var dec = jpegDecoder();
    defer dec.deinit();

    var buf = try dec.decode(jpeg_slice, std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, W), buf.width);
    try std.testing.expectEqual(@as(u32, H), buf.height);
}

// 壊れたバイト列を渡すと CorruptData エラーが返ること。
test "JpegDecoder: corrupt data returns CorruptData" {
    const garbage = [_]u8{ 0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02, 0x03, 0x04 };

    var dec = jpegDecoder();
    defer dec.deinit();

    const result = dec.decode(&garbage, std.testing.allocator);
    try std.testing.expectError(DecodeError.CorruptData, result);
}

// ─────────────────────────────────────────────────────────────────────────────
// PNG デコードパスのテスト (libpng が必要)
// ─────────────────────────────────────────────────────────────────────────────

// 4×4 RGB PNG をエンコードしてデコード。寸法・チャンネル・フォーマットを検証。
test "PngDecoder: decode RGB image" {
    const W = 4;
    const H = 4;
    var pixels = [_]u8{200} ** (W * H * 3); // 4×4 グレー RGB

    var png_ptr: ?[*]u8 = null;
    var png_len: c_ulong = 0;
    const enc = pict_png_encode(@as([*]const u8, &pixels), W, H, 3, &png_ptr, &png_len);
    try std.testing.expectEqual(@as(c_int, 0), enc);
    defer if (png_ptr) |p| pict_png_free(p);

    const png_slice = png_ptr.?[0..png_len];

    var dec = pngDecoder();
    defer dec.deinit();

    var buf = try dec.decode(png_slice, std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, W), buf.width);
    try std.testing.expectEqual(@as(u32, H), buf.height);
    try std.testing.expectEqual(@as(u8, 3), buf.channels);
    try std.testing.expectEqual(PixelFormat.rgb8, buf.format);
    try std.testing.expectEqual(W * H * 3, buf.data.len);
}

// 4×4 RGBA PNG をエンコードしてデコード。alpha チャンネルが正しく復元されること。
test "PngDecoder: decode RGBA image" {
    const W = 4;
    const H = 4;
    var pixels = [_]u8{ 100, 150, 200, 255 } ** (W * H); // 半透明ブルー RGBA

    var png_ptr: ?[*]u8 = null;
    var png_len: c_ulong = 0;
    const enc = pict_png_encode(@as([*]const u8, &pixels), W, H, 4, &png_ptr, &png_len);
    try std.testing.expectEqual(@as(c_int, 0), enc);
    defer if (png_ptr) |p| pict_png_free(p);

    const png_slice = png_ptr.?[0..png_len];

    var dec = pngDecoder();
    defer dec.deinit();

    var buf = try dec.decode(png_slice, std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, W), buf.width);
    try std.testing.expectEqual(@as(u32, H), buf.height);
    try std.testing.expectEqual(@as(u8, 4), buf.channels);
    try std.testing.expectEqual(PixelFormat.rgba8, buf.format);
    try std.testing.expectEqual(W * H * 4, buf.data.len);
}

// detectFormat が .png を返すバイト列を PngDecoder がデコードできること。
test "PngDecoder: detectFormat and decode consistency" {
    const W = 2;
    const H = 2;
    var pixels = [_]u8{ 0, 255, 0 } ** (W * H); // 緑 RGB

    var png_ptr: ?[*]u8 = null;
    var png_len: c_ulong = 0;
    const enc = pict_png_encode(@as([*]const u8, &pixels), W, H, 3, &png_ptr, &png_len);
    try std.testing.expectEqual(@as(c_int, 0), enc);
    defer if (png_ptr) |p| pict_png_free(p);

    const png_slice = png_ptr.?[0..png_len];
    try std.testing.expectEqual(Format.png, detectFormat(png_slice));

    var dec = pngDecoder();
    defer dec.deinit();

    var buf = try dec.decode(png_slice, std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, W), buf.width);
    try std.testing.expectEqual(@as(u32, H), buf.height);
}

// 壊れたバイト列を渡すと CorruptData が返ること。
test "PngDecoder: corrupt data returns CorruptData" {
    const garbage = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03 };

    var dec = pngDecoder();
    defer dec.deinit();

    const result = dec.decode(&garbage, std.testing.allocator);
    try std.testing.expectError(DecodeError.CorruptData, result);
}
