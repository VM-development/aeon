const SYSTEM_PROMPT =
    \\You are Aeon, a helpful AI assistant. You can help users with various tasks.
    \\You have access to tools for reading files, writing files, and executing shell commands.
    \\When a user asks you to perform an action that requires these tools, use them.
    \\Be concise and helpful in your responses.
;

/// Global runtime pointer for the message handler callback
var g_runtime: ?*runtime.AgentRuntime = null;
var g_dialog_mode: config.Config.DialogMode = .cli;

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
    try _logger.info("Aeon starting up", @src());

    // Get API key from environment
    const api_key = env.getRequired(allocator, "OPENAI_API_KEY") catch |err| {
        try utils.stderr_print("Error: OPENAI_API_KEY environment variable not set: {}\n", .{err});
        return;
    };
    defer allocator.free(api_key);

    // Initialize LLM client
    var _openai = try openai.OpenAIClient.init(allocator, api_key);
    defer _openai.deinit();
    var client = _openai.asLlmClient();

    // Initialize agent runtime
    var agent = try runtime.AgentRuntime.init(
        allocator,
        &client,
        "gpt-4o-mini",
        SYSTEM_PROMPT,
    );
    defer agent.deinit();

    // Set global for callback
    g_runtime = &agent;
    defer {
        g_runtime = null;
    }

    // Start the appropriate dialog based on config
    g_dialog_mode = _config.dialog_mode;
    switch (_config.dialog_mode) {
        .telegram => {
            // Get Telegram bot token from environment
            const telegram_token = env.getRequired(allocator, "TELEGRAM_BOT_TOKEN") catch |err| {
                try utils.stderr_print("Error: TELEGRAM_BOT_TOKEN environment variable not set: {}\n", .{err});
                return;
            };
            defer allocator.free(telegram_token);

            try _logger.info("Starting Telegram dialog", @src());

            var telegram_dialog = telegram_provider.TelegramDialog.init(allocator, telegram_token) catch |err| {
                try utils.stderr_print("Error initializing Telegram: {}\n", .{err});
                return;
            };
            defer telegram_dialog.deinit();
            var dialog = telegram_dialog.asDialogProvider();

            try dialog.start(handleMessage);
        },
        .cli => {
            // Initialize CLI dialog and start interactive loop
            var cli_dialog = cli_provider.CliDialog.init(allocator);
            defer cli_dialog.deinit();
            var dialog = cli_dialog.asDialogProvider();

            try _logger.info("Starting CLI dialog", @src());
            try dialog.start(handleMessage);
        },
    }
}

/// Handle an inbound message from any dialog provider.
/// This is called by the dialog provider with each user message.
fn handleMessage(msg: provider.InboundMessage) anyerror![]const u8 {
    const agent = g_runtime orelse return error.RuntimeNotInitialized;

    // Handle /clear command
    if (std.mem.eql(u8, msg.text, "/clear")) {
        agent.clearHistory();
        return try agent.allocator.dupe(u8, "");
    }

    // Process via streaming — text deltas printed in real-time (CLI only)
    const callback: *const fn ([]const u8) anyerror!void = switch (g_dialog_mode) {
        .cli => streamTextDelta,
        .telegram => noOpDelta,
    };
    const response = try agent.processMessageStreaming(msg.text, callback);
    return response;
}

/// Callback for streaming text deltas — prints to stdout in real-time
fn streamTextDelta(text: []const u8) anyerror!void {
    try utils.stdout_print("{s}", .{text});
}

/// No-op callback for non-CLI modes (Telegram handles response separately)
fn noOpDelta(_: []const u8) anyerror!void {}

const openai = @import("agent/openai.zig");
const llm = @import("agent/llm_client.zig");
const runtime = @import("agent/runtime.zig");
const std = @import("std");
const cli = @import("core/cli.zig");
const utils = @import("utils/utils.zig");
const env = @import("utils/env.zig");
const config = @import("core/config.zig");
const build_options = @import("build_options");
const constants = @import("core/constants.zig");
const logger = @import("core/logger.zig");
const provider = @import("dialogs/provider.zig");
const cli_provider = @import("dialogs/cli.zig");
const telegram_provider = @import("dialogs/telegram.zig");
