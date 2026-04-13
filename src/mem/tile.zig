/// tile.zig — タイルバッファ
///
/// H-pass の出力を蓄積し、V-pass に渡す中間バッファ。
/// TILE_HEIGHT 行が揃ったら V-pass を発火させる。
///
/// Edge (128MB):  TILE_HEIGHT = 64  → ~512 KB/タイル
/// VPS (2GB):     TILE_HEIGHT = 256 → ~2 MB/タイル (より少ない V-pass 呼び出し)

const std = @import("std");

/// 環境ごとのデフォルトタイル高さ
pub const TILE_HEIGHT_EDGE: u32 = 64;
pub const TILE_HEIGHT_VPS: u32 = 256;

/// タイルバッファ: f32 行データを TILE_HEIGHT 行分保持する。
/// V-pass は `rows_ready == tile_height` のとき発火。
pub const TileBuffer = struct {
    /// フラットなデータ: [tile_height * row_width * channels] f32
    data: []f32,
    row_width: u32,
    channels: u8,
    tile_height: u32,
    /// 現在格納されている行数
    rows_ready: u32,
    /// このタイルの開始行 (dst 座標系での絶対 y)
    start_row: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        row_width: u32,
        channels: u8,
        tile_height: u32,
    ) !TileBuffer {
        const data = try allocator.alloc(
            f32,
            @as(usize, tile_height) * row_width * channels,
        );
        return .{
            .data = data,
            .row_width = row_width,
            .channels = channels,
            .tile_height = tile_height,
            .rows_ready = 0,
            .start_row = 0,
        };
    }

    pub fn deinit(self: *TileBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }

    /// H-pass 済みの行を追加する。タイルが満杯なら error.TileFull を返す。
    pub fn appendRow(self: *TileBuffer, row: []const f32) error{TileFull}!void {
        if (self.rows_ready >= self.tile_height) return error.TileFull;
        std.debug.assert(row.len == @as(usize, self.row_width) * self.channels);
        const stride = @as(usize, self.row_width) * self.channels;
        const dst = self.data[self.rows_ready * stride .. (self.rows_ready + 1) * stride];
        @memcpy(dst, row);
        self.rows_ready += 1;
    }

    pub inline fn isFull(self: *const TileBuffer) bool {
        return self.rows_ready >= self.tile_height;
    }

    /// タイルをリセット (次タイルの先頭行を設定)
    pub fn reset(self: *TileBuffer, new_start_row: u32) void {
        self.rows_ready = 0;
        self.start_row = new_start_row;
    }

    /// 行スライスを取得 (tile-local インデックス)
    pub fn rowSlice(self: *const TileBuffer, local_y: usize) []const f32 {
        std.debug.assert(local_y < self.rows_ready);
        const stride = @as(usize, self.row_width) * self.channels;
        return self.data[local_y * stride .. (local_y + 1) * stride];
    }

    pub fn memoryBytes(self: *const TileBuffer) usize {
        return self.data.len * @sizeOf(f32);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// テスト
// ─────────────────────────────────────────────────────────────────────────────

test "TileBuffer: appendRow と isFull" {
    var tile = try TileBuffer.init(std.testing.allocator, 4, 4, 2);
    defer tile.deinit(std.testing.allocator);

    const row = [_]f32{0.1} ** (4 * 4); // 4px, 4ch
    try tile.appendRow(&row);
    try std.testing.expect(!tile.isFull());
    try tile.appendRow(&row);
    try std.testing.expect(tile.isFull());

    // 満杯時は error.TileFull
    try std.testing.expectError(error.TileFull, tile.appendRow(&row));
}

test "TileBuffer: reset でカウンタが戻る" {
    var tile = try TileBuffer.init(std.testing.allocator, 2, 4, 3);
    defer tile.deinit(std.testing.allocator);

    const row = [_]f32{1.0} ** (2 * 4);
    for (0..3) |_| try tile.appendRow(&row);
    try std.testing.expect(tile.isFull());

    tile.reset(10);
    try std.testing.expectEqual(@as(u32, 10), tile.start_row);
    try std.testing.expect(!tile.isFull());
}

test "TileBuffer: メモリ使用量の推算 (Edge 4000px幅 64行)" {
    // 4000px * 4ch * 64行 * 4byte = 4,096,000 bytes ≈ 4 MB
    var tile = try TileBuffer.init(std.testing.allocator, 4000, 4, 64);
    defer tile.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4000 * 4 * 64 * 4), tile.memoryBytes());
}
