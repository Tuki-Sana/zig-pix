/// test/bench/main.zig — リサイズ性能ベンチマーク (Phase 4: マルチスレッド対応)
///
/// zig build bench                        → SIMD=off, threads=1
/// zig build bench -Dsimd=true            → SIMD=on,  threads=1
/// zig build bench -- --threads 2         → SIMD=off, threads=2
/// zig build bench -Dsimd=true -- --threads 2 → SIMD=on, threads=2
///
/// 計測項目:
///   1. lanczosKernel マイクロベンチ
///   2. resizeLanczos3 フルフレーム (1920×1080 → 640×360, RGBA)
///   3. StreamingResizer   (同サイズ, RGBA)
///   4. resizeLanczos3 フルフレーム (1920×1080 → 640×360, RGB, ch=3 fallback)

const std = @import("std");
const pict = @import("pict");

const resize = pict.resize;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // --threads <n> の解析 (0=自動, デフォルト=1)
    var n_threads: u32 = 1;
    var args_iter = try std.process.argsWithAllocator(alloc);
    defer args_iter.deinit();
    _ = args_iter.next(); // argv[0]
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--threads")) {
            if (args_iter.next()) |val| {
                n_threads = try std.fmt.parseInt(u32, val, 10);
                if (n_threads == 0) {
                    n_threads = @intCast(@max(1, std.Thread.getCpuCount() catch 1));
                }
            }
        }
    }

    const stdout = std.io.getStdOut().writer();

    const simd_label = if (resize.simd_enabled) "SIMD=on " else "SIMD=off";
    try stdout.print(
        "pict-zig-engine benchmarks  [{s}  threads={d}]\n",
        .{ simd_label, n_threads },
    );
    try stdout.writeAll("=============================================\n\n");

    try benchLanczosKernel(stdout);
    try benchFullFrame(alloc, stdout, 1920, 1080, 640, 360, 4, n_threads, "RGBA 1920×1080→640×360");
    try benchStreaming(alloc, stdout, 1920, 1080, 640, 360, 4, "RGBA 1920×1080→640×360 (streaming)");
    try benchFullFrame(alloc, stdout, 1920, 1080, 640, 360, 3, n_threads, "RGB  1920×1080→640×360 (ch=3 fallback)");
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
    n_threads: u32,
    label: []const u8,
) !void {
    const src_len = @as(usize, sw) * sh * ch;
    const dst_len = @as(usize, dw) * dh * ch;

    const src = try alloc.alloc(u8, src_len);
    defer alloc.free(src);
    const dst = try alloc.alloc(u8, dst_len);
    defer alloc.free(dst);

    for (src, 0..) |*p, i| p.* = @intCast(i % 251);

    const cfg = resize.ResizeConfig{
        .src_width = sw, .src_height = sh,
        .dst_width = dw, .dst_height = dh,
        .channels = ch, .n_threads = n_threads,
    };

    // ウォームアップ
    try resize.resizeLanczos3(alloc, src, dst, cfg);

    // 計測
    const RUNS = 5;
    const t0 = std.time.nanoTimestamp();
    for (0..RUNS) |_| {
        try resize.resizeLanczos3(alloc, src, dst, cfg);
    }
    const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000.0;

    try out.print(
        "{s:<44} {d:>7.1} ms/frame  (avg of {d})\n",
        .{ label, elapsed_ms / RUNS, RUNS },
    );
}

// ─── ストリーミングリサイザー (シングルスレッド) ─────────────────────────────

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

    try runStreaming(alloc, src, dst, sw, sh, dw, ch, cfg);

    const RUNS = 5;
    const t0 = std.time.nanoTimestamp();
    for (0..RUNS) |_| {
        try runStreaming(alloc, src, dst, sw, sh, dw, ch, cfg);
    }
    const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000.0;

    try out.print(
        "{s:<44} {d:>7.1} ms/frame  (avg of {d})\n",
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
