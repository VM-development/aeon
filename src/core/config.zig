pub const Config = struct {
    log_file_path: ?[]const u8 = null,
    dialog_mode: DialogMode = .cli,

    pub const DialogMode = enum {
        cli,
        telegram,
    };

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.log_file_path) |path| {
            allocator.free(path);
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

        // Parse dialog mode: "cli" or "telegram"
        if (value.object.get("dialog_mode")) |mode| {
            const mode_str = mode.string;
            if (std.mem.eql(u8, mode_str, "telegram")) {
                config.dialog_mode = .telegram;
            } else {
                config.dialog_mode = .cli;
            }
        }

        return config;
    }
};

const std = @import("std");
