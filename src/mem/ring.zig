/// ring.zig — ストリーミング用行リングバッファ
///
/// Lanczos-3 の V-pass に必要な「直近 N 行のスライディングウィンドウ」を提供する。
/// メモリレイアウト: data[abs_index % capacity * row_stride] に格納。
/// これにより abs_index → slot の計算が O(1) かつ剰余だけで完結する。
///
/// 使い方:
///   var ring = try RingBuffer(u8).init(alloc, 6, width * 4); // Lanczos-3: 6行窓
///   ring.pushRow(src_row_0);
///   ring.pushRow(src_row_1);
///   ...
///   const row = ring.getRow(abs_index); // null = 既にリングから追い出された

const std = @import("std");

pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,
        capacity: usize,
        row_stride: usize,
        /// 書き込み済み行の総数 (絶対インデックス)
        write_count: usize,

        pub fn init(
            allocator: std.mem.Allocator,
            capacity: usize,
            row_stride: usize,
        ) !Self {
            std.debug.assert(capacity > 0);
            std.debug.assert(row_stride > 0);
            const data = try allocator.alloc(T, capacity * row_stride);
            return .{
                .data = data,
                .capacity = capacity,
                .row_stride = row_stride,
                .write_count = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.data);
            self.* = undefined;
        }

        /// 1行を末尾に追加する。容量超過時は最古行を上書き。
        pub fn pushRow(self: *Self, row: []const T) void {
            std.debug.assert(row.len == self.row_stride);
            const slot = self.write_count % self.capacity;
            const dst = self.data[slot * self.row_stride .. (slot + 1) * self.row_stride];
            @memcpy(dst, row);
            self.write_count += 1;
        }

        /// 絶対行インデックス `abs_index` の行を返す。
        /// リングから追い出されていれば null。
        pub fn getRow(self: *const Self, abs_index: usize) ?[]const T {
            if (abs_index >= self.write_count) return null;
            const oldest = if (self.write_count > self.capacity)
                self.write_count - self.capacity
            else
                0;
            if (abs_index < oldest) return null;
            const slot = abs_index % self.capacity;
            return self.data[slot * self.row_stride .. (slot + 1) * self.row_stride];
        }

        /// リングが満杯か (Lanczos カーネル窓が揃ったかの判定に使う)
        pub inline fn isFull(self: *const Self) bool {
            return self.write_count >= self.capacity;
        }

        /// 有効な行数 (min(write_count, capacity))
        pub inline fn validCount(self: *const Self) usize {
            return @min(self.write_count, self.capacity);
        }

        /// 最新行の絶対インデックス。行が1つも無い場合は null。
        pub fn latestIndex(self: *const Self) ?usize {
            if (self.write_count == 0) return null;
            return self.write_count - 1;
        }
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// テスト
// ─────────────────────────────────────────────────────────────────────────────

test "RingBuffer: 基本的な push / get" {
    var ring = try RingBuffer(u8).init(std.testing.allocator, 6, 4);
    defer ring.deinit(std.testing.allocator);

    const row0 = [_]u8{ 1, 2, 3, 4 };
    const row1 = [_]u8{ 5, 6, 7, 8 };
    ring.pushRow(&row0);
    ring.pushRow(&row1);

    try std.testing.expectEqualSlices(u8, &row0, ring.getRow(0).?);
    try std.testing.expectEqualSlices(u8, &row1, ring.getRow(1).?);
    try std.testing.expect(ring.getRow(2) == null); // まだ書いていない
}

test "RingBuffer: 容量超過で最古行が追い出される" {
    var ring = try RingBuffer(u8).init(std.testing.allocator, 3, 2);
    defer ring.deinit(std.testing.allocator);

    ring.pushRow(&[_]u8{ 0, 0 }); // row 0
    ring.pushRow(&[_]u8{ 1, 1 }); // row 1
    ring.pushRow(&[_]u8{ 2, 2 }); // row 2
    ring.pushRow(&[_]u8{ 3, 3 }); // row 3 → row 0 が追い出される

    try std.testing.expect(ring.getRow(0) == null); // 追い出し済み
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1 }, ring.getRow(1).?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 2 }, ring.getRow(2).?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 3 }, ring.getRow(3).?);
}

test "RingBuffer: isFull / validCount" {
    var ring = try RingBuffer(u8).init(std.testing.allocator, 6, 1);
    defer ring.deinit(std.testing.allocator);

    try std.testing.expect(!ring.isFull());
    for (0..6) |i| ring.pushRow(&[_]u8{@intCast(i)});
    try std.testing.expect(ring.isFull());
    try std.testing.expectEqual(@as(usize, 6), ring.validCount());

    ring.pushRow(&[_]u8{99}); // 1行追加してもまだ満杯
    try std.testing.expect(ring.isFull());
    try std.testing.expectEqual(@as(usize, 6), ring.validCount());
}

test "RingBuffer: latestIndex" {
    var ring = try RingBuffer(u8).init(std.testing.allocator, 3, 1);
    defer ring.deinit(std.testing.allocator);

    try std.testing.expect(ring.latestIndex() == null);
    ring.pushRow(&[_]u8{0});
    try std.testing.expectEqual(@as(usize, 0), ring.latestIndex().?);
    ring.pushRow(&[_]u8{1});
    try std.testing.expectEqual(@as(usize, 1), ring.latestIndex().?);
}
