const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// pict-zig-engine  build.zig
//
// ビルドターゲット一覧:
//   zig build                   → Native dev binary (Mac ARM, Debug)
//   zig build -Doptimize=ReleaseFast  → Native release
//   zig build linux             → Linux x86_64 cross-compile (ReleaseFast)
//   zig build wasm              → WebAssembly / WASI (ReleaseSmall)
//   zig build lib               → Shared library for FFI (.dylib / .so)
//   zig build test              → Unit tests
//   zig build bench             → Benchmarks (ReleaseFast)
// ─────────────────────────────────────────────────────────────────────────────

pub fn build(b: *std.Build) void {
    // ── Standard options ──────────────────────────────────────────────────────
    const optimize = b.standardOptimizeOption(.{});
    const native_target = b.standardTargetOptions(.{});

    // ── Cross-compile targets ─────────────────────────────────────────────────
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        // Baseline CPU: 汎用サーバー向け (VPS は AVX2 非保証のため x86_64_v2 に留める)
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
    });

    // Cloudflare Workers は wasm32-freestanding が理想だが、
    // Phase 0 では WASI で end-to-end を確認後に切り替える。
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    // ── Core pipeline module (target-agnostic Zig source) ────────────────────
    // C ライブラリは各アーティファクトで個別にリンクする (ターゲット依存のため)
    const pict_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
    });

    // ── Native CLI (dev: Mac ARM) ─────────────────────────────────────────────
    const cli = b.addExecutable(.{
        .name = "pict",
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    cli.root_module.addImport("pict", pict_mod);
    b.installArtifact(cli);

    const run_cmd = b.addRunArtifact(cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the CLI (native dev)");
    run_step.dependOn(&run_cmd.step);

    // ── Linux x86_64 cross-compile ────────────────────────────────────────────
    const cli_linux = b.addExecutable(.{
        .name = "pict",
        .root_source_file = b.path("src/main.zig"),
        .target = linux_target,
        .optimize = .ReleaseFast,
    });
    cli_linux.root_module.addImport("pict", pict_mod);
    // TODO Phase 2: addCLibraries(cli_linux, linux_target);

    const linux_step = b.step("linux", "Cross-compile for Linux x86_64 VPS");
    linux_step.dependOn(&b.addInstallArtifact(cli_linux, .{
        .dest_dir = .{ .override = .{ .custom = "linux-x86_64" } },
    }).step);

    // ── WebAssembly / WASI ────────────────────────────────────────────────────
    const wasm_exe = b.addExecutable(.{
        .name = "pict",
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_exe.rdynamic = true; // pub export fn を外部公開
    // Edge 環境: スタックサイズを保守的に設定 (128MB 制約)
    wasm_exe.stack_size = 64 * 1024; // 64 KB

    const wasm_step = b.step("wasm", "Build WebAssembly / WASI module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    }).step);

    // ── Shared library (FFI: Bun / Node.js) ───────────────────────────────────
    const ffi_lib = b.addSharedLibrary(.{
        .name = "pict",
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = .ReleaseFast,
    });
    ffi_lib.root_module.addImport("pict", pict_mod);

    const lib_step = b.step("lib", "Build shared library for FFI (.dylib/.so)");
    lib_step.dependOn(&b.addInstallArtifact(ffi_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    }).step);

    // ── Unit tests ────────────────────────────────────────────────────────────
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ── Benchmarks ────────────────────────────────────────────────────────────
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("test/bench/main.zig"),
        .target = native_target,
        .optimize = .ReleaseFast,
    });
    bench_exe.root_module.addImport("pict", pict_mod);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
}

// ─────────────────────────────────────────────────────────────────────────────
// TODO Phase 2: C ライブラリ統合ヘルパー
//
// fn addCLibraries(artifact: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
//     artifact.addIncludePath(b.path("vendor/libjpeg-turbo/include"));
//     artifact.addCSourceFiles(.{ ... });
//     artifact.linkLibC();
// }
// ─────────────────────────────────────────────────────────────────────────────
