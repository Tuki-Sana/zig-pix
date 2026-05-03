const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CropError = error{ OutOfBounds, ZeroDimension, OutOfMemory };

/// src ピクセル列から矩形を切り出して新しいバッファに返す。
/// 確保は caller から渡された allocator で行う。解放も caller 責任。
pub fn crop(
    pixels: []const u8,
    src_w: u32,
    src_h: u32,
    channels: u8,
    left: u32,
    top: u32,
    crop_w: u32,
    crop_h: u32,
    allocator: Allocator,
) CropError![]u8 {
    if (crop_w == 0 or crop_h == 0) return error.ZeroDimension;

    // checked add — オーバーフロー後に範囲内に見えるケースを防ぐ
    const right = @addWithOverflow(left, crop_w);
    if (right[1] != 0 or right[0] > src_w) return error.OutOfBounds;
    const bottom = @addWithOverflow(top, crop_h);
    if (bottom[1] != 0 or bottom[0] > src_h) return error.OutOfBounds;

    const ch: usize = channels;
    const sw: usize = src_w;
    const cw: usize = crop_w;
    const ch_usize: usize = ch;

    // 出力バッファサイズのオーバーフローチェック
    const row_bytes_ab = @mulWithOverflow(cw, ch_usize);
    if (row_bytes_ab[1] != 0) return error.OutOfMemory;
    const row_bytes: usize = row_bytes_ab[0];
    const total_ab = @mulWithOverflow(row_bytes, @as(usize, crop_h));
    if (total_ab[1] != 0) return error.OutOfMemory;
    const total: usize = total_ab[0];

    const dst = try allocator.alloc(u8, total);

    const left_usize: usize = left;
    const top_usize: usize = top;

    for (0..@as(usize, crop_h)) |i| {
        const src_row_start = (top_usize + i) * sw * ch + left_usize * ch;
        const dst_row_start = i * row_bytes;
        @memcpy(dst[dst_row_start..][0..row_bytes], pixels[src_row_start..][0..row_bytes]);
    }

    return dst;
}

// ── テスト ────────────────────────────────────────────────────────────────────

test "crop: 4x4 RGBA から左上 2x2 を切り出す" {
    const W: u32 = 4;
    const H: u32 = 4;
    const CH: u8 = 4;
    // 各ピクセルに (row, col, 0, 255) を埋める
    var src = [_]u8{0} ** (W * H * CH);
    for (0..H) |r| {
        for (0..W) |c| {
            const off = (r * W + c) * CH;
            src[off + 0] = @intCast(r);
            src[off + 1] = @intCast(c);
            src[off + 2] = 0;
            src[off + 3] = 255;
        }
    }
    const alloc = std.testing.allocator;
    const dst = try crop(&src, W, H, CH, 0, 0, 2, 2, alloc);
    defer alloc.free(dst);

    try std.testing.expectEqual(@as(usize, 2 * 2 * CH), dst.len);
    // (0,0): row=0 col=0
    try std.testing.expectEqual(@as(u8, 0), dst[0]);
    try std.testing.expectEqual(@as(u8, 0), dst[1]);
    // (0,1): row=0 col=1
    try std.testing.expectEqual(@as(u8, 0), dst[4]);
    try std.testing.expectEqual(@as(u8, 1), dst[5]);
    // (1,0): row=1 col=0
    try std.testing.expectEqual(@as(u8, 1), dst[8]);
    try std.testing.expectEqual(@as(u8, 0), dst[9]);
}

test "crop: 右下コーナーを切り出す" {
    const W: u32 = 4;
    const H: u32 = 4;
    const CH: u8 = 3;
    var src = [_]u8{0} ** (W * H * CH);
    for (0..H) |r| {
        for (0..W) |c| {
            const off = (r * W + c) * CH;
            src[off + 0] = @intCast(r * 10);
            src[off + 1] = @intCast(c * 10);
            src[off + 2] = 0;
        }
    }
    const alloc = std.testing.allocator;
    // left=2, top=2, crop_w=2, crop_h=2 → 右下 2x2
    const dst = try crop(&src, W, H, CH, 2, 2, 2, 2, alloc);
    defer alloc.free(dst);

    try std.testing.expectEqual(@as(usize, 2 * 2 * CH), dst.len);
    // (2,2): r=2 c=2 → (20, 20, 0)
    try std.testing.expectEqual(@as(u8, 20), dst[0]);
    try std.testing.expectEqual(@as(u8, 20), dst[1]);
    // (2,3): r=2 c=3 → (20, 30, 0)
    try std.testing.expectEqual(@as(u8, 20), dst[3]);
    try std.testing.expectEqual(@as(u8, 30), dst[4]);
}

test "crop: ZeroDimension エラー" {
    var src = [_]u8{0} ** 16;
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.ZeroDimension, crop(&src, 4, 4, 1, 0, 0, 0, 2, alloc));
    try std.testing.expectError(error.ZeroDimension, crop(&src, 4, 4, 1, 0, 0, 2, 0, alloc));
}

test "crop: OutOfBounds エラー" {
    var src = [_]u8{0} ** (4 * 4 * 4);
    const alloc = std.testing.allocator;
    // left + crop_w > src_w
    try std.testing.expectError(error.OutOfBounds, crop(&src, 4, 4, 4, 3, 0, 2, 2, alloc));
    // top + crop_h > src_h
    try std.testing.expectError(error.OutOfBounds, crop(&src, 4, 4, 4, 0, 3, 2, 2, alloc));
    // u32 overflow: left=0xFFFFFFFF, crop_w=1
    try std.testing.expectError(error.OutOfBounds, crop(&src, 4, 4, 4, 0xFFFFFFFF, 0, 1, 1, alloc));
}

test "crop: src 全体と同じサイズで切り出すと元データと一致" {
    const W: u32 = 3;
    const H: u32 = 3;
    const CH: u8 = 4;
    var src: [W * H * CH]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i % 256);
    const alloc = std.testing.allocator;
    const dst = try crop(&src, W, H, CH, 0, 0, W, H, alloc);
    defer alloc.free(dst);
    try std.testing.expectEqualSlices(u8, &src, dst);
}
