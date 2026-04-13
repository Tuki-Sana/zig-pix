/// resize.zig — Lanczos-3 リサイズ (f32 スカラー リファレンス実装)
///
/// 設計方針 (Q2):
///   - f32 スカラーで「数学的正解」を確立する。SIMD は Phase 3 でこの実装を安全網にして導入。
///   - 2-pass 分離フィルタ: H-pass (横方向) → V-pass (縦方向)
///   - a = 3: カーネル半径 3px, 各軸最大 6 tap

const std = @import("std");
const math = std.math;
const ring_mod = @import("../mem/ring.zig");
const build_options = @import("build_options");

/// ビルド時 SIMD フラグ。`zig build -Dsimd=true` で有効化、デフォルト false。
/// Phase 3B でこのフラグが true のとき NEON / SSE 実装に切り替わる。
pub const simd_enabled: bool = build_options.simd_enabled;

// ─────────────────────────────────────────────────────────────────────────────
// 型定義
// ─────────────────────────────────────────────────────────────────────────────

pub const LANCZOS_A: f32 = 3.0;

/// channels は 1–4 をサポート (sum バッファ上限 = 4)
pub const ResizeConfig = struct {
    src_width: u32,
    src_height: u32,
    dst_width: u32,
    dst_height: u32,
    /// サポート値: 1 (Gray), 2 (Gray+A), 3 (RGB), 4 (RGBA)
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
/// comptime simd_enabled で SIMD / スカラーを切り替える。
fn hPassRow(src_row: []const u8, out_row: []f32, sw: u32, ch: u8, scale_x: f32) void {
    if (comptime simd_enabled) {
        hPassRowSimd(src_row, out_row, sw, ch, scale_x);
    } else {
        hPassRowScalar(src_row, out_row, sw, ch, scale_x);
    }
}

/// スカラー実装 (f32 リファレンス)。SIMD 実装の正解基準として残す。
fn hPassRowScalar(src_row: []const u8, out_row: []f32, sw: u32, ch: u8, scale_x: f32) void {
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

/// SIMD H-pass 実装 — Zig @Vector(4, f32) で 4 チャンネルを並列処理する。
///
/// 戦略:
///   - ch == 4 (RGBA) のとき @Vector(4, f32) でチャンネル方向の積算を並列化する。
///   - ch != 4 (RGB 等) の場合はスカラーにフォールバックする。
///   - 各 tap のカーネル重みは引き続きスカラー `lanczosKernel` で計算する。
///   - f32 積算 (スカラーは f64) のため精度差が生じるが ±1 LSB 以内に収まる。
///   - Phase 3B 完了: H-pass / V-pass ともに SIMD 実装済み。
fn hPassRowSimd(src_row: []const u8, out_row: []f32, sw: u32, ch: u8, scale_x: f32) void {
    if (ch != 4) {
        // RGB (ch=3) など 4ch 以外はスカラーで処理する。
        hPassRowScalar(src_row, out_row, sw, ch, scale_x);
        return;
    }

    const Vec4f = @Vector(4, f32);
    const dw = out_row.len / 4;
    const support = LANCZOS_A / @min(scale_x, 1.0);

    for (0..dw) |dx| {
        const sx_center = (@as(f32, @floatFromInt(dx)) + 0.5) / scale_x - 0.5;
        const sx_min: i64 = @intFromFloat(@floor(sx_center - support));
        const sx_max: i64 = @intFromFloat(@ceil(sx_center + support));

        // 4 チャンネルを f32 ベクトルで並列積算する。
        var sum: Vec4f = @splat(0.0);
        var weight_sum: f32 = 0.0;

        var sx: i64 = sx_min;
        while (sx <= sx_max) : (sx += 1) {
            const kernel_x = (@as(f32, @floatFromInt(sx)) - sx_center) * @min(scale_x, 1.0);
            const w: f32 = lanczosKernel(kernel_x);
            if (w == 0.0) continue;

            const clamped: usize = @intCast(std.math.clamp(sx, 0, @as(i64, @intCast(sw)) - 1));
            const base = clamped * 4;
            // u8×4 を f32×4 ベクトルにロードして重み付き加算する。
            const px: Vec4f = .{
                @floatFromInt(src_row[base + 0]),
                @floatFromInt(src_row[base + 1]),
                @floatFromInt(src_row[base + 2]),
                @floatFromInt(src_row[base + 3]),
            };
            const wv: Vec4f = @splat(w);
            sum += px * wv;
            weight_sum += w;
        }

        // 正規化して out_row に書き出す。
        const inv_w: Vec4f = @splat(1.0 / weight_sum);
        const result = sum * inv_w;
        out_row[dx * 4 + 0] = result[0];
        out_row[dx * 4 + 1] = result[1];
        out_row[dx * 4 + 2] = result[2];
        out_row[dx * 4 + 3] = result[3];
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

// ─────────────────────────────────────────────────────────────────────────────
// V-pass 行取得抽象 (RowSource)
//
// `vPassOneDyRow*` は V-pass カーネルの積算ロジックを 1 行単位で提供する。
// 行データの取得元が「連続 inter バッファ」か「ring バッファ」かは RowSource で抽象化し、
// vPassFull* と StreamingResizer.emitRow が同一の計算コアを共有できるようにする。
// ─────────────────────────────────────────────────────────────────────────────

/// V-pass の行アクセス抽象。RowSink と対称な vtable 設計。
/// `get(sy)` はソース空間の絶対行インデックス `sy` を受け取り行スライスを返す。
/// ring バッファの場合、窓外の行は null を返す (→ InternalRingEviction)。
const RowSource = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, sy: usize) ?[]const f32,

    fn get(self: RowSource, sy: usize) ?[]const f32 {
        return self.getFn(self.ctx, sy);
    }
};

/// 連続 f32 中間バッファ用 RowSource — vPassFull* から使用する。
/// clamped インデックスは常に [0, sh-1] に収まるため null は返さない。
const InterSource = struct {
    inter: []const f32,
    row_stride: usize,

    fn rowSource(self: *InterSource) RowSource {
        return .{ .ctx = self, .getFn = getFn };
    }

    fn getFn(ctx: *anyopaque, sy: usize) ?[]const f32 {
        const s: *InterSource = @ptrCast(@alignCast(ctx));
        const base = sy * s.row_stride;
        return s.inter[base .. base + s.row_stride];
    }
};

/// RingBuffer(f32) 用 RowSource — StreamingResizer.emitRow から使用する。
/// 窓外の行が要求された場合は null を返し、呼び出し元が InternalRingEviction を返す。
const RingSource = struct {
    ring: *const ring_mod.RingBuffer(f32),

    fn rowSource(self: *RingSource) RowSource {
        return .{ .ctx = self, .getFn = getFn };
    }

    fn getFn(ctx: *anyopaque, sy: usize) ?[]const f32 {
        const s: *RingSource = @ptrCast(@alignCast(ctx));
        return s.ring.getRow(sy);
    }
};

/// V-pass ディスパッチャ: comptime simd_enabled で SIMD / スカラーを切り替える。
fn vPassFull(inter: []const f32, dst: []u8, sh: u32, dh: u32, dw: u32, ch: u8, scale_y: f32) void {
    if (comptime simd_enabled) {
        vPassFullSimd(inter, dst, sh, dh, dw, ch, scale_y);
    } else {
        vPassFullScalar(inter, dst, sh, dh, dw, ch, scale_y);
    }
}

/// スカラー V-pass フルフレームラッパー。
/// InterSource + vPassOneDyRowScalar を全 dy 行に適用する。
fn vPassFullScalar(inter: []const f32, dst: []u8, sh: u32, dh: u32, dw: u32, ch: u8, scale_y: f32) void {
    const support = LANCZOS_A / @min(scale_y, 1.0);
    const row_stride = @as(usize, dw) * ch;
    var src = InterSource{ .inter = inter, .row_stride = row_stride };
    const source = src.rowSource();
    for (0..dh) |dy| {
        // InterSource は clamped インデックスに対して null を返さない。
        vPassOneDyRowScalar(
            source,
            dst[dy * row_stride .. (dy + 1) * row_stride],
            @intCast(dy),
            sh, dw, ch, scale_y, support,
        ) catch unreachable;
    }
}

/// SIMD V-pass フルフレームラッパー。
/// InterSource + vPassOneDyRowSimd を全 dy 行に適用する。
/// ch != 4 は vPassOneDyRowSimd 内のフォールバックでスカラー処理される。
fn vPassFullSimd(inter: []const f32, dst: []u8, sh: u32, dh: u32, dw: u32, ch: u8, scale_y: f32) void {
    const support = LANCZOS_A / @min(scale_y, 1.0);
    const row_stride = @as(usize, dw) * ch;
    var src = InterSource{ .inter = inter, .row_stride = row_stride };
    const source = src.rowSource();
    for (0..dh) |dy| {
        // InterSource は clamped インデックスに対して null を返さない。
        vPassOneDyRowSimd(
            source,
            dst[dy * row_stride .. (dy + 1) * row_stride],
            @intCast(dy),
            sh, dw, ch, scale_y, support,
        ) catch unreachable;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// V-pass 1 行計算コア
//
// vPassFull* と StreamingResizer.emitRow が共有する計算の単一実装。
// SIMD / スカラーの分岐はここのみに集約し、外側のループ構造は各呼び出し元が担う。
// ─────────────────────────────────────────────────────────────────────────────

/// V-pass スカラー 1 行コア (f64 積算)。
/// RowSource 経由で行データを取得するため、inter バッファと ring の両方に対応する。
fn vPassOneDyRowScalar(
    source: RowSource,
    dst_row: []u8,
    dy: u32,
    sh: u32,
    dw: u32,
    ch: u8,
    scale_y: f32,
    support_y: f32,
) ResizeError!void {
    const sy_center = (@as(f32, @floatFromInt(dy)) + 0.5) / scale_y - 0.5;
    const sy_min: i64 = @intFromFloat(@floor(sy_center - support_y));
    const sy_max: i64 = @intFromFloat(@ceil(sy_center + support_y));

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
            const row = source.get(clamped) orelse return ResizeError.InternalRingEviction;
            for (0..ch) |c| sum[c] += @as(f64, row[dx * ch + c]) * w;
            weight_sum += w;
        }

        const dst_base = dx * ch;
        for (0..ch) |c| {
            dst_row[dst_base + c] = @intFromFloat(
                std.math.clamp(@round(sum[c] / weight_sum), 0.0, 255.0),
            );
        }
    }
}

/// V-pass SIMD 1 行コア (@Vector(4, f32)、f32 積算)。
/// ch == 4 のときのみ SIMD を使用し、それ以外は vPassOneDyRowScalar に委譲する。
fn vPassOneDyRowSimd(
    source: RowSource,
    dst_row: []u8,
    dy: u32,
    sh: u32,
    dw: u32,
    ch: u8,
    scale_y: f32,
    support_y: f32,
) ResizeError!void {
    if (ch != 4) {
        return vPassOneDyRowScalar(source, dst_row, dy, sh, dw, ch, scale_y, support_y);
    }

    const Vec4f = @Vector(4, f32);
    const sy_center = (@as(f32, @floatFromInt(dy)) + 0.5) / scale_y - 0.5;
    const sy_min: i64 = @intFromFloat(@floor(sy_center - support_y));
    const sy_max: i64 = @intFromFloat(@ceil(sy_center + support_y));

    for (0..dw) |dx| {
        var sum: Vec4f = @splat(0.0);
        var weight_sum: f32 = 0.0;

        var sy: i64 = sy_min;
        while (sy <= sy_max) : (sy += 1) {
            const w: f32 = lanczosKernel(
                (@as(f32, @floatFromInt(sy)) - sy_center) * @min(scale_y, 1.0),
            );
            if (w == 0.0) continue;
            const clamped: usize = @intCast(std.math.clamp(sy, 0, @as(i64, @intCast(sh)) - 1));
            const row = source.get(clamped) orelse return ResizeError.InternalRingEviction;
            const base = dx * 4;
            const px: Vec4f = .{ row[base + 0], row[base + 1], row[base + 2], row[base + 3] };
            const wv: Vec4f = @splat(w);
            sum += px * wv;
            weight_sum += w;
        }

        const inv_w: Vec4f = @splat(1.0 / weight_sum);
        const result = sum * inv_w;
        const base = dx * 4;
        dst_row[base + 0] = @intFromFloat(std.math.clamp(@round(result[0]), 0.0, 255.0));
        dst_row[base + 1] = @intFromFloat(std.math.clamp(@round(result[1]), 0.0, 255.0));
        dst_row[base + 2] = @intFromFloat(std.math.clamp(@round(result[2]), 0.0, 255.0));
        dst_row[base + 3] = @intFromFloat(std.math.clamp(@round(result[3]), 0.0, 255.0));
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
        // RingSource 経由で vPassOneDyRow* を呼び、vPassFull* と計算ロジックを共有する。
        var ring_src = RingSource{ .ring = &self.ring };
        const source = ring_src.rowSource();
        if (comptime simd_enabled) {
            try vPassOneDyRowSimd(
                source, self.out_row_buf, dy,
                self.config.src_height, self.config.dst_width, self.config.channels,
                self.scale_y, self.support_y,
            );
        } else {
            try vPassOneDyRowScalar(
                source, self.out_row_buf, dy,
                self.config.src_height, self.config.dst_width, self.config.channels,
                self.scale_y, self.support_y,
            );
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

// ─────────────────────────────────────────────────────────────────────────────
// Phase 3A: SIMD トグル scaffold テスト
// ─────────────────────────────────────────────────────────────────────────────

test "simd_enabled: bool 型でアクセス可能" {
    // true / false どちらのビルドでもクラッシュしないことを確認する。
    const x: bool = simd_enabled;
    _ = x;
}

test "simd toggle: hPassRow + vPassFull がどちらのパスでもクラッシュしない" {
    // simd_enabled の値に関わらず resize 結果が一致することを確認する。
    const src = [_]u8{ 100, 150, 200, 255 } ** (2 * 2);
    var dst = [_]u8{0} ** (2 * 2 * 4);
    try resizeLanczos3(std.testing.allocator, &src, &dst, .{
        .src_width = 2, .src_height = 2, .dst_width = 2, .dst_height = 2,
    });
    for (0..4) |i| {
        const diff: i16 = @as(i16, src[i]) - @as(i16, dst[i]);
        try std.testing.expect(diff >= -1 and diff <= 1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 3B: H-pass SIMD 正確性テスト
// ─────────────────────────────────────────────────────────────────────────────

// hPassRowSimd と hPassRowScalar を直接比較する。
// -Dsimd=false でも常に両関数を呼び出してプライベート関数の正確性を検証する。
test "hPassRowSimd: 4ch グラデーション行でスカラーと ±1.0 以内に一致 (2x downscale)" {
    const SW: u32 = 8;
    const DW: u32 = 4;
    const CH: u8 = 4;
    const scale_x: f32 = @as(f32, @floatFromInt(DW)) / @as(f32, @floatFromInt(SW));

    var src: [SW * CH]u8 = undefined;
    for (0..SW) |x| {
        src[x * CH + 0] = @intCast(x * 255 / (SW - 1));
        src[x * CH + 1] = @intCast((SW - 1 - x) * 255 / (SW - 1));
        src[x * CH + 2] = 128;
        src[x * CH + 3] = 255;
    }

    var ref: [DW * CH]f32 = undefined;
    var got: [DW * CH]f32 = undefined;
    hPassRowScalar(&src, &ref, SW, CH, scale_x);
    hPassRowSimd(&src, &got, SW, CH, scale_x);

    for (0..DW * CH) |i| {
        const diff = @abs(ref[i] - got[i]);
        if (diff > 1.0) {
            std.debug.print("hpass[{d}]: scalar={d:.4} simd={d:.4} diff={d:.6}\n", .{ i, ref[i], got[i], diff });
            return error.TestUnexpectedResult;
        }
    }
}

test "hPassRowSimd: 4ch チェッカーボード行でスカラーと ±1.0 以内に一致 (2x upscale)" {
    const SW: u32 = 4;
    const DW: u32 = 8;
    const CH: u8 = 4;
    const scale_x: f32 = @as(f32, @floatFromInt(DW)) / @as(f32, @floatFromInt(SW));

    var src: [SW * CH]u8 = undefined;
    for (0..SW) |x| {
        const v: u8 = if (x % 2 == 0) 240 else 20;
        src[x * CH + 0] = v;
        src[x * CH + 1] = v;
        src[x * CH + 2] = v;
        src[x * CH + 3] = 255;
    }

    var ref: [DW * CH]f32 = undefined;
    var got: [DW * CH]f32 = undefined;
    hPassRowScalar(&src, &ref, SW, CH, scale_x);
    hPassRowSimd(&src, &got, SW, CH, scale_x);

    for (0..DW * CH) |i| {
        const diff = @abs(ref[i] - got[i]);
        if (diff > 1.0) {
            std.debug.print("hpass[{d}]: scalar={d:.4} simd={d:.4} diff={d:.6}\n", .{ i, ref[i], got[i], diff });
            return error.TestUnexpectedResult;
        }
    }
}

test "hPassRowSimd: ch=3 (RGB) はスカラーフォールバックで一致" {
    const SW: u32 = 6;
    const DW: u32 = 3;
    const CH: u8 = 3;
    const scale_x: f32 = @as(f32, @floatFromInt(DW)) / @as(f32, @floatFromInt(SW));

    var src: [SW * CH]u8 = undefined;
    for (0..SW) |x| {
        src[x * CH + 0] = @intCast(x * 40);
        src[x * CH + 1] = 128;
        src[x * CH + 2] = @intCast(255 - x * 40);
    }

    var ref: [DW * CH]f32 = undefined;
    var got: [DW * CH]f32 = undefined;
    hPassRowScalar(&src, &ref, SW, CH, scale_x);
    hPassRowSimd(&src, &got, SW, CH, scale_x);  // フォールバック = スカラー → 完全一致

    for (0..DW * CH) |i| {
        try std.testing.expectEqual(ref[i], got[i]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 3B: V-pass SIMD 正確性テスト
// ─────────────────────────────────────────────────────────────────────────────

test "vPassFullSimd: 4ch グラデーション中間バッファでスカラーと ±1 以内に一致 (2x downscale)" {
    const SH: u32 = 8;
    const DW: u32 = 4;
    const DH: u32 = 4;
    const CH: u8 = 4;
    const scale_y: f32 = @as(f32, @floatFromInt(DH)) / @as(f32, @floatFromInt(SH));

    // H-pass 後の f32 中間バッファを模擬する (値は 0–255 の範囲内 f32)
    var inter: [SH * DW * CH]f32 = undefined;
    for (0..SH) |y| for (0..DW) |x| {
        const base = (y * DW + x) * CH;
        inter[base + 0] = @floatFromInt(x * 60 + y * 10);
        inter[base + 1] = @floatFromInt(255 - x * 50);
        inter[base + 2] = 128.0;
        inter[base + 3] = 255.0;
    };

    var ref: [DH * DW * CH]u8 = undefined;
    var got: [DH * DW * CH]u8 = undefined;
    vPassFullScalar(&inter, &ref, SH, DH, DW, CH, scale_y);
    vPassFullSimd(&inter, &got, SH, DH, DW, CH, scale_y);

    for (0..DH * DW * CH) |i| {
        const diff: i16 = @as(i16, ref[i]) - @as(i16, got[i]);
        if (diff < -1 or diff > 1) {
            std.debug.print("vpass[{d}]: scalar={d} simd={d}\n", .{ i, ref[i], got[i] });
            return error.TestUnexpectedResult;
        }
    }
}

test "vPassFullSimd: 4ch チェッカーボード中間バッファでスカラーと ±1 以内に一致 (2x upscale)" {
    const SH: u32 = 4;
    const DW: u32 = 4;
    const DH: u32 = 8;
    const CH: u8 = 4;
    const scale_y: f32 = @as(f32, @floatFromInt(DH)) / @as(f32, @floatFromInt(SH));

    var inter: [SH * DW * CH]f32 = undefined;
    for (0..SH) |y| for (0..DW) |x| {
        const v: f32 = if ((x + y) % 2 == 0) 240.0 else 20.0;
        const base = (y * DW + x) * CH;
        inter[base + 0] = v;
        inter[base + 1] = v;
        inter[base + 2] = v;
        inter[base + 3] = 255.0;
    };

    var ref: [DH * DW * CH]u8 = undefined;
    var got: [DH * DW * CH]u8 = undefined;
    vPassFullScalar(&inter, &ref, SH, DH, DW, CH, scale_y);
    vPassFullSimd(&inter, &got, SH, DH, DW, CH, scale_y);

    for (0..DH * DW * CH) |i| {
        const diff: i16 = @as(i16, ref[i]) - @as(i16, got[i]);
        if (diff < -1 or diff > 1) {
            std.debug.print("vpass[{d}]: scalar={d} simd={d}\n", .{ i, ref[i], got[i] });
            return error.TestUnexpectedResult;
        }
    }
}

test "vPassFullSimd: ch=3 (RGB) はスカラーフォールバックで完全一致" {
    const SH: u32 = 4;
    const DW: u32 = 4;
    const DH: u32 = 4;
    const CH: u8 = 3;
    const scale_y: f32 = 1.0;

    var inter: [SH * DW * CH]f32 = undefined;
    for (0..SH) |y| for (0..DW) |x| {
        const base = (y * DW + x) * CH;
        inter[base + 0] = @floatFromInt(x * 80);
        inter[base + 1] = @floatFromInt(y * 80);
        inter[base + 2] = 128.0;
    };

    var ref: [DH * DW * CH]u8 = undefined;
    var got: [DH * DW * CH]u8 = undefined;
    vPassFullScalar(&inter, &ref, SH, DH, DW, CH, scale_y);
    vPassFullSimd(&inter, &got, SH, DH, DW, CH, scale_y);  // フォールバック → 完全一致

    try std.testing.expectEqualSlices(u8, &ref, &got);
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 3B.5: StreamingResizer.emitRow 整合テスト
// ─────────────────────────────────────────────────────────────────────────────

test "StreamingResizer (emitRow): ch=3 (RGB) フォールバック回帰" {
    // ch=3 では simd_enabled の値に関わらず emitRow がスカラーフォールバックを使い、
    // resizeLanczos3 (フルフレーム) と ±1 以内で一致することを確認する。
    const alloc = std.testing.allocator;
    const SW: u32 = 6;
    const SH: u32 = 6;
    const DW: u32 = 3;
    const DH: u32 = 3;
    const CH: u8 = 3;

    var src: [SH * SW * CH]u8 = undefined;
    for (0..SH) |y| for (0..SW) |x| {
        const b = (y * SW + x) * CH;
        src[b + 0] = @intCast(x * 40);
        src[b + 1] = @intCast(y * 40);
        src[b + 2] = 128;
    };

    // フルフレーム参照値 (ch=3 は常にスカラー)
    var ref = [_]u8{0} ** (DH * DW * CH);
    try resizeLanczos3(alloc, &src, &ref, .{
        .src_width = SW, .src_height = SH,
        .dst_width = DW, .dst_height = DH,
        .channels = CH,
    });

    // ストリーミング (emitRow → ch=3 フォールバック)
    var out = [_]u8{0} ** (DH * DW * CH);
    var ss = SliceSink.init(&out, DW, CH);
    var sr = try StreamingResizer.init(alloc, .{
        .src_width = SW, .src_height = SH,
        .dst_width = DW, .dst_height = DH,
        .channels = CH,
    });
    defer sr.deinit();
    for (0..SH) |y| try sr.feedRow(src[y * SW * CH .. (y + 1) * SW * CH], ss.rowSink());
    try sr.flush(ss.rowSink());

    // ch=3 は full-frame / streaming ともに同一コア (vPassOneDyRowScalar) を通るため完全一致する。
    try std.testing.expectEqualSlices(u8, &ref, &out);
}
