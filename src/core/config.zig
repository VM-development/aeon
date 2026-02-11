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
        const file = try std.fs.cwd().openFile(path, .{});
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

    fn parseConfigFromJson(allocator: std.mem.Allocator, value: std.json.Value) !Config {
        var config = Config{};

        if (value.object.get("log_file_path")) |log_path| {
            if (log_path.string.len > 0) {
                config.log_file_path = try allocator.dupe(u8, log_path.string);
            }
        }

        // Parse role file path
        if (value.object.get("role_path")) |role_path| {
            if (role_path.string.len > 0) {
                config.role_path = try allocator.dupe(u8, role_path.string);
            }
        }

        // Parse messenger mode: "cli" or "telegram"
        if (value.object.get("messenger")) |mode| {
            const mode_str = mode.string;
            if (std.mem.eql(u8, mode_str, "telegram")) {
                config.messenger = .telegram;
            } else {
                config.messenger = .cli;
            }
        }

        // Parse LLM provider: "openai" or "anthropic"
        if (value.object.get("llm_provider")) |provider| {
            const provider_str = provider.string;
            if (std.mem.eql(u8, provider_str, "anthropic")) {
                config.llm_provider = .anthropic;
            } else if (std.mem.eql(u8, provider_str, "openai")) {
                config.llm_provider = .openai;
            }
        }

        // Parse LLM model name
        if (value.object.get("llm_model")) |model| {
            if (model.string.len > 0) {
                config.llm_model = try allocator.dupe(u8, model.string);
            }
        }

        return config;
    }
};

const std = @import("std");
