/// encode.zig — Encoder 抽象化レイヤー
///
/// decode.zig と対称的な vtable 設計。

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

// ─────────────────────────────────────────────────────────────────────────────
// libwebp C bridge (extern 宣言)
// src/c/webp_encode.c で実装。
// ─────────────────────────────────────────────────────────────────────────────

extern fn pict_webp_encode(
    pixels: [*]const u8,
    width: c_int,
    height: c_int,
    channels: c_int,
    quality: f32,
    lossless: c_int,
    out_data: *[*]u8,
    out_len: *usize,
) c_int;

extern fn pict_webp_free(data: [*]u8) void;

// ─────────────────────────────────────────────────────────────────────────────
// WebPEncoder — libwebp を使う Encoder 実装
// ─────────────────────────────────────────────────────────────────────────────

/// libwebp を使って ImageBuffer を WebP にエンコードする Encoder 実装。
///
/// - 入力は rgb8 (channels=3) または rgba8 (channels=4) を受け付ける。
/// - options.webp.lossless = true でロスレス出力。
/// - 出力バイト列は allocator で管理された EncodedBuffer に格納される。
pub const WebPEncoder = struct {
    pub const vtable = Encoder.VTable{
        .encode = encodeImpl,
        .deinit = deinitImpl,
    };

    fn encodeImpl(
        ptr: *anyopaque,
        image: decode.ImageBuffer,
        options: EncodeOptions,
        allocator: std.mem.Allocator,
    ) EncodeError!EncodedBuffer {
        _ = ptr;

        if (image.channels != 3 and image.channels != 4)
            return EncodeError.InvalidInput;

        const opts = options.webp;
        var out_data: [*]u8 = undefined;
        var out_len: usize = 0;

        const result = pict_webp_encode(
            image.data.ptr,
            @intCast(image.width),
            @intCast(image.height),
            @intCast(image.channels),
            opts.quality,
            if (opts.lossless) @as(c_int, 1) else 0,
            &out_data,
            &out_len,
        );

        if (result != 0) return EncodeError.EncodingFailed;

        const webp_slice = out_data[0..out_len];
        defer pict_webp_free(out_data);

        const zig_buf = try allocator.alloc(u8, out_len);
        errdefer allocator.free(zig_buf);
        @memcpy(zig_buf, webp_slice);

        return EncodedBuffer{
            .format = .webp,
            .data = zig_buf,
            .allocator = allocator,
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// libwebp で ImageBuffer を WebP にエンコードする Encoder を返す。
pub fn webpEncoder() Encoder {
    const Anchor = struct {
        var byte: u8 = 0;
    };
    return .{
        .ptr = &Anchor.byte,
        .vtable = &WebPEncoder.vtable,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// テスト
// ─────────────────────────────────────────────────────────────────────────────

test "WebPEncoder: encode RGB image (lossy)" {
    // 8×8 赤の RGB 画像
    const W = 8;
    const H = 8;
    var pixels = [_]u8{ 255, 0, 0 } ** (W * H);

    const img = decode.ImageBuffer{
        .width = W,
        .height = H,
        .channels = 3,
        .format = .rgb8,
        .data = &pixels,
        .allocator = std.testing.allocator,
    };

    var enc = webpEncoder();
    defer enc.deinit();

    var out = try enc.encode(img, .{ .webp = .{ .quality = 80.0 } }, std.testing.allocator);
    defer out.deinit();

    try std.testing.expectEqual(OutputFormat.webp, out.format);
    try std.testing.expect(out.data.len > 0);
    // WebP ファイルは "RIFF" マジックで始まる
    try std.testing.expectEqualSlices(u8, "RIFF", out.data[0..4]);
}

test "WebPEncoder: encode RGBA image (lossless)" {
    const W = 4;
    const H = 4;
    var pixels = [_]u8{ 0, 128, 255, 200 } ** (W * H); // 半透明ブルー RGBA

    const img = decode.ImageBuffer{
        .width = W,
        .height = H,
        .channels = 4,
        .format = .rgba8,
        .data = &pixels,
        .allocator = std.testing.allocator,
    };

    var enc = webpEncoder();
    defer enc.deinit();

    var out = try enc.encode(img, .{ .webp = .{ .lossless = true } }, std.testing.allocator);
    defer out.deinit();

    try std.testing.expectEqual(OutputFormat.webp, out.format);
    try std.testing.expect(out.data.len > 0);
    try std.testing.expectEqualSlices(u8, "RIFF", out.data[0..4]);
}

test "WebPEncoder: invalid channel count returns InvalidInput" {
    var pixels = [_]u8{0} ** (4 * 4 * 2); // 2ch は非対応
    const img = decode.ImageBuffer{
        .width = 4,
        .height = 4,
        .channels = 2,
        .format = .rgb8,
        .data = &pixels,
        .allocator = std.testing.allocator,
    };

    var enc = webpEncoder();
    defer enc.deinit();

    const result = enc.encode(img, .{ .webp = .{} }, std.testing.allocator);
    try std.testing.expectError(EncodeError.InvalidInput, result);
}
