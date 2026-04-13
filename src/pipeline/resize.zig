/// resize.zig — Lanczos-3 リサイズ (f32 スカラー リファレンス実装)
///
/// 設計方針 (Q2 決定事項):
///   - f32 スカラーで「数学的正解」を確立する。
///   - SIMD / i16 最適化は Phase 3 でこの実装を通過したテストに対して行う。
///   - 2-pass 分離フィルタ: H-pass (横方向) → V-pass (縦方向)
///   - a = 3 (Lanczos-3): カーネル半径 3px, 各軸最大 6 tap

const std = @import("std");
const math = std.math;
const ring_mod = @import("../mem/ring.zig");

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
/// SIMD 実装はこの出力と一致することを検証すること (Phase 3)。
pub fn lanczosKernel(x: f32) f32 {
    const ax = @abs(x);
    if (ax == 0.0) return 1.0;
    if (ax >= LANCZOS_A) return 0.0;
    const pi_x = math.pi * x;
    const pi_x_a = math.pi * x / LANCZOS_A;
    return (math.sin(pi_x) / pi_x) * (math.sin(pi_x_a) / pi_x_a);
}

// ─────────────────────────────────────────────────────────────────────────────
// H-pass (共通コア)
// ─────────────────────────────────────────────────────────────────────────────

/// H-pass: 1行 (u8) → 1行 (f32)
/// src_row: sw * ch バイト / out_row: dw * ch f32
/// full-frame 版と StreamingResizer の両方がこれを呼ぶ。
fn hPassRow(
    src_row: []const u8,
    out_row: []f32,
    sw: u32,
    ch: u8,
    scale_x: f32,
) void {
    const dw = out_row.len / ch;
    const support = LANCZOS_A / @min(scale_x, 1.0);

    for (0..dw) |dx| {
        const sx_center = (@as(f32, @floatFromInt(dx)) + 0.5) / scale_x - 0.5;
        const sx_min: i64 = @intFromFloat(@floor(sx_center - support));
        const sx_max: i64 = @intFromFloat(@ceil(sx_center + support));

        var sum = [_]f64{0.0} ** 4;
        var weight_sum: f64 = 0.0;

        var sx: i64 = sx_min;
        while (sx <= sx_max) : (sx += 1) {
            const kernel_x = (@as(f32, @floatFromInt(sx)) - sx_center) * @min(scale_x, 1.0);
            const w = lanczosKernel(kernel_x);
            if (w == 0.0) continue;

            const clamped: usize = @intCast(std.math.clamp(sx, 0, @as(i64, @intCast(sw)) - 1));
            for (0..ch) |c| {
                sum[c] += @as(f64, @floatFromInt(src_row[clamped * ch + c])) * w;
            }
            weight_sum += w;
        }

        for (0..ch) |c| {
            out_row[dx * ch + c] = @floatCast(sum[c] / weight_sum);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// フルフレーム リサイズ (リファレンス実装)
// ─────────────────────────────────────────────────────────────────────────────

/// Lanczos-3 リサイズ (full-frame, f32 スカラー)
///
/// StreamingResizer の正解基準。
/// src_data: u8 RGBA interleaved / dst_data: 呼び出し元確保済み
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

    const scale_x: f32 = @as(f32, @floatFromInt(dw)) / @as(f32, @floatFromInt(sw));
    const scale_y: f32 = @as(f32, @floatFromInt(dh)) / @as(f32, @floatFromInt(sh));

    // ── H-pass: src → inter (dst_width × src_height, f32) ────────────────────
    const row_stride = @as(usize, dw) * ch;
    const inter = try allocator.alloc(f32, @as(usize, sh) * row_stride);
    defer allocator.free(inter);

    for (0..sh) |y| {
        const src_row = src_data[y * sw * ch .. (y + 1) * sw * ch];
        const out_row = inter[y * row_stride .. (y + 1) * row_stride];
        hPassRow(src_row, out_row, sw, ch, scale_x);
    }

    // ── V-pass: inter → dst ───────────────────────────────────────────────────
    vPassFull(inter, dst_data, sh, dh, dw, ch, scale_y);
}

/// V-pass: フルフレーム中間バッファ (f32) → dst (u8)
fn vPassFull(
    inter: []const f32,
    dst: []u8,
    sh: u32,
    dh: u32,
    dw: u32,
    ch: u8,
    scale_y: f32,
) void {
    const support = LANCZOS_A / @min(scale_y, 1.0);
    const row_stride = @as(usize, dw) * ch;

    for (0..dh) |dy| {
        const sy_center = (@as(f32, @floatFromInt(dy)) + 0.5) / scale_y - 0.5;
        const sy_min: i64 = @intFromFloat(@floor(sy_center - support));
        const sy_max: i64 = @intFromFloat(@ceil(sy_center + support));

        for (0..dw) |dx| {
            var sum = [_]f64{0.0} ** 4;
            var weight_sum: f64 = 0.0;

            var sy: i64 = sy_min;
            while (sy <= sy_max) : (sy += 1) {
                const kernel_y = (@as(f32, @floatFromInt(sy)) - sy_center) * @min(scale_y, 1.0);
                const w = lanczosKernel(kernel_y);
                if (w == 0.0) continue;

                const clamped: usize = @intCast(std.math.clamp(sy, 0, @as(i64, @intCast(sh)) - 1));
                const base = clamped * row_stride + dx * ch;
                for (0..ch) |c| {
                    sum[c] += @as(f64, inter[base + c]) * w;
                }
                weight_sum += w;
            }

            const dst_base = dy * row_stride + dx * ch;
            for (0..ch) |c| {
                dst[dst_base + c] = @intFromFloat(
                    std.math.clamp(@round(sum[c] / weight_sum), 0.0, 255.0),
                );
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// StreamingResizer
// ─────────────────────────────────────────────────────────────────────────────

/// Lanczos-3 ストリーミングリサイザー
///
/// 使い方:
///   var sr = try StreamingResizer.init(alloc, config);
///   defer sr.deinit();
///   for (src_rows) |row| sr.feedRow(row, dst_buf);
///   sr.flush(dst_buf);
///
/// ring buffer のサイズは scale_y から自動計算する。
/// - scale_y >= 1 (等倍/拡大): support=3  → ring 8行
/// - scale_y = 0.5 (2x縮小):  support=6  → ring 14行
pub const StreamingResizer = struct {
    allocator: std.mem.Allocator,
    config: ResizeConfig,
    scale_x: f32,
    scale_y: f32,
    support_y: f32,
    /// H-pass 済み中間行を保持するリングバッファ (f32, dst_width × channels)
    ring: ring_mod.RingBuffer(f32),
    /// H-pass の一時出力バッファ (1行分)
    hpass_buf: []f32,
    src_rows_fed: u32,
    dst_rows_emitted: u32,

    pub fn init(allocator: std.mem.Allocator, config: ResizeConfig) !StreamingResizer {
        const scale_x: f32 = @as(f32, @floatFromInt(config.dst_width)) /
            @as(f32, @floatFromInt(config.src_width));
        const scale_y: f32 = @as(f32, @floatFromInt(config.dst_height)) /
            @as(f32, @floatFromInt(config.src_height));
        const support_y = LANCZOS_A / @min(scale_y, 1.0);
        // ring_cap: カーネルスパン + 2 の余裕
        const ring_cap: usize = @as(usize, @intFromFloat(@ceil(2.0 * support_y))) + 2;
        const row_stride: usize = @as(usize, config.dst_width) * config.channels;

        var ring = try ring_mod.RingBuffer(f32).init(allocator, ring_cap, row_stride);
        errdefer ring.deinit(allocator);

        const hpass_buf = try allocator.alloc(f32, row_stride);

        return .{
            .allocator = allocator,
            .config = config,
            .scale_x = scale_x,
            .scale_y = scale_y,
            .support_y = support_y,
            .ring = ring,
            .hpass_buf = hpass_buf,
            .src_rows_fed = 0,
            .dst_rows_emitted = 0,
        };
    }

    pub fn deinit(self: *StreamingResizer) void {
        self.ring.deinit(self.allocator);
        self.allocator.free(self.hpass_buf);
        self.* = undefined;
    }

    /// 1行分のソースデータを受け取り、準備できた出力行を out に書き出す。
    /// out: [dst_height * dst_width * channels] bytes の事前確保バッファ
    pub fn feedRow(self: *StreamingResizer, src_row: []const u8, out: []u8) void {
        std.debug.assert(src_row.len == @as(usize, self.config.src_width) * self.config.channels);

        // H-pass → ring に push
        hPassRow(src_row, self.hpass_buf, self.config.src_width, self.config.channels, self.scale_x);
        self.ring.pushRow(self.hpass_buf);
        self.src_rows_fed += 1;

        self.emitReady(out);
    }

    /// 全ソース行を受け取った後、残りの出力行を書き出す。
    /// feedRow を src_height 回呼んだ後に必ず呼ぶ。
    pub fn flush(self: *StreamingResizer, out: []u8) void {
        std.debug.assert(self.src_rows_fed == self.config.src_height);
        while (self.dst_rows_emitted < self.config.dst_height) {
            self.emitRow(self.dst_rows_emitted, out);
            self.dst_rows_emitted += 1;
        }
    }

    pub fn isDone(self: *const StreamingResizer) bool {
        return self.dst_rows_emitted == self.config.dst_height;
    }

    // ── 内部 ──────────────────────────────────────────────────────────────────

    /// sy_max(dy) に必要な最後のソース行が揃っていれば出力行 dy を emit する。
    fn emitReady(self: *StreamingResizer, out: []u8) void {
        const sh_i64: i64 = @intCast(self.config.src_height);
        while (self.dst_rows_emitted < self.config.dst_height) {
            const dy = self.dst_rows_emitted;
            const sy_center = (@as(f32, @floatFromInt(dy)) + 0.5) / self.scale_y - 0.5;
            const sy_max_raw: i64 = @intFromFloat(@ceil(sy_center + self.support_y));
            // 画像端クランプ後の実際の最大ソース行
            const actual_sy_max = @min(sy_max_raw, sh_i64 - 1);

            // src_rows_fed がまだ足りなければここで停止
            if (actual_sy_max >= @as(i64, @intCast(self.src_rows_fed))) break;

            self.emitRow(dy, out);
            self.dst_rows_emitted += 1;
        }
    }

    /// 出力行 dy を V-pass で計算して out に書く。
    fn emitRow(self: *const StreamingResizer, dy: u32, out: []u8) void {
        const dw = self.config.dst_width;
        const ch = self.config.channels;
        const sh = self.config.src_height;
        const row_stride = @as(usize, dw) * ch;

        const sy_center = (@as(f32, @floatFromInt(dy)) + 0.5) / self.scale_y - 0.5;
        const sy_min: i64 = @intFromFloat(@floor(sy_center - self.support_y));
        const sy_max: i64 = @intFromFloat(@ceil(sy_center + self.support_y));

        for (0..dw) |dx| {
            var sum = [_]f64{0.0} ** 4;
            var weight_sum: f64 = 0.0;

            var sy: i64 = sy_min;
            while (sy <= sy_max) : (sy += 1) {
                const kernel_y = (@as(f32, @floatFromInt(sy)) - sy_center) *
                    @min(self.scale_y, 1.0);
                const w = lanczosKernel(kernel_y);
                if (w == 0.0) continue;

                const clamped: usize = @intCast(
                    std.math.clamp(sy, 0, @as(i64, @intCast(sh)) - 1),
                );
                const row = self.ring.getRow(clamped) orelse std.debug.panic(
                    "ring eviction: sy={d}, write_count={d}, cap={d}",
                    .{ clamped, self.ring.write_count, self.ring.capacity },
                );

                for (0..ch) |c| {
                    sum[c] += @as(f64, row[dx * ch + c]) * w;
                }
                weight_sum += w;
            }

            const dst_base = @as(usize, dy) * row_stride + dx * ch;
            for (0..ch) |c| {
                out[dst_base + c] = @intFromFloat(
                    std.math.clamp(@round(sum[c] / weight_sum), 0.0, 255.0),
                );
            }
        }
    }
};

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
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lanczosKernel(1.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lanczosKernel(2.0), 1e-5);
}

test "resizeLanczos3: 1x1 → 1x1" {
    const src = [_]u8{ 128, 64, 200, 255 };
    var dst = [_]u8{0} ** 4;
    try resizeLanczos3(std.testing.allocator, &src, &dst, .{
        .src_width = 1, .src_height = 1, .dst_width = 1, .dst_height = 1,
    });
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "resizeLanczos3: 均一色は拡大縮小後も保存" {
    const W = 4;
    const H = 4;
    const src = [_]u8{ 255, 128, 64, 255 } ** (W * H);
    var dst = [_]u8{0} ** (2 * 2 * 4);
    try resizeLanczos3(std.testing.allocator, &src, &dst, .{
        .src_width = W, .src_height = H, .dst_width = 2, .dst_height = 2,
    });
    for (0..4) |i| {
        try std.testing.expectApproxEqAbs(
            @as(f32, @floatFromInt(src[i])),
            @as(f32, @floatFromInt(dst[i])),
            2.0,
        );
    }
}

// ストリーミング版とフルフレーム版の出力が一致することを検証する。
// これが StreamingResizer の正確性テスト (Phase 3 SIMD の安全網にもなる)。
test "StreamingResizer: フルフレーム版と出力一致 (8x8 → 4x4 縮小)" {
    const alloc = std.testing.allocator;
    const SW = 8;
    const SH = 8;
    const DW = 4;
    const DH = 4;
    const CH = 4;

    // グラデーション画像 (X方向: R, Y方向: G, B=128, A=255)
    var src: [SH * SW * CH]u8 = undefined;
    for (0..SH) |y| {
        for (0..SW) |x| {
            const base = (y * SW + x) * CH;
            src[base + 0] = @intCast(x * 255 / (SW - 1)); // R
            src[base + 1] = @intCast(y * 255 / (SH - 1)); // G
            src[base + 2] = 128;                           // B
            src[base + 3] = 255;                           // A
        }
    }

    // フルフレーム参照
    var ref_dst = [_]u8{0} ** (DH * DW * CH);
    try resizeLanczos3(alloc, &src, &ref_dst, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });

    // ストリーミング版
    var stream_dst = [_]u8{0} ** (DH * DW * CH);
    var sr = try StreamingResizer.init(alloc, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });
    defer sr.deinit();

    for (0..SH) |y| {
        const row = src[y * SW * CH .. (y + 1) * SW * CH];
        sr.feedRow(row, &stream_dst);
    }
    sr.flush(&stream_dst);

    try std.testing.expect(sr.isDone());

    // 全ピクセル比較 (丸め誤差 ±1 許容)
    for (0..DH * DW * CH) |i| {
        const ref_v = @as(i16, ref_dst[i]);
        const str_v = @as(i16, stream_dst[i]);
        const diff = if (ref_v > str_v) ref_v - str_v else str_v - ref_v;
        if (diff > 1) {
            std.debug.print("pixel[{d}]: ref={d} stream={d}\n", .{ i, ref_dst[i], stream_dst[i] });
            try std.testing.expect(false);
        }
    }
}

test "StreamingResizer: 2x縮小 (8x8 → 4x4) フルフレーム一致" {
    const alloc = std.testing.allocator;
    const SW = 8;
    const SH = 8;
    const DW = 4;
    const DH = 4;
    const CH = 4;

    // チェッカーボード
    var src: [SH * SW * CH]u8 = undefined;
    for (0..SH) |y| {
        for (0..SW) |x| {
            const v: u8 = if ((x + y) % 2 == 0) 240 else 20;
            const base = (y * SW + x) * CH;
            src[base + 0] = v;
            src[base + 1] = v;
            src[base + 2] = v;
            src[base + 3] = 255;
        }
    }

    var ref_dst = [_]u8{0} ** (DH * DW * CH);
    try resizeLanczos3(alloc, &src, &ref_dst, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });

    var stream_dst = [_]u8{0} ** (DH * DW * CH);
    var sr = try StreamingResizer.init(alloc, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });
    defer sr.deinit();

    for (0..SH) |y| sr.feedRow(src[y * SW * CH .. (y + 1) * SW * CH], &stream_dst);
    sr.flush(&stream_dst);

    for (0..DH * DW * CH) |i| {
        const diff: i16 = @as(i16, ref_dst[i]) - @as(i16, stream_dst[i]);
        try std.testing.expect(diff >= -1 and diff <= 1);
    }
}

test "StreamingResizer: 2x拡大 (4x4 → 8x8) フルフレーム一致" {
    const alloc = std.testing.allocator;
    const SW = 4;
    const SH = 4;
    const DW = 8;
    const DH = 8;
    const CH = 4;

    var src: [SH * SW * CH]u8 = undefined;
    for (0..SH) |y| {
        for (0..SW) |x| {
            const base = (y * SW + x) * CH;
            src[base + 0] = @intCast(x * 85);
            src[base + 1] = @intCast(y * 85);
            src[base + 2] = 200;
            src[base + 3] = 255;
        }
    }

    var ref_dst = [_]u8{0} ** (DH * DW * CH);
    try resizeLanczos3(alloc, &src, &ref_dst, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });

    var stream_dst = [_]u8{0} ** (DH * DW * CH);
    var sr = try StreamingResizer.init(alloc, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });
    defer sr.deinit();

    for (0..SH) |y| sr.feedRow(src[y * SW * CH .. (y + 1) * SW * CH], &stream_dst);
    sr.flush(&stream_dst);

    for (0..DH * DW * CH) |i| {
        const diff: i16 = @as(i16, ref_dst[i]) - @as(i16, stream_dst[i]);
        try std.testing.expect(diff >= -1 and diff <= 1);
    }
}
