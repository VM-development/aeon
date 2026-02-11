const std = @import("std");

pub fn stdout_print(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buffer);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

pub fn stderr_print(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buffer);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

/// Expand ~ to home directory in paths
/// Returns a new allocated string if expansion occurred, otherwise returns a dupe of input
pub fn expandPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) return try allocator.dupe(u8, path);

    if (path[0] == '~') {
        const home = std.posix.getenv("HOME") orelse return try allocator.dupe(u8, path);
        if (path.len == 1) {
            return try allocator.dupe(u8, home);
        } else if (path[1] == '/') {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
        }
    }
    return try allocator.dupe(u8, path);
}
