/// root.zig — ライブラリエントリポイント
///
/// FFI (.so / .dylib) および Wasm モジュールとして公開するシンボルはここで管理する。
/// CLI は main.zig からこのモジュールを import する。

// ── パイプラインモジュール (公開 API) ─────────────────────────────────────────
pub const decode = @import("pipeline/decode.zig");
pub const encode = @import("pipeline/encode.zig");
pub const resize = @import("pipeline/resize.zig");

// ── メモリ管理モジュール ───────────────────────────────────────────────────────
pub const mem = struct {
    pub const ring = @import("mem/ring.zig");
    pub const tile = @import("mem/tile.zig");
};

// ── プラットフォーム抽象 ───────────────────────────────────────────────────────
pub const platform = @import("platform.zig");

// ─────────────────────────────────────────────────────────────────────────────
// Wasm / FFI 公開シンボル (Phase 2 以降で実装)
//
// export fn pict_resize(...) はここに追加する。
// Wasm ターゲットでのみコンパイルされるシンボルは comptime で制御する:
//
//   comptime {
//       if (builtin.target.cpu.arch == .wasm32) {
//           _ = @import("wasm_api.zig");
//       }
//   }
// ─────────────────────────────────────────────────────────────────────────────

// ── テスト集約 ─────────────────────────────────────────────────────────────────
// `zig build test` でサブモジュールのテストもすべて走らせる
test {
    _ = decode;
    _ = encode;
    _ = resize;
    _ = mem.ring;
    _ = mem.tile;
    _ = platform;
    @import("std").testing.refAllDecls(@This());
}
