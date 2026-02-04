pub const CliArgs = struct {
    version: bool = false,
    help: bool = false,
    config_path: ?[]const u8 = null,

    pub fn deinit(self: *CliArgs, allocator: std.mem.Allocator) void {
        if (self.config_path) |path| {
            allocator.free(path);
        }
    }
};

pub fn parseArgs(allocator: std.mem.Allocator) !CliArgs {
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cli_args = CliArgs{};

    // Skip the first argument (program name)
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            cli_args.version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cli_args.help = true;
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            const path = arg[9..];
            cli_args.config_path = try allocator.dupe(u8, path);
        } else {
            return error.InvalidArgument;
        }
    }

    return cli_args;
}

const std = @import("std");
