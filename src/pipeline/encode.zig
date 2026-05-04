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
    avif,
    png,
};

pub const WebPOptions = struct {
    /// 品質 0..100 (100 = lossless に近い。イラスト向けデフォルト: 92)
    quality: f32 = 92.0,
    /// true = ロスレス (ファイルサイズは大きくなる)
    lossless: bool = false,
    /// エンコーダ内スレッド数 (0 = 自動)
    thread_level: u8 = 0,
};

pub const AvifOptions = struct {
    /// 品質 0..100 (libavif 規約: 高いほど高品質。デフォルト: 60)
    quality: u8 = 60,
    /// エンコーダスピード 0..10 (10 = 最速 / 最低品質努力)
    speed: u8 = 6,
    /// エンコーダスレッド数（デフォルト: 1 = シングルスレッド）
    threads: u8 = 1,
};

pub const PngOptions = struct {
    /// zlib 圧縮レベル 0..9 (0=無圧縮, 9=最高圧縮, デフォルト: 6)
    compression: u8 = 6,
};

pub const EncodeOptions = union(OutputFormat) {
    webp: WebPOptions,
    avif: AvifOptions,
    png: PngOptions,
};

pub const EncodeError = error{
    EncodingFailed,
    UnsupportedFormat,
    InvalidInput,
    OutOfMemory,
    AvifDisabled,
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

/// `image.icc` を WebP ICCP に載せる経路（mux）。`pict_webp_free` で解放。
extern fn pict_webp_encode_with_icc(
    pixels: [*]const u8,
    width: c_int,
    height: c_int,
    channels: c_int,
    quality: f32,
    lossless: c_int,
    icc: [*]const u8,
    icc_len: c_uint,
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
/// - `image.icc` があれば WebP の ICCP チャンクに埋め込む（無ければ従来どおり裸ビットストリーム相当の RIFF）。
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

        const result: c_int = if (image.icc) |icc| blk: {
            if (icc.len == 0 or icc.len > @as(usize, @intCast(std.math.maxInt(c_uint)))) {
                return EncodeError.InvalidInput;
            }
            break :blk pict_webp_encode_with_icc(
                image.data.ptr,
                @intCast(image.width),
                @intCast(image.height),
                @intCast(image.channels),
                opts.quality,
                if (opts.lossless) @as(c_int, 1) else 0,
                icc.ptr,
                @intCast(icc.len),
                &out_data,
                &out_len,
            );
        } else blk: {
            break :blk pict_webp_encode(
                image.data.ptr,
                @intCast(image.width),
                @intCast(image.height),
                @intCast(image.channels),
                opts.quality,
                if (opts.lossless) @as(c_int, 1) else 0,
                &out_data,
                &out_len,
            );
        };

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
// libavif C bridge (extern 宣言)
// has_avif=false のターゲット (unit_tests, ffi_lib 等) ではシンボル参照を
// comptime で完全に除去することでリンクエラーを防ぐ。
// ─────────────────────────────────────────────────────────────────────────────

const has_avif = @import("avif_options").has_avif;

const avif_c = if (has_avif) struct {
    extern fn pict_avif_encode(
        pixels: [*]const u8,
        width: u32,
        height: u32,
        channels: c_int,
        quality: c_int,
        speed: c_int,
        threads: c_int,
        icc: ?[*]const u8,
        icc_len: usize,
        out_data: *[*]u8,
        out_size: *usize,
    ) c_int;
    extern fn pict_avif_free(data: [*]u8) void;
} else struct {};

// ─────────────────────────────────────────────────────────────────────────────
// AvifEncoder — libavif + aom を使う Encoder 実装
// ─────────────────────────────────────────────────────────────────────────────

/// libavif で ImageBuffer を AVIF にエンコードする Encoder 実装。
///
/// - 入力は rgb8 (channels=3) または rgba8 (channels=4) を受け付ける。
/// - has_avif=false のビルドでは encode() が error.AvifDisabled を返す。
pub const AvifEncoder = struct {
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

        if (comptime !has_avif) return EncodeError.AvifDisabled;

        if (image.channels != 3 and image.channels != 4)
            return EncodeError.InvalidInput;

        const opts = options.avif;
        var out_data: [*]u8 = undefined;
        var out_size: usize = 0;

        const icc_ptr: ?[*]const u8 = if (image.icc) |b| b.ptr else null;
        const icc_len: usize = if (image.icc) |b| b.len else 0;

        const result = avif_c.pict_avif_encode(
            image.data.ptr,
            image.width,
            image.height,
            @intCast(image.channels),
            @intCast(opts.quality),
            @intCast(opts.speed),
            @intCast(opts.threads),
            icc_ptr,
            icc_len,
            &out_data,
            &out_size,
        );

        if (result != 0) return EncodeError.EncodingFailed;

        const avif_slice = out_data[0..out_size];
        defer avif_c.pict_avif_free(out_data);

        const zig_buf = try allocator.alloc(u8, out_size);
        errdefer allocator.free(zig_buf);
        @memcpy(zig_buf, avif_slice);

        return EncodedBuffer{
            .format    = .avif,
            .data      = zig_buf,
            .allocator = allocator,
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// libavif で ImageBuffer を AVIF にエンコードする Encoder を返す。
/// has_avif=false のビルドでは encode() が error.AvifDisabled を返す。
pub fn avifEncoder() Encoder {
    const Anchor = struct {
        var byte: u8 = 0;
    };
    return .{
        .ptr = &Anchor.byte,
        .vtable = &AvifEncoder.vtable,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// libpng C bridge (extern 宣言)
// src/c/png_decode.c で実装。
// ─────────────────────────────────────────────────────────────────────────────

extern fn pict_png_encode(
    pixels: [*]const u8,
    width: c_uint,
    height: c_uint,
    channels: c_uint,
    compression: c_int,
    icc: ?[*]const u8,
    icc_len: usize,
    out_png: *[*]u8,
    out_len: *usize,
) c_int;

extern fn pict_png_free(data: [*]u8) void;

// ─────────────────────────────────────────────────────────────────────────────
// PngEncoder — libpng を使う Encoder 実装
// ─────────────────────────────────────────────────────────────────────────────

/// libpng を使って ImageBuffer を PNG にエンコードする Encoder 実装。
///
/// - 入力は rgb8 (channels=3) または rgba8 (channels=4) を受け付ける。
/// - options.png.compression で zlib 圧縮レベル (0-9) を指定。
/// - `image.icc` があれば PNG の iCCP チャンクに埋め込む。
pub const PngEncoder = struct {
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

        const opts = options.png;
        var out_data: [*]u8 = undefined;
        var out_len: usize = 0;

        const icc_ptr: ?[*]const u8 = if (image.icc) |b| b.ptr else null;
        const icc_len: usize = if (image.icc) |b| b.len else 0;

        const result = pict_png_encode(
            image.data.ptr,
            @intCast(image.width),
            @intCast(image.height),
            @intCast(image.channels),
            @intCast(opts.compression),
            icc_ptr,
            icc_len,
            &out_data,
            &out_len,
        );

        if (result != 0) return EncodeError.EncodingFailed;

        const png_slice = out_data[0..out_len];
        defer pict_png_free(out_data);

        const zig_buf = try allocator.alloc(u8, out_len);
        errdefer allocator.free(zig_buf);
        @memcpy(zig_buf, png_slice);

        return EncodedBuffer{
            .format = .png,
            .data = zig_buf,
            .allocator = allocator,
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// libpng で ImageBuffer を PNG にエンコードする Encoder を返す。
pub fn pngEncoder() Encoder {
    const Anchor = struct {
        var byte: u8 = 0;
    };
    return .{
        .ptr = &Anchor.byte,
        .vtable = &PngEncoder.vtable,
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

test "AvifEncoder: has_avif=false returns AvifDisabled" {
    // has_avif=true のビルド (CLI/ffi_lib) ではこのテストをスキップする。
    // has_avif=false (unit_tests) でのみ AvifDisabled 契約を検証する。
    if (comptime has_avif) return error.SkipZigTest;

    const W = 4;
    const H = 4;
    var pixels = [_]u8{128} ** (W * H * 4);
    const img = decode.ImageBuffer{
        .width     = W,
        .height    = H,
        .channels  = 4,
        .format    = .rgba8,
        .data      = &pixels,
        .allocator = std.testing.allocator,
    };

    var enc = avifEncoder();
    defer enc.deinit();

    const result = enc.encode(img, .{ .avif = .{} }, std.testing.allocator);
    try std.testing.expectError(EncodeError.AvifDisabled, result);
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

test "WebP encode then WebpDecoder: RGB roundtrip dimensions" {
    const W = 5;
    const H = 5;
    var pixels = [_]u8{33} ** (W * H * 3);

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
    var encoded = try enc.encode(img, .{ .webp = .{ .quality = 90.0 } }, std.testing.allocator);
    defer encoded.deinit();

    try std.testing.expectEqual(decode.Format.webp, decode.detectFormat(encoded.data));

    var wdec = decode.webpDecoder();
    defer wdec.deinit();

    var dec_buf = try wdec.decode(encoded.data, std.testing.allocator);
    defer dec_buf.deinit();

    try std.testing.expectEqual(@as(u32, W), dec_buf.width);
    try std.testing.expectEqual(@as(u32, H), dec_buf.height);
    try std.testing.expectEqual(@as(u8, 3), dec_buf.channels);
    try std.testing.expectEqual(decode.PixelFormat.rgb8, dec_buf.format);
}

test "WebP encode then WebpDecoder: RGBA lossless roundtrip" {
    const W = 3;
    const H = 3;
    var pixels = [_]u8{ 11, 22, 33, 220 } ** (W * H);

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
    var encoded = try enc.encode(img, .{ .webp = .{ .lossless = true } }, std.testing.allocator);
    defer encoded.deinit();

    var wdec = decode.webpDecoder();
    defer wdec.deinit();

    var dec_buf = try wdec.decode(encoded.data, std.testing.allocator);
    defer dec_buf.deinit();

    try std.testing.expectEqual(@as(u32, W), dec_buf.width);
    try std.testing.expectEqual(@as(u32, H), dec_buf.height);
    try std.testing.expectEqual(@as(u8, 4), dec_buf.channels);
    try std.testing.expectEqual(decode.PixelFormat.rgba8, dec_buf.format);
}

test "PngEncoder: encode RGB image" {
    const W = 4;
    const H = 4;
    var pixels = [_]u8{ 255, 0, 0 } ** (W * H);
    const img = decode.ImageBuffer{
        .width = W, .height = H, .channels = 3,
        .format = .rgb8, .data = &pixels,
        .allocator = std.testing.allocator,
    };
    var enc = pngEncoder();
    defer enc.deinit();
    var out = try enc.encode(img, .{ .png = .{} }, std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(OutputFormat.png, out.format);
    try std.testing.expect(out.data.len > 0);
    // PNG マジック: \x89PNG
    try std.testing.expectEqual(@as(u8, 0x89), out.data[0]);
    try std.testing.expectEqualSlices(u8, "PNG", out.data[1..4]);
}

test "PngEncoder: encode RGBA image" {
    const W = 2;
    const H = 2;
    var pixels = [_]u8{ 0, 128, 255, 200 } ** (W * H);
    const img = decode.ImageBuffer{
        .width = W, .height = H, .channels = 4,
        .format = .rgba8, .data = &pixels,
        .allocator = std.testing.allocator,
    };
    var enc = pngEncoder();
    defer enc.deinit();
    var out = try enc.encode(img, .{ .png = .{} }, std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(out.data.len > 0);
    try std.testing.expectEqual(@as(u8, 0x89), out.data[0]);
}

test "PngEncoder: compression=0 larger than compression=9" {
    const W = 16;
    const H = 16;
    var pixels = [_]u8{128} ** (W * H * 3);
    const img = decode.ImageBuffer{
        .width = W, .height = H, .channels = 3,
        .format = .rgb8, .data = &pixels,
        .allocator = std.testing.allocator,
    };
    var enc = pngEncoder();
    defer enc.deinit();
    var out0 = try enc.encode(img, .{ .png = .{ .compression = 0 } }, std.testing.allocator);
    defer out0.deinit();
    var out9 = try enc.encode(img, .{ .png = .{ .compression = 9 } }, std.testing.allocator);
    defer out9.deinit();
    try std.testing.expect(out0.data.len >= out9.data.len);
}

test "PngEncoder: ICC profile embedded in iCCP chunk" {
    const W = 2;
    const H = 2;
    var pixels = [_]u8{50} ** (W * H * 3);
    // libpng は ICC プロファイルを検証する（最低 132 バイト、'acsp' シグネチャ、D50 照明体など必須）。
    // ICC v2 最小構造: size(4) + cmm(4) + ver(4) + class(4) + cs(4) + pcs(4) + date(12)
    //                  + 'acsp'(4) + platform(4) + flags(4) + mfr(4) + model(4) + attr(8)
    //                  + intent(4) + illuminant(12) + creator(4) + id(16) + reserved(28) + tagCount(4)
    var icc = [_]u8{0} ** 132;
    icc[3] = 0x84;                                        // size = 132
    icc[8] = 0x02;                                        // version major = 2
    icc[12] = 0x6D; icc[13] = 0x6E; icc[14] = 0x74; icc[15] = 0x72; // 'mntr'
    icc[16] = 0x52; icc[17] = 0x47; icc[18] = 0x42; icc[19] = 0x20; // 'RGB '
    icc[20] = 0x58; icc[21] = 0x59; icc[22] = 0x5A; icc[23] = 0x20; // 'XYZ '
    icc[36] = 0x61; icc[37] = 0x63; icc[38] = 0x73; icc[39] = 0x70; // 'acsp'
    // D50 illuminant XYZ (libpng が ±5 以内を要求)
    icc[70] = 0xF6; icc[71] = 0xD6; // X = 0x0000F6D6
    icc[73] = 0x01;                  // Y = 0x00010000
    icc[78] = 0xD3; icc[79] = 0x2D; // Z = 0x0000D32D
    // tag count = 0 (bytes 128-131 already 0)
    const img = decode.ImageBuffer{
        .width = W, .height = H, .channels = 3,
        .format = .rgb8, .data = &pixels,
        .icc = &icc,
        .allocator = std.testing.allocator,
    };
    var enc = pngEncoder();
    defer enc.deinit();
    var out = try enc.encode(img, .{ .png = .{} }, std.testing.allocator);
    defer out.deinit();
    // iCCP チャンク ("iCCP") が PNG バイト列内に存在することを確認
    const png_bytes = out.data;
    var found = false;
    var i: usize = 8; // PNG シグネチャ 8 バイトを跳ばす
    while (i + 12 <= png_bytes.len) {
        if (std.mem.eql(u8, png_bytes[i + 4 .. i + 8], "iCCP")) {
            found = true;
            break;
        }
        const chunk_len = std.mem.readInt(u32, png_bytes[i..][0..4], .big);
        i += 12 + chunk_len; // length(4) + type(4) + data(chunk_len) + crc(4)
    }
    try std.testing.expect(found);
}

test "PngEncoder: invalid channel count returns InvalidInput" {
    var pixels = [_]u8{0} ** (4 * 4 * 2);
    const img = decode.ImageBuffer{
        .width = 4, .height = 4, .channels = 2,
        .format = .rgb8, .data = &pixels,
        .allocator = std.testing.allocator,
    };
    var enc = pngEncoder();
    defer enc.deinit();
    const result = enc.encode(img, .{ .png = .{} }, std.testing.allocator);
    try std.testing.expectError(EncodeError.InvalidInput, result);
}

test "WebPEncoder: ImageBuffer.icc embedded as WebP ICCP" {
    const W = 4;
    const H = 4;
    var pixels = [_]u8{50} ** (W * H * 3);
    var dummy_icc: [128]u8 = undefined;
    for (&dummy_icc, 0..) |*b, i| b.* = @intCast(i & 0xff);

    const img = decode.ImageBuffer{
        .width = W,
        .height = H,
        .channels = 3,
        .format = .rgb8,
        .data = &pixels,
        .icc = &dummy_icc,
        .allocator = std.testing.allocator,
    };

    var enc = webpEncoder();
    defer enc.deinit();
    var encoded = try enc.encode(img, .{ .webp = .{ .quality = 85.0 } }, std.testing.allocator);
    defer encoded.deinit();

    var wdec = decode.webpDecoder();
    defer wdec.deinit();
    var dec_buf = try wdec.decode(encoded.data, std.testing.allocator);
    defer dec_buf.deinit();

    try std.testing.expect(dec_buf.icc != null);
    try std.testing.expectEqual(dummy_icc.len, dec_buf.icc.?.len);
    try std.testing.expectEqualSlices(u8, &dummy_icc, dec_buf.icc.?);
}
