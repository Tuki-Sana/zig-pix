/// test/bench/main.zig — ベンチマーク (Phase 3 以降で充実させる)
///
/// Phase 0: Lanczos カーネル計算のマイクロベンチのみ。
/// `zig build bench` で実行する。

const std = @import("std");
const pict = @import("pict");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("pict-zig-engine benchmarks\n");
    try stdout.writeAll("==========================\n\n");

    try benchLanczosKernel(stdout);
}

fn benchLanczosKernel(out: anytype) !void {
    const N = 10_000_000;
    var sum: f64 = 0;

    const t0 = std.time.nanoTimestamp();
    for (0..N) |i| {
        const x = @as(f32, @floatFromInt(i % 600)) / 100.0 - 3.0; // -3.0..3.0
        sum += pict.resize.lanczosKernel(x);
    }
    const elapsed_ns = std.time.nanoTimestamp() - t0;

    const ns_per_call = @as(f64, @floatFromInt(elapsed_ns)) / N;
    try out.print(
        "lanczosKernel: {d:.2} ns/call  (N={d}, checksum={d:.4})\n",
        .{ ns_per_call, N, sum },
    );
}
