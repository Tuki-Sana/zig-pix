const std = @import("std");
const Allocator = std.mem.Allocator;
const decode = @import("decode.zig");
const ImageBuffer = decode.ImageBuffer;

pub const RotateError = error{OutOfMemory};

/// EXIF Orientation に従いピクセルを変換した新しい ImageBuffer を返す。
///
/// orientation=1: コピーなし、src をそのまま返す（caller は src を解放しないこと）。
/// それ以外: 新しいバッファを確保して変換し返す（caller が allocator.free(dst.data) で解放）。
///
/// channels=3 (RGB) / 4 (RGBA) のみ想定。それ以外は orientation=1 と同じ扱い。
pub fn rotate(src: ImageBuffer, orientation: u8, allocator: Allocator) RotateError!ImageBuffer {
    if (orientation == 1 or orientation > 8) return src;

    const w = src.width;
    const h = src.height;
    const ch: usize = src.channels;

    // orientation 5-8 は幅高さが交換される
    const transpose = orientation >= 5;
    const dst_w: u32 = if (transpose) h else w;
    const dst_h: u32 = if (transpose) w else h;

    const dst_size = @as(usize, dst_w) * @as(usize, dst_h) * ch;
    const dst_data = try allocator.alloc(u8, dst_size);

    const sw: usize = w;
    const sh: usize = h;
    const dw: usize = dst_w;

    for (0..sh) |r| {
        for (0..sw) |c| {
            const src_off = (r * sw + c) * ch;

            // 変換後の dst 座標
            const dr: usize, const dc: usize = switch (orientation) {
                2 => .{ r,          sw - 1 - c }, // 水平反転
                3 => .{ sh - 1 - r, sw - 1 - c }, // 180°回転
                4 => .{ sh - 1 - r, c           }, // 垂直反転
                5 => .{ c,          r           }, // 転置（90°CW + 水平反転）
                6 => .{ c,          sh - 1 - r  }, // 90°CW
                7 => .{ sw - 1 - c, sh - 1 - r  }, // 90°CW + 垂直反転
                8 => .{ sw - 1 - c, r           }, // 90°CCW
                else => unreachable,
            };

            const dst_off = (dr * dw + dc) * ch;
            @memcpy(dst_data[dst_off..][0..ch], src.data[src_off..][0..ch]);
        }
    }

    return ImageBuffer{
        .data      = dst_data,
        .width     = dst_w,
        .height    = dst_h,
        .channels  = src.channels,
        .format    = src.format,
        .icc       = src.icc,
        .allocator = allocator,
    };
}

// ── テスト ────────────────────────────────────────────────────────────────────

test "rotate orientation=1: 入力をそのまま返す" {
    const alloc = std.testing.allocator;
    var data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const src = ImageBuffer{
        .data      = &data,
        .width     = 2,
        .height    = 2,
        .channels  = 3,
        .format    = .rgb8,
        .icc       = null,
        .allocator = alloc,
    };
    const dst = try rotate(src, 1, alloc);
    // orientation=1 は元ポインタを返す（allocate なし）
    try std.testing.expect(dst.data.ptr == src.data.ptr);
    try std.testing.expectEqual(@as(u32, 2), dst.width);
    try std.testing.expectEqual(@as(u32, 2), dst.height);
}

test "rotate orientation=3: 180° 回転" {
    // 2×1 RGB: [R=1 G=2 B=3] [R=4 G=5 B=6]
    // 180° 後: [R=4 G=5 B=6] [R=1 G=2 B=3]
    const alloc = std.testing.allocator;
    var data = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const src = ImageBuffer{
        .data      = &data,
        .width     = 2,
        .height    = 1,
        .channels  = 3,
        .format    = .rgb8,
        .icc       = null,
        .allocator = alloc,
    };
    const dst = try rotate(src, 3, alloc);
    defer alloc.free(dst.data);

    try std.testing.expectEqual(@as(u32, 2), dst.width);
    try std.testing.expectEqual(@as(u32, 1), dst.height);
    try std.testing.expectEqual(@as(u8, 4), dst.data[0]);
    try std.testing.expectEqual(@as(u8, 5), dst.data[1]);
    try std.testing.expectEqual(@as(u8, 6), dst.data[2]);
    try std.testing.expectEqual(@as(u8, 1), dst.data[3]);
    try std.testing.expectEqual(@as(u8, 2), dst.data[4]);
    try std.testing.expectEqual(@as(u8, 3), dst.data[5]);
}

test "rotate orientation=6: 90° CW（幅高さ交換）" {
    // 2×1 RGBA: [(r=0,c=0)=A] [(r=0,c=1)=B]
    // 90°CW 後は 1×2:
    //   (dr=0, dc=0) ← (r=0, c=1) = B  (dc = sh-1-r = 1-0-0 = 0... wait)
    // orientation=6: dr=c, dc=sh-1-r
    //   (r=0,c=0) → (dr=0, dc=0) = A
    //   (r=0,c=1) → (dr=1, dc=0) = B
    // dst は width=1, height=2: [A][B]
    const alloc = std.testing.allocator;
    var data = [_]u8{ 10, 0, 0, 255,  20, 0, 0, 255 };
    const src = ImageBuffer{
        .data      = &data,
        .width     = 2,
        .height    = 1,
        .channels  = 4,
        .format    = .rgba8,
        .icc       = null,
        .allocator = alloc,
    };
    const dst = try rotate(src, 6, alloc);
    defer alloc.free(dst.data);

    try std.testing.expectEqual(@as(u32, 1), dst.width);
    try std.testing.expectEqual(@as(u32, 2), dst.height);
    // 先頭が元の (r=0,c=0) = 10
    try std.testing.expectEqual(@as(u8, 10), dst.data[0]);
    // 次が元の (r=0,c=1) = 20
    try std.testing.expectEqual(@as(u8, 20), dst.data[4]);
}

test "rotate orientation=8: 90° CCW（幅高さ交換）" {
    // 2×1 RGB: [(r=0,c=0)=(1,2,3)] [(r=0,c=1)=(4,5,6)]
    // orientation=8: dr=sw-1-c, dc=r
    //   (r=0,c=0) → (dr=1, dc=0)
    //   (r=0,c=1) → (dr=0, dc=0)
    // dst は width=1, height=2: [(4,5,6)] [(1,2,3)]
    const alloc = std.testing.allocator;
    var data = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const src = ImageBuffer{
        .data      = &data,
        .width     = 2,
        .height    = 1,
        .channels  = 3,
        .format    = .rgb8,
        .icc       = null,
        .allocator = alloc,
    };
    const dst = try rotate(src, 8, alloc);
    defer alloc.free(dst.data);

    try std.testing.expectEqual(@as(u32, 1), dst.width);
    try std.testing.expectEqual(@as(u32, 2), dst.height);
    try std.testing.expectEqual(@as(u8, 4), dst.data[0]);
    try std.testing.expectEqual(@as(u8, 1), dst.data[3]);
}
