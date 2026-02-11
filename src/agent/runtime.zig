const std = @import("std");
const llm = @import("llm_client.zig");
const tools = @import("tools.zig");
const utils = @import("../utils/utils.zig");

// ─────────────────────────────────────────────────────────────
// Agent Runtime — message processing pipeline
// ─────────────────────────────────────────────────────────────

pub const AgentRuntime = struct {
    allocator: std.mem.Allocator,
    client: *llm.LlmClient,
    tool_registry: tools.ToolRegistry,
    conversation: std.ArrayList(llm.Message),
    system_prompt: ?[]const u8,
    model: []const u8,
    max_tool_rounds: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        client: *llm.LlmClient,
        model: []const u8,
        system_prompt: ?[]const u8,
    ) !AgentRuntime {
        var registry = tools.ToolRegistry.init(allocator);
        try registry.registerBuiltins();

        return .{
            .allocator = allocator,
            .client = client,
            .tool_registry = registry,
            .conversation = .{},
            .system_prompt = system_prompt,
            .model = model,
            .max_tool_rounds = 10,
        };
    }

    pub fn deinit(self: *AgentRuntime) void {
        // Free owned message content
        for (self.conversation.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.conversation.deinit(self.allocator);
        self.tool_registry.deinit();
    }

    /// Process a user message: send to LLM, handle tool calls in a loop,
    /// return the final assistant text response.
    pub fn processMessage(self: *AgentRuntime, user_message: []const u8) ![]const u8 {
        // Add user message to conversation
        try self.conversation.append(self.allocator, .{
            .role = .user,
            .content = try self.allocator.dupe(u8, user_message),
        });

        var round: u32 = 0;
        while (round < self.max_tool_rounds) : (round += 1) {
            // Build messages array for LLM (with system prompt prepended)
            const messages = try self.buildMessages();
            defer self.allocator.free(messages);

            // Get tool definitions
            const tool_defs = try self.tool_registry.getToolDefinitions();
            defer self.allocator.free(tool_defs);

            // Call LLM
            const response = try self.client.completion(.{
                .model = self.model,
                .messages = messages,
                .tools = if (tool_defs.len > 0) tool_defs else null,
                .stream = false,
            });

            // Store assistant response content
            const assistant_content = response.content orelse
                try self.allocator.dupe(u8, "");
            try self.conversation.append(self.allocator, .{
                .role = .assistant,
                .content = assistant_content,
            });

            // Check if LLM wants to call tools
            if (response.tool_calls) |tool_calls| {
                if (tool_calls.len > 0) {
                    try self.executeToolCalls(tool_calls);
                    // Continue loop — send tool results back to LLM
                    continue;
                }
            }

            // No tool calls — we have the final response
            return try self.allocator.dupe(u8, assistant_content);
        }

        return try self.allocator.dupe(u8, "[Max tool rounds exceeded]");
    }

    /// Process a user message with streaming output.
    /// Streams text deltas via the callback, handles tool calls in a loop.
    /// Returns the accumulated full response text.
    pub fn processMessageStreaming(
        self: *AgentRuntime,
        user_message: []const u8,
        on_text: *const fn (text: []const u8) anyerror!void,
    ) ![]const u8 {
        // Add user message to conversation
        try self.conversation.append(self.allocator, .{
            .role = .user,
            .content = try self.allocator.dupe(u8, user_message),
        });

        var round: u32 = 0;
        while (round < self.max_tool_rounds) : (round += 1) {

            // Build messages array for LLM
            const messages = try self.buildMessages();
            defer self.allocator.free(messages);

            // Get tool definitions
            const tool_defs = try self.tool_registry.getToolDefinitions();
            defer self.allocator.free(tool_defs);

            // Stream from LLM — collect text + tool calls
            var stream_collector = StreamCollector.init(self.allocator, on_text);
            g_stream_collector = &stream_collector;
            defer {
                g_stream_collector = null;
                stream_collector.deinit();
            }

            try self.client.streamCompletion(.{
                .model = self.model,
                .messages = messages,
                .tools = if (tool_defs.len > 0) tool_defs else null,
                .stream = true,
            }, StreamCollector.callback);

            // Get streamed content and tool calls
            const assistant_content = try stream_collector.getContent();
            const pending_tools = stream_collector.getToolCalls();

            // Convert pending tool calls to llm.ToolCall for storage
            var tool_calls_for_msg: ?[]const llm.ToolCall = null;
            if (pending_tools.len > 0) {
                var tc_list: std.ArrayList(llm.ToolCall) = .{};
                for (pending_tools) |ptc| {
                    try tc_list.append(self.allocator, .{
                        .id = try self.allocator.dupe(u8, ptc.id.items),
                        .name = try self.allocator.dupe(u8, ptc.name.items),
                        .arguments = try self.allocator.dupe(u8, ptc.arguments.items),
                    });
                }
                tool_calls_for_msg = try tc_list.toOwnedSlice(self.allocator);
            }

            // Store assistant response (with tool_calls if any)
            try self.conversation.append(self.allocator, .{
                .role = .assistant,
                .content = assistant_content,
                .tool_calls = tool_calls_for_msg,
            });

            // Handle tool calls if any
            if (pending_tools.len > 0) {
                try self.executeToolCallsFromStream(pending_tools);
                continue;
            }

            // No tool calls — done
            return try self.allocator.dupe(u8, assistant_content);
        }

        return try self.allocator.dupe(u8, "[Max tool rounds exceeded]");
    }

    /// Clear conversation history
    pub fn clearHistory(self: *AgentRuntime) void {
        for (self.conversation.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.conversation.clearRetainingCapacity();
    }

    // ─────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────

    fn buildMessages(self: *AgentRuntime) ![]llm.Message {
        var msgs: std.ArrayList(llm.Message) = .{};

        // Prepend system prompt if set
        if (self.system_prompt) |sp| {
            try msgs.append(self.allocator, .{
                .role = .system,
                .content = sp,
            });
        }

        // Add conversation history
        for (self.conversation.items) |msg| {
            try msgs.append(self.allocator, msg);
        }

        return try msgs.toOwnedSlice(self.allocator);
    }

    fn executeToolCalls(self: *AgentRuntime, tool_calls: []const llm.ToolCall) !void {
        for (tool_calls) |tc| {
            var result = try self.tool_registry.executeTool(
                tc.name,
                tc.arguments,
                .{ .allocator = self.allocator },
            );
            defer result.deinit(self.allocator);

            // Add tool result as a message
            try self.conversation.append(self.allocator, .{
                .role = .tool,
                .content = try self.allocator.dupe(u8, result.output),
                .name = tc.name,
                .tool_call_id = tc.id,
            });
        }
    }

    fn executeToolCallsFromStream(self: *AgentRuntime, pending: []const StreamCollector.PendingToolCall) !void {
        for (pending) |tc| {
            const name = tc.name.items;
            const args = tc.arguments.items;

            var result = try self.tool_registry.executeTool(
                name,
                args,
                .{ .allocator = self.allocator },
            );
            defer result.deinit(self.allocator);

            const id = tc.id.items;
            try self.conversation.append(self.allocator, .{
                .role = .tool,
                .content = try self.allocator.dupe(u8, result.output),
                .name = try self.allocator.dupe(u8, name),
                .tool_call_id = try self.allocator.dupe(u8, id),
            });
        }
    }
};

// ─────────────────────────────────────────────────────────────
// Stream collector — accumulates text + tool calls from stream
// ─────────────────────────────────────────────────────────────

/// Thread-local / global pointer for the stream callback.
/// Zig function pointers can't capture context, so we use a global.
var g_stream_collector: ?*StreamCollector = null;

const StreamCollector = struct {
    allocator: std.mem.Allocator,
    text_buf: std.ArrayList(u8),
    tool_calls: std.ArrayList(PendingToolCall),
    on_text: *const fn (text: []const u8) anyerror!void,

    const PendingToolCall = struct {
        id: std.ArrayList(u8),
        name: std.ArrayList(u8),
        arguments: std.ArrayList(u8),

        fn deinit(self: *PendingToolCall, allocator: std.mem.Allocator) void {
            self.id.deinit(allocator);
            self.name.deinit(allocator);
            self.arguments.deinit(allocator);
        }
    };

    fn init(allocator: std.mem.Allocator, on_text: *const fn (text: []const u8) anyerror!void) StreamCollector {
        return .{
            .allocator = allocator,
            .text_buf = .{},
            .tool_calls = .{},
            .on_text = on_text,
        };
    }

    fn deinit(self: *StreamCollector) void {
        self.text_buf.deinit(self.allocator);
        for (self.tool_calls.items) |*tc| {
            tc.deinit(self.allocator);
        }
        self.tool_calls.deinit(self.allocator);
        if (g_stream_collector == self) {
            g_stream_collector = null;
        }
    }

    fn callback(event: llm.StreamEvent) anyerror!void {
        const self = g_stream_collector orelse return;
        switch (event) {
            .text_delta => |text| {
                try self.text_buf.appendSlice(self.allocator, text);
                try self.on_text(text);
            },
            .tool_call => |tc| {
                var pending = PendingToolCall{
                    .id = .{},
                    .name = .{},
                    .arguments = .{},
                };
                try pending.id.appendSlice(self.allocator, tc.id);
                try pending.name.appendSlice(self.allocator, tc.name);
                try pending.arguments.appendSlice(self.allocator, tc.arguments);
                try self.tool_calls.append(self.allocator, pending);
            },
            .tool_call_delta => |delta| {
                // Accumulate into the last pending tool call
                if (self.tool_calls.items.len == 0) {
                    // Start a new pending tool call
                    var pending = PendingToolCall{
                        .id = .{},
                        .name = .{},
                        .arguments = .{},
                    };
                    if (delta.id) |id| try pending.id.appendSlice(self.allocator, id);
                    if (delta.name) |name| try pending.name.appendSlice(self.allocator, name);
                    if (delta.arguments) |args| try pending.arguments.appendSlice(self.allocator, args);
                    try self.tool_calls.append(self.allocator, pending);
                } else {
                    var last = &self.tool_calls.items[self.tool_calls.items.len - 1];
                    if (delta.id) |id| try last.id.appendSlice(self.allocator, id);
                    if (delta.name) |name| try last.name.appendSlice(self.allocator, name);
                    if (delta.arguments) |args| try last.arguments.appendSlice(self.allocator, args);
                }
            },
            .done => {},
            .@"error" => |err| {
                try utils.stderr_print("Stream error: {s}\n", .{err});
            },
        }
    }

    fn getContent(self: *StreamCollector) ![]const u8 {
        if (self.text_buf.items.len > 0) {
            return try self.allocator.dupe(u8, self.text_buf.items);
        }
        return try self.allocator.dupe(u8, "");
    }

    fn getToolCalls(self: *StreamCollector) []const PendingToolCall {
        return self.tool_calls.items;
    }
};
