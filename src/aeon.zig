pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI arguments
    var args = cli.parseArgs(allocator) catch |err| {
        try utils.stderr_print("Error parsing arguments: {}\n", .{err});
        try utils.stdout_print("{s}\n", .{constants.HELP_MESSAGE});
        return;
    };
    defer args.deinit(allocator);

    if (args.help) {
        try utils.stdout_print("{s}\n", .{constants.HELP_MESSAGE});
        return;
    }

    if (args.version) {
        try utils.stdout_print("aeon version {s}\n", .{build_options.version});
        return;
    }

    if (args.config_path) |config_path| {
        try utils.stdout_print("Using config file: {s}\n", .{config_path});
    } else {
        try utils.stdout_print("Using default config file path: {s}\n", .{constants.DEFAULT_CONFIG_PATH});
    }

    const config_path = args.config_path orelse constants.DEFAULT_CONFIG_PATH;
    var _config = config.Config.loadFromFile(allocator, config_path) catch |err| {
        try utils.stderr_print("Error: Failed to load config from '{s}': {}\n", .{ config_path, err });
        return;
    };
    defer _config.deinit(allocator);

    // Configure logger
    logger.init(allocator, _config.log_file_path) catch |err| {
        try utils.stderr_print("Error initializing logger: {}\n", .{err});
        return;
    };
    defer logger.deinit();

    const _logger = logger.get();
    try _logger.info("Logly installed successfully!", @src());

    try utils.stdout_print("Log file path: {s}\n", .{_config.log_file_path orelse "not set"});
}

const std = @import("std");
const cli = @import("core/cli.zig");
const utils = @import("utils/utils.zig");
const config = @import("core/config.zig");
const build_options = @import("build_options");
const constants = @import("core/constants.zig");
const logger = @import("core/logger.zig");
