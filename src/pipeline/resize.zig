/// resize.zig — Lanczos-3 リサイズ (f32 スカラー リファレンス実装)
///
/// 設計方針 (Q2 決定事項):
///   - まず f32 スカラーで「数学的正解」を確立する。
///   - SIMD / i16 最適化は Phase 3 でこの実装を通過したテストに対して行う。
///   - 2-pass 分離フィルタ: H-pass (横方向) → V-pass (縦方向)
///   - a = 3 (Lanczos-3): カーネル半径 3px, 各軸 6 tap

const std = @import("std");
const math = std.math;
const decode = @import("decode.zig");

// ─────────────────────────────────────────────────────────────────────────────
// 設定
// ─────────────────────────────────────────────────────────────────────────────

pub const LANCZOS_A: f32 = 3.0;

pub const ResizeConfig = struct {
    src_width: u32,
    src_height: u32,
    dst_width: u32,
    dst_height: u32,
    /// 出力チャンネル数 (通常 4 = RGBA)
    channels: u8 = 4,
};

// ─────────────────────────────────────────────────────────────────────────────
// Lanczos-3 カーネル
// ─────────────────────────────────────────────────────────────────────────────

/// Lanczos-3 窓関数: sinc(x) * sinc(x / a), |x| < a
///
/// この関数単体をテスト・ベンチマークの基準にする。
/// SIMD 実装はこの出力と一致することを検証すること。
pub fn lanczosKernel(x: f32) f32 {
    const ax = @abs(x);
    if (ax == 0.0) return 1.0;
    if (ax >= LANCZOS_A) return 0.0;
    const pi_x = math.pi * x;
    const pi_x_a = math.pi * x / LANCZOS_A;
    // sinc(x) = sin(π x) / (π x)
    return (math.sin(pi_x) / pi_x) * (math.sin(pi_x_a) / pi_x_a);
}

// ─────────────────────────────────────────────────────────────────────────────
// フルフレーム リサイズ (フラットバッファ版, Phase 1 リファレンス)
// ─────────────────────────────────────────────────────────────────────────────

/// Lanczos-3 リサイズ (full-frame, f32 スカラー)
///
/// src_data: [src_height * src_width * channels] bytes (u8, RGBA interleaved)
/// dst_data: 呼び出し元が確保した [dst_height * dst_width * channels] bytes
///
/// ストリーミング版 (Phase 1 後半) のリファレンスとして使う。
pub fn resizeLanczos3(
    allocator: std.mem.Allocator,
    src_data: []const u8,
    dst_data: []u8,
    config: ResizeConfig,
) !void {
    const sw = config.src_width;
    const sh = config.src_height;
    const dw = config.dst_width;
    const dh = config.dst_height;
    const ch = config.channels;

    std.debug.assert(src_data.len == @as(usize, sh) * sw * ch);
    std.debug.assert(dst_data.len == @as(usize, dh) * dw * ch);

    // ── H-pass: src → intermediate (dst_width × src_height) ─────────────────
    // intermediate[y * dw * ch .. (y+1) * dw * ch] = H-filtered row y
    const inter = try allocator.alloc(f32, @as(usize, sh) * dw * ch);
    defer allocator.free(inter);

    const scale_x = @as(f32, @floatFromInt(dw)) / @as(f32, @floatFromInt(sw));
    const scale_y = @as(f32, @floatFromInt(dh)) / @as(f32, @floatFromInt(sh));

    hPass(src_data, inter, sw, sh, dw, ch, scale_x);

    // ── V-pass: intermediate → dst ───────────────────────────────────────────
    vPass(inter, dst_data, sh, dh, dw, ch, scale_y);
}

/// H-pass: src (u8) → inter (f32)
fn hPass(
    src: []const u8,
    inter: []f32,
    sw: u32,
    sh: u32,
    dw: u32,
    ch: u8,
    scale_x: f32,
) void {
    const support = LANCZOS_A / @min(scale_x, 1.0); // downscale 時はカーネルを広げる

    for (0..sh) |y| {
        for (0..dw) |dx| {
            // 出力ピクセル dx の中心が対応するソース座標
            const sx_center = (@as(f32, @floatFromInt(dx)) + 0.5) / scale_x - 0.5;
            const sx_min: i64 = @intFromFloat(@floor(sx_center - support));
            const sx_max: i64 = @intFromFloat(@ceil(sx_center + support));

            var sum = [_]f64{0.0} ** 4; // チャンネルごとの加重和
            var weight_sum: f64 = 0.0;

            var sx: i64 = sx_min;
            while (sx <= sx_max) : (sx += 1) {
                const kernel_x = (@as(f32, @floatFromInt(sx)) - sx_center) *
                    @min(scale_x, 1.0);
                const w = lanczosKernel(kernel_x);
                if (w == 0.0) continue;

                const clamped_sx: usize = @intCast(std.math.clamp(sx, 0, @as(i64, @intCast(sw)) - 1));
                const src_base = y * sw * ch + clamped_sx * ch;

                for (0..ch) |c| {
                    sum[c] += @as(f64, @floatFromInt(src[src_base + c])) * w;
                }
                weight_sum += w;
            }

            const inter_base = y * dw * ch + dx * ch;
            for (0..ch) |c| {
                inter[inter_base + c] = @floatCast(sum[c] / weight_sum);
            }
        }
    }
}

/// V-pass: inter (f32) → dst (u8)
fn vPass(
    inter: []const f32,
    dst: []u8,
    sh: u32,
    dh: u32,
    dw: u32,
    ch: u8,
    scale_y: f32,
) void {
    const support = LANCZOS_A / @min(scale_y, 1.0);

    for (0..dh) |dy| {
        const sy_center = (@as(f32, @floatFromInt(dy)) + 0.5) / scale_y - 0.5;
        const sy_min: i64 = @intFromFloat(@floor(sy_center - support));
        const sy_max: i64 = @intFromFloat(@ceil(sy_center + support));

        for (0..dw) |dx| {
            var sum = [_]f64{0.0} ** 4;
            var weight_sum: f64 = 0.0;

            var sy: i64 = sy_min;
            while (sy <= sy_max) : (sy += 1) {
                const kernel_y = (@as(f32, @floatFromInt(sy)) - sy_center) *
                    @min(scale_y, 1.0);
                const w = lanczosKernel(kernel_y);
                if (w == 0.0) continue;

                const clamped_sy: usize = @intCast(std.math.clamp(sy, 0, @as(i64, @intCast(sh)) - 1));
                const inter_base = clamped_sy * dw * ch + dx * ch;

                for (0..ch) |c| {
                    sum[c] += @as(f64, inter[inter_base + c]) * w;
                }
                weight_sum += w;
            }

            const dst_base = dy * dw * ch + dx * ch;
            for (0..ch) |c| {
                const val = sum[c] / weight_sum;
                dst[dst_base + c] = @intFromFloat(
                    std.math.clamp(@round(val), 0.0, 255.0),
                );
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// テスト
// ─────────────────────────────────────────────────────────────────────────────

test "lanczosKernel: center = 1.0" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lanczosKernel(0.0), 1e-6);
}

test "lanczosKernel: 境界 |x| = 3 → 0" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lanczosKernel(3.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lanczosKernel(-3.0), 1e-6);
}

test "lanczosKernel: 対称性" {
    const xs = [_]f32{ 0.5, 1.0, 1.5, 2.0, 2.5 };
    for (xs) |x| {
        try std.testing.expectApproxEqAbs(lanczosKernel(x), lanczosKernel(-x), 1e-6);
    }
}

test "lanczosKernel: 整数座標での周期的ゼロ交差" {
    // sinc 関数は非ゼロ整数で 0 になる (Lanczos も同様)
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lanczosKernel(1.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lanczosKernel(2.0), 1e-5);
}

test "resizeLanczos3: 1x1 → 1x1 (同一サイズ)" {
    const allocator = std.testing.allocator;
    const src = [_]u8{ 128, 64, 200, 255 }; // 1px RGBA
    var dst = [_]u8{0} ** 4;

    try resizeLanczos3(allocator, &src, &dst, .{
        .src_width = 1,
        .src_height = 1,
        .dst_width = 1,
        .dst_height = 1,
    });

    try std.testing.expectEqual(src[0], dst[0]);
    try std.testing.expectEqual(src[1], dst[1]);
    try std.testing.expectEqual(src[2], dst[2]);
    try std.testing.expectEqual(src[3], dst[3]);
}

test "resizeLanczos3: 均一色画像は拡大縮小後も同色" {
    const allocator = std.testing.allocator;

    // 4x4 均一色 (R=255, G=128, B=64, A=255)
    const W = 4;
    const H = 4;
    var src = [_]u8{ 255, 128, 64, 255 } ** (W * H);
    var dst = [_]u8{0} ** (2 * 2 * 4); // 2x2 に縮小

    try resizeLanczos3(allocator, &src, &dst, .{
        .src_width = W,
        .src_height = H,
        .dst_width = 2,
        .dst_height = 2,
    });

    // 均一色はどのフィルタリングでも保存される
    for (0..4) |i| {
        try std.testing.expectApproxEqAbs(
            @as(f32, @floatFromInt(src[i])),
            @as(f32, @floatFromInt(dst[i])),
            2.0, // 丸め誤差 ±2
        );
    }
}
