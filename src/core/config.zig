pub const Config = struct {
    log_file_path: ?[]const u8 = null,
    role_path: ?[]const u8 = null,
    messenger: Messenger = .cli,
    llm_provider: LlmProvider = .openai,
    llm_model: []const u8 = "gpt-4o-mini",

    pub const Messenger = enum {
        cli,
        telegram,
    };

    pub const LlmProvider = enum {
        openai,
        anthropic,
    };

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.log_file_path) |path| {
            allocator.free(path);
        }
        if (self.role_path) |path| {
            allocator.free(path);
        }
        // Free model if it was allocated (not the default)
        if (self.llm_model.ptr != @as([]const u8, "gpt-4o-mini").ptr) {
            allocator.free(self.llm_model);
        }
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        // Expand ~ in config path
        const expanded_path = try utils.expandPath(allocator, path);
        defer allocator.free(expanded_path);

        const file = try std.fs.cwd().openFile(expanded_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try allocator.alloc(u8, file_size);
        defer allocator.free(buffer);

        _ = try file.readAll(buffer);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer, .{
            .allocate = .alloc_if_needed,
        });
        defer parsed.deinit();

        return parseConfigFromJson(allocator, parsed.value);
    }

    pub fn loadFromString(allocator: std.mem.Allocator, json_str: []const u8) !Config {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{
            .allocate = .alloc_if_needed,
        });
        defer parsed.deinit();

        return parseConfigFromJson(allocator, parsed.value);
    }

    /// Helper to safely get a string from JSON value
    fn getJsonString(value: std.json.Value) ?[]const u8 {
        return if (value == .string) value.string else null;
    }

    fn parseConfigFromJson(allocator: std.mem.Allocator, value: std.json.Value) !Config {
        // Validate root is an object
        if (value != .object) {
            return error.InvalidConfig;
        }

        var config = Config{};

        // Parse log_file_path with ~ expansion
        if (value.object.get("log_file_path")) |log_path_val| {
            if (getJsonString(log_path_val)) |log_path| {
                if (log_path.len > 0) {
                    config.log_file_path = try utils.expandPath(allocator, log_path);
                }
            }
        }

        // Parse role_path with ~ expansion
        if (value.object.get("role_path")) |role_path_val| {
            if (getJsonString(role_path_val)) |role_path| {
                if (role_path.len > 0) {
                    config.role_path = try utils.expandPath(allocator, role_path);
                }
            }
        }

        // Parse messenger mode: "cli" or "telegram"
        if (value.object.get("messenger")) |mode_val| {
            if (getJsonString(mode_val)) |mode_str| {
                if (std.mem.eql(u8, mode_str, "telegram")) {
                    config.messenger = .telegram;
                } else {
                    config.messenger = .cli;
                }
            }
        }

        // Parse LLM provider: "openai" or "anthropic"
        if (value.object.get("llm_provider")) |provider_val| {
            if (getJsonString(provider_val)) |provider_str| {
                if (std.mem.eql(u8, provider_str, "anthropic")) {
                    config.llm_provider = .anthropic;
                } else if (std.mem.eql(u8, provider_str, "openai")) {
                    config.llm_provider = .openai;
                }
            }
        }

        // Parse LLM model name
        if (value.object.get("llm_model")) |model_val| {
            if (getJsonString(model_val)) |model| {
                if (model.len > 0) {
                    config.llm_model = try allocator.dupe(u8, model);
                }
            }
        }

        return config;
    }
};

const std = @import("std");
const utils = @import("../utils/utils.zig");
