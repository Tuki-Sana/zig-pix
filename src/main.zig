/// main.zig — CLI エントリポイント
///
/// パイプライン: ファイル読み込み → decode → (resize) → WebP encode → ファイル書き込み

const std = @import("std");
const pict = @import("pict");

const usage =
    \\Usage: pict [options] <input> <output>
    \\
    \\Options:
    \\  -w, --width  <px>     出力幅 (省略時: アスペクト比維持)
    \\  -h, --height <px>     出力高さ
    \\  -q, --quality <0-100> WebP 品質 (デフォルト: 92)
    \\  -t, --threads <n>     並列スレッド数 (0=自動, デフォルト: 1)
    \\  --lossless            ロスレス出力
    \\  --version             バージョンを表示
    \\
    \\Examples:
    \\  pict illustration.png output.webp -w 1920
    \\  pict portrait.jpg thumbnail.webp -w 400 -h 400 --threads 2
    \\
;

const CliArgs = struct {
    input: []const u8,
    output: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
    quality: f32 = 92.0,
    lossless: bool = false,
    /// 0 = CPU コア数を自動検出, 1 = シングルスレッド (デフォルト)
    threads: u32 = 1,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try std.io.getStdErr().writer().writeAll(usage);
        std.process.exit(1);
    }

    const cli = parseArgs(args) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: {s}\n\n{s}", .{ @errorName(err), usage });
        std.process.exit(1);
    };

    runPipeline(allocator, cli) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// パイプライン実装
// ─────────────────────────────────────────────────────────────────────────────

fn runPipeline(allocator: std.mem.Allocator, cli: CliArgs) !void {
    // ── 入力ファイル読み込み ──────────────────────────────────────────────────
    const input_data = try std.fs.cwd().readFileAlloc(allocator, cli.input, 256 * 1024 * 1024);
    defer allocator.free(input_data);

    // ── フォーマット検出 & デコード ──────────────────────────────────────────
    const fmt = pict.decode.detectFormat(input_data);
    var decoder = switch (fmt) {
        .jpeg => pict.decode.jpegDecoder(),
        .png  => pict.decode.pngDecoder(),
        .unknown => {
            std.log.err("Unsupported input format (expected JPEG or PNG): {s}", .{cli.input});
            return error.UnsupportedFormat;
        },
    };
    defer decoder.deinit();

    var src_buf = try decoder.decode(input_data, allocator);
    defer src_buf.deinit();

    std.log.info("Decoded: {s} → {}×{} ch={}", .{
        cli.input, src_buf.width, src_buf.height, src_buf.channels,
    });

    // ── リサイズ (必要な場合のみ) ──────────────────────────────────────────
    const out_buf: pict.decode.ImageBuffer = blk: {
        const dst_w, const dst_h = computeOutputDims(
            src_buf.width, src_buf.height,
            cli.width, cli.height,
        );

        if (dst_w == src_buf.width and dst_h == src_buf.height) {
            // リサイズ不要: 元バッファをそのまま使う (所有権は src_buf が持つ)
            break :blk src_buf;
        }

        std.log.info("Resize: {}×{} → {}×{}", .{ src_buf.width, src_buf.height, dst_w, dst_h });

        const dst_data = try allocator.alloc(u8, @as(usize, dst_w) * dst_h * src_buf.channels);
        errdefer allocator.free(dst_data);

        try pict.resize.resizeLanczos3(allocator, src_buf.data, dst_data, .{
            .src_width  = src_buf.width,
            .src_height = src_buf.height,
            .dst_width  = dst_w,
            .dst_height = dst_h,
            .channels   = src_buf.channels,
            .n_threads  = cli.threads,
        });

        break :blk pict.decode.ImageBuffer{
            .width     = dst_w,
            .height    = dst_h,
            .channels  = src_buf.channels,
            .format    = src_buf.format,
            .data      = dst_data,
            .allocator = allocator,
        };
    };
    // src_buf と out_buf が別オブジェクトの場合のみ out_buf を deinit する
    defer if (out_buf.data.ptr != src_buf.data.ptr) {
        var b = out_buf;
        b.deinit();
    };

    // ── WebP エンコード ───────────────────────────────────────────────────────
    var encoder = pict.encode.webpEncoder();
    defer encoder.deinit();

    var encoded = try encoder.encode(out_buf, .{ .webp = .{
        .quality  = cli.quality,
        .lossless = cli.lossless,
    } }, allocator);
    defer encoded.deinit();

    std.log.info("Encoded: {} bytes WebP → {s}", .{ encoded.data.len, cli.output });

    // ── 出力ファイル書き込み ─────────────────────────────────────────────────
    try std.fs.cwd().writeFile(.{
        .sub_path = cli.output,
        .data     = encoded.data,
    });

    std.log.info("Done.", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// 出力寸法計算 (アスペクト比維持)
// ─────────────────────────────────────────────────────────────────────────────

fn computeOutputDims(
    src_w: u32, src_h: u32,
    req_w: ?u32, req_h: ?u32,
) struct { u32, u32 } {
    if (req_w != null and req_h != null) return .{ req_w.?, req_h.? };

    if (req_w) |w| {
        const h = @max(1, @as(u32, @intFromFloat(
            @as(f64, @floatFromInt(src_h)) * @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(src_w))
        )));
        return .{ w, h };
    }
    if (req_h) |h| {
        const w = @max(1, @as(u32, @intFromFloat(
            @as(f64, @floatFromInt(src_w)) * @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(src_h))
        )));
        return .{ w, h };
    }
    return .{ src_w, src_h };
}

// ─────────────────────────────────────────────────────────────────────────────
// 引数パーサ
// ─────────────────────────────────────────────────────────────────────────────

fn parseArgs(args: []const []const u8) !CliArgs {
    if (args.len < 3) return error.TooFewArguments;

    // --version
    if (std.mem.eql(u8, args[1], "--version")) {
        try std.io.getStdOut().writer().print("pict-zig-engine v{s}\n", .{"0.1.0"});
        std.process.exit(0);
    }

    var result = CliArgs{
        .input  = args[1],
        .output = args[2],
    };

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            result.width = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--height")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            result.height = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quality")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const q = try std.fmt.parseFloat(f32, args[i]);
            if (std.math.isNan(q) or q < 0.0 or q > 100.0) return error.InvalidQuality;
            result.quality = q;
        } else if (std.mem.eql(u8, arg, "--lossless")) {
            result.lossless = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            result.threads = try std.fmt.parseInt(u32, args[i], 10);
        } else {
            return error.UnknownArgument;
        }
    }

    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// parseArgs ユニットテスト
// ─────────────────────────────────────────────────────────────────────────────

test "parseArgs: basic input/output" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqualStrings("in.jpg", cli.input);
    try std.testing.expectEqualStrings("out.webp", cli.output);
    try std.testing.expectEqual(@as(f32, 92.0), cli.quality);
    try std.testing.expectEqual(false, cli.lossless);
}

test "parseArgs: -w and -h" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "-w", "1920", "-h", "1080" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 1920), cli.width.?);
    try std.testing.expectEqual(@as(u32, 1080), cli.height.?);
}

test "parseArgs: --lossless flag" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "--lossless" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqual(true, cli.lossless);
}

test "parseArgs: -q valid value (80)" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "-q", "80" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqual(@as(f32, 80.0), cli.quality);
}

test "parseArgs: -q boundary 0 (valid)" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "-q", "0" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqual(@as(f32, 0.0), cli.quality);
}

test "parseArgs: -q boundary 100 (valid)" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "-q", "100" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqual(@as(f32, 100.0), cli.quality);
}

test "parseArgs: -q negative returns InvalidQuality" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "-q", "-1" };
    try std.testing.expectError(error.InvalidQuality, parseArgs(&args));
}

test "parseArgs: -q over 100 returns InvalidQuality" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "-q", "101" };
    try std.testing.expectError(error.InvalidQuality, parseArgs(&args));
}

test "parseArgs: -q NaN returns InvalidQuality" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "-q", "nan" };
    try std.testing.expectError(error.InvalidQuality, parseArgs(&args));
}

test "parseArgs: too few arguments" {
    const args = [_][]const u8{ "pict", "in.jpg" };
    try std.testing.expectError(error.TooFewArguments, parseArgs(&args));
}

test "parseArgs: unknown argument" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "--unknown" };
    try std.testing.expectError(error.UnknownArgument, parseArgs(&args));
}

test "parseArgs: missing value for -w" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "-w" };
    try std.testing.expectError(error.MissingValue, parseArgs(&args));
}

test "parseArgs: --threads 2 (explicit)" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "--threads", "2" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 2), cli.threads);
}

test "parseArgs: --threads 0 (auto)" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "--threads", "0" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 0), cli.threads);
}

test "parseArgs: -t shorthand for --threads" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "-t", "4" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 4), cli.threads);
}

test "parseArgs: --threads default is 1" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp" };
    const cli = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 1), cli.threads);
}

test "parseArgs: --threads missing value" {
    const args = [_][]const u8{ "pict", "in.jpg", "out.webp", "--threads" };
    try std.testing.expectError(error.MissingValue, parseArgs(&args));
}
