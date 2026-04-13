/// platform.zig — コンパイル時プラットフォーム選択
///
/// 使い方: const platform = @import("platform.zig");
///         const tile_h = platform.DEFAULT_TILE_HEIGHT;
///
/// ターゲットが wasm32 なら platform/wasm.zig、それ以外は platform/native.zig を選ぶ。
/// 呼び出し元はプラットフォームを意識しなくてよい。

const builtin = @import("builtin");

pub usingnamespace if (builtin.target.cpu.arch == .wasm32)
    @import("platform/wasm.zig")
else
    @import("platform/native.zig");
