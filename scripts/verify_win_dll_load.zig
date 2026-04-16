//! CI / 手元: Windows で DLL を純 ARM64 プロセスとしてロードできるか確認する。
//! actions/setup-python の arm64 ビルドは ARM64EC のことがあり、純 ARM64（Machine 0xAA64）の
//! libpict.dll を ctypes で読むと WinError 193 になる。Zig で生成した同ターゲットのローダで検証する。
//!
//! 二段階テスト:
//!   1. LOAD_LIBRARY_AS_DATAFILE: 依存 DLL 解決なし・DllMain なし。
//!      → 失敗(193)なら DLL ファイル自体のフォーマット異常。
//!      → 成功なら DLL は有効な ARM64 PE。
//!   2. LOAD_WITH_ALTERED_SEARCH_PATH: 通常ロード。DLL 自身のディレクトリを依存解決先頭にする。
//!      → 失敗なら依存 DLL（vcruntime140.dll 等）の解決問題。
const std = @import("std");
const w = std.os.windows;

const LOAD_LIBRARY_AS_DATAFILE: u32 = 0x00000002;
const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x00000008;

extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: [*:0]const u16,
    hFile: ?w.HANDLE,
    dwFlags: u32,
) callconv(w.WINAPI) ?w.HMODULE;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const al = arena.allocator();

    const argv = try std.process.argsAlloc(al);
    if (argv.len < 2) {
        std.debug.print("usage: verify_win_dll_load <path-to.dll>\n", .{});
        return error.BadArgs;
    }

    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const abs = std.fs.realpath(argv[1], &path_buf) catch |err| {
        std.debug.print("realpath failed: {}\n", .{err});
        return err;
    };
    std.debug.print("path: {s}\n", .{abs});

    const path_utf16 = try std.unicode.utf8ToUtf16LeWithNull(al, abs);

    // --- test 1: DATAFILE (no dep resolution, no DllMain) ---
    const h_data = LoadLibraryExW(path_utf16.ptr, null, LOAD_LIBRARY_AS_DATAFILE);
    if (h_data == null) {
        const err = w.kernel32.GetLastError();
        std.debug.print("LOAD_LIBRARY_AS_DATAFILE failed GetLastError={d} -- DLL file invalid\n", .{@intFromEnum(err)});
        return error.LoadFailed;
    }
    _ = w.kernel32.FreeLibrary(h_data.?);
    std.debug.print("LOAD_LIBRARY_AS_DATAFILE OK -- DLL file is valid ARM64 PE\n", .{});

    // --- test 2: full load (dep resolution + DllMain) ---
    const h = LoadLibraryExW(path_utf16.ptr, null, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (h == null) {
        const err = w.kernel32.GetLastError();
        std.debug.print("LoadLibraryExW(ALTERED_SEARCH) failed GetLastError={d} -- dependency issue\n", .{@intFromEnum(err)});
        return error.LoadFailed;
    }
    defer _ = w.kernel32.FreeLibrary(h.?);
    std.debug.print("LoadLibraryExW OK\n", .{});
}
