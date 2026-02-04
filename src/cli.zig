const std = @import("std");

pub const CliArgs = struct {
    version: bool = false,
    help: bool = false,
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
        }
    }

    return cli_args;
}

pub const HELP_MESSAGE =
    \\Usage: aeon [OPTIONS]
    \\
    \\Options:
    \\  -v, --version  Print version
    \\  -h, --help     Print this help message
;
