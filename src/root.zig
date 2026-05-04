/// root.zig — ライブラリエントリポイント
///
/// FFI (.so / .dylib) および Wasm モジュールとして公開するシンボルはここで管理する。
/// CLI は main.zig からこのモジュールを import する。

const std = @import("std");

// ── パイプラインモジュール (公開 API) ─────────────────────────────────────────
pub const decode = @import("pipeline/decode.zig");
pub const encode = @import("pipeline/encode.zig");
pub const resize = @import("pipeline/resize.zig");
pub const crop   = @import("pipeline/crop.zig");
pub const rotate = @import("pipeline/rotate.zig");

const has_avif = @import("avif_options").has_avif;

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
//
// メモリ管理:
//   - 返却ポインタは c_allocator (malloc/free) で確保する。
//   - 呼び出し元は使用後に pict_free_buffer(ptr, len) で解放する。
//   - エラー時は null を返す。out_len は失敗時に変更しない。
//   - out_w / out_h / out_ch は失敗時に未定義 (呼び出し元は null 返却後に読まない)。
//
// NULL 耐性:
//   - 入力ポインタ (data/src/pixels) は [*c]const u8 — null チェックあり。
//   - 出力ポインタ (out_w/out_h/out_ch/out_len) は ?*T — null チェックあり。
//
// C シグネチャ (参照用):
//   uint8_t* pict_decode(const uint8_t* data, size_t len,       // @deprecated
//                        uint32_t* out_w, uint32_t* out_h, uint8_t* out_ch);
//   uint8_t* pict_decode_v2(const uint8_t* data, size_t len,
//                           uint32_t* out_w, uint32_t* out_h, uint8_t* out_ch,
//                           size_t* out_len);
//   uint8_t* pict_decode_v3(const uint8_t* data, size_t len,
//                           uint32_t* out_w, uint32_t* out_h, uint8_t* out_ch,
//                           size_t* out_len,
//                           uint8_t** out_icc, size_t* out_icc_len);
//   // out_icc / out_icc_len: 両方 NULL なら v2 と同様 ICC は破棄。
//   // 両方非 NULL なら、埋め込み ICC があるとき *out_icc を割り当て *out_icc_len を設定（無ければ NULL/0）。
//   // *out_icc は pict_free_buffer(*out_icc, *out_icc_len) で解放。
//   uint8_t* pict_resize(const uint8_t* src,
//                        uint32_t src_w, uint32_t src_h, uint8_t channels,
//                        uint32_t dst_w, uint32_t dst_h, uint32_t n_threads,
//                        size_t* out_len);
//   uint8_t* pict_encode_webp(const uint8_t* pixels, ...);  // ICC なし（後方互換）
//   uint8_t* pict_encode_webp_v2(..., const uint8_t* icc, size_t icc_len);
//   // icc == NULL または icc_len == 0 で従来と同じ。それ以外は WebP ICCP に埋め込む。
//   uint8_t* pict_encode_avif(const uint8_t* pixels,
//                             uint32_t width, uint32_t height, uint8_t channels,
//                             uint8_t quality, uint8_t speed,
//                             size_t* out_len);
//   void pict_free_buffer(uint8_t* ptr, size_t len);
// ─────────────────────────────────────────────────────────────────────────────

const ffi_alloc = std.heap.c_allocator;

/// a * b * c をオーバーフローチェック付きで計算する。
/// いずれかの段でオーバーフローした場合は null を返す。
inline fn mul3SizeChecked(a: usize, b: usize, c: usize) ?usize {
    const ab = @mulWithOverflow(a, b);
    if (ab[1] != 0) return null;
    const abc = @mulWithOverflow(ab[0], c);
    if (abc[1] != 0) return null;
    return abc[0];
}

/// @deprecated Use pict_decode_v2 which returns out_len for safe buffer release.
/// JPEG / PNG / 静止画 WebP をデコードして RGB または RGBA ピクセル列を返す。
/// HEIC/HEIF・アニメーション WebP は非対応。
/// 成功時: ピクセルデータへのポインタ (pict_free_buffer(ptr, w*h*ch) で解放)。
/// 失敗時: null。
export fn pict_decode(
    data: [*c]const u8,
    len: usize,
    out_w: ?*u32,
    out_h: ?*u32,
    out_ch: ?*u8,
) ?[*]u8 {
    var tmp_len: usize = 0;
    return pict_decode_v2(data, len, out_w, out_h, out_ch, &tmp_len);
}

/// JPEG / PNG / 静止画 WebP をデコードして RGB または RGBA ピクセル列を返す。
/// HEIC/HEIF・アニメーション WebP は非対応。
/// 成功時: ピクセルデータへのポインタ (pict_free_buffer(ptr, out_len) で解放)。
/// 失敗時: null。out_len は変更しない。
export fn pict_decode_v2(
    data: [*c]const u8,
    len: usize,
    out_w: ?*u32,
    out_h: ?*u32,
    out_ch: ?*u8,
    out_len: ?*usize,
) ?[*]u8 {
    if (data == null or out_w == null or out_h == null or out_ch == null or out_len == null) return null;
    const slice = data[0..len];
    const fmt = decode.detectFormat(slice);
    var decoder = switch (fmt) {
        .jpeg    => decode.jpegDecoder(),
        .png     => decode.pngDecoder(),
        .webp    => decode.webpDecoder(),
        .avif    => decode.avifDecoder(),
        .gif     => decode.gifDecoder(),
        .unknown => return null,
    };
    defer decoder.deinit();

    var buf = decoder.decode(slice, ffi_alloc) catch return null;
    // 所有権を caller に移す: deinit を呼ばず buf.data をそのまま返す。
    // buf.allocator は ffi_alloc (c_allocator) なので pict_free_buffer で解放可能。
    out_w.?.* = buf.width;
    out_h.?.* = buf.height;
    out_ch.?.* = buf.channels;
    if (out_len) |ol| ol.* = buf.data.len;
    const ptr = buf.data.ptr;
    buf.data = &[_]u8{}; // deinit が free しないよう長さを 0 に
    // FFI はまだ ICC を返さない: ピクセル所有権を手放したあと Zig 側バッファのみ解放
    if (buf.icc) |icc| {
        buf.allocator.free(icc);
        buf.icc = null;
    }
    return ptr;
}

/// `pict_decode_v2` と同じだが、`out_icc` / `out_icc_len` で埋め込み ICC を返せる。
/// - 両方 NULL: ICC は破棄（v2 と同じ）。
/// - 片方だけ NULL: null を返す（どちらも渡すか、どちらも渡さないか）。
/// - 両方非 NULL: 成功時、ICC が無ければ `*out_icc = NULL`, `*out_icc_len = 0`。
///   あれば `*out_icc` / `*out_icc_len` に所有権を移し、`pict_free_buffer(*out_icc, *out_icc_len)` で解放。
export fn pict_decode_v3(
    data: [*c]const u8,
    len: usize,
    out_w: ?*u32,
    out_h: ?*u32,
    out_ch: ?*u8,
    out_len: ?*usize,
    out_icc: ?*?[*]u8,
    out_icc_len: ?*usize,
) ?[*]u8 {
    if (data == null or out_w == null or out_h == null or out_ch == null or out_len == null) return null;
    if ((out_icc == null) != (out_icc_len == null)) return null;

    const want_icc = out_icc != null and out_icc_len != null;

    const slice = data[0..len];
    const fmt = decode.detectFormat(slice);
    var decoder = switch (fmt) {
        .jpeg    => decode.jpegDecoder(),
        .png     => decode.pngDecoder(),
        .webp    => decode.webpDecoder(),
        .avif    => decode.avifDecoder(),
        .gif     => decode.gifDecoder(),
        .unknown => return null,
    };
    defer decoder.deinit();

    var buf = decoder.decode(slice, ffi_alloc) catch return null;

    out_w.?.* = buf.width;
    out_h.?.* = buf.height;
    out_ch.?.* = buf.channels;
    if (out_len) |ol| ol.* = buf.data.len;
    const ptr = buf.data.ptr;
    buf.data = &[_]u8{};

    if (want_icc) {
        out_icc.?.* = null;
        out_icc_len.?.* = 0;
        if (buf.icc) |icc| {
            out_icc.?.* = icc.ptr;
            out_icc_len.?.* = icc.len;
            buf.icc = null;
        }
    } else {
        if (buf.icc) |icc| {
            buf.allocator.free(icc);
            buf.icc = null;
        }
    }
    return ptr;
}

/// ピクセルデータを Lanczos-3 でリサイズする。
/// 成功時: リサイズ済みピクセルデータ (pict_free_buffer(ptr, out_len) で解放)。
/// 失敗時: null。out_len は変更しない。
export fn pict_resize(
    src: [*c]const u8,
    src_w: u32,
    src_h: u32,
    channels: u8,
    dst_w: u32,
    dst_h: u32,
    n_threads: u32,
    out_len: ?*usize,
) ?[*]u8 {
    if (src == null or out_len == null) return null;
    if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0 or channels == 0) return null;
    const src_size = mul3SizeChecked(src_w, src_h, channels) orelse return null;
    const dst_size = mul3SizeChecked(dst_w, dst_h, channels) orelse return null;
    const dst_buf = ffi_alloc.alloc(u8, dst_size) catch return null;

    resize.resizeLanczos3(ffi_alloc, src[0..src_size], dst_buf, .{
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

    if (out_len) |ol| ol.* = dst_size;
    return dst_buf.ptr;
}

/// `pict_resize` の fit モード対応版。
/// fit: 0=stretch (既存と同じ), 1=contain (縦横比保持、dst_w×dst_h に収まる最大), 2=cover (縦横比保持、中央クロップ)
/// out_actual_w / out_actual_h: 実際の出力寸法（contain では dst より小さくなりうる）
/// 成功時: リサイズ済みピクセルデータ (pict_free_buffer(ptr, out_len) で解放)。失敗時: null。
export fn pict_resize_v2(
    src: [*c]const u8,
    src_w: u32,
    src_h: u32,
    channels: u8,
    dst_w: u32,
    dst_h: u32,
    fit: u8,
    n_threads: u32,
    out_actual_w: ?*u32,
    out_actual_h: ?*u32,
    out_len: ?*usize,
) ?[*]u8 {
    if (src == null or out_len == null) return null;
    if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0 or channels == 0) return null;

    const FitDims = struct { actual_w: u32, actual_h: u32, scaled_w: u32, scaled_h: u32 };
    const dims: FitDims = switch (fit) {
        1 => blk: { // contain
            const sx = @as(f64, @floatFromInt(dst_w)) / @as(f64, @floatFromInt(src_w));
            const sy = @as(f64, @floatFromInt(dst_h)) / @as(f64, @floatFromInt(src_h));
            const s = @min(sx, sy);
            const aw = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src_w)) * s))));
            const ah = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src_h)) * s))));
            break :blk .{ .actual_w = aw, .actual_h = ah, .scaled_w = aw, .scaled_h = ah };
        },
        2 => blk: { // cover
            const sx = @as(f64, @floatFromInt(dst_w)) / @as(f64, @floatFromInt(src_w));
            const sy = @as(f64, @floatFromInt(dst_h)) / @as(f64, @floatFromInt(src_h));
            const s = @max(sx, sy);
            const sw = @max(dst_w, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src_w)) * s))));
            const sh = @max(dst_h, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(src_h)) * s))));
            break :blk .{ .actual_w = dst_w, .actual_h = dst_h, .scaled_w = sw, .scaled_h = sh };
        },
        else => .{ .actual_w = dst_w, .actual_h = dst_h, .scaled_w = dst_w, .scaled_h = dst_h },
    };

    const src_size = mul3SizeChecked(src_w, src_h, channels) orelse return null;

    if (fit == 2 and (dims.scaled_w != dims.actual_w or dims.scaled_h != dims.actual_h)) {
        // cover: 中間サイズにリサイズ → 中央クロップ
        const mid_size = mul3SizeChecked(dims.scaled_w, dims.scaled_h, channels) orelse return null;
        const mid_buf = ffi_alloc.alloc(u8, mid_size) catch return null;
        defer ffi_alloc.free(mid_buf);

        resize.resizeLanczos3(ffi_alloc, src[0..src_size], mid_buf, .{
            .src_width = src_w, .src_height = src_h,
            .dst_width = dims.scaled_w, .dst_height = dims.scaled_h,
            .channels = channels, .n_threads = n_threads,
        }) catch return null;

        const crop_left = (dims.scaled_w - dims.actual_w) / 2;
        const crop_top  = (dims.scaled_h - dims.actual_h) / 2;
        const ch: usize = channels;
        const dst_size = mul3SizeChecked(dims.actual_w, dims.actual_h, channels) orelse return null;
        const dst_buf = ffi_alloc.alloc(u8, dst_size) catch return null;

        for (0..dims.actual_h) |y| {
            const src_off = (crop_top + y) * dims.scaled_w * ch + crop_left * ch;
            const dst_off = y * dims.actual_w * ch;
            @memcpy(dst_buf[dst_off..][0..dims.actual_w * ch], mid_buf[src_off..][0..dims.actual_w * ch]);
        }

        if (out_actual_w) |p| p.* = dims.actual_w;
        if (out_actual_h) |p| p.* = dims.actual_h;
        out_len.?.* = dst_size;
        return dst_buf.ptr;
    }

    // stretch / contain: 直接リサイズ
    const dst_size = mul3SizeChecked(dims.actual_w, dims.actual_h, channels) orelse return null;
    const dst_buf = ffi_alloc.alloc(u8, dst_size) catch return null;

    resize.resizeLanczos3(ffi_alloc, src[0..src_size], dst_buf, .{
        .src_width = src_w, .src_height = src_h,
        .dst_width = dims.actual_w, .dst_height = dims.actual_h,
        .channels = channels, .n_threads = n_threads,
    }) catch {
        ffi_alloc.free(dst_buf);
        return null;
    };

    if (out_actual_w) |p| p.* = dims.actual_w;
    if (out_actual_h) |p| p.* = dims.actual_h;
    out_len.?.* = dst_size;
    return dst_buf.ptr;
}

/// ピクセルデータを WebP にエンコードする（埋め込み ICC なし）。`pict_encode_webp_v2(..., null, 0)` と同じ。
export fn pict_encode_webp(
    pixels: [*c]const u8,
    width: u32,
    height: u32,
    channels: u8,
    quality: f32,
    lossless: bool,
    out_len: ?*usize,
) ?[*]u8 {
    return pict_encode_webp_v2(pixels, width, height, channels, quality, lossless, null, 0, out_len);
}

/// `icc` / `icc_len` で埋め込み ICC を渡す（`icc == null` または `icc_len == 0` で ICC なし）。
export fn pict_encode_webp_v2(
    pixels: [*c]const u8,
    width: u32,
    height: u32,
    channels: u8,
    quality: f32,
    lossless: bool,
    /// 埋め込み ICC。`icc_len == 0` のときは未使用（`icc` は NULL でよい）。
    icc: ?*const u8,
    icc_len: usize,
    out_len: ?*usize,
) ?[*]u8 {
    if (pixels == null or out_len == null or width == 0 or height == 0 or channels == 0) return null;
    const pixel_size = mul3SizeChecked(width, height, channels) orelse return null;

    const icc_z: ?[]u8 = if (icc != null and icc_len > 0)
        @constCast(@as([*]const u8, @ptrCast(icc.?))[0..icc_len])
    else
        null;

    const img = decode.ImageBuffer{
        .width     = width,
        .height    = height,
        .channels  = channels,
        .format    = if (channels == 4) .rgba8 else .rgb8,
        .data      = @constCast(pixels[0..pixel_size]),
        .icc       = icc_z,
        .allocator = ffi_alloc,
    };

    var encoder = encode.webpEncoder();
    defer encoder.deinit();

    var encoded = encoder.encode(img, .{ .webp = .{
        .quality  = quality,
        .lossless = lossless,
    } }, ffi_alloc) catch return null;

    if (out_len) |ol| ol.* = encoded.data.len;
    const ptr = encoded.data.ptr;
    encoded.data = &[_]u8{};
    return ptr;
}

/// ピクセルデータを AVIF にエンコードする。
/// 成功時: AVIF バイト列 (pict_free_buffer(ptr, out_len) で解放)。
/// 失敗時: null。out_len は変更しない。
/// has_avif=false のビルド (Linux VPS 等) では常に null を返す。
export fn pict_encode_avif(
    pixels: [*c]const u8,
    width: u32,
    height: u32,
    channels: u8,
    quality: u8,
    speed: u8,
    threads: u8,
    out_len: ?*usize,
) ?[*]u8 {
    if (comptime !has_avif) return null;
    if (pixels == null or out_len == null or width == 0 or height == 0 or channels == 0) return null;
    if (channels != 3 and channels != 4) return null;
    if (quality > 100 or speed > 10) return null;
    const pixel_size = mul3SizeChecked(width, height, channels) orelse return null;

    const img = decode.ImageBuffer{
        .width     = width,
        .height    = height,
        .channels  = channels,
        .format    = if (channels == 4) .rgba8 else .rgb8,
        .data      = @constCast(pixels[0..pixel_size]),
        .icc       = null,
        .allocator = ffi_alloc,
    };

    var enc = encode.avifEncoder();
    defer enc.deinit();

    var encoded = enc.encode(img, .{ .avif = .{
        .quality = quality,
        .speed   = speed,
        .threads = threads,
    } }, ffi_alloc) catch return null;

    if (out_len) |ol| ol.* = encoded.data.len;
    const p = encoded.data.ptr;
    encoded.data = &[_]u8{};
    return p;
}

/// ピクセルデータを PNG にエンコードする。
/// compression: zlib 圧縮レベル 0-9（範囲外は C 側で 6 に clamp）。
/// icc / icc_len: 埋め込み ICC（null または icc_len==0 で省略）。
/// 成功時: PNG バイト列 (pict_free_buffer(ptr, out_len) で解放)。
/// 失敗時: null。out_len は変更しない。
export fn pict_encode_png(
    pixels: [*c]const u8,
    width: u32,
    height: u32,
    channels: u8,
    compression: u8,
    icc: ?*const u8,
    icc_len: usize,
    out_len: ?*usize,
) ?[*]u8 {
    if (pixels == null or out_len == null or width == 0 or height == 0 or channels == 0) return null;
    if (channels != 3 and channels != 4) return null;
    const pixel_size = mul3SizeChecked(width, height, channels) orelse return null;

    const icc_z: ?[]u8 = if (icc != null and icc_len > 0)
        @constCast(@as([*]const u8, @ptrCast(icc.?))[0..icc_len])
    else
        null;

    const img = decode.ImageBuffer{
        .width     = width,
        .height    = height,
        .channels  = channels,
        .format    = if (channels == 4) .rgba8 else .rgb8,
        .data      = @constCast(pixels[0..pixel_size]),
        .icc       = icc_z,
        .allocator = ffi_alloc,
    };

    var encoder = encode.pngEncoder();
    defer encoder.deinit();

    var encoded = encoder.encode(img, .{ .png = .{
        .compression = compression,
    } }, ffi_alloc) catch return null;

    if (out_len) |ol| ol.* = encoded.data.len;
    const ptr = encoded.data.ptr;
    encoded.data = &[_]u8{};
    return ptr;
}

/// ピクセルデータから矩形を切り出す。
/// 失敗時（null / ゼロ次元 / 範囲外 / OOM）: null。out_len は変更しない。
export fn pict_crop(
    pixels: [*c]const u8,
    src_w: u32,
    src_h: u32,
    channels: u8,
    left: u32,
    top: u32,
    crop_w: u32,
    crop_h: u32,
    out_len: ?*usize,
) ?[*]u8 {
    if (pixels == null or out_len == null) return null;
    if (src_w == 0 or src_h == 0 or channels == 0) return null;
    const src_size = mul3SizeChecked(src_w, src_h, channels) orelse return null;

    const dst = crop.crop(pixels[0..src_size], src_w, src_h, channels, left, top, crop_w, crop_h, ffi_alloc) catch return null;
    out_len.?.* = dst.len;
    return dst.ptr;
}

/// ピクセルデータを EXIF Orientation に従って変換する。
/// orientation=1 または不正値: null を返す（呼び出し元は元バッファをそのまま使う）。
/// それ以外: 新しいバッファを返す (pict_free_buffer(ptr, out_len) で解放)。
/// 向き 5-8 は幅高さが交換されるため out_w / out_h を必ず読むこと。
export fn pict_rotate(
    pixels: [*c]const u8,
    src_w: u32,
    src_h: u32,
    channels: u8,
    orientation: u8,
    out_w: ?*u32,
    out_h: ?*u32,
    out_len: ?*usize,
) ?[*]u8 {
    if (pixels == null or out_w == null or out_h == null or out_len == null) return null;
    if (orientation == 1 or orientation > 8) return null;
    if (src_w == 0 or src_h == 0 or channels == 0) return null;
    if (channels != 3 and channels != 4) return null;

    const src_size = mul3SizeChecked(src_w, src_h, channels) orelse return null;

    const src_buf = decode.ImageBuffer{
        .data      = @constCast(pixels[0..src_size]),
        .width     = src_w,
        .height    = src_h,
        .channels  = channels,
        .format    = if (channels == 4) .rgba8 else .rgb8,
        .icc       = null,
        .allocator = ffi_alloc,
    };

    const dst = rotate.rotate(src_buf, orientation, ffi_alloc) catch return null;
    // orientation=1 は元ポインタを返すが、ここでは orientation != 1 が保証されている
    out_w.?.* = dst.width;
    out_h.?.* = dst.height;
    out_len.?.* = dst.data.len;
    return dst.data.ptr;
}

/// pict_decode / pict_decode_v2 / pict_decode_v3 / pict_resize / pict_encode_webp / pict_encode_webp_v2 / pict_encode_avif / pict_encode_png / pict_crop / pict_rotate
/// が返したバッファを解放する。
/// pict_decode_v3 の埋め込み ICC バッファ (*out_icc) も同じくこの関数で解放する。
export fn pict_free_buffer(ptr: [*]u8, len: usize) void {
    ffi_alloc.free(ptr[0..len]);
}

// ── テスト集約 ─────────────────────────────────────────────────────────────────
// `zig build test` でサブモジュールのテストもすべて走らせる
test {
    _ = decode;
    _ = encode;
    _ = resize;
    _ = crop;
    _ = rotate;
    _ = mem.ring;
    _ = mem.tile;
    _ = platform;
    std.testing.refAllDecls(@This());
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 6 FFI ユニットテスト
// ─────────────────────────────────────────────────────────────────────────────

// pict_jpeg_orientation の extern 宣言 (src/c/jpeg_decode.c)
extern fn pict_jpeg_orientation(data: [*]const u8, len: c_ulong) u8;

// テスト内で PNG を生成するための extern 宣言 (src/c/png_decode.c を参照)
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
// 成功系 (Category C)
// ─────────────────────────────────────────────────────────────────────────────

test "pict_resize: 4x4 RGBA を 2x2 にリサイズ (成功系)" {
    const W: u32 = 4;
    const H: u32 = 4;
    const CH: u8 = 4;
    var src = [_]u8{0} ** (W * H * CH);
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
    try std.testing.expect(ptr[0] > 200); // R チャンネル: 単色なのでほぼ 255
}

test "pict_resize: out_len == dst_w * dst_h * channels (成功系)" {
    const W: u32 = 8;
    const H: u32 = 8;
    const CH: u8 = 3;
    var src = [_]u8{128} ** (W * H * CH);
    var out_len: usize = 0;
    const ptr = pict_resize(src[0..].ptr, W, H, CH, 4, 4, 1, &out_len) orelse
        return error.ResizeFailed;
    defer pict_free_buffer(ptr, out_len);
    try std.testing.expectEqual(@as(usize, 4 * 4 * CH), out_len);
}

test "pict_encode_webp: 4x4 RGBA を WebP にエンコード (成功系)" {
    const W: u32 = 4;
    const H: u32 = 4;
    const CH: u8 = 4;
    var src = [_]u8{128} ** (W * H * CH);
    var out_len: usize = 0;
    const ptr = pict_encode_webp(src[0..].ptr, W, H, CH, 80.0, false, &out_len) orelse
        return error.EncodeFailed;
    defer pict_free_buffer(ptr, out_len);

    try std.testing.expect(out_len > 12);
    try std.testing.expectEqual(@as(u8, 'R'), ptr[0]);
    try std.testing.expectEqual(@as(u8, 'I'), ptr[1]);
    try std.testing.expectEqual(@as(u8, 'F'), ptr[2]);
    try std.testing.expectEqual(@as(u8, 'F'), ptr[3]);
}

test "pict_decode_v2: PNG デコード成功 + out_len == w*h*ch (成功系)" {
    const W: c_uint = 4;
    const H: c_uint = 4;
    const CH: c_uint = 4;
    var pixels = [_]u8{ 100, 150, 200, 255 } ** (W * H);

    var png_raw: [*]u8 = undefined;
    var png_len: usize = 0;
    const rc = pict_png_encode(&pixels, W, H, CH, 6, null, 0, &png_raw, &png_len);
    try std.testing.expectEqual(@as(c_int, 0), rc); // fail fast if encode fails
    defer pict_png_free(png_raw);

    const png_slice = png_raw[0..png_len];
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_ch: u8 = 0;
    var out_len: usize = 0;
    const ptr = pict_decode_v2(png_slice.ptr, png_len, &out_w, &out_h, &out_ch, &out_len) orelse
        return error.DecodeFailed;
    defer pict_free_buffer(ptr, out_len);

    try std.testing.expect(out_w > 0);
    try std.testing.expect(out_h > 0);
    try std.testing.expect(out_ch > 0);
    try std.testing.expectEqual(@as(usize, out_w) * out_h * out_ch, out_len);
}

test "pict_decode_v2: WebP (pict_encode_webp → pict_decode_v2)" {
    const W: u32 = 4;
    const H: u32 = 4;
    const CH: u8 = 3;
    var pixels = [_]u8{88} ** (W * H * CH);
    var enc_len: usize = 0;
    const webp_ptr = pict_encode_webp(pixels[0..].ptr, W, H, CH, 80.0, false, &enc_len) orelse
        return error.EncodeFailed;
    defer pict_free_buffer(webp_ptr, enc_len);

    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_ch: u8 = 0;
    var out_len: usize = 0;
    const pix = pict_decode_v2(webp_ptr, enc_len, &out_w, &out_h, &out_ch, &out_len) orelse
        return error.DecodeFailed;
    defer pict_free_buffer(pix, out_len);

    try std.testing.expectEqual(W, out_w);
    try std.testing.expectEqual(H, out_h);
    try std.testing.expectEqual(CH, out_ch);
    try std.testing.expectEqual(@as(usize, W) * H * CH, out_len);
}

test "pict_decode_v3: iCCP 付き PNG で ICC バッファを返す" {
    const path = "vendor/libavif/tests/data/paris_icc_exif_xmp.png";
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 4 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);

    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_ch: u8 = 0;
    var out_len: usize = 0;
    var icc_ptr: ?[*]u8 = null;
    var icc_len: usize = 0;
    const pix = pict_decode_v3(bytes.ptr, bytes.len, &out_w, &out_h, &out_ch, &out_len, &icc_ptr, &icc_len) orelse
        return error.DecodeFailed;
    defer pict_free_buffer(pix, out_len);
    defer if (icc_ptr) |p| pict_free_buffer(p, icc_len);

    try std.testing.expect(icc_ptr != null);
    try std.testing.expect(icc_len >= 128);
}

test "pict_decode_v3: ICC 不要のとき out_icc は null のまま" {
    const W: c_uint = 2;
    const H: c_uint = 2;
    const CH: c_uint = 3;
    var pixels = [_]u8{ 10, 20, 30 } ** (W * H);

    var png_raw: [*]u8 = undefined;
    var png_len: usize = 0;
    const rc = pict_png_encode(&pixels, W, H, CH, 6, null, 0, &png_raw, &png_len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    defer pict_png_free(png_raw);

    const png_slice = png_raw[0..png_len];
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_ch: u8 = 0;
    var out_len: usize = 0;
    var icc_ptr: ?[*]u8 = null;
    var icc_len: usize = 0xDEAD;
    const pix = pict_decode_v3(png_slice.ptr, png_len, &out_w, &out_h, &out_ch, &out_len, &icc_ptr, &icc_len) orelse
        return error.DecodeFailed;
    defer pict_free_buffer(pix, out_len);

    try std.testing.expectEqual(@as(?[*]u8, null), icc_ptr);
    try std.testing.expectEqual(@as(usize, 0), icc_len);
}

// ─────────────────────────────────────────────────────────────────────────────
// null out arg — null 返却のみ検証 (Category A)
// ─────────────────────────────────────────────────────────────────────────────

test "pict_resize: out_len=null は null を返す (Category A)" {
    var src = [_]u8{0} ** (4 * 4 * 4);
    const ptr = pict_resize(src[0..].ptr, 4, 4, 4, 2, 2, 1, null);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

test "pict_encode_webp: out_len=null は null を返す (Category A)" {
    var src = [_]u8{128} ** (4 * 4 * 4);
    const ptr = pict_encode_webp(src[0..].ptr, 4, 4, 4, 80.0, false, null);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

test "pict_decode_v2: out_len=null は null を返す (Category A)" {
    const bad = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x00 };
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_ch: u8 = 0;
    // out_len=null は必須引数欠如なので即 null 返却
    const ptr = pict_decode_v2(bad[0..].ptr, bad.len, &out_w, &out_h, &out_ch, null);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

test "pict_decode_v3: out_icc と out_icc_len の片方だけ指定は null (Category A)" {
    const bad = [_]u8{ 0x00, 0x01, 0x02 };
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_ch: u8 = 0;
    var out_len: usize = 0;
    var icc_ptr: ?[*]u8 = null;
    const ptr = pict_decode_v3(bad[0..].ptr, bad.len, &out_w, &out_h, &out_ch, &out_len, &icc_ptr, null);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

// ─────────────────────────────────────────────────────────────────────────────
// sentinel 不変 — 失敗時に out_len が変更されないことを確認 (Category B)
// ─────────────────────────────────────────────────────────────────────────────

test "pict_resize: overflow で null 返却、out_len 不変 (Category B)" {
    var src = [_]u8{0} ** 16;
    var out_len: usize = 0xDEAD;
    const ptr = pict_resize(src[0..].ptr, 0xFFFF_FFFF, 0xFFFF_FFFF, 4,
                            0xFFFF_FFFF, 0xFFFF_FFFF, 1, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
    try std.testing.expectEqual(@as(usize, 0xDEAD), out_len);
}

test "pict_resize: ゼロ次元で null 返却、out_len 不変 (Category B)" {
    var src = [_]u8{0} ** 16;
    var out_len: usize = 0xDEAD;
    const ptr = pict_resize(src[0..].ptr, 0, 4, 4, 4, 4, 1, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
    try std.testing.expectEqual(@as(usize, 0xDEAD), out_len);
}

test "pict_encode_webp: null 入力で null 返却、out_len 不変 (Category B)" {
    var out_len: usize = 0xDEAD;
    const ptr = pict_encode_webp(@as([*c]const u8, null), 4, 4, 4, 80.0, false, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
    try std.testing.expectEqual(@as(usize, 0xDEAD), out_len);
}

test "pict_decode_v2: 不正データで null 返却、out_len 不変 (Category B)" {
    const bad = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04 };
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_ch: u8 = 0;
    var out_len: usize = 0xDEAD;
    const ptr = pict_decode_v2(bad[0..].ptr, bad.len, &out_w, &out_h, &out_ch, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
    try std.testing.expectEqual(@as(usize, 0xDEAD), out_len);
}

test "pict_encode_png: RGBA 4x4 を PNG にエンコード (成功系)" {
    const W: u32 = 4;
    const H: u32 = 4;
    const CH: u8 = 4;
    var src = [_]u8{ 100, 150, 200, 255 } ** (W * H);
    var out_len: usize = 0;
    const ptr = pict_encode_png(src[0..].ptr, W, H, CH, 6, null, 0, &out_len) orelse
        return error.EncodeFailed;
    defer pict_free_buffer(ptr, out_len);

    try std.testing.expect(out_len > 8);
    // PNG マジック
    try std.testing.expectEqual(@as(u8, 0x89), ptr[0]);
    try std.testing.expectEqual(@as(u8, 'P'), ptr[1]);
    try std.testing.expectEqual(@as(u8, 'N'), ptr[2]);
    try std.testing.expectEqual(@as(u8, 'G'), ptr[3]);
}

test "pict_encode_png: out_len=null は null を返す (Category A)" {
    var src = [_]u8{128} ** (4 * 4 * 3);
    const ptr = pict_encode_png(src[0..].ptr, 4, 4, 3, 6, null, 0, null);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

test "pict_encode_png: null 入力で null 返却、out_len 不変 (Category B)" {
    var out_len: usize = 0xDEAD;
    const ptr = pict_encode_png(@as([*c]const u8, null), 4, 4, 3, 6, null, 0, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
    try std.testing.expectEqual(@as(usize, 0xDEAD), out_len);
}

test "pict_encode_png: channels=2 は null を返す" {
    var src = [_]u8{0} ** (4 * 4 * 2);
    var out_len: usize = 0;
    const ptr = pict_encode_png(src[0..].ptr, 4, 4, 2, 6, null, 0, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

test "pict_decode: 不正データは null を返す" {
    const bad = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04 };
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_ch: u8 = 0;
    const ptr = pict_decode(bad[0..].ptr, bad.len, &out_w, &out_h, &out_ch);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

test "pict_crop: 4x4 RGBA から 2x2 を切り出す (成功系)" {
    const W: u32 = 4;
    const H: u32 = 4;
    const CH: u8 = 4;
    var src = [_]u8{0} ** (W * H * CH);
    // ピクセル (row, col, 0, 255)
    for (0..H) |r| {
        for (0..W) |c| {
            const off = (r * W + c) * CH;
            src[off + 0] = @intCast(r * 10);
            src[off + 1] = @intCast(c * 10);
            src[off + 2] = 0;
            src[off + 3] = 255;
        }
    }
    var out_len: usize = 0;
    const ptr = pict_crop(src[0..].ptr, W, H, CH, 1, 1, 2, 2, &out_len) orelse
        return error.CropFailed;
    defer pict_free_buffer(ptr, out_len);

    try std.testing.expectEqual(@as(usize, 2 * 2 * CH), out_len);
    // (1,1): R=10, G=10
    try std.testing.expectEqual(@as(u8, 10), ptr[0]);
    try std.testing.expectEqual(@as(u8, 10), ptr[1]);
}

test "pict_crop: out_len=null は null を返す (Category A)" {
    var src = [_]u8{0} ** (4 * 4 * 4);
    const ptr = pict_crop(src[0..].ptr, 4, 4, 4, 0, 0, 2, 2, null);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

test "pict_crop: null 入力で null 返却、out_len 不変 (Category B)" {
    var out_len: usize = 0xDEAD;
    const ptr = pict_crop(@as([*c]const u8, null), 4, 4, 4, 0, 0, 2, 2, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
    try std.testing.expectEqual(@as(usize, 0xDEAD), out_len);
}

test "pict_crop: 範囲外で null 返却、out_len 不変 (Category B)" {
    var src = [_]u8{0} ** (4 * 4 * 4);
    var out_len: usize = 0xDEAD;
    // left=3, crop_w=2 → 3+2=5 > 4
    const ptr = pict_crop(src[0..].ptr, 4, 4, 4, 3, 0, 2, 2, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
    try std.testing.expectEqual(@as(usize, 0xDEAD), out_len);
}

// ─────────────────────────────────────────────────────────────────────────────
// pict_jpeg_orientation テスト
// ─────────────────────────────────────────────────────────────────────────────

test "pict_jpeg_orientation: 非 JPEG データは 1 を返す" {
    const bad = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    try std.testing.expectEqual(@as(u8, 1), pict_jpeg_orientation(bad[0..].ptr, bad.len));
}

test "pict_jpeg_orientation: orientation=1 fixture → 1 を返す" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "test/fixtures/jpeg_orientation_1.jpg", 4 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(u8, 1), pict_jpeg_orientation(bytes.ptr, bytes.len));
}

test "pict_jpeg_orientation: orientation=6 fixture → 6 を返す" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "test/fixtures/jpeg_orientation_6.jpg", 4 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(u8, 6), pict_jpeg_orientation(bytes.ptr, bytes.len));
}

test "pict_jpeg_orientation: orientation=8 fixture → 8 を返す" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "test/fixtures/jpeg_orientation_8.jpg", 4 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(u8, 8), pict_jpeg_orientation(bytes.ptr, bytes.len));
}

// ─────────────────────────────────────────────────────────────────────────────
// pict_rotate テスト
// ─────────────────────────────────────────────────────────────────────────────

test "pict_rotate: orientation=6 で幅高さが交換される (成功系)" {
    const W: u32 = 4;
    const H: u32 = 6;
    const CH: u8 = 3;
    var src = [_]u8{128} ** (W * H * CH);
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_len: usize = 0;
    const ptr = pict_rotate(src[0..].ptr, W, H, CH, 6, &out_w, &out_h, &out_len) orelse
        return error.RotateFailed;
    defer pict_free_buffer(ptr, out_len);

    try std.testing.expectEqual(H, out_w);  // orientation 5-8: 幅高さ交換
    try std.testing.expectEqual(W, out_h);
    try std.testing.expectEqual(@as(usize, H) * W * CH, out_len);
}

test "pict_rotate: orientation=1 は null を返す" {
    var src = [_]u8{128} ** (4 * 4 * 3);
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_len: usize = 0;
    const ptr = pict_rotate(src[0..].ptr, 4, 4, 3, 1, &out_w, &out_h, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}

test "pict_rotate: null 入力で null 返却 (Category A)" {
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    var out_len: usize = 0;
    const ptr = pict_rotate(@as([*c]const u8, null), 4, 4, 3, 6, &out_w, &out_h, &out_len);
    try std.testing.expectEqual(@as(?[*]u8, null), ptr);
}
