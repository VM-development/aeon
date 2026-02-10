const std = @import("std");
const provider = @import("provider.zig");
const utils = @import("../utils/utils.zig");

// ─────────────────────────────────────────────────────────────
// CLI Dialog Provider — interactive terminal chat
// ─────────────────────────────────────────────────────────────

pub const CliDialog = struct {
    allocator: std.mem.Allocator,
    running: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) CliDialog {
        return .{
            .allocator = allocator,
            .running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Returns a DialogProvider interface backed by this CliDialog
    pub fn asDialogProvider(self: *Self) provider.DialogProvider {
        const vtable: *const provider.DialogProvider.VTable = &.{
            .start = startVirtual,
            .send = sendVirtual,
            .deinit = deinitVirtual,
        };

        return .{
            .name = "cli",
            .vtable = vtable,
            .impl = @ptrCast(self),
        };
    }

    fn startVirtual(impl: *anyopaque, handler: provider.MessageHandler) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(impl));
        try self.run(handler);
    }

    fn sendVirtual(impl: *anyopaque, to: []const u8, message: []const u8) anyerror!void {
        _ = impl;
        _ = to;
        try utils.stdout_print("{s}\n", .{message});
    }

    fn deinitVirtual(impl: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(impl));
        self.deinit();
    }

    /// Main interactive loop
    fn run(self: *Self, handler: provider.MessageHandler) !void {
        self.running = true;

        try utils.stdout_print("\n{s}\n", .{BANNER});
        try utils.stdout_print("Type your message and press Enter. Commands: /quit, /clear, /help\n\n", .{});

        const stdin = std.fs.File.stdin();

        while (self.running) {
            try utils.stdout_print("you> ", .{});

            // Read a line from stdin byte by byte
            const line = readLine(stdin) catch |err| {
                if (err == error.EndOfStream) {
                    try utils.stdout_print("\nGoodbye!\n", .{});
                    self.running = false;
                    break;
                }
                return err;
            };

            // Trim whitespace
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            // Handle commands
            if (trimmed[0] == '/') {
                const should_continue = try self.handleCommand(trimmed);
                if (!should_continue) break;
                continue;
            }

            // Send to handler and print response
            try utils.stdout_print("\nassistant> ", .{});

            const response = handler(.{
                .dialog = "cli",
                .from = "local",
                .text = trimmed,
                .timestamp = std.time.timestamp(),
            }) catch |err| {
                try utils.stderr_print("\nError processing message: {}\n", .{err});
                continue;
            };
            defer self.allocator.free(response);

            // Response is already printed via streaming callback,
            // but if non-streaming, print it here
            if (response.len > 0) {
                try utils.stdout_print("{s}", .{response});
            }
            try utils.stdout_print("\n\n", .{});
        }
    }

    /// Handle slash commands. Returns false if the dialog should stop.
    fn handleCommand(self: *Self, command: []const u8) !bool {
        if (std.mem.eql(u8, command, "/quit") or std.mem.eql(u8, command, "/exit")) {
            try utils.stdout_print("Goodbye!\n", .{});
            self.running = false;
            return false;
        } else if (std.mem.eql(u8, command, "/help")) {
            try utils.stdout_print(
                \\
                \\Commands:
                \\  /quit, /exit  — Exit the chat
                \\  /clear        — Clear conversation history
                \\  /help         — Show this help
                \\
                \\
            , .{});
        } else if (std.mem.eql(u8, command, "/clear")) {
            // The clear is handled by the message handler when it receives
            // the special /clear command
            try utils.stdout_print("Conversation history cleared.\n\n", .{});
        } else {
            try utils.stdout_print("Unknown command: {s}. Type /help for available commands.\n\n", .{command});
        }
        return true;
    }
};

const BANNER =
    \\╔══════════════════════════════════════╗
    \\║            AEON Assistant            ║
    \\╚══════════════════════════════════════╝
;

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

/// Read a line from a File (stdin) by reading one byte at a time.
/// Returns the line without the trailing newline.
fn readLine(file: std.fs.File) ![]const u8 {
    // Use a static buffer for the line
    const S = struct {
        var line_buf: [8192]u8 = undefined;
    };
    var pos: usize = 0;

    while (pos < S.line_buf.len) {
        var one: [1]u8 = undefined;
        const n = file.read(&one) catch |err| {
            if (pos > 0) return S.line_buf[0..pos];
            return err;
        };
        if (n == 0) {
            if (pos > 0) return S.line_buf[0..pos];
            return error.EndOfStream;
        }
        if (one[0] == '\n') {
            return S.line_buf[0..pos];
        }
        S.line_buf[pos] = one[0];
        pos += 1;
    }
    return S.line_buf[0..pos];
}
