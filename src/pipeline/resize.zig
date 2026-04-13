/// resize.zig — Lanczos-3 リサイズ (f32 スカラー リファレンス実装)
///
/// 設計方針 (Q2):
///   - f32 スカラーで「数学的正解」を確立する。SIMD は Phase 3 でこの実装を安全網にして導入。
///   - 2-pass 分離フィルタ: H-pass (横方向) → V-pass (縦方向)
///   - a = 3: カーネル半径 3px, 各軸最大 6 tap

const std = @import("std");
const math = std.math;
const ring_mod = @import("../mem/ring.zig");

// ─────────────────────────────────────────────────────────────────────────────
// 型定義
// ─────────────────────────────────────────────────────────────────────────────

pub const LANCZOS_A: f32 = 3.0;

/// channels は 1/3/4 のみサポート (sum バッファ上限 = 4)
pub const ResizeConfig = struct {
    src_width: u32,
    src_height: u32,
    dst_width: u32,
    dst_height: u32,
    /// サポート値: 1 (Gray), 3 (RGB), 4 (RGBA)
    channels: u8 = 4,
};

pub const ResizeError = error{
    /// channels が 1/3/4 以外
    UnsupportedChannelCount,
    /// feedRow に渡した行の長さが src_width * channels と不一致
    InvalidInputDimensions,
    /// flush 前に src_height 行に満たない feedRow 呼び出し
    IncompleteInput,
    /// ring バッファからの行取得に失敗 (内部不変条件違反)
    InternalRingEviction,
    OutOfMemory,
};

// ─────────────────────────────────────────────────────────────────────────────
// RowSink — ストリーミング出力の抽象
//
// StreamingResizer は 1 行ずつ RowSink.writeRow() を呼び出す。
// ピーク消費メモリ = ring_cap 行 (8〜14 行) + hpass/out 各 1 行分のみ。
//
// 実装例:
//   - SliceSink   : テスト・デバッグ用。フラットバッファに書き込む。
//   - TileSink    : Phase 2 でエンコーダに接続 (tile.zig 統合)。
//   - WriterSink  : Phase 6 で Bun FFI へのストリーム出力。
// ─────────────────────────────────────────────────────────────────────────────

pub const RowSink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, row: []const u8, dst_y: u32) anyerror!void,

    pub fn writeRow(self: RowSink, row: []const u8, dst_y: u32) !void {
        return self.writeFn(self.ctx, row, dst_y);
    }
};

/// テスト / デバッグ用シンク: 全行をフラットバッファに蓄積する。
/// Phase 2 以降は TileSink で置き換える。
pub const SliceSink = struct {
    buf: []u8,
    row_stride: usize, // dst_width * channels

    pub fn init(buf: []u8, dst_width: u32, channels: u8) SliceSink {
        return .{ .buf = buf, .row_stride = @as(usize, dst_width) * channels };
    }

    pub fn rowSink(self: *SliceSink) RowSink {
        return .{ .ctx = self, .writeFn = writeFn };
    }

    fn writeFn(ctx: *anyopaque, row: []const u8, dst_y: u32) anyerror!void {
        const self: *SliceSink = @ptrCast(@alignCast(ctx));
        const start = dst_y * self.row_stride;
        @memcpy(self.buf[start .. start + self.row_stride], row);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// H-pass コア (full-frame / streaming 共用)
// ─────────────────────────────────────────────────────────────────────────────

/// 1 行 (u8) を Lanczos-3 H-pass して f32 行に変換する。
/// full-frame 版と StreamingResizer の両方がこれを呼ぶ (重複なし)。
fn hPassRow(src_row: []const u8, out_row: []f32, sw: u32, ch: u8, scale_x: f32) void {
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
        for (0..ch) |c| out_row[dx * ch + c] = @floatCast(sum[c] / weight_sum);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lanczos-3 カーネル
// ─────────────────────────────────────────────────────────────────────────────

/// Lanczos-3 窓関数: sinc(x) * sinc(x/a), |x| < a=3
/// SIMD 実装 (Phase 3) はこの出力と一致することを検証すること。
pub fn lanczosKernel(x: f32) f32 {
    const ax = @abs(x);
    if (ax == 0.0) return 1.0;
    if (ax >= LANCZOS_A) return 0.0;
    const pi_x = math.pi * x;
    const pi_x_a = math.pi * x / LANCZOS_A;
    return (math.sin(pi_x) / pi_x) * (math.sin(pi_x_a) / pi_x_a);
}

// ─────────────────────────────────────────────────────────────────────────────
// フルフレーム リサイズ (リファレンス実装)
// ─────────────────────────────────────────────────────────────────────────────

/// Lanczos-3 フルフレームリサイズ (f32 スカラー)
/// StreamingResizer の正解基準として使う。
/// src_data: u8 RGBA interleaved / dst_data: 呼び出し元確保済み
pub fn resizeLanczos3(
    allocator: std.mem.Allocator,
    src_data: []const u8,
    dst_data: []u8,
    config: ResizeConfig,
) ResizeError!void {
    if (config.channels == 0 or config.channels > 4) return ResizeError.UnsupportedChannelCount;

    const sw = config.src_width;
    // バッファ長の事前検証 (FFI 経由でも安全に失敗させる)
    {
        const expected_src = @as(usize, config.src_height) * config.src_width * config.channels;
        const expected_dst = @as(usize, config.dst_height) * config.dst_width * config.channels;
        if (src_data.len < expected_src) return ResizeError.InvalidInputDimensions;
        if (dst_data.len < expected_dst) return ResizeError.InvalidInputDimensions;
    }
    const sh = config.src_height;
    const dw = config.dst_width;
    const dh = config.dst_height;
    const ch = config.channels;
    const row_stride = @as(usize, dw) * ch;
    const scale_x: f32 = @as(f32, @floatFromInt(dw)) / @as(f32, @floatFromInt(sw));
    const scale_y: f32 = @as(f32, @floatFromInt(dh)) / @as(f32, @floatFromInt(sh));

    const inter = allocator.alloc(f32, @as(usize, sh) * row_stride) catch
        return ResizeError.OutOfMemory;
    defer allocator.free(inter);

    for (0..sh) |y| {
        hPassRow(
            src_data[y * sw * ch .. (y + 1) * sw * ch],
            inter[y * row_stride .. (y + 1) * row_stride],
            sw, ch, scale_x,
        );
    }
    vPassFull(inter, dst_data, sh, dh, dw, ch, scale_y);
}

fn vPassFull(inter: []const f32, dst: []u8, sh: u32, dh: u32, dw: u32, ch: u8, scale_y: f32) void {
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
                const w = lanczosKernel(
                    (@as(f32, @floatFromInt(sy)) - sy_center) * @min(scale_y, 1.0),
                );
                if (w == 0.0) continue;
                const clamped: usize = @intCast(std.math.clamp(sy, 0, @as(i64, @intCast(sh)) - 1));
                const base = clamped * row_stride + dx * ch;
                for (0..ch) |c| sum[c] += @as(f64, inter[base + c]) * w;
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
/// ピーク消費メモリ (4000px 幅, 等倍):
///   ring   : 8 行 × 4000px × 4ch × 4B = 512 KB
///   hpass  : 1 行 ×            〃      =  64 KB
///   out_row: 1 行 × 4000px × 4ch × 1B =  16 KB
///   合計 ≈ 600 KB (全体バッファ方式の 1/数十)
///
/// 使い方:
///   var sr = try StreamingResizer.init(alloc, config);
///   defer sr.deinit();
///   var sink = SliceSink.init(dst_buf, dw, ch);
///   for (src_rows) |row| try sr.feedRow(row, sink.rowSink());
///   try sr.flush(sink.rowSink());
pub const StreamingResizer = struct {
    allocator: std.mem.Allocator,
    config: ResizeConfig,
    scale_x: f32,
    scale_y: f32,
    support_y: f32,
    /// H-pass 済み中間行のスライディングウィンドウ (f32, dst_width × channels)
    ring: ring_mod.RingBuffer(f32),
    /// H-pass 一時出力 (1 行分, f32)
    hpass_buf: []f32,
    /// V-pass 出力ステージングバッファ (1 行分, u8) — シンクに渡す直前に書き込む
    out_row_buf: []u8,
    src_rows_fed: u32,
    dst_rows_emitted: u32,

    pub fn init(allocator: std.mem.Allocator, config: ResizeConfig) ResizeError!StreamingResizer {
        if (config.channels == 0 or config.channels > 4)
            return ResizeError.UnsupportedChannelCount;

        const scale_x: f32 = @as(f32, @floatFromInt(config.dst_width)) /
            @as(f32, @floatFromInt(config.src_width));
        const scale_y: f32 = @as(f32, @floatFromInt(config.dst_height)) /
            @as(f32, @floatFromInt(config.src_height));
        const support_y = LANCZOS_A / @min(scale_y, 1.0);
        // ring_cap: カーネルスパン + 2 の余裕 (ring sizing 証明は resize.zig コメント参照)
        const ring_cap: usize = @as(usize, @intFromFloat(@ceil(2.0 * support_y))) + 2;
        const f32_stride: usize = @as(usize, config.dst_width) * config.channels;
        const u8_stride: usize = @as(usize, config.dst_width) * config.channels;

        var ring = ring_mod.RingBuffer(f32).init(allocator, ring_cap, f32_stride) catch
            return ResizeError.OutOfMemory;
        errdefer ring.deinit(allocator);

        const hpass_buf = allocator.alloc(f32, f32_stride) catch
            return ResizeError.OutOfMemory;
        errdefer allocator.free(hpass_buf);

        const out_row_buf = allocator.alloc(u8, u8_stride) catch
            return ResizeError.OutOfMemory;

        return .{
            .allocator = allocator,
            .config = config,
            .scale_x = scale_x,
            .scale_y = scale_y,
            .support_y = support_y,
            .ring = ring,
            .hpass_buf = hpass_buf,
            .out_row_buf = out_row_buf,
            .src_rows_fed = 0,
            .dst_rows_emitted = 0,
        };
    }

    pub fn deinit(self: *StreamingResizer) void {
        self.ring.deinit(self.allocator);
        self.allocator.free(self.hpass_buf);
        self.allocator.free(self.out_row_buf);
        self.* = undefined;
    }

    /// 1 行分のソースデータを受け取り、準備できた出力行を sink に書き出す。
    /// src_row の長さは src_width * channels でなければならない。
    pub fn feedRow(self: *StreamingResizer, src_row: []const u8, sink: RowSink) !void {
        if (src_row.len != @as(usize, self.config.src_width) * self.config.channels)
            return ResizeError.InvalidInputDimensions;

        hPassRow(src_row, self.hpass_buf, self.config.src_width, self.config.channels, self.scale_x);
        self.ring.pushRow(self.hpass_buf);
        self.src_rows_fed += 1;

        try self.emitReady(sink);
    }

    /// 全ソース行を受け取った後、残りの出力行を sink に書き出す。
    /// src_height 回 feedRow を呼んでから呼ぶ。
    pub fn flush(self: *StreamingResizer, sink: RowSink) !void {
        if (self.src_rows_fed != self.config.src_height)
            return ResizeError.IncompleteInput;
        while (self.dst_rows_emitted < self.config.dst_height) {
            try self.emitRow(self.dst_rows_emitted, sink);
            self.dst_rows_emitted += 1;
        }
    }

    pub fn isDone(self: *const StreamingResizer) bool {
        return self.dst_rows_emitted == self.config.dst_height;
    }

    // ── 内部実装 ──────────────────────────────────────────────────────────────

    fn emitReady(self: *StreamingResizer, sink: RowSink) !void {
        const sh_i64: i64 = @intCast(self.config.src_height);
        while (self.dst_rows_emitted < self.config.dst_height) {
            const dy = self.dst_rows_emitted;
            const sy_center = (@as(f32, @floatFromInt(dy)) + 0.5) / self.scale_y - 0.5;
            const sy_max_raw: i64 = @intFromFloat(@ceil(sy_center + self.support_y));
            const actual_sy_max = @min(sy_max_raw, sh_i64 - 1);

            if (actual_sy_max >= @as(i64, @intCast(self.src_rows_fed))) break;

            try self.emitRow(dy, sink);
            self.dst_rows_emitted += 1;
        }
    }

    fn emitRow(self: *StreamingResizer, dy: u32, sink: RowSink) !void {
        const dw = self.config.dst_width;
        const ch = self.config.channels;
        const sh = self.config.src_height;
        const sy_center = (@as(f32, @floatFromInt(dy)) + 0.5) / self.scale_y - 0.5;
        const sy_min: i64 = @intFromFloat(@floor(sy_center - self.support_y));
        const sy_max: i64 = @intFromFloat(@ceil(sy_center + self.support_y));

        for (0..dw) |dx| {
            var sum = [_]f64{0.0} ** 4;
            var weight_sum: f64 = 0.0;

            var sy: i64 = sy_min;
            while (sy <= sy_max) : (sy += 1) {
                const w = lanczosKernel(
                    (@as(f32, @floatFromInt(sy)) - sy_center) * @min(self.scale_y, 1.0),
                );
                if (w == 0.0) continue;

                const clamped: usize = @intCast(
                    std.math.clamp(sy, 0, @as(i64, @intCast(sh)) - 1),
                );
                const row = self.ring.getRow(clamped) orelse
                    return ResizeError.InternalRingEviction;

                for (0..ch) |c| sum[c] += @as(f64, row[dx * ch + c]) * w;
                weight_sum += w;
            }

            for (0..ch) |c| {
                self.out_row_buf[dx * ch + c] = @intFromFloat(
                    std.math.clamp(@round(sum[c] / weight_sum), 0.0, 255.0),
                );
            }
        }

        try sink.writeRow(self.out_row_buf, dy);
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
    for (xs) |x| try std.testing.expectApproxEqAbs(lanczosKernel(x), lanczosKernel(-x), 1e-6);
}

test "lanczosKernel: 整数座標でゼロ交差" {
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
    const src = [_]u8{ 255, 128, 64, 255 } ** (4 * 4);
    var dst = [_]u8{0} ** (2 * 2 * 4);
    try resizeLanczos3(std.testing.allocator, &src, &dst, .{
        .src_width = 4, .src_height = 4, .dst_width = 2, .dst_height = 2,
    });
    for (0..4) |i| try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(src[i])), @as(f32, @floatFromInt(dst[i])), 2.0,
    );
}

test "resizeLanczos3: src_data 短すぎ → InvalidInputDimensions" {
    var dst = [_]u8{0} ** 4;
    try std.testing.expectError(ResizeError.InvalidInputDimensions, resizeLanczos3(
        std.testing.allocator,
        &[_]u8{ 0, 1, 2 }, // 4 bytes 必要なのに 3 bytes
        &dst,
        .{ .src_width = 1, .src_height = 1, .dst_width = 1, .dst_height = 1 },
    ));
}

test "resizeLanczos3: dst_data 短すぎ → InvalidInputDimensions" {
    var dst = [_]u8{ 0, 0 }; // 4 bytes 必要なのに 2 bytes
    try std.testing.expectError(ResizeError.InvalidInputDimensions, resizeLanczos3(
        std.testing.allocator,
        &[_]u8{ 0, 0, 0, 0 },
        &dst,
        .{ .src_width = 1, .src_height = 1, .dst_width = 1, .dst_height = 1 },
    ));
}

test "resizeLanczos3: channels=5 は UnsupportedChannelCount" {
    var dst = [_]u8{0} ** 4;
    try std.testing.expectError(ResizeError.UnsupportedChannelCount, resizeLanczos3(
        std.testing.allocator, &[_]u8{0} ** 4, &dst,
        .{ .src_width = 1, .src_height = 1, .dst_width = 1, .dst_height = 1, .channels = 5 },
    ));
}

test "StreamingResizer.init: channels=5 は UnsupportedChannelCount" {
    try std.testing.expectError(ResizeError.UnsupportedChannelCount, StreamingResizer.init(
        std.testing.allocator,
        .{ .src_width = 4, .src_height = 4, .dst_width = 2, .dst_height = 2, .channels = 5 },
    ));
}

test "StreamingResizer.feedRow: 行長不一致は InvalidInputDimensions" {
    var sr = try StreamingResizer.init(std.testing.allocator, .{
        .src_width = 4, .src_height = 4, .dst_width = 2, .dst_height = 2,
    });
    defer sr.deinit();

    var buf = [_]u8{0} ** (2 * 2 * 4);
    var ss = SliceSink.init(&buf, 2, 4);
    // 正しい長さ = 4 * 4 = 16。3 バイトで渡すとエラー。
    try std.testing.expectError(
        ResizeError.InvalidInputDimensions,
        sr.feedRow(&[_]u8{ 0, 1, 2 }, ss.rowSink()),
    );
}

test "StreamingResizer.flush: src_height 未満で flush は IncompleteInput" {
    var sr = try StreamingResizer.init(std.testing.allocator, .{
        .src_width = 4, .src_height = 4, .dst_width = 2, .dst_height = 2,
    });
    defer sr.deinit();

    var buf = [_]u8{0} ** (2 * 2 * 4);
    var ss = SliceSink.init(&buf, 2, 4);
    // 1 行だけ送って flush → エラー
    const row = [_]u8{128} ** (4 * 4);
    try sr.feedRow(&row, ss.rowSink());
    try std.testing.expectError(ResizeError.IncompleteInput, sr.flush(ss.rowSink()));
}

// ストリーミング版とフルフレーム版の出力一致 (安全網テスト)
fn streamMatchesFullframe(comptime SW: u32, comptime SH: u32, comptime DW: u32, comptime DH: u32) !void {
    const alloc = std.testing.allocator;
    const CH = 4;

    var src: [SH * SW * CH]u8 = undefined;
    for (0..SH) |y| for (0..SW) |x| {
        const b = (y * SW + x) * CH;
        src[b] = @intCast(x * 255 / @max(SW - 1, 1));
        src[b + 1] = @intCast(y * 255 / @max(SH - 1, 1));
        src[b + 2] = 128;
        src[b + 3] = 255;
    };

    var ref = [_]u8{0} ** (DH * DW * CH);
    try resizeLanczos3(alloc, &src, &ref, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });

    var out = [_]u8{0} ** (DH * DW * CH);
    var ss = SliceSink.init(&out, DW, CH);
    var sr = try StreamingResizer.init(alloc, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });
    defer sr.deinit();
    for (0..SH) |y| try sr.feedRow(src[y * SW * CH .. (y + 1) * SW * CH], ss.rowSink());
    try sr.flush(ss.rowSink());
    try std.testing.expect(sr.isDone());

    for (0..DH * DW * CH) |i| {
        const diff: i16 = @as(i16, ref[i]) - @as(i16, out[i]);
        if (diff < -1 or diff > 1) {
            std.debug.print("pixel[{d}]: ref={d} stream={d}\n", .{ i, ref[i], out[i] });
            return error.TestUnexpectedResult;
        }
    }
}

test "StreamingResizer: 8x8→4x4 縮小 (グラデーション)" {
    try streamMatchesFullframe(8, 8, 4, 4);
}

test "StreamingResizer: 8x8→4x4 縮小 (チェッカーボード)" {
    const alloc = std.testing.allocator;
    const SW = 8;
    const SH = 8;
    const DW = 4;
    const DH = 4;
    const CH = 4;

    var src: [SH * SW * CH]u8 = undefined;
    for (0..SH) |y| for (0..SW) |x| {
        const v: u8 = if ((x + y) % 2 == 0) 240 else 20;
        const b = (y * SW + x) * CH;
        src[b] = v; src[b + 1] = v; src[b + 2] = v; src[b + 3] = 255;
    };

    var ref = [_]u8{0} ** (DH * DW * CH);
    try resizeLanczos3(alloc, &src, &ref, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });

    var out = [_]u8{0} ** (DH * DW * CH);
    var ss = SliceSink.init(&out, DW, CH);
    var sr = try StreamingResizer.init(alloc, .{
        .src_width = SW, .src_height = SH, .dst_width = DW, .dst_height = DH,
    });
    defer sr.deinit();
    for (0..SH) |y| try sr.feedRow(src[y * SW * CH .. (y + 1) * SW * CH], ss.rowSink());
    try sr.flush(ss.rowSink());

    for (0..DH * DW * CH) |i| {
        const diff: i16 = @as(i16, ref[i]) - @as(i16, out[i]);
        try std.testing.expect(diff >= -1 and diff <= 1);
    }
}

test "StreamingResizer: 4x4→8x8 拡大" {
    try streamMatchesFullframe(4, 4, 8, 8);
}
