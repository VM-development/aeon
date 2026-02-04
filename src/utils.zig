const std = @import("std");

pub fn stdout_print(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buffer);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
