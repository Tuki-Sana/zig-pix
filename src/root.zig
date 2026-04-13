/// root.zig — ライブラリエントリポイント
///
/// FFI (.so / .dylib) および Wasm モジュールとして公開するシンボルはここで管理する。
/// CLI は main.zig からこのモジュールを import する。

const std = @import("std");

// ── パイプラインモジュール (公開 API) ─────────────────────────────────────────
pub const decode = @import("pipeline/decode.zig");
pub const encode = @import("pipeline/encode.zig");
pub const resize = @import("pipeline/resize.zig");

// ── メモリ管理モジュール ───────────────────────────────────────────────────────
pub const mem = struct {
    pub const ring = @import("mem/ring.zig");
    pub const tile = @import("mem/tile.zig");
};

// ── プラットフォーム抽象 ───────────────────────────────────────────────────────
pub const platform = @import("platform.zig");

// ─────────────────────────────────────────────────────────────────────────────
// Phase 6 — FFI 公開シンボル
//
// C-compatible API: Bun / Node.js / Python 等の FFI から呼び出せる。
// メモリ管理:
//   - 返却ポインタは c_allocator (malloc/free) で確保する。
//   - 呼び出し元は使用後に pict_free_buffer(ptr, len) で解放する。
//   - エラー時は null を返す。
//
// C シグネチャ (参照用):
//   uint8_t* pict_decode(const uint8_t* data, size_t len,
//                        uint32_t* out_w, uint32_t* out_h, uint8_t* out_ch);
//   uint8_t* pict_resize(const uint8_t* src,
//                        uint32_t src_w, uint32_t src_h, uint8_t channels,
//                        uint32_t dst_w, uint32_t dst_h, uint32_t n_threads,
//                        size_t* out_len);
//   uint8_t* pict_encode_webp(const uint8_t* pixels,
//                             uint32_t width, uint32_t height, uint8_t channels,
//                             float quality, bool lossless,
//                             size_t* out_len);
//   void pict_free_buffer(uint8_t* ptr, size_t len);
// ─────────────────────────────────────────────────────────────────────────────

const ffi_alloc = std.heap.c_allocator;

/// JPEG または PNG をデコードして RGBA/RGB ピクセル列を返す。
/// 成功時: ピクセルデータへのポインタ (pict_free_buffer で解放)。
/// 失敗時: null。
export fn pict_decode(
    data: [*]const u8,
    len: usize,
    out_w: *u32,
    out_h: *u32,
    out_ch: *u8,
) ?[*]u8 {
    const slice = data[0..len];
    const fmt = decode.detectFormat(slice);
    var decoder = switch (fmt) {
        .jpeg => decode.jpegDecoder(),
        .png  => decode.pngDecoder(),
        .unknown => return null,
    };
    defer decoder.deinit();

    var buf = decoder.decode(slice, ffi_alloc) catch return null;
    // 所有権を caller に移す: deinit を呼ばず、buf.data をそのまま返す。
    // buf.allocator は ffi_alloc (c_allocator) なので pict_free_buffer で解放可能。
    out_w.* = buf.width;
    out_h.* = buf.height;
    out_ch.* = buf.channels;
    const ptr = buf.data.ptr;
    buf.data = &[_]u8{}; // deinit が free しないよう長さを 0 に
    return ptr;
}

/// ピクセルデータを Lanczos-3 でリサイズする。
/// 成功時: リサイズ済みピクセルデータ (pict_free_buffer で解放)。
/// 失敗時: null。
export fn pict_resize(
    src: [*]const u8,
    src_w: u32,
    src_h: u32,
    channels: u8,
    dst_w: u32,
    dst_h: u32,
    n_threads: u32,
    out_len: *usize,
) ?[*]u8 {
    if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0 or channels == 0) return null;
    const dst_size = @as(usize, dst_w) * dst_h * channels;
    const dst_buf = ffi_alloc.alloc(u8, dst_size) catch return null;
    errdefer ffi_alloc.free(dst_buf);

    resize.resizeLanczos3(ffi_alloc, src[0 .. @as(usize, src_w) * src_h * channels], dst_buf, .{
        .src_width  = src_w,
        .src_height = src_h,
        .dst_width  = dst_w,
        .dst_height = dst_h,
        .channels   = channels,
        .n_threads  = n_threads,
    }) catch {
        ffi_alloc.free(dst_buf);
        return null;
    };

    out_len.* = dst_size;
    return dst_buf.ptr;
}

/// ピクセルデータを WebP にエンコードする。
/// 成功時: WebP バイト列 (pict_free_buffer で解放)。
/// 失敗時: null。
export fn pict_encode_webp(
    pixels: [*]const u8,
    width: u32,
    height: u32,
    channels: u8,
    quality: f32,
    lossless: bool,
    out_len: *usize,
) ?[*]u8 {
    const img = decode.ImageBuffer{
        .width     = width,
        .height    = height,
        .channels  = channels,
        .format    = if (channels == 4) .rgba8 else .rgb8,
        .data      = @constCast(pixels[0 .. @as(usize, width) * height * channels]),
        .allocator = ffi_alloc,
    };

    var encoder = encode.webpEncoder();
    defer encoder.deinit();

    var encoded = encoder.encode(img, .{ .webp = .{
        .quality  = quality,
        .lossless = lossless,
    } }, ffi_alloc) catch return null;

    out_len.* = encoded.data.len;
    const ptr = encoded.data.ptr;
    encoded.data = &[_]u8{}; // deinit が free しないよう長さを 0 に
    return ptr;
}

/// pict_decode / pict_resize / pict_encode_webp が返したバッファを解放する。
export fn pict_free_buffer(ptr: [*]u8, len: usize) void {
    ffi_alloc.free(ptr[0..len]);
}

// ── テスト集約 ─────────────────────────────────────────────────────────────────
// `zig build test` でサブモジュールのテストもすべて走らせる
test {
    _ = decode;
    _ = encode;
    _ = resize;
    _ = mem.ring;
    _ = mem.tile;
    _ = platform;
    std.testing.refAllDecls(@This());
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 6 FFI ユニットテスト
// ─────────────────────────────────────────────────────────────────────────────

test "pict_resize: 4x4 RGBA を 2x2 にリサイズ" {
    // 4×4 RGBA の単色 (赤) ピクセル
    const W: u32 = 4;
    const H: u32 = 4;
    const CH: u8 = 4;
    var src = [_]u8{255} ** (W * H * CH);
    for (0..W * H) |i| {
        src[i * CH + 0] = 255; // R
        src[i * CH + 1] = 0;   // G
        src[i * CH + 2] = 0;   // B
        src[i * CH + 3] = 255; // A
    }
    var out_len: usize = 0;
    const ptr = pict_resize(src[0..].ptr, W, H, CH, 2, 2, 1, &out_len) orelse
        return error.ResizeFailed;
    defer pict_free_buffer(ptr, out_len);

    try std.testing.expectEqual(@as(usize, 2 * 2 * CH), out_len);
    // 単色画像をリサイズしても赤成分は 255 のまま
    try std.testing.expect(ptr[0] > 200); // R
}

test "pict_resize: 不正な dst_w=0 は null を返す" {
    var src = [_]u8{0} ** (4 * 4 * 4);
    var out_len: usize = 0;
    const ptr = pict_resize(src[0..].ptr, 4, 4, 4, 0, 4, 1, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

test "pict_encode_webp: 4x4 RGBA を WebP にエンコード" {
    const W: u32 = 4;
    const H: u32 = 4;
    const CH: u8 = 4;
    var src = [_]u8{128} ** (W * H * CH);
    var out_len: usize = 0;
    const ptr = pict_encode_webp(src[0..].ptr, W, H, CH, 80.0, false, &out_len) orelse
        return error.EncodeFailed;
    defer pict_free_buffer(ptr, out_len);

    // WebP ヘッダ: "RIFF" (52 49 46 46)
    try std.testing.expect(out_len > 12);
    try std.testing.expectEqual(@as(u8, 'R'), ptr[0]);
    try std.testing.expectEqual(@as(u8, 'I'), ptr[1]);
    try std.testing.expectEqual(@as(u8, 'F'), ptr[2]);
    try std.testing.expectEqual(@as(u8, 'F'), ptr[3]);
}

test "pict_decode: 不正データは null を返す" {
    const bad = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04 };
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_ch: u8 = 0;
    const ptr = pict_decode(bad[0..].ptr, bad.len, &out_w, &out_h, &out_ch);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}
