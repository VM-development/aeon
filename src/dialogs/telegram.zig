const std = @import("std");
const telegram = @import("../agent/telegram_client.zig");
const provider = @import("provider.zig");
const logger = @import("../core/logger.zig");

// ─────────────────────────────────────────────────────────────
// Telegram Dialog Provider — Telegram Bot API integration
// ─────────────────────────────────────────────────────────────

pub const TelegramDialog = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    client: telegram.TelegramClient,
    running: bool,
    offset: i64,

    const Self = @This();

    /// Initialize the Telegram dialog provider
    /// bot_token is NOT owned by this struct — caller must keep it alive
    pub fn init(allocator: std.mem.Allocator, bot_token: []const u8) !TelegramDialog {
        var client = try telegram.TelegramClient.init(allocator, bot_token);
        errdefer client.deinit();

        return .{
            .allocator = allocator,
            .bot_token = bot_token,
            .client = client,
            .running = false,
            .offset = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }

    /// Returns a DialogProvider interface backed by this TelegramDialog
    pub fn asDialogProvider(self: *Self) provider.DialogProvider {
        const vtable: *const provider.DialogProvider.VTable = &.{
            .start = startVirtual,
            .send = sendVirtual,
            .deinit = deinitVirtual,
        };

        return .{
            .name = "telegram",
            .vtable = vtable,
            .impl = @ptrCast(self),
        };
    }

    fn startVirtual(impl: *anyopaque, handler: provider.MessageHandler) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(impl));
        try self.run(handler);
    }

    fn sendVirtual(impl: *anyopaque, to: []const u8, message: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(impl));

        // Parse chat_id from string
        const chat_id = std.fmt.parseInt(i64, to, 10) catch {
            const log = logger.get();
            log.err("Invalid chat_id: {s}", @src()) catch {};
            return error.InvalidChatId;
        };

        _ = try self.client.sendMessage(chat_id, message);
    }

    fn deinitVirtual(impl: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(impl));
        self.deinit();
    }

    /// Main polling loop
    fn run(self: *Self, handler: provider.MessageHandler) !void {
        self.running = true;

        const log = logger.get();
        try log.info("Telegram bot starting polling...", @src());

        // Verify bot is working
        var me = self.client.getMe() catch |err| {
            try log.err("Failed to get bot info", @src());
            return err;
        };
        defer me.deinit();

        const username = me.username orelse me.first_name;
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Telegram bot @{s} is online!", .{username}) catch "Telegram bot is online!";
        try log.info(msg, @src());

        while (self.running) {
            // Poll for updates with 30 second timeout
            const updates = self.client.getUpdates(self.offset, 100, 30) catch {
                try log.err("Failed to get updates", @src());
                // Sleep briefly and retry
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            };
            defer {
                for (updates) |*update| {
                    var u = update.*;
                    u.deinit();
                }
                self.allocator.free(updates);
            }

            for (updates) |update| {
                self.offset = update.update_id + 1;

                // Handle text messages
                if (update.message) |message| {
                    if (message.text) |text| {
                        const chat_id = message.chat.id;
                        const from_id = if (message.from) |from| from.id else chat_id;

                        // Format from_id as string for the handler
                        var from_id_buf: [32]u8 = undefined;
                        const from_id_str = std.fmt.bufPrint(&from_id_buf, "{d}", .{from_id}) catch continue;

                        // Call the message handler
                        const response = handler(.{
                            .dialog = "telegram",
                            .from = from_id_str,
                            .text = text,
                            .timestamp = message.date,
                        }) catch {
                            log.err("Error processing message", @src()) catch {};
                            continue;
                        };
                        defer self.allocator.free(response);

                        // Send response back to user
                        if (response.len > 0) {
                            // Split long messages (Telegram has 4096 char limit)
                            self.sendLongMessage(chat_id, response) catch {
                                log.err("Failed to send response", @src()) catch {};
                            };
                        }
                    }
                }
            }
        }
    }

    /// Send a message, splitting into multiple messages if too long
    fn sendLongMessage(self: *Self, chat_id: i64, text: []const u8) !void {
        const MAX_MESSAGE_LEN = 4000; // Leave some margin below 4096

        var remaining = text;
        while (remaining.len > 0) {
            const chunk_len = @min(remaining.len, MAX_MESSAGE_LEN);

            // Try to split at a newline or space to avoid cutting words
            var actual_len = chunk_len;
            if (remaining.len > MAX_MESSAGE_LEN) {
                // Look for a good split point
                var i = chunk_len;
                while (i > 0) : (i -= 1) {
                    if (remaining[i - 1] == '\n' or remaining[i - 1] == ' ') {
                        actual_len = i;
                        break;
                    }
                }
            }

            const chunk = remaining[0..actual_len];
            var msg = try self.client.sendMessage(chat_id, chunk);
            msg.deinit();

            remaining = remaining[actual_len..];
        }
    }

    /// Stop the polling loop
    pub fn stop(self: *Self) void {
        self.running = false;
    }
};
