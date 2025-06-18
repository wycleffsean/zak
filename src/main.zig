const std = @import("std");
const lib = @import("zak_lib");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sessions = try lib.kakSessions(allocator);
    const selected_session = try lib.selectSession(allocator, sessions);
    try lib.execKak(allocator, selected_session);
}
