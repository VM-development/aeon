const std = @import("std");

// ─────────────────────────────────────────────────────────────
// Dialog Provider Interface
// ─────────────────────────────────────────────────────────────

/// An inbound message from a dialog
pub const InboundMessage = struct {
    dialog: []const u8, // e.g. "cli", "telegram"
    from: []const u8, // user identifier
    text: []const u8,
    timestamp: i64,
};

/// Callback type for handling inbound messages.
/// Returns the response text to send back to the user.
pub const MessageHandler = *const fn (msg: InboundMessage) anyerror![]const u8;

/// Dialog provider interface using vtable-based polymorphism
pub const DialogProvider = struct {
    name: []const u8,
    vtable: *const VTable,
    impl: *anyopaque,

    pub const VTable = struct {
        /// Start the dialog provider (blocking — runs the main loop)
        start: *const fn (impl: *anyopaque, handler: MessageHandler) anyerror!void,
        /// Send a message to a specific user/chat
        send: *const fn (impl: *anyopaque, to: []const u8, message: []const u8) anyerror!void,
        /// Clean up resources
        deinit: *const fn (impl: *anyopaque) void,
    };

    pub fn start(self: *DialogProvider, handler: MessageHandler) !void {
        try self.vtable.start(self.impl, handler);
    }

    pub fn send(self: *DialogProvider, to: []const u8, message: []const u8) !void {
        try self.vtable.send(self.impl, to, message);
    }

    pub fn deinit(self: *DialogProvider) void {
        self.vtable.deinit(self.impl);
    }
};
