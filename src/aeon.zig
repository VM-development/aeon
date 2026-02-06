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
    try _logger.info("Logly installed successfully!", @src());

    // code for openai client example
    const api_key = env.getRequired(allocator, "OPENAI_API_KEY") catch |err| {
        try utils.stderr_print("Error: OPENAI_API_KEY environment variable not set: {}\n", .{err});
        return;
    };
    defer allocator.free(api_key);

    var _openai = try openai.OpenAIClient.init(allocator, api_key);
    defer _openai.deinit();
    var client = _openai.asLlmClient();

    try client.streamCompletion(
        .{
            .model = "gpt-3.5-turbo",
            .messages = &.{.{ .role = .user, .content = "Count to 3!" }},
            .stream = true,
        },
        streamCallback,
    );

    try utils.stdout_print("Log file path: {s}\n", .{_config.log_file_path orelse "not set"});
}

fn streamCallback(event: llm.StreamEvent) anyerror!void {
    switch (event) {
        .text_delta => |content| {
            try utils.stdout_print("Received content chunk: {s}\n", .{content});
        },
        .tool_call => |tc| {
            try utils.stdout_print("Received tool call: {s}\n", .{tc.name});
        },
        .tool_call_delta => {},
        .done => {
            try utils.stdout_print("Stream finished\n", .{});
        },
        .@"error" => |err| {
            try utils.stderr_print("Stream error: {s}\n", .{err});
        },
    }
}

const openai = @import("agent/openai.zig");
const llm = @import("agent/llm_client.zig");
const std = @import("std");
const cli = @import("core/cli.zig");
const utils = @import("utils/utils.zig");
const env = @import("utils/env.zig");
const config = @import("core/config.zig");
const build_options = @import("build_options");
const constants = @import("core/constants.zig");
const logger = @import("core/logger.zig");
