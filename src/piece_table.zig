const std = @import("std");

const PieceTable = @This();
// Doesn't use ArrayListUnmanaged as you may want to use different allocators for the `add_buffer` vs `entries`

base: []const u8,
add_buffer: std.ArrayList(u8),
entries: std.ArrayList(Entry),

/// Unsigned integer that can fit max file size in it
/// This is usize rather than u64 as we mmap the file
const Pos = usize;
pub const Entry = struct {
    // index into base/add_buffer
    from: Pos,

    len: Pos,

    const BufferType = enum { base, add };
    fn bufferType(entry: Entry, pt: PieceTable) BufferType {
        if (entry.from < pt.base.len) {
            return .base;
        } else {
            return .add;
        }
    }

    fn bufferSlice(entry: Entry, pt: PieceTable) []const u8 {
        return switch (entry.bufferType(pt)) {
            .base => pt.base[entry.from..],
            .add => pt.add_buffer.items[entry.from - pt.base.len ..],
        }[0..entry.len];
    }

    fn pointsAtLastAdded(entry: Entry, pt: PieceTable) bool {
        return entry.bufferType(pt) == .add and
            entry.from - pt.base.len + entry.len == pt.add_buffer.items.len;
    }
};

pub fn init(allocator: std.mem.Allocator, base: []const u8) error{OutOfMemory}!@This() {
    var pt = PieceTable{
        .base = base,
        .add_buffer = std.ArrayList(u8).init(allocator),
        .entries = try std.ArrayList(Entry).initCapacity(allocator, 1),
    };
    pt.entries.appendAssumeCapacity(.{ .from = 0, .len = pt.base.len });
    return pt;
}

pub fn deinit(self: @This()) void {
    self.entries.deinit();
    self.add_buffer.deinit();
}

const FindResult = struct {
    /// Where this entry starts (offset from start of file)
    start: Pos,

    /// If found, where the entry can be found by indexing `entries`
    /// If Zig had pointer subtraction then this could be a pointer
    e: ?usize,
};
fn findEntry(self: @This(), index: Pos) FindResult {
    var a: Pos = 0;
    for (self.entries.items, 0..) |e, i| {
        if (index < a + e.len) {
            return .{
                .start = a,
                .e = i,
            };
        }
        a += e.len;
    }
    return .{
        .start = a,
        .e = null,
    };
}

fn getSlice(self: @This(), index: Pos) error{OutOfBounds}![]const u8 {
    const indexedEntry = self.findEntry(index);
    const entry_index = indexedEntry.e orelse return error.OutOfBounds;
    const entry = self.entries.items[entry_index];
    return entry.bufferSlice(self)[index - indexedEntry.start ..];
}

pub fn get(self: @This(), index: Pos) error{OutOfBounds}!u8 {
    return (try self.getSlice(index))[0];
}

pub fn append(self: *@This(), bytes: []const u8) error{OutOfMemory}!void {
    try self.add_buffer.ensureUnusedCapacity(bytes.len);

    const last_entry = &self.entries.items[self.entries.items.len - 1];
    if (last_entry.pointsAtLastAdded(self.*)) {
        // if previous entry is at end of add_buffer, then re-use
        last_entry.len += bytes.len;
    } else {
        try self.entries.append(.{
            .from = self.base.len + self.add_buffer.items.len,
            .len = bytes.len,
        });
    }

    self.add_buffer.appendSliceAssumeCapacity(bytes);
}

pub fn insert(self: *@This(), index: Pos, bytes: []const u8) error{ OutOfBounds, OutOfMemory }!void {
    try self.add_buffer.ensureUnusedCapacity(bytes.len);

    const new_entry: Entry = .{
        .from = self.base.len + self.add_buffer.items.len,
        .len = bytes.len,
    };

    const indexedEntry = self.findEntry(index);
    if (indexedEntry.e) |entry_index| {
        if (indexedEntry.start == index) {
            // on edge of existing entries
            if (!blk: {
                if (entry_index == 0) break :blk false;
                const previous_entry = &self.entries.items[entry_index - 1];
                if (previous_entry.pointsAtLastAdded(self.*)) {
                    // if previous entry is at end of `add_buffer`, then re-use
                    previous_entry.len += bytes.len;
                    break :blk true;
                } else {
                    break :blk false;
                }
            }) {
                try self.entries.insert(entry_index, new_entry);
            }
        } else {
            const split_point = index - indexedEntry.start;
            // This ensures we make a copy to avoid aliasing problems with the entry
            const old_entry = self.entries.items[entry_index];
            try self.entries.replaceRange(entry_index, 1, &[3]Entry{
                .{
                    .from = old_entry.from,
                    .len = split_point,
                },
                new_entry,
                .{
                    .from = old_entry.from + split_point,
                    .len = old_entry.len - split_point,
                },
            });
        }
    } else if (indexedEntry.start == index) {
        // appending to file
        try self.entries.append(new_entry);
    } else {
        return error.OutOfBounds;
    }

    self.add_buffer.appendSliceAssumeCapacity(bytes);
}

// Note: `set` is one of only things that *modify* `add_buffer`. Avoid if you're constructing an undo-log
pub fn set(self: *@This(), index: Pos, value: u8) error{ OutOfBounds, OutOfMemory }!u8 {
    const indexedEntry = self.findEntry(index);
    const entry_index = indexedEntry.e orelse return error.OutOfBounds;
    const old_entry = self.entries.items[entry_index];
    switch (old_entry.bufferType(self)) {
        .base => {
            try self.add_buffer.ensureUnusedCapacity(1);

            const new_entry: Entry = .{
                .from = self.base.len + self.add_buffer.items.len,
                .len = 1,
            };

            if (indexedEntry.start == index) {
                // on edge of existing entries
                try self.entries.insert(entry_index, new_entry);
            } else {
                const split_point = index - indexedEntry.start;
                try self.entries.replaceRange(entry_index, 1, &[3]Entry{
                    .{
                        .from = old_entry.from,
                        .len = split_point,
                    },
                    new_entry,
                    .{
                        .from = old_entry.from + split_point,
                        .len = old_entry.len - split_point,
                    },
                });
            }

            self.add_buffer.appendAssumeCapacity(value);
        },
        .add => self.add_buffer.items[old_entry.from - self.base.len] = value,
    }
}

pub fn delete(self: *@This(), index: Pos, length: Pos) error{ OutOfBounds, OutOfMemory }!void {
    const indexedEntry = self.findEntry(index);
    if (indexedEntry.e) |start_entry_index| {
        const split_point = index - indexedEntry.start;

        var entry_index = start_entry_index;
        var length_to_delete = length;

        if (split_point != 0) {
            // delete starting in the middle of an entry
            const start_entry = &self.entries.items[start_entry_index];
            const available_to_delete = start_entry.len - split_point;
            if (available_to_delete > length_to_delete) {
                // split the entry
                try self.entries.insert(entry_index, .{
                    .from = start_entry.from + split_point + length_to_delete,
                    .len = available_to_delete - length_to_delete,
                });
                start_entry.len = split_point;
                return;
            }
            length_to_delete -= available_to_delete;
            start_entry.len = split_point;
            entry_index += 1;
        }

        var entries_to_delete: usize = 0;
        while (entry_index < self.entries.items.len) : (entry_index += 1) {
            const e = self.entries.items[entry_index];
            if (length_to_delete < e.len) break;
            entries_to_delete += 1;
            length_to_delete -= e.len;
        }

        if (entries_to_delete > 0) {
            // TODO: send zig PR adding ArrayList.orderedRemoveMany
            const i = entry_index;
            const n = entries_to_delete;
            std.mem.copyBackwards(Entry, self.entries.items[i..], self.entries.items[i + n ..]);
            self.entries.shrinkRetainingCapacity(self.entries.items.len - n);
        }

        if (length_to_delete != 0) {
            const trim_entry = &self.entries.items[entry_index];
            trim_entry.from += length_to_delete;
            trim_entry.len -= length_to_delete;
        }
    } else {
        return error.OutOfBounds;
    }
}

fn expectGets(expected: []const u8, pt: PieceTable) !void {
    for (expected, 0..) |c, i| {
        const actual = try pt.get(i);
        if (c != actual) {
            std.debug.print("index {} incorrect. expected {}, found {}\n", .{
                i,
                std.fmt.fmtSliceEscapeLower(&[1]u8{c}),
                std.fmt.fmtSliceEscapeLower(&[1]u8{actual}),
            });
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expectError(error.OutOfBounds, pt.get(expected.len));
}

test "PieceTable" {
    var pt = try PieceTable.init(std.testing.allocator, "example content");
    defer pt.deinit();

    try expectGets("example content", pt);

    try pt.append(". this");
    try expectGets("example content. this", pt);

    try pt.append(" was appended.");
    try expectGets("example content. this was appended.", pt);

    try pt.insert(0, "Some ");
    try expectGets("Some example content. this was appended.", pt);

    try pt.delete(5, 8);
    try expectGets("Some content. this was appended.", pt);

    try pt.delete(8, 9);
    try expectGets("Some cons was appended.", pt);
}
