//! CI / 手元: Windows で DLL を純 ARM64 プロセスとしてロードできるか確認する。
//! actions/setup-python の arm64 ビルドは ARM64EC のことがあり、純 ARM64（Machine 0xAA64）の
//! libpict.dll を ctypes で読むと WinError 193 になる。Zig で生成した同ターゲットのローダで検証する。
//!
//! LoadLibraryExW + LOAD_WITH_ALTERED_SEARCH_PATH を使用する理由:
//! 通常の LoadLibraryW では「呼び出し元 exe のディレクトリ → System32 → CWD → PATH」の順に
//! 依存 DLL を探す。CI の PATH には x64 版 vcruntime140.dll が含まれる場合があり、
//! 先に x64 版を掴むと GetLastError=193 になる。
//! LOAD_WITH_ALTERED_SEARCH_PATH + 絶対パス指定により DLL 自身のディレクトリを
//! 依存解決の先頭に置くため、同じ場所に置いた ARM64 CRT が確実に使われる。
const std = @import("std");
const w = std.os.windows;

/// LOAD_WITH_ALTERED_SEARCH_PATH: 絶対パス指定時に DLL 自身のディレクトリを
/// 依存 DLL の検索パス先頭にする。
const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x00000008;

/// Zig 0.13.0 stdlib の kernel32 バインディングに LoadLibraryExW がない場合用。
/// 既に stdlib に同名宣言があってもリンカは同一シンボルに解決する。
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

    // 絶対パスに変換。LOAD_WITH_ALTERED_SEARCH_PATH は絶対パス必須。
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const abs = std.fs.realpath(argv[1], &path_buf) catch |err| {
        std.debug.print("realpath failed: {}\n", .{err});
        return err;
    };
    std.debug.print("path: {s}\n", .{abs});

    const path_utf16 = try std.unicode.utf8ToUtf16LeWithNull(al, abs);
    const h = LoadLibraryExW(path_utf16.ptr, null, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (h == null) {
        const err = w.kernel32.GetLastError();
        std.debug.print("LoadLibraryExW failed, GetLastError={d}\n", .{@intFromEnum(err)});
        return error.LoadFailed;
    }
    defer _ = w.kernel32.FreeLibrary(h.?);
    std.debug.print("LoadLibraryExW OK\n", .{});
}
