pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try cli.parseArgs(allocator);

    if (args.help) {
        try utils.stdout_print("{s}\n", .{cli.HELP_MESSAGE});
        return;
    }

    if (args.version) {
        try utils.stdout_print("aeon version {s}\n", .{build_options.version});
        return;
    }

    // Print help message if no arguments are provided
    try utils.stdout_print("{s}\n", .{cli.HELP_MESSAGE});
}

const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");
const build_options = @import("build_options");
