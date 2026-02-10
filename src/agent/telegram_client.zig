const std = @import("std");
const http = @import("../utils/http.zig");

// ─────────────────────────────────────────────────────────────
// Telegram Bot API Client
// A minimal implementation using the existing HTTP client
// ─────────────────────────────────────────────────────────────

pub const TelegramClient = struct {
    allocator: std.mem.Allocator,
    http_client: http.HttpClient,
    bot_token: []const u8,
    api_base_url: []const u8,

    const Self = @This();

    /// Initialize the Telegram client
    /// bot_token is NOT owned — caller must keep it alive
    pub fn init(allocator: std.mem.Allocator, bot_token: []const u8) !TelegramClient {
        // Build API base URL
        const api_base_url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}", .{bot_token});

        return .{
            .allocator = allocator,
            .http_client = http.HttpClient.init(allocator),
            .bot_token = bot_token,
            .api_base_url = api_base_url,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.api_base_url);
        self.http_client.deinit();
    }

    /// Get basic info about the bot
    pub fn getMe(self: *Self) !User {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/getMe", .{self.api_base_url});
        defer self.allocator.free(url);

        var response = try self.http_client.get(url, &.{});
        defer response.deinit();

        if (response.status != .ok) {
            return error.TelegramAPIError;
        }

        return try self.parseResponse(User, response.body);
    }

    /// Long-poll for updates
    pub fn getUpdates(self: *Self, offset: i64, limit: u32, timeout: u32) ![]Update {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/getUpdates?offset={d}&limit={d}&timeout={d}",
            .{ self.api_base_url, offset, limit, timeout },
        );
        defer self.allocator.free(url);

        var response = try self.http_client.get(url, &.{});
        defer response.deinit();

        if (response.status != .ok) {
            return error.TelegramAPIError;
        }

        return try self.parseResponseArray(Update, response.body);
    }

    /// Send a text message
    pub fn sendMessage(self: *Self, chat_id: i64, text: []const u8) !Message {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/sendMessage", .{self.api_base_url});
        defer self.allocator.free(url);

        // Build JSON body
        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(.{
            .chat_id = chat_id,
            .text = text,
        }, .{}, &out.writer);
        const json_body = try out.toOwnedSlice();
        defer self.allocator.free(json_body);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.post(url, &headers, json_body);
        defer response.deinit();

        if (response.status != .ok) {
            return error.TelegramAPIError;
        }

        return try self.parseResponse(Message, response.body);
    }

    /// Parse a Telegram API response into a type
    fn parseResponse(self: *Self, comptime T: type, body: []const u8) !T {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_if_needed,
        });
        defer parsed.deinit();

        const value = parsed.value;
        if (value != .object) return error.InvalidResponse;

        const ok = value.object.get("ok") orelse return error.InvalidResponse;
        if (ok != .bool or !ok.bool) {
            return error.TelegramAPIError;
        }

        const result = value.object.get("result") orelse return error.InvalidResponse;
        return try parseValue(self.allocator, T, result);
    }

    /// Parse a Telegram API response that returns an array
    fn parseResponseArray(self: *Self, comptime T: type, body: []const u8) ![]T {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_if_needed,
        });
        defer parsed.deinit();

        const value = parsed.value;
        if (value != .object) return error.InvalidResponse;

        const ok = value.object.get("ok") orelse return error.InvalidResponse;
        if (ok != .bool or !ok.bool) {
            return error.TelegramAPIError;
        }

        const result = value.object.get("result") orelse return error.InvalidResponse;
        if (result != .array) return error.InvalidResponse;

        var items = try self.allocator.alloc(T, result.array.items.len);
        errdefer self.allocator.free(items);

        for (result.array.items, 0..) |item, i| {
            items[i] = try parseValue(self.allocator, T, item);
        }

        return items;
    }
};

// ─────────────────────────────────────────────────────────────
// Telegram Types
// ─────────────────────────────────────────────────────────────

pub const User = struct {
    id: i64,
    is_bot: bool,
    first_name: []const u8,
    last_name: ?[]const u8 = null,
    username: ?[]const u8 = null,
    language_code: ?[]const u8 = null,

    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *User) void {
        if (self.allocator) |alloc| {
            alloc.free(self.first_name);
            if (self.last_name) |v| alloc.free(v);
            if (self.username) |v| alloc.free(v);
            if (self.language_code) |v| alloc.free(v);
        }
    }
};

pub const Chat = struct {
    id: i64,
    type: []const u8,
    title: ?[]const u8 = null,
    username: ?[]const u8 = null,
    first_name: ?[]const u8 = null,
    last_name: ?[]const u8 = null,

    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Chat) void {
        if (self.allocator) |alloc| {
            alloc.free(self.type);
            if (self.title) |v| alloc.free(v);
            if (self.username) |v| alloc.free(v);
            if (self.first_name) |v| alloc.free(v);
            if (self.last_name) |v| alloc.free(v);
        }
    }
};

pub const Message = struct {
    message_id: i64,
    date: i64,
    chat: Chat,
    from: ?User = null,
    text: ?[]const u8 = null,

    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Message) void {
        if (self.allocator) |alloc| {
            var chat = self.chat;
            chat.allocator = alloc;
            chat.deinit();
            if (self.from) |*from| {
                var user = from.*;
                user.allocator = alloc;
                user.deinit();
            }
            if (self.text) |v| alloc.free(v);
        }
    }
};

pub const Update = struct {
    update_id: i64,
    message: ?Message = null,
    edited_message: ?Message = null,
    channel_post: ?Message = null,
    edited_channel_post: ?Message = null,

    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Update) void {
        if (self.allocator) |alloc| {
            if (self.message) |*msg| {
                var m = msg.*;
                m.allocator = alloc;
                m.deinit();
            }
            if (self.edited_message) |*msg| {
                var m = msg.*;
                m.allocator = alloc;
                m.deinit();
            }
            if (self.channel_post) |*msg| {
                var m = msg.*;
                m.allocator = alloc;
                m.deinit();
            }
            if (self.edited_channel_post) |*msg| {
                var m = msg.*;
                m.allocator = alloc;
                m.deinit();
            }
        }
    }
};

// ─────────────────────────────────────────────────────────────
// JSON Parsing Helpers
// ─────────────────────────────────────────────────────────────

fn parseValue(allocator: std.mem.Allocator, comptime T: type, value: std.json.Value) !T {
    switch (T) {
        User => return try parseUser(allocator, value),
        Chat => return try parseChat(allocator, value),
        Message => return try parseMessage(allocator, value),
        Update => return try parseUpdate(allocator, value),
        else => @compileError("Unsupported type for parseValue"),
    }
}

fn parseUser(allocator: std.mem.Allocator, value: std.json.Value) !User {
    if (value != .object) return error.InvalidResponse;
    const obj = value.object;

    return .{
        .id = getInt(obj, "id") orelse return error.InvalidResponse,
        .is_bot = getBool(obj, "is_bot") orelse false,
        .first_name = try dupeString(allocator, obj, "first_name") orelse return error.InvalidResponse,
        .last_name = try dupeString(allocator, obj, "last_name"),
        .username = try dupeString(allocator, obj, "username"),
        .language_code = try dupeString(allocator, obj, "language_code"),
        .allocator = allocator,
    };
}

fn parseChat(allocator: std.mem.Allocator, value: std.json.Value) !Chat {
    if (value != .object) return error.InvalidResponse;
    const obj = value.object;

    return .{
        .id = getInt(obj, "id") orelse return error.InvalidResponse,
        .type = try dupeString(allocator, obj, "type") orelse return error.InvalidResponse,
        .title = try dupeString(allocator, obj, "title"),
        .username = try dupeString(allocator, obj, "username"),
        .first_name = try dupeString(allocator, obj, "first_name"),
        .last_name = try dupeString(allocator, obj, "last_name"),
        .allocator = allocator,
    };
}

fn parseMessage(allocator: std.mem.Allocator, value: std.json.Value) !Message {
    if (value != .object) return error.InvalidResponse;
    const obj = value.object;

    var msg = Message{
        .message_id = getInt(obj, "message_id") orelse return error.InvalidResponse,
        .date = getInt(obj, "date") orelse return error.InvalidResponse,
        .chat = undefined,
        .allocator = allocator,
    };

    // Parse chat
    const chat_val = obj.get("chat") orelse return error.InvalidResponse;
    msg.chat = try parseChat(allocator, chat_val);

    // Parse optional from
    if (obj.get("from")) |from_val| {
        msg.from = try parseUser(allocator, from_val);
    }

    // Parse optional text
    msg.text = try dupeString(allocator, obj, "text");

    return msg;
}

fn parseUpdate(allocator: std.mem.Allocator, value: std.json.Value) !Update {
    if (value != .object) return error.InvalidResponse;
    const obj = value.object;

    var update = Update{
        .update_id = getInt(obj, "update_id") orelse return error.InvalidResponse,
        .allocator = allocator,
    };

    // Parse optional message types
    if (obj.get("message")) |msg_val| {
        update.message = try parseMessage(allocator, msg_val);
    }
    if (obj.get("edited_message")) |msg_val| {
        update.edited_message = try parseMessage(allocator, msg_val);
    }
    if (obj.get("channel_post")) |msg_val| {
        update.channel_post = try parseMessage(allocator, msg_val);
    }
    if (obj.get("edited_channel_post")) |msg_val| {
        update.edited_channel_post = try parseMessage(allocator, msg_val);
    }

    return update;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    if (val != .integer) return null;
    return val.integer;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    if (val != .bool) return null;
    return val.bool;
}

fn dupeString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val != .string) return null;
    return try allocator.dupe(u8, val.string);
}
