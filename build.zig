const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// pict-zig-engine  build.zig
//
// ビルドターゲット一覧:
//   zig build                        → Native dev binary (Mac ARM, Debug)
//   zig build -Doptimize=ReleaseFast → Native release
//   zig build linux                  → Linux x86_64 cross-compile (ReleaseFast)
//   zig build wasm                   → WebAssembly / WASI (ReleaseSmall)
//   zig build lib                    → Shared library for FFI (.dylib / .so)
//   zig build test                   → Unit tests (Zig のみ、C ライブラリ除く)
//   zig build bench                  → Benchmarks (ReleaseFast)
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
        // VPS は AVX2 非保証のため x86_64_v2 に留める。SIMD は Phase 3 で有効化。
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
    });

    // Phase 5 で Cloudflare Workers 向けに wasm32-freestanding に切り替える。
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    // ── libjpeg-turbo 設定ヘッダー生成 ───────────────────────────────────────
    // jconfig.h / jconfigint.h は通常 CMake が生成するが、
    // Zig ビルドでは addConfigHeader で直接生成する。
    // Phase 2: WITH_SIMD = null (SIMD 無効)。Phase 3 で有効化。
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
        .WITH_SIMD = null, // Phase 3 で有効化
        .RIGHT_SHIFT_IS_UNSIGNED = null,
    });

    // jversion.h: @COPYRIGHT_YEAR@ のみ置換すれば良い
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
        .HIDDEN = "__attribute__((visibility(\"hidden\")))",
        .INLINE = "inline __attribute__((always_inline))",
        .THREAD_LOCAL = "_Thread_local",
        .CMAKE_PROJECT_NAME = "libjpeg-turbo",
        .VERSION = "3.0.4",
        .SIZE_T = @as(i64, 8), // → SIZEOF_SIZE_T (x86_64 / ARM64)
        .HAVE_BUILTIN_CTZL = @as(i64, 1),
        .HAVE_INTRIN_H = null,
        .C_ARITH_CODING_SUPPORTED = @as(i64, 1),
        .D_ARITH_CODING_SUPPORTED = @as(i64, 1),
        .WITH_SIMD = null,
    });

    // ── Core pipeline module (target-agnostic Zig source) ────────────────────
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
    addCLibraries(b, cli, jconfig_h, jconfigint_h, jversion_h);
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
    addCLibraries(b, cli_linux, jconfig_h, jconfigint_h, jversion_h);

    const linux_step = b.step("linux", "Cross-compile for Linux x86_64 VPS");
    linux_step.dependOn(&b.addInstallArtifact(cli_linux, .{
        .dest_dir = .{ .override = .{ .custom = "linux-x86_64" } },
    }).step);

    // ── WebAssembly / WASI (C ライブラリは Phase 5 で接続) ───────────────────
    const wasm_exe = b.addExecutable(.{
        .name = "pict",
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_exe.rdynamic = true;
    wasm_exe.stack_size = 64 * 1024;

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
    addCLibraries(b, ffi_lib, jconfig_h, jconfigint_h, jversion_h);

    const lib_step = b.step("lib", "Build shared library for FFI (.dylib/.so)");
    lib_step.dependOn(&b.addInstallArtifact(ffi_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    }).step);

    // ── Unit tests ────────────────────────────────────────────────────────────
    // C ライブラリ (libjpeg-turbo 等) も同時にリンクして JPEG デコードパスを検証する。
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    addCLibraries(b, unit_tests, jconfig_h, jconfigint_h, jversion_h);
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
// C ライブラリ統合ヘルパー
// ─────────────────────────────────────────────────────────────────────────────

const ConfigHeader = std.Build.Step.ConfigHeader;

fn addCLibraries(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    jconfig_h: *ConfigHeader,
    jconfigint_h: *ConfigHeader,
    jversion_h: *ConfigHeader,
) void {
    addZlib(b, artifact);
    addLibpng(b, artifact);
    addLibjpegTurbo(b, artifact, jconfig_h, jconfigint_h, jversion_h);
    addLibwebp(b, artifact);
    // pict-zig-engine C bridges (JPEG / PNG decode/encode wrappers with setjmp support)
    artifact.addCSourceFiles(.{
        .files = &.{
            "src/c/jpeg_decode.c",
            "src/c/png_decode.c",
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
    // pnglibconf.h は prebuilt をコピーして使う
    artifact.addIncludePath(b.path("vendor/libpng"));
    artifact.addIncludePath(b.path("vendor/libpng/scripts")); // pnglibconf.h.prebuilt
    artifact.addIncludePath(b.path("vendor/zlib"));

    // pnglibconf.h: prebuilt を include_path が通るようにシンボリックリンクは
    // 使わず、Zig の WriteFile ステップでコピーする。
    const copy_pnglibconf = b.addWriteFiles();
    _ = copy_pnglibconf.addCopyFile(
        b.path("vendor/libpng/scripts/pnglibconf.h.prebuilt"),
        "pnglibconf.h",
    );
    artifact.addIncludePath(copy_pnglibconf.getDirectory());
    artifact.step.dependOn(&copy_pnglibconf.step);

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
        .flags = &.{
            "-std=c11",
            "-DPNG_ARM_NEON_OPT=0",   // SIMD は Phase 3 で有効化
            "-DPNG_INTEL_SSE_OPT=0",
        },
    });
}

// ── libjpeg-turbo 3.0.4 (non-SIMD) ──────────────────────────────────────────
fn addLibjpegTurbo(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    jconfig_h: *ConfigHeader,
    jconfigint_h: *ConfigHeader,
    jversion_h: *ConfigHeader,
) void {
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
            // WITH_SIMD は定義しない (Phase 2: non-SIMD)
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
            .flags = &.{ "-std=c11", "-msse2", "-msse4.1" },
        });
    }
    // wasm32: SIMD は Phase 5 で追加。スカラー baseline のみで動作する。
}
