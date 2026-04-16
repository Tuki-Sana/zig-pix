//! CI / 手元: Windows で DLL を純 ARM64 プロセスとしてロードできるか確認する。
//! actions/setup-python の arm64 ビルドは ARM64EC のことがあり、純 ARM64（Machine 0xAA64）の
//! libpict.dll を ctypes で読むと WinError 193 になる。Zig で生成した同ターゲットのローダで検証する。
const std = @import("std");
const w = std.os.windows;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const al = arena.allocator();

    const argv = try std.process.argsAlloc(al);
    if (argv.len < 2) {
        std.debug.print("usage: verify_win_dll_load <path-to.dll>\n", .{});
        return error.BadArgs;
    }

    const path_utf16 = try std.unicode.utf8ToUtf16LeWithNull(al, argv[1]);
    const h = w.kernel32.LoadLibraryW(path_utf16.ptr);
    if (h == null) {
        const err = w.kernel32.GetLastError();
        std.debug.print("LoadLibraryW failed, GetLastError={d}\n", .{@intFromEnum(err)});
        return error.LoadFailed;
    }
    defer _ = w.kernel32.FreeLibrary(h.?);

    std.debug.print("LoadLibraryW OK {s}\n", .{argv[1]});
}
