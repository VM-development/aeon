// Role is now loaded from config.role_path or uses constants.DEFAULT_ROLE
// See roles/ folder for available role files

/// Load role prompt from file or return default
fn loadRole(allocator: std.mem.Allocator, role_path: ?[]const u8) ![]const u8 {
    if (role_path) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Note: Could not open role file '{s}': {}. Using default role.\n", .{ path, err });
            return constants.DEFAULT_ROLE;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > 100 * 1024) {
            std.debug.print("Note: Role file too large (>100KB). Using default role.\n", .{});
            return constants.DEFAULT_ROLE;
        }

        const content = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(content);

        const bytes_read = try file.readAll(content);
        return content[0..bytes_read];
    }
    return constants.DEFAULT_ROLE;
}

/// Global runtime pointer for the message handler callback
var g_runtime: ?*runtime.AgentRuntime = null;
var g_messenger: config.Config.Messenger = .cli;

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

    // Initialize LLM client based on provider config
    var llm_client = switch (_config.llm_provider) {
        .openai => blk: {
            var _openai = try openai.OpenAIClient.init(allocator, api_key);
            break :blk _openai.asLlmClient();
        },
        .anthropic => {
            try utils.stderr_print("Error: Anthropic provider is not yet implemented\n", .{});
            return;
        },
    };
    defer llm_client.deinit();

    // Load skills from the skills directory
    const skills_result = skills.loadSkills(allocator, skills.DEFAULT_SKILLS_PATH) catch {
        try _logger.err("Failed to load skills", @src());
        return;
    };
    defer skills_result.deinit(allocator);

    // Load role from file or use default
    const role_content = loadRole(allocator, _config.role_path) catch |err| {
        try _logger.err("Failed to load role", @src());
        try utils.stderr_print("Error loading role: {}\\n", .{err});
        return;
    };
    const role_allocated = role_content.ptr != constants.DEFAULT_ROLE.ptr;
    defer if (role_allocated) allocator.free(role_content);

    // Combine role prompt with skills
    const full_system_prompt = if (skills_result.content.len > 0)
        std.fmt.allocPrint(allocator, "{s}{s}", .{ role_content, skills_result.content }) catch role_content
    else
        role_content;
    defer if (skills_result.content.len > 0 and full_system_prompt.ptr != role_content.ptr)
        allocator.free(full_system_prompt);

    // Initialize agent runtime
    var agent = try runtime.AgentRuntime.init(
        allocator,
        &llm_client,
        _config.llm_model,
        full_system_prompt,
    );
    defer agent.deinit();

    // Set global for callback
    g_runtime = &agent;
    defer {
        g_runtime = null;
    }

    // Start the appropriate messenger based on config
    g_messenger = _config.messenger;
    switch (_config.messenger) {
        .telegram => {
            // Get Telegram bot token from environment
            const telegram_token = env.getRequired(allocator, "TELEGRAM_BOT_TOKEN") catch |err| {
                try utils.stderr_print("Error: TELEGRAM_BOT_TOKEN environment variable not set: {}\n", .{err});
                return;
            };
            defer allocator.free(telegram_token);

            try _logger.info("Starting Telegram messenger", @src());

            var telegram_messenger = telegram_provider.TelegramMessenger.init(allocator, telegram_token) catch |err| {
                try utils.stderr_print("Error initializing Telegram: {}\n", .{err});
                return;
            };
            defer telegram_messenger.deinit();
            var messenger = telegram_messenger.asMessengerProvider();

            try messenger.start(handleMessage);
        },
        .cli => {
            // Initialize CLI messenger and start interactive loop
            var cli_messenger = cli_provider.CliMessenger.init(allocator);
            defer cli_messenger.deinit();
            var messenger = cli_messenger.asMessengerProvider();

            try _logger.info("Starting CLI messenger", @src());
            try messenger.start(handleMessage);
        },
    }
}

/// Handle an inbound message from any messenger provider.
/// This is called by the messenger provider with each user message.
fn handleMessage(msg: provider.InboundMessage) anyerror![]const u8 {
    const agent = g_runtime orelse return error.RuntimeNotInitialized;

    // Handle /clear command
    if (std.mem.eql(u8, msg.text, "/clear")) {
        agent.clearHistory();
        return try agent.allocator.dupe(u8, "");
    }

    // Process via streaming — text deltas printed in real-time (CLI only)
    const callback: *const fn ([]const u8) anyerror!void = switch (g_messenger) {
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
const provider = @import("messengers/provider.zig");
const cli_provider = @import("messengers/cli.zig");
const telegram_provider = @import("messengers/telegram.zig");
const skills = @import("agent/skills.zig");
