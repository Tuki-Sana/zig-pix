/// test/bench/main.zig — リサイズ性能ベンチマーク
///
/// zig build bench              → SIMD off (default)
/// zig build bench -Dsimd=true  → SIMD on
///
/// 計測項目:
///   1. lanczosKernel マイクロベンチ (10M 呼び出し)
///   2. resizeLanczos3 フルフレーム (1920×1080 → 640×360, RGBA)
///   3. StreamingResizer   (同サイズ, RGBA)
///   4. resizeLanczos3 フルフレーム (1920×1080 → 640×360, RGB, ch=3 fallback 確認)

const std = @import("std");
const pict = @import("pict");

const resize = pict.resize;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    const simd_label = if (resize.simd_enabled) "SIMD=on " else "SIMD=off";
    try stdout.print("pict-zig-engine benchmarks  [{s}]\n", .{simd_label});
    try stdout.writeAll("==========================================\n\n");

    try benchLanczosKernel(stdout);
    try benchFullFrame(alloc, stdout, 1920, 1080, 640, 360, 4, "RGBA 1920×1080→640×360");
    try benchStreaming(alloc, stdout, 1920, 1080, 640, 360, 4, "RGBA 1920×1080→640×360 (streaming)");
    try benchFullFrame(alloc, stdout, 1920, 1080, 640, 360, 3, "RGB  1920×1080→640×360 (ch=3 fallback)");
}

// ─── マイクロベンチ ──────────────────────────────────────────────────────────

fn benchLanczosKernel(out: anytype) !void {
    const N = 10_000_000;
    var sum: f64 = 0;

    const t0 = std.time.nanoTimestamp();
    for (0..N) |i| {
        const x = @as(f32, @floatFromInt(i % 600)) / 100.0 - 3.0;
        sum += resize.lanczosKernel(x);
    }
    const elapsed_ns = std.time.nanoTimestamp() - t0;

    try out.print(
        "lanczosKernel  {d:>7.2} ns/call   N={d}  checksum={d:.4}\n",
        .{ @as(f64, @floatFromInt(elapsed_ns)) / N, N, sum },
    );
}

// ─── フルフレームリサイズ ────────────────────────────────────────────────────

fn benchFullFrame(
    alloc: std.mem.Allocator,
    out: anytype,
    sw: u32,
    sh: u32,
    dw: u32,
    dh: u32,
    ch: u8,
    label: []const u8,
) !void {
    const src_len = @as(usize, sw) * sh * ch;
    const dst_len = @as(usize, dw) * dh * ch;

    const src = try alloc.alloc(u8, src_len);
    defer alloc.free(src);
    const dst = try alloc.alloc(u8, dst_len);
    defer alloc.free(dst);

    // 疑似画像データ (グラデーション)
    for (src, 0..) |*p, i| p.* = @intCast(i % 251);

    // ウォームアップ
    try resize.resizeLanczos3(alloc, src, dst, .{
        .src_width = sw, .src_height = sh,
        .dst_width = dw, .dst_height = dh,
        .channels = ch,
    });

    // 計測
    const RUNS = 5;
    const t0 = std.time.nanoTimestamp();
    for (0..RUNS) |_| {
        try resize.resizeLanczos3(alloc, src, dst, .{
            .src_width = sw, .src_height = sh,
            .dst_width = dw, .dst_height = dh,
            .channels = ch,
        });
    }
    const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000.0;

    try out.print(
        "{s:<42} {d:>7.1} ms/frame  (avg of {d})\n",
        .{ label, elapsed_ms / RUNS, RUNS },
    );
}

// ─── ストリーミングリサイザー ────────────────────────────────────────────────

fn benchStreaming(
    alloc: std.mem.Allocator,
    out: anytype,
    sw: u32,
    sh: u32,
    dw: u32,
    dh: u32,
    ch: u8,
    label: []const u8,
) !void {
    const src_row_len = @as(usize, sw) * ch;
    const dst_len = @as(usize, dw) * dh * ch;

    const src = try alloc.alloc(u8, src_row_len * sh);
    defer alloc.free(src);
    const dst = try alloc.alloc(u8, dst_len);
    defer alloc.free(dst);

    for (src, 0..) |*p, i| p.* = @intCast(i % 251);

    const cfg = resize.ResizeConfig{
        .src_width = sw, .src_height = sh,
        .dst_width = dw, .dst_height = dh,
        .channels = ch,
    };

    // ウォームアップ
    try runStreaming(alloc, src, dst, sw, sh, dw, dh, ch, cfg);

    // 計測
    const RUNS = 5;
    const t0 = std.time.nanoTimestamp();
    for (0..RUNS) |_| {
        try runStreaming(alloc, src, dst, sw, sh, dw, dh, ch, cfg);
    }
    const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000.0;

    try out.print(
        "{s:<42} {d:>7.1} ms/frame  (avg of {d})\n",
        .{ label, elapsed_ms / RUNS, RUNS },
    );
}

fn runStreaming(
    alloc: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    sw: u32,
    sh: u32,
    dw: u32,
    _: u32,
    ch: u8,
    cfg: resize.ResizeConfig,
) !void {
    var sr = try resize.StreamingResizer.init(alloc, cfg);
    defer sr.deinit();

    var sink = resize.SliceSink.init(dst, dw, ch);
    const src_row_len = @as(usize, sw) * ch;
    for (0..sh) |y| {
        const row = src[y * src_row_len .. (y + 1) * src_row_len];
        try sr.feedRow(row, sink.rowSink());
    }
    try sr.flush(sink.rowSink());
}
