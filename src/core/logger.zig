pub var logger_instance: ?*logly.Logger = null;

pub fn init(
    allocator: std.mem.Allocator,
    log_file_path: ?[]const u8,
) !void {
    if (logger_instance != null) return;

    const logger = try logly.Logger.initWithConfig(allocator, .{
        .json = true,
        .global_console_display = false,
    });

    if (log_file_path) |log_path| {
        _ = try logger.add(.{ .path = log_path, .retention = 5, .rotation = "daily" });
    }

    logger_instance = logger;
}

pub fn deinit() void {
    if (logger_instance) |l| {
        l.deinit();
        logger_instance = null;
    }
}

pub fn get() *logly.Logger {
    return logger_instance orelse
        @panic("Logger used before init");
}

const std = @import("std");
const logly = @import("logly");
