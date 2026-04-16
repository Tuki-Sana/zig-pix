const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// pict-zig-engine  build.zig
//
// ビルドターゲット一覧:
//   zig build                        → Native dev binary (Mac ARM, Debug)
//   zig build -Doptimize=ReleaseFast → Native release
//   zig build linux                  → Linux x86_64 cross-compile (ReleaseFast)
//   zig build wasm                   → WebAssembly / WASI (実験用; ネイティブ decode/ICC/WebP パス非搭載。npm zigpix-wasm は別系統)
//   zig build lib                    → Shared library for FFI (.dylib / .so)
//   zig build lib-linux              → Linux x86_64 shared library for FFI (.so)
//   zig build lib-windows            → Windows x86_64 MSVC shared library for FFI (.dll, AVIF=static)
//   zig build lib-windows-arm64      → Windows aarch64 MSVC shared library for FFI (.dll, AVIF=static)
//   zig build test                   → Unit tests (Zig + C ライブラリ、JPEG/PNG/WebP パス含む)
//   zig build bench                  → Benchmarks (ReleaseFast)
// ─────────────────────────────────────────────────────────────────────────────

pub fn build(b: *std.Build) void {
    // ── Standard options ──────────────────────────────────────────────────────
    const optimize = b.standardOptimizeOption(.{});
    const native_target = b.standardTargetOptions(.{});

    // ── SIMD トグル ───────────────────────────────────────────────────────────
    // Phase 3A: スキャフォールディングのみ。デフォルト off。
    // 有効化: zig build -Dsimd=true
    const simd_enabled = b.option(
        bool,
        "simd",
        "Enable SIMD optimizations in the Zig resize path (default: off)",
    ) orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "simd_enabled", simd_enabled);

    // ── AVIF リンクモード ─────────────────────────────────────────────────────
    // -Davif=system (デフォルト): システムの libavif を動的リンク (apt install libavif-dev 必要)
    // -Davif=static            : 事前ビルド済みの静的ライブラリを使用 (追加インストール不要)
    const AvifMode = enum { system, static };
    const avif_mode = b.option(
        AvifMode,
        "avif",
        "libavif linking mode: system (default) or static",
    ) orelse .system;

    // has_avif=true は CLI 専用 (pict_mod_cli)。他の artifact はすべて false。
    const no_avif_options = b.addOptions();
    no_avif_options.addOption(bool, "has_avif", false);
    const avif_options = b.addOptions();
    avif_options.addOption(bool, "has_avif", true);

    // ── Cross-compile targets ─────────────────────────────────────────────────
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        // VPS は AVX2 非保証のため x86_64_v2 に留める。SIMD は Phase 3 で有効化。
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
    });

    // Windows でも libwebp SSE41 等は SSSE3/SSE4.1 が必要。`-mssse3` だけでは clang-cl 経路で効かない
    // ことがあるため、ターゲット CPU を x86_64_v2 に固定し C/Zig 双方に ISA を伝播させる（Linux VPS と同格）。
    const windows_x64_msvc = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .msvc,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
    });

    const windows_aarch64_msvc = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .windows,
        .abi = .msvc,
    });

    // Phase 5 で Cloudflare Workers 向けに wasm32-freestanding に切り替える。
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    // ── Core pipeline module (target-agnostic Zig source) ────────────────────
    const pict_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
    });
    pict_mod.addOptions("build_options", build_options);
    pict_mod.addOptions("avif_options", no_avif_options);

    // ── CLI 専用モジュール (has_avif=true) ────────────────────────────────────
    // cli のみがこれを使う。他の artifact は pict_mod (has_avif=false) を使い続ける。
    const pict_mod_cli = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
    });
    pict_mod_cli.addOptions("build_options", build_options);
    pict_mod_cli.addOptions("avif_options", avif_options);

    // ── Native CLI (dev: Mac ARM) ─────────────────────────────────────────────
    const cli = b.addExecutable(.{
        .name = "pict",
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    cli.root_module.addImport("pict", pict_mod_cli); // pict_mod_cli (has_avif=true)
    addCLibraries(b, cli);
    switch (avif_mode) {
        .system => addLibAvifSystem(b, cli),
        .static => addLibAvifStatic(b, cli),
    }
    cli.addCSourceFiles(.{
        .files = &.{"src/c/avif_encode.c"},
        .flags = &.{"-std=c11"},
    });
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
    addCLibraries(b, cli_linux);

    const linux_step = b.step("linux", "Cross-compile for Linux x86_64 VPS");
    linux_step.dependOn(&b.addInstallArtifact(cli_linux, .{
        .dest_dir = .{ .override = .{ .custom = "linux-x86_64" } },
    }).step);

    // ── WebAssembly / WASI ───────────────────────────────────────────────────
    // `zig build wasm` は Zig の root を wasm32-wasi にコンパイルする実験用ターゲット。
    // 現状この成果物は **ネイティブ FFI（libjpeg/libpng/libwebp 経由の decode・ICC・WebP encode）と同等の機能を持たない**。
    // ブラウザ向け配布は npm の `zigpix-wasm`（Emscripten で libavif 静的リンクの AVIF エンコード専用）を正とする。
    const wasm_exe = b.addExecutable(.{
        .name = "pict",
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_exe.rdynamic = true;
    wasm_exe.stack_size = 64 * 1024;
    wasm_exe.root_module.addOptions("build_options", build_options);
    wasm_exe.root_module.addOptions("avif_options", no_avif_options);

    const wasm_step = b.step("wasm", "Build WebAssembly / WASI module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    }).step);

    // ── Shared library (FFI: Bun / Node.js) ───────────────────────────────────
    // Phase 7B: Mac native lib は has_avif=true。pict_encode_avif を公開する。
    // Linux cross-compile (ffi_lib_linux) は Phase 7C まで has_avif=false のまま。
    const ffi_lib = b.addSharedLibrary(.{
        .name = "pict",
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = .ReleaseFast,
    });
    ffi_lib.root_module.addImport("pict", pict_mod);
    ffi_lib.root_module.addOptions("build_options", build_options);
    ffi_lib.root_module.addOptions("avif_options", avif_options); // has_avif=true
    addCLibraries(b, ffi_lib);
    switch (avif_mode) {
        .system => addLibAvifSystem(b, ffi_lib),
        .static => addLibAvifStatic(b, ffi_lib),
    }
    ffi_lib.addCSourceFiles(.{
        .files = &.{"src/c/avif_encode.c"},
        .flags = &.{"-std=c11"},
    });

    const lib_step = b.step("lib", "Build shared library for FFI (.dylib/.so)");
    lib_step.dependOn(&b.addInstallArtifact(ffi_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    }).step);

    // ── Shared library Linux x86_64 cross-compile (FFI: VPS) ─────────────────
    const ffi_lib_linux = b.addSharedLibrary(.{
        .name = "pict",
        .root_source_file = b.path("src/root.zig"),
        .target = linux_target,
        .optimize = .ReleaseFast,
    });
    ffi_lib_linux.root_module.addImport("pict", pict_mod);
    ffi_lib_linux.root_module.addOptions("build_options", build_options);
    ffi_lib_linux.root_module.addOptions("avif_options", no_avif_options);
    addCLibraries(b, ffi_lib_linux);

    const lib_linux_step = b.step("lib-linux", "Cross-compile shared library for Linux x86_64 VPS (.so) [AVIF disabled; for AVIF FFI run 'zig build lib' natively on VPS]");
    lib_linux_step.dependOn(&b.addInstallArtifact(ffi_lib_linux, .{
        .dest_dir = .{ .override = .{ .custom = "linux-x86_64" } },
    }).step);

    // ── Shared library Windows x86_64 MSVC (FFI: CI windows-latest) ───────────
    // 事前ビルド: build/libavif で CMake (Ninja) + ninja install（build-native.yml と同型）。
    // 静的 .lib をリンク。pthread / m は Unix のみ。
    const ffi_lib_win = b.addSharedLibrary(.{
        .name = "pict",
        .root_source_file = b.path("src/root.zig"),
        .target = windows_x64_msvc,
        .optimize = .ReleaseFast,
    });
    ffi_lib_win.root_module.addImport("pict", pict_mod);
    ffi_lib_win.root_module.addOptions("build_options", build_options);
    ffi_lib_win.root_module.addOptions("avif_options", avif_options);
    addCLibraries(b, ffi_lib_win);
    // Windows は pkg-config 前提の system モードが使えないため、常に事前ビルドの静的 .lib をリンクする。
    // CI / 手元とも `zig build lib-windows` は `-Davif=static` と CMake 済みの build/libavif-install を前提にする。
    addLibAvifStatic(b, ffi_lib_win);
    ffi_lib_win.addCSourceFiles(.{
        .files = &.{"src/c/avif_encode.c"},
        .flags = &.{"-std=c11"},
    });

    const lib_windows_step = b.step("lib-windows", "Build shared library for Windows x86_64 MSVC (.dll); libavif is always statically linked (run CMake first; CI uses -Davif=static for consistency)");
    // COFF では Zig の出力名が pict.dll（lib 接頭辞なし）。FFI / npm は libpict.dll で統一する。
    lib_windows_step.dependOn(&b.addInstallArtifact(ffi_lib_win, .{
        .dest_dir = .{ .override = .{ .custom = "windows-x86_64" } },
        .dest_sub_path = "libpict.dll",
    }).step);

    // ── Shared library Windows aarch64 MSVC (FFI: CI windows-11-arm 等) ───────
    const ffi_lib_win_arm = b.addSharedLibrary(.{
        .name = "pict",
        .root_source_file = b.path("src/root.zig"),
        .target = windows_aarch64_msvc,
        .optimize = .ReleaseFast,
    });
    ffi_lib_win_arm.root_module.addImport("pict", pict_mod);
    ffi_lib_win_arm.root_module.addOptions("build_options", build_options);
    ffi_lib_win_arm.root_module.addOptions("avif_options", avif_options);
    addCLibraries(b, ffi_lib_win_arm);
    addLibAvifStatic(b, ffi_lib_win_arm);
    ffi_lib_win_arm.addCSourceFiles(.{
        .files = &.{"src/c/avif_encode.c"},
        .flags = &.{"-std=c11"},
    });

    const lib_windows_arm64_step = b.step("lib-windows-arm64", "Build shared library for Windows aarch64 MSVC (.dll); libavif is always statically linked (CMake + build/libavif-install; CI uses -Davif=static)");
    lib_windows_arm64_step.dependOn(&b.addInstallArtifact(ffi_lib_win_arm, .{
        .dest_dir = .{ .override = .{ .custom = "windows-aarch64" } },
        .dest_sub_path = "libpict.dll",
    }).step);

    // ── Unit tests ────────────────────────────────────────────────────────────
    // C ライブラリ (libjpeg-turbo 等) も同時にリンクして JPEG デコードパスを検証する。
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    addCLibraries(b, unit_tests);
    unit_tests.root_module.addOptions("build_options", build_options);
    unit_tests.root_module.addOptions("avif_options", no_avif_options);

    // CLI (main.zig) の parseArgs 等の純 Zig テストも同じステップで実行する。
    const cli_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    cli_tests.root_module.addImport("pict", pict_mod);
    addCLibraries(b, cli_tests);
    cli_tests.root_module.addOptions("avif_options", no_avif_options);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    // ── Benchmarks ────────────────────────────────────────────────────────────
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("test/bench/main.zig"),
        .target = native_target,
        .optimize = .ReleaseFast,
    });
    bench_exe.root_module.addImport("pict", pict_mod);

    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks (pass args after --: zig build bench -- --threads 2)");
    bench_step.dependOn(&bench_run.step);
}

// ─────────────────────────────────────────────────────────────────────────────
// C ライブラリ統合ヘルパー
// ─────────────────────────────────────────────────────────────────────────────

fn addCLibraries(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    addZlib(b, artifact);
    addLibpng(b, artifact);
    addLibjpegTurbo(b, artifact);
    addLibwebp(b, artifact);
    // pict-zig-engine C bridges (JPEG/PNG decode, WebP encode)
    artifact.addCSourceFiles(.{
        .files = &.{
            "src/c/jpeg_decode.c",
            "src/c/png_decode.c",
            "src/c/webp_encode.c",
            "src/c/webp_decode.c",
        },
        .flags = &.{"-std=c11"},
    });
    artifact.linkLibC();
}

// ── zlib 1.3.1 ───────────────────────────────────────────────────────────────
// gz*.c はファイルI/O用で libpng には不要。POSIX 関数依存を避けるため除外。
fn addZlib(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    artifact.addIncludePath(b.path("vendor/zlib"));
    artifact.addCSourceFiles(.{
        .files = &.{
            "vendor/zlib/adler32.c",
            "vendor/zlib/compress.c",
            "vendor/zlib/crc32.c",
            "vendor/zlib/deflate.c",
            "vendor/zlib/infback.c",
            "vendor/zlib/inffast.c",
            "vendor/zlib/inflate.c",
            "vendor/zlib/inftrees.c",
            "vendor/zlib/trees.c",
            "vendor/zlib/uncompr.c",
            "vendor/zlib/zutil.c",
        },
        .flags = &.{"-std=c11"},
    });
}

// ── libpng 1.6.43 ─────────────────────────────────────────────────────────────
fn addLibpng(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    artifact.addIncludePath(b.path("vendor/libpng"));
    artifact.addIncludePath(b.path("vendor/libpng/scripts"));
    artifact.addIncludePath(b.path("vendor/zlib"));

    const copy_pnglibconf = b.addWriteFiles();
    _ = copy_pnglibconf.addCopyFile(
        b.path("vendor/libpng/scripts/pnglibconf.h.prebuilt"),
        "pnglibconf.h",
    );
    artifact.addIncludePath(copy_pnglibconf.getDirectory());
    artifact.step.dependOn(&copy_pnglibconf.step);

    const arch = artifact.rootModuleTarget().cpu.arch;

    // コアファイルをアーキテクチャ別フラグで追加
    // aarch64: PNG_ARM_NEON_OPT=2 で常時 NEON 有効 (pngpriv.h が __ARM_NEON 自動検出)
    // x86_64:  PNG_INTEL_SSE_OPT=1 で SSE2 有効
    // other:   両方 0 (SIMD なし)
    const core_flags: []const []const u8 = switch (arch) {
        .aarch64 => &.{ "-std=c11", "-DPNG_ARM_NEON_OPT=2", "-DPNG_INTEL_SSE_OPT=0" },
        .x86_64 => &.{ "-std=c11", "-DPNG_ARM_NEON_OPT=0", "-DPNG_INTEL_SSE_OPT=1" },
        else => &.{ "-std=c11", "-DPNG_ARM_NEON_OPT=0", "-DPNG_INTEL_SSE_OPT=0" },
    };
    artifact.addCSourceFiles(.{
        .files = &.{
            "vendor/libpng/png.c",
            "vendor/libpng/pngerror.c",
            "vendor/libpng/pngget.c",
            "vendor/libpng/pngmem.c",
            "vendor/libpng/pngpread.c",
            "vendor/libpng/pngread.c",
            "vendor/libpng/pngrio.c",
            "vendor/libpng/pngrtran.c",
            "vendor/libpng/pngrutil.c",
            "vendor/libpng/pngset.c",
            "vendor/libpng/pngtrans.c",
            "vendor/libpng/pngwio.c",
            "vendor/libpng/pngwrite.c",
            "vendor/libpng/pngwtran.c",
            "vendor/libpng/pngwutil.c",
        },
        .flags = core_flags,
    });

    // SIMD 実装ファイル (ターゲット別)
    switch (arch) {
        .aarch64 => artifact.addCSourceFiles(.{
            .files = &.{
                "vendor/libpng/arm/arm_init.c",
                "vendor/libpng/arm/filter_neon_intrinsics.c",
                "vendor/libpng/arm/palette_neon_intrinsics.c",
            },
            .flags = &.{ "-std=c11", "-DPNG_ARM_NEON_OPT=2" },
        }),
        .x86_64 => artifact.addCSourceFiles(.{
            .files = &.{
                "vendor/libpng/intel/intel_init.c",
                "vendor/libpng/intel/filter_sse2_intrinsics.c",
            },
            .flags = if (artifact.rootModuleTarget().os.tag == .windows)
                &.{ "-std=c11", "-DPNG_INTEL_SSE_OPT=1" }
            else
                &.{ "-std=c11", "-DPNG_INTEL_SSE_OPT=1", "-msse2" },
        }),
        else => {},
    }
}

// ── libjpeg-turbo 3.0.4 ──────────────────────────────────────────────────────
// aarch64: WITH_SIMD=1、NEON C + ASM ファイルを追加。
// x86_64 : NASM 必須のため WITH_SIMD=null (非 SIMD fallback)。
// その他 : WITH_SIMD=null。
fn addLibjpegTurbo(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    const arch = artifact.rootModuleTarget().cpu.arch;
    const os_tag = artifact.rootModuleTarget().os.tag;
    const with_simd: ?i64 = if (arch == .aarch64) 1 else null;

    const jconfig_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("vendor/libjpeg-turbo/jconfig.h.in") },
        .include_path = "jconfig.h",
    }, .{
        .JPEG_LIB_VERSION = @as(i64, 62),
        .VERSION = "3.0.4",
        .LIBJPEG_TURBO_VERSION = "3.0.4",
        .LIBJPEG_TURBO_VERSION_NUMBER = @as(i64, 3000004),
        .C_ARITH_CODING_SUPPORTED = @as(i64, 1),
        .D_ARITH_CODING_SUPPORTED = @as(i64, 1),
        .WITH_SIMD = with_simd,
        .RIGHT_SHIFT_IS_UNSIGNED = null,
    });
    const jversion_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("vendor/libjpeg-turbo/jversion.h.in") },
        .include_path = "jversion.h",
    }, .{
        .COPYRIGHT_YEAR = "2024",
    });
    const jconfigint_h = b.addConfigHeader(.{
        .style = .{ .cmake = b.path("vendor/libjpeg-turbo/jconfigint.h.in") },
        .include_path = "jconfigint.h",
    }, .{
        .BUILD = "20240101",
        .HIDDEN = if (os_tag == .windows) "" else "__attribute__((visibility(\"hidden\")))",
        .INLINE = if (os_tag == .windows) "__forceinline" else "inline __attribute__((always_inline))",
        .THREAD_LOCAL = if (os_tag == .windows) "__declspec(thread)" else "_Thread_local",
        .CMAKE_PROJECT_NAME = "libjpeg-turbo",
        .VERSION = "3.0.4",
        .SIZE_T = @as(i64, 8),
        .HAVE_BUILTIN_CTZL = if (os_tag == .windows) null else @as(i64, 1),
        .HAVE_INTRIN_H = if (os_tag == .windows) @as(i64, 1) else null,
        .C_ARITH_CODING_SUPPORTED = @as(i64, 1),
        .D_ARITH_CODING_SUPPORTED = @as(i64, 1),
        .WITH_SIMD = with_simd,
    });
    artifact.addConfigHeader(jconfig_h);
    artifact.addConfigHeader(jconfigint_h);
    artifact.addConfigHeader(jversion_h);
    artifact.addIncludePath(b.path("vendor/libjpeg-turbo"));

    // ── 8-bit コア (BITS_IN_JSAMPLE=8 デフォルト) ────────────────────────
    // Phase 2: non-SIMD コアのみ。rd*/wr* (cjpeg/djpeg ツール用) は除外。
    artifact.addCSourceFiles(.{
        .files = &.{
            "vendor/libjpeg-turbo/jaricom.c",
            "vendor/libjpeg-turbo/jcapimin.c",
            "vendor/libjpeg-turbo/jcapistd.c",
            "vendor/libjpeg-turbo/jcarith.c",
            "vendor/libjpeg-turbo/jccoefct.c",
            // jccolext.c は jccolor.c に #include されるフラグメント → 除外
            "vendor/libjpeg-turbo/jccolor.c",
            "vendor/libjpeg-turbo/jcdctmgr.c",
            "vendor/libjpeg-turbo/jcdiffct.c",
            "vendor/libjpeg-turbo/jchuff.c",
            "vendor/libjpeg-turbo/jcicc.c",
            "vendor/libjpeg-turbo/jcinit.c",
            "vendor/libjpeg-turbo/jclhuff.c",
            "vendor/libjpeg-turbo/jclossls.c",
            "vendor/libjpeg-turbo/jcmainct.c",
            "vendor/libjpeg-turbo/jcmarker.c",
            "vendor/libjpeg-turbo/jcmaster.c",
            "vendor/libjpeg-turbo/jcomapi.c",
            "vendor/libjpeg-turbo/jcparam.c",
            "vendor/libjpeg-turbo/jcphuff.c",
            "vendor/libjpeg-turbo/jcprepct.c",
            "vendor/libjpeg-turbo/jcsample.c",
            "vendor/libjpeg-turbo/jctrans.c",
            "vendor/libjpeg-turbo/jdapimin.c",
            "vendor/libjpeg-turbo/jdapistd.c",
            "vendor/libjpeg-turbo/jdarith.c",
            "vendor/libjpeg-turbo/jdatadst-tj.c",
            "vendor/libjpeg-turbo/jdatadst.c",
            "vendor/libjpeg-turbo/jdatasrc-tj.c",
            "vendor/libjpeg-turbo/jdatasrc.c",
            "vendor/libjpeg-turbo/jdcoefct.c",
            // jdcol565.c / jdcolext.c は jdcolor.c に #include されるフラグメント → 除外
            "vendor/libjpeg-turbo/jdcolor.c",
            "vendor/libjpeg-turbo/jddctmgr.c",
            "vendor/libjpeg-turbo/jddiffct.c",
            "vendor/libjpeg-turbo/jdhuff.c",
            "vendor/libjpeg-turbo/jdicc.c",
            "vendor/libjpeg-turbo/jdinput.c",
            "vendor/libjpeg-turbo/jdlhuff.c",
            "vendor/libjpeg-turbo/jdlossls.c",
            "vendor/libjpeg-turbo/jdmainct.c",
            "vendor/libjpeg-turbo/jdmarker.c",
            "vendor/libjpeg-turbo/jdmaster.c",
            "vendor/libjpeg-turbo/jdmerge.c",
            // jdmrg565.c / jdmrgext.c は jdmerge.c に #include されるフラグメント → 除外
            "vendor/libjpeg-turbo/jdphuff.c",
            "vendor/libjpeg-turbo/jdpostct.c",
            "vendor/libjpeg-turbo/jdsample.c",
            "vendor/libjpeg-turbo/jdtrans.c",
            "vendor/libjpeg-turbo/jerror.c",
            "vendor/libjpeg-turbo/jfdctflt.c",
            "vendor/libjpeg-turbo/jfdctfst.c",
            "vendor/libjpeg-turbo/jfdctint.c",
            "vendor/libjpeg-turbo/jidctflt.c",
            "vendor/libjpeg-turbo/jidctfst.c",
            "vendor/libjpeg-turbo/jidctint.c",
            "vendor/libjpeg-turbo/jidctred.c",
            "vendor/libjpeg-turbo/jmemmgr.c",
            "vendor/libjpeg-turbo/jmemnobs.c",
            "vendor/libjpeg-turbo/jpeg_nbits.c",
            "vendor/libjpeg-turbo/jquant1.c",
            "vendor/libjpeg-turbo/jquant2.c",
            // jstdhuff.c は jcparam.c / jdhuff.c に #include されるフラグメント → 除外
            "vendor/libjpeg-turbo/jutils.c",
            // turbojpeg.c は内部で turbojpeg-mp.c を BITS_IN_JSAMPLE=8/12/16 の 3 回
            // #include し、j12*/j16* シンボルと transupp.c 依存を生む。
            // Phase 2 では plain libjpeg API (jpeg_*) を使うため除外。
            // Phase 6 で TurboJPEG API が必要になった時点で再検討する。
        },
        .flags = &.{
            "-std=c11",
            // glibc の strict C11 では setenv 等の POSIX 関数が隠れるため明示的に expose
            "-D_DEFAULT_SOURCE",
            "-DWITH_ARITH_DEC=1",
            "-DWITH_ARITH_ENC=1",
        },
    });

    // ── 12-bit 精度 (j12init_* シンボル生成) ────────────────────────────
    // jdmaster.c / jcinit.c 等が runtime で cinfo->data_precision == 12 の場合に
    // j12init_* を呼び出す。jsamplecomp.h が BITS_IN_JSAMPLE=12 のとき
    // _jinit_* → j12init_* にリネームする仕組み。
    // CMakeLists.txt の JPEG12_SOURCES に相当。
    artifact.addCSourceFiles(.{
        .files = &.{
            "vendor/libjpeg-turbo/jcapistd.c",
            "vendor/libjpeg-turbo/jccoefct.c",
            // jccolext.c はフラグメント → 除外
            "vendor/libjpeg-turbo/jccolor.c",
            "vendor/libjpeg-turbo/jcdctmgr.c",
            "vendor/libjpeg-turbo/jcdiffct.c",
            "vendor/libjpeg-turbo/jclossls.c",
            "vendor/libjpeg-turbo/jcmainct.c",
            "vendor/libjpeg-turbo/jcprepct.c",
            "vendor/libjpeg-turbo/jcsample.c",
            "vendor/libjpeg-turbo/jdapistd.c",
            "vendor/libjpeg-turbo/jdcoefct.c",
            // jdcol565.c / jdcolext.c はフラグメント → 除外
            "vendor/libjpeg-turbo/jdcolor.c",
            "vendor/libjpeg-turbo/jddctmgr.c",
            "vendor/libjpeg-turbo/jddiffct.c",
            "vendor/libjpeg-turbo/jdlossls.c",
            "vendor/libjpeg-turbo/jdmainct.c",
            "vendor/libjpeg-turbo/jdmerge.c",
            // jdmrg565.c / jdmrgext.c はフラグメント → 除外
            "vendor/libjpeg-turbo/jdpostct.c",
            "vendor/libjpeg-turbo/jdsample.c",
            "vendor/libjpeg-turbo/jfdctfst.c",
            "vendor/libjpeg-turbo/jfdctint.c",
            "vendor/libjpeg-turbo/jidctflt.c",
            "vendor/libjpeg-turbo/jidctfst.c",
            "vendor/libjpeg-turbo/jidctint.c",
            "vendor/libjpeg-turbo/jidctred.c",
            "vendor/libjpeg-turbo/jquant1.c",
            "vendor/libjpeg-turbo/jquant2.c",
            "vendor/libjpeg-turbo/jutils.c",
        },
        .flags = &.{
            "-std=c11",
            "-D_DEFAULT_SOURCE",
            "-DBITS_IN_JSAMPLE=12",
            "-DWITH_ARITH_DEC=1",
            "-DWITH_ARITH_ENC=1",
        },
    });

    // ── 16-bit 精度 (j16init_* シンボル生成) ────────────────────────────
    // CMakeLists.txt の JPEG16_SOURCES に相当 (JPEG12_SOURCES のサブセット)。
    artifact.addCSourceFiles(.{
        .files = &.{
            "vendor/libjpeg-turbo/jcapistd.c",
            // jccolext.c はフラグメント → 除外
            "vendor/libjpeg-turbo/jccolor.c",
            "vendor/libjpeg-turbo/jcdiffct.c",
            "vendor/libjpeg-turbo/jclossls.c",
            "vendor/libjpeg-turbo/jcmainct.c",
            "vendor/libjpeg-turbo/jcprepct.c",
            "vendor/libjpeg-turbo/jcsample.c",
            "vendor/libjpeg-turbo/jdapistd.c",
            // jdcol565.c / jdcolext.c はフラグメント → 除外
            "vendor/libjpeg-turbo/jdcolor.c",
            "vendor/libjpeg-turbo/jddiffct.c",
            "vendor/libjpeg-turbo/jdlossls.c",
            "vendor/libjpeg-turbo/jdmainct.c",
            // jdmrg565.c / jdmrgext.c はフラグメント → 除外
            "vendor/libjpeg-turbo/jdpostct.c",
            "vendor/libjpeg-turbo/jdsample.c",
            "vendor/libjpeg-turbo/jutils.c",
        },
        .flags = &.{
            "-std=c11",
            "-D_DEFAULT_SOURCE",
            "-DBITS_IN_JSAMPLE=16",
            "-DWITH_ARITH_DEC=1",
            "-DWITH_ARITH_ENC=1",
        },
    });

    // ── aarch64 NEON SIMD ─────────────────────────────────────────────────
    // x86_64 の SIMD は NASM 必須 (.asm ファイル) のため今フェーズはスキップ。
    //
    // vendor/libjpeg-turbo/simd/CMakeLists.txt と整合: **NEON_INTRINSICS=1** のときは
    // jccolor-neon.c / jidctint-neon.c 等の **C intrinsics のみ**で、`jsimd_neon.S` は
    // **含めない**（.S と .c が jsimd_*_neon を二重定義し、Windows の lld-link で失敗する）。
    // `-DNEON_INTRINSICS` で jsimd.c が asm 専用分岐（slowld3 等）を参照しないようにする。
    //
    // コンパイル単位に含めないファイル (別ファイルから #include されるフラグメント):
    //   simd/arm/jcgryext-neon.c  → jcgray-neon.c に #include される
    //   simd/arm/jdcolext-neon.c  → jdcolor-neon.c に #include される
    //   simd/arm/jdmrgext-neon.c  → jdmerge-neon.c に #include される
    //   simd/arm/aarch64/jccolext-neon.c → jccolor-neon.c に #if __aarch64__ で #include される
    if (arch == .aarch64) {
        // neon-compat.h を WriteFile で生成し include パスに追加する。
        // on aarch64/clang: HAVE_VLD1_S16_X3, HAVE_VLD1_U16_X2, HAVE_VLD1Q_U8_X4 は利用可能。
        const neon_compat = b.addWriteFiles();
        _ = neon_compat.add("neon-compat.h",
            \\#define HAVE_VLD1_S16_X3
            \\#define HAVE_VLD1_U16_X2
            \\#define HAVE_VLD1Q_U8_X4
            \\
            \\#if defined(_MSC_VER) && !defined(__clang__)
            \\#define BUILTIN_CLZ(x)      _CountLeadingZeros(x)
            \\#define BUILTIN_CLZLL(x)    _CountLeadingZeros64(x)
            \\#define BUILTIN_BSWAP64(x)  _byteswap_uint64(x)
            \\#elif defined(__clang__) || defined(__GNUC__)
            \\#define BUILTIN_CLZ(x)      __builtin_clz(x)
            \\#define BUILTIN_CLZLL(x)    __builtin_clzll(x)
            \\#define BUILTIN_BSWAP64(x)  __builtin_bswap64(x)
            \\#else
            \\#error "Unknown compiler"
            \\#endif
        );
        artifact.addIncludePath(neon_compat.getDirectory());
        artifact.step.dependOn(&neon_compat.step);

        const neon_flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE", "-DNEON_INTRINSICS" };

        // 共有 ARM NEON C ファイル (aarch32/aarch64 両対応; __aarch64__ で内部分岐)
        artifact.addCSourceFiles(.{
            .files = &.{
                "vendor/libjpeg-turbo/simd/arm/jccolor-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jcgray-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jcphuff-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jcsample-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jdcolor-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jdmerge-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jdsample-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jfdctfst-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jfdctint-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jidctfst-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jidctint-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jidctred-neon.c",
                "vendor/libjpeg-turbo/simd/arm/jquanti-neon.c",
                // aarch64 専用スタンドアロン C ファイル
                "vendor/libjpeg-turbo/simd/arm/aarch64/jsimd.c",
                "vendor/libjpeg-turbo/simd/arm/aarch64/jchuff-neon.c",
            },
            .flags = neon_flags,
        });
    }
}

// ── libwebp 1.4.0 ────────────────────────────────────────────────────────────
// DSP 層は CPU dispatch を使う。各 dsp/*.c がアーキテクチャを自動検出して
// WEBP_HAVE_NEON / WEBP_HAVE_SSE2 等を定義し、SIMD 初期化関数を extern 宣言→呼び出す。
// そのため SIMD 実装ファイルをターゲットアーキテクチャに応じてリンクする必要がある。
// sharpyuv/ はサブライブラリとして picture_csp_enc.c から SharpYuvInit() 経由で使用。
fn addLibwebp(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    artifact.addIncludePath(b.path("vendor/libwebp"));
    artifact.addIncludePath(b.path("vendor/libwebp/sharpyuv"));

    // ── enc + dsp (C スカラー baseline) + utils ───────────────────────────
    artifact.addCSourceFiles(.{
        .files = &.{
            // enc
            "vendor/libwebp/src/enc/alpha_enc.c",
            "vendor/libwebp/src/enc/analysis_enc.c",
            "vendor/libwebp/src/enc/backward_references_cost_enc.c",
            "vendor/libwebp/src/enc/backward_references_enc.c",
            "vendor/libwebp/src/enc/config_enc.c",
            "vendor/libwebp/src/enc/cost_enc.c",
            "vendor/libwebp/src/enc/filter_enc.c",
            "vendor/libwebp/src/enc/frame_enc.c",
            "vendor/libwebp/src/enc/histogram_enc.c",
            "vendor/libwebp/src/enc/iterator_enc.c",
            "vendor/libwebp/src/enc/near_lossless_enc.c",
            "vendor/libwebp/src/enc/picture_csp_enc.c",
            "vendor/libwebp/src/enc/picture_enc.c",
            "vendor/libwebp/src/enc/picture_psnr_enc.c",
            "vendor/libwebp/src/enc/picture_rescale_enc.c",
            "vendor/libwebp/src/enc/picture_tools_enc.c",
            "vendor/libwebp/src/enc/predictor_enc.c",
            "vendor/libwebp/src/enc/quant_enc.c",
            "vendor/libwebp/src/enc/syntax_enc.c",
            "vendor/libwebp/src/enc/token_enc.c",
            "vendor/libwebp/src/enc/tree_enc.c",
            "vendor/libwebp/src/enc/vp8l_enc.c",
            "vendor/libwebp/src/enc/webp_enc.c",
            // dec (still-image WebP — animated は bridge 側で拒否)
            "vendor/libwebp/src/dec/alpha_dec.c",
            "vendor/libwebp/src/dec/buffer_dec.c",
            "vendor/libwebp/src/dec/frame_dec.c",
            "vendor/libwebp/src/dec/idec_dec.c",
            "vendor/libwebp/src/dec/io_dec.c",
            "vendor/libwebp/src/dec/quant_dec.c",
            "vendor/libwebp/src/dec/tree_dec.c",
            "vendor/libwebp/src/dec/vp8_dec.c",
            "vendor/libwebp/src/dec/vp8l_dec.c",
            "vendor/libwebp/src/dec/webp_dec.c",
            // dsp (C スカラー)
            "vendor/libwebp/src/dsp/alpha_processing.c",
            "vendor/libwebp/src/dsp/cost.c",
            "vendor/libwebp/src/dsp/cpu.c",
            "vendor/libwebp/src/dsp/dec_clip_tables.c",
            "vendor/libwebp/src/dsp/dec.c",
            "vendor/libwebp/src/dsp/enc.c",
            "vendor/libwebp/src/dsp/filters.c",
            "vendor/libwebp/src/dsp/lossless_enc.c",
            "vendor/libwebp/src/dsp/lossless.c",
            "vendor/libwebp/src/dsp/rescaler.c",
            "vendor/libwebp/src/dsp/ssim.c",
            "vendor/libwebp/src/dsp/upsampling.c",
            "vendor/libwebp/src/dsp/yuv.c",
            // utils
            "vendor/libwebp/src/utils/bit_reader_utils.c",
            "vendor/libwebp/src/utils/bit_writer_utils.c",
            "vendor/libwebp/src/utils/color_cache_utils.c",
            "vendor/libwebp/src/utils/filters_utils.c",
            "vendor/libwebp/src/utils/huffman_encode_utils.c",
            "vendor/libwebp/src/utils/huffman_utils.c",
            "vendor/libwebp/src/utils/palette.c",
            "vendor/libwebp/src/utils/quant_levels_dec_utils.c",
            "vendor/libwebp/src/utils/quant_levels_utils.c",
            "vendor/libwebp/src/utils/random_utils.c",
            "vendor/libwebp/src/utils/rescaler_utils.c",
            "vendor/libwebp/src/utils/thread_utils.c",
            "vendor/libwebp/src/utils/utils.c",
            // demux: VP8X / ICCP チャンク走査 (静止画のみ bridge で使用)
            "vendor/libwebp/src/demux/demux.c",
            "vendor/libwebp/src/demux/anim_decode.c",
            // mux: テスト用 ICC 付き WebP の組み立て
            "vendor/libwebp/src/mux/anim_encode.c",
            "vendor/libwebp/src/mux/muxedit.c",
            "vendor/libwebp/src/mux/muxinternal.c",
            "vendor/libwebp/src/mux/muxread.c",
        },
        .flags = &.{"-std=c11"},
    });

    // ── sharpyuv (C スカラー + dispatch core) ────────────────────────────
    // picture_csp_enc.c → SharpYuvInit() → sharpyuv.c で定義
    artifact.addCSourceFiles(.{
        .files = &.{
            "vendor/libwebp/sharpyuv/sharpyuv.c",
            "vendor/libwebp/sharpyuv/sharpyuv_cpu.c",
            "vendor/libwebp/sharpyuv/sharpyuv_csp.c",
            "vendor/libwebp/sharpyuv/sharpyuv_dsp.c",
            "vendor/libwebp/sharpyuv/sharpyuv_gamma.c",
        },
        .flags = &.{"-std=c11"},
    });

    // ── アーキテクチャ別 SIMD dispatch 実装 ──────────────────────────────
    // dsp/*.c の各 Init 関数 (WebPInitAlphaProcessingNEON 等) は extern 宣言されており、
    // ターゲットアーキテクチャに対応する実装ファイルをリンクしないと undefined symbol になる。
    const arch = artifact.rootModuleTarget().cpu.arch;
    if (arch == .aarch64) {
        // ARM64: NEON は常に利用可能 (clang が __aarch64__ を定義 → WEBP_HAVE_NEON)
        artifact.addCSourceFiles(.{
            .files = &.{
                "vendor/libwebp/src/dsp/alpha_processing_neon.c",
                "vendor/libwebp/src/dsp/cost_neon.c",
                "vendor/libwebp/src/dsp/dec_neon.c",
                "vendor/libwebp/src/dsp/enc_neon.c",
                "vendor/libwebp/src/dsp/filters_neon.c",
                "vendor/libwebp/src/dsp/lossless_enc_neon.c",
                "vendor/libwebp/src/dsp/lossless_neon.c",
                "vendor/libwebp/src/dsp/rescaler_neon.c",
                "vendor/libwebp/src/dsp/upsampling_neon.c",
                "vendor/libwebp/src/dsp/yuv_neon.c",
                "vendor/libwebp/sharpyuv/sharpyuv_neon.c",
            },
            .flags = &.{"-std=c11"},
        });
    } else if (arch == .x86_64) {
        // x86_64: SSE2 は x86_64 ABI の保証範囲。SSE4.1 は x86_64_v2 以上で利用可能。
        // SSE41 系ソースは SSSE3（_mm_shuffle_epi8 等）が必要。Windows でも clang 用に ISA フラグを付ける。
        const webp_x86_flags: []const []const u8 = if (artifact.rootModuleTarget().os.tag == .windows)
            &.{ "-std=c11", "-msse2", "-mssse3", "-msse4.1" }
        else
            &.{ "-std=c11", "-msse2", "-mssse3", "-msse4.1" };
        artifact.addCSourceFiles(.{
            .files = &.{
                "vendor/libwebp/src/dsp/alpha_processing_sse2.c",
                "vendor/libwebp/src/dsp/alpha_processing_sse41.c",
                "vendor/libwebp/src/dsp/cost_sse2.c",
                "vendor/libwebp/src/dsp/dec_sse2.c",
                "vendor/libwebp/src/dsp/dec_sse41.c",
                "vendor/libwebp/src/dsp/enc_sse2.c",
                "vendor/libwebp/src/dsp/enc_sse41.c",
                "vendor/libwebp/src/dsp/filters_sse2.c",
                "vendor/libwebp/src/dsp/lossless_enc_sse2.c",
                "vendor/libwebp/src/dsp/lossless_enc_sse41.c",
                "vendor/libwebp/src/dsp/lossless_sse2.c",
                "vendor/libwebp/src/dsp/lossless_sse41.c",
                "vendor/libwebp/src/dsp/rescaler_sse2.c",
                "vendor/libwebp/src/dsp/ssim_sse2.c",
                "vendor/libwebp/src/dsp/upsampling_sse2.c",
                "vendor/libwebp/src/dsp/upsampling_sse41.c",
                "vendor/libwebp/src/dsp/yuv_sse2.c",
                "vendor/libwebp/src/dsp/yuv_sse41.c",
                "vendor/libwebp/sharpyuv/sharpyuv_sse2.c",
            },
            .flags = webp_x86_flags,
        });
    }
    // wasm32: SIMD は Phase 5 で追加。スカラー baseline のみで動作する。
}

// ── libavif system library (CLI + Mac native ffi_lib, Phase 7A/7B) ───────────
// パス解決優先順位:
//   1. pkg-config --cflags-only-I / --libs-only-L libavif が成功した場合はその出力を使用
//   2. macOS のみ: 失敗時は Homebrew 標準プレフィクス (/opt/homebrew) に fallback
//   3. Linux: pkg-config が必須。失敗時は stderr にエラーを出力して exit(1) する。
//
// 分岐は artifact の target OS で行う (ホスト OS ではない)。
// ffi_lib_linux (linux_target) には呼ばれない設計 (has_avif=false のため)。
// 注: b.fatal は Zig 0.13.0 未収録のため stderr + std.process.exit(1) で代替している。
// ── addLibAvifStatic ─────────────────────────────────────────────────────────
// 事前ビルド済みの静的ライブラリを使用する。
// VPS / CI での事前ビルド手順:
//   mkdir -p build/libavif && cd build/libavif
//   cmake ../../vendor/libavif -G Ninja -DCMAKE_BUILD_TYPE=Release \
//     -DCMAKE_INSTALL_PREFIX=../../build/libavif-install \
//     -DAVIF_CODEC_AOM=LOCAL -DAVIF_CODEC_DAV1D=OFF \
//     -DAVIF_BUILD_TESTS=OFF -DAVIF_BUILD_APPS=OFF -DAVIF_LIBYUV=OFF \
//     -DBUILD_SHARED_LIBS=OFF
//   ninja && ninja install
//
// 静的ライブラリのパス:
//   build/libavif-install/lib/libavif.a
//   build/libavif/_deps/libaom-build/libaom.a  (FetchContent による libaom ビルド)
fn addLibAvifStatic(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    const target = artifact.rootModuleTarget();
    artifact.addIncludePath(b.path("build/libavif-install/include"));
    if (target.os.tag == .windows) {
        // MSVC + Ninja: libavif の静的ターゲットは OUTPUT_NAME `avif` → **avif.lib**（libavif.lib ではない）。
        // libaom は FetchContent 先のビルドツリーに aom.lib。
        artifact.addObjectFile(b.path("build/libavif-install/lib/avif.lib"));
        artifact.addObjectFile(b.path("build/libavif/_deps/libaom-build/aom.lib"));
        // linkLibCpp() は Zig 同梱の libcxxabi を引き、ilammy/msvc-dev-cmd の MSVC ヘッダと衝突する。
        // CMake+MSVC でビルドした aom.lib は MSVC の C++ ランタイム（/MD 系）に合わせる。
        artifact.linkSystemLibrary("msvcprt");
        // libaom / 周辺が参照し得る Windows システムライブラリ
        artifact.linkSystemLibrary("ws2_32");
        artifact.linkSystemLibrary("bcrypt");
    } else {
        artifact.addObjectFile(b.path("build/libavif-install/lib/libavif.a"));
        artifact.addObjectFile(b.path("build/libavif/_deps/libaom-build/libaom.a"));
        artifact.linkSystemLibrary("pthread");
        artifact.linkSystemLibrary("m");
    }
    artifact.linkLibC();
}

fn addLibAvifSystem(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    const target_os = artifact.rootModuleTarget().os.tag;
    const is_macos = target_os == .macos;

    if (target_os == .windows) {
        std.io.getStdErr().writer().print(
            "error: -Davif=system is not supported on Windows. Use -Davif=static (prebuild libavif with CMake; see docs/windows-rollout-plan.md).\n",
            .{},
        ) catch {};
        std.process.exit(1);
    }

    const pkg_cflags = b.runAllowFail(
        &.{ "pkg-config", "--cflags-only-I", "libavif" },
        @constCast(&@as(u8, 0)),
        .Ignore,
    ) catch null;
    const pkg_libs = b.runAllowFail(
        &.{ "pkg-config", "--libs-only-L", "libavif" },
        @constCast(&@as(u8, 0)),
        .Ignore,
    ) catch null;

    // Linux: どちらか一方でも欠けたら即エラー終了
    if (!is_macos and pkg_cflags == null) {
        std.io.getStdErr().writer().print(
            "error: libavif headers not found for target {s}.\n" ++
                "  Install libavif development package and pkg-config\n" ++
                "  (e.g. apt install libavif-dev pkg-config)\n",
            .{@tagName(target_os)},
        ) catch {};
        std.process.exit(1);
    }
    if (!is_macos and pkg_libs == null) {
        std.io.getStdErr().writer().print(
            "error: libavif library path not found for target {s}.\n" ++
                "  Install libavif development package and pkg-config\n" ++
                "  (e.g. apt install libavif-dev pkg-config)\n",
            .{@tagName(target_os)},
        ) catch {};
        std.process.exit(1);
    }

    // インクルードパス解決
    if (pkg_cflags) |cflags| {
        var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, cflags, " \n\r"), ' ');
        while (it.next()) |token| {
            if (std.mem.startsWith(u8, token, "-I"))
                artifact.addSystemIncludePath(.{ .cwd_relative = token[2..] });
        }
    } else {
        // macOS のみ Homebrew fallback (Apple Silicon 前提)
        artifact.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    }

    // ライブラリパス解決
    if (pkg_libs) |libs| {
        var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, libs, " \n\r"), ' ');
        while (it.next()) |token| {
            if (std.mem.startsWith(u8, token, "-L"))
                artifact.addLibraryPath(.{ .cwd_relative = token[2..] });
        }
    } else {
        // macOS のみ Homebrew fallback (Apple Silicon 前提)
        artifact.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }

    artifact.linkSystemLibrary("avif");
    artifact.linkLibC();
}
