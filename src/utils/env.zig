const std = @import("std");

/// Get environment variable value
/// Returns null if the variable is not set
pub fn get(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    const value = std.process.getEnvVarOwned(allocator, key) catch |err| {
        return switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => err,
        };
    };
    return value;
}

/// Get environment variable value or return a default value
pub fn getOrDefault(allocator: std.mem.Allocator, key: []const u8, default: []const u8) ![]const u8 {
    if (try get(allocator, key)) |value| {
        return value;
    }
    return try allocator.dupe(u8, default);
}

/// Get environment variable value or return an error if not set
pub fn getRequired(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    if (try get(allocator, key)) |value| {
        return value;
    }
    return error.EnvironmentVariableNotFound;
}
