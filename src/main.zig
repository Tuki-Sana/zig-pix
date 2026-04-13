/// main.zig — CLI エントリポイント
///
/// Phase 0: 引数パース骨格のみ。
/// Phase 2 で decode → resize → encode の end-to-end を実装する。

const std = @import("std");
const pict = @import("pict");

const usage =
    \\Usage: pict [options] <input> <output>
    \\
    \\Options:
    \\  -w, --width  <px>     出力幅 (省略時: アスペクト比維持)
    \\  -h, --height <px>     出力高さ
    \\  -q, --quality <0-100> WebP 品質 (デフォルト: 92)
    \\  --lossless            ロスレス出力
    \\  --version             バージョンを表示
    \\
    \\Examples:
    \\  pict illustration.png output.webp -w 1920
    \\  pict portrait.jpg thumbnail.webp -w 400 -h 400
    \\
;

const CliArgs = struct {
    input: []const u8,
    output: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
    quality: f32 = 92.0,
    lossless: bool = false,
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

    // Phase 2 でここに pipeline を実装する
    _ = pict;
    std.log.warn("Phase 2: pipeline not yet implemented. Input: {s}", .{cli.input});
}

fn parseArgs(args: []const []const u8) !CliArgs {
    if (args.len < 3) return error.TooFewArguments;

    // --version
    if (std.mem.eql(u8, args[1], "--version")) {
        try std.io.getStdOut().writer().print("pict-zig-engine v{s}\n", .{"0.1.0"});
        std.process.exit(0);
    }

    var result = CliArgs{
        .input = args[1],
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
            result.quality = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, arg, "--lossless")) {
            result.lossless = true;
        } else {
            return error.UnknownArgument;
        }
    }

    return result;
}
