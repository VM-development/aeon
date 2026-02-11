const std = @import("std");

// ─────────────────────────────────────────────────────────────
// Shared types for all LLM providers
// ─────────────────────────────────────────────────────────────

/// Role of a message in the conversation
pub const MessageRole = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toString(self: MessageRole) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

/// A single message in a conversation
pub const Message = struct {
    role: MessageRole,
    content: []const u8,
    name: ?[]const u8 = null, // For tool messages
    tool_call_id: ?[]const u8 = null, // For tool response messages
    tool_calls: ?[]const ToolCall = null, // For assistant messages with tool calls

    pub fn init(role: MessageRole, content: []const u8) Message {
        return .{
            .role = role,
            .content = content,
        };
    }

    /// Free all owned allocations. Pass the same allocator used for allocations.
    pub fn deinit(self: *const Message, allocator: std.mem.Allocator) void {
        if (self.content.len > 0) {
            allocator.free(self.content);
        }
        if (self.name) |name| {
            allocator.free(name);
        }
        if (self.tool_call_id) |id| {
            allocator.free(id);
        }
        if (self.tool_calls) |tcs| {
            for (tcs) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.name);
                allocator.free(tc.arguments);
            }
            allocator.free(tcs);
        }
    }
};

/// Tool parameter definition
pub const ToolParameter = struct {
    type: []const u8, // "string", "number", "boolean", "object", "array"
    description: ?[]const u8 = null,
    @"enum": ?[]const []const u8 = null, // For enum values
    required: bool = false,
};

/// Tool definition for LLM
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.StringHashMap(ToolParameter),

    pub fn deinit(self: *Tool) void {
        var it = self.parameters.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.@"enum") |enum_vals| {
                _ = enum_vals;
            }
        }
        self.parameters.deinit();
    }
};

/// Tool call from LLM
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // JSON string
};

/// Stream events from LLM (provider-agnostic)
pub const StreamEvent = union(enum) {
    text_delta: []const u8,
    tool_call_delta: struct {
        index: ?usize = null, // Tool call index for multi-tool-call handling
        id: ?[]const u8,
        name: ?[]const u8,
        arguments: ?[]const u8,
    },
    tool_call: ToolCall,
    done: void,
    @"error": []const u8,
};

/// Request to LLM for completion
pub const CompletionRequest = struct {
    model: []const u8,
    messages: []const Message,
    system_prompt: ?[]const u8 = null, // Extracted system prompt (used by Anthropic)
    tools: ?[]const Tool = null,
    max_tokens: u32 = 4096,
    temperature: f32 = 1.0,
    stream: bool = true,
};

/// Response from LLM
pub const CompletionResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    finish_reason: []const u8, // "stop", "length", "tool_calls"
    usage: ?Usage = null,
};

/// Token usage statistics
pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

/// Callback for streaming responses
pub const StreamCallback = *const fn (event: StreamEvent) anyerror!void;

/// LLM provider type
pub const LlmProvider = enum {
    openai,
    anthropic,

    pub fn toString(self: LlmProvider) []const u8 {
        return switch (self) {
            .openai => "openai",
            .anthropic => "anthropic",
        };
    }
};

// ─────────────────────────────────────────────────────────────
// Generic LLM client interface (vtable-based polymorphism)
// ─────────────────────────────────────────────────────────────

/// Generic LLM client interface
pub const LlmClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,

    // Virtual function table
    vtable: *const VTable,
    impl: *anyopaque,

    pub const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        streamCompletion: *const fn (
            *anyopaque,
            std.mem.Allocator,
            CompletionRequest,
            StreamCallback,
        ) anyerror!void,
        completion: *const fn (
            *anyopaque,
            std.mem.Allocator,
            CompletionRequest,
        ) anyerror!CompletionResponse,
    };

    pub fn deinit(self: *LlmClient) void {
        self.vtable.deinit(self.impl);
    }

    pub fn streamCompletion(
        self: *LlmClient,
        request: CompletionRequest,
        callback: StreamCallback,
    ) !void {
        try self.vtable.streamCompletion(self.impl, self.allocator, request, callback);
    }

    pub fn completion(
        self: *LlmClient,
        request: CompletionRequest,
    ) !CompletionResponse {
        return try self.vtable.completion(self.impl, self.allocator, request);
    }
};

// ─────────────────────────────────────────────────────────────
// Shared SSE (Server-Sent Events) parsing utilities
// ─────────────────────────────────────────────────────────────

/// Context for SSE stream processing, reusable across providers
pub const SseLineBuffer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .{},

    pub fn init(allocator: std.mem.Allocator) SseLineBuffer {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SseLineBuffer) void {
        self.buffer.deinit(self.allocator);
    }

    /// Append a raw chunk from HTTP and yield complete lines via the callback.
    /// Returns lines one at a time; caller decides how to interpret them.
    pub fn feed(self: *SseLineBuffer, chunk: []const u8, onLine: *const fn (line: []const u8, ctx: *anyopaque) anyerror!void, ctx: *anyopaque) !void {
        try self.buffer.appendSlice(self.allocator, chunk);

        while (std.mem.indexOf(u8, self.buffer.items, "\n")) |newline_idx| {
            const line = self.buffer.items[0..newline_idx];

            // Trim trailing \r
            const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
                line[0 .. line.len - 1]
            else
                line;

            try onLine(trimmed, ctx);

            // Remove processed line from buffer
            const remaining = self.buffer.items[newline_idx + 1 ..];
            std.mem.copyForwards(u8, self.buffer.items, remaining);
            self.buffer.shrinkRetainingCapacity(remaining.len);
        }
    }
};

/// Extract the data payload from an SSE "data: ..." line.
/// Returns null if the line is not a data line.
pub fn parseSseDataLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "data: ")) return null;
    return std.mem.trimLeft(u8, line[6..], " ");
}

// ─────────────────────────────────────────────────────────────
// Shared JSON helpers
// ─────────────────────────────────────────────────────────────

/// Write a JSON-escaped string (without surrounding quotes) to the writer.
pub fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    // Control characters as \u00XX
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Write the shared "tools" array in OpenAI-compatible function-calling format.
/// Both OpenAI and Anthropic use similar (but not identical) tool schemas;
/// this helper writes the OpenAI shape. Anthropic overrides with its own format.
pub fn writeToolsJson(writer: anytype, tools: []const Tool) !void {
    for (tools, 0..) |tool, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"");
        try writer.writeAll(tool.name);
        try writer.writeAll("\",\"description\":\"");
        try writeJsonEscaped(writer, tool.description);
        try writer.writeAll("\",\"parameters\":{\"type\":\"object\",\"properties\":{");

        var prop_it = tool.parameters.iterator();
        var prop_idx: usize = 0;
        while (prop_it.next()) |entry| {
            if (prop_idx > 0) try writer.writeAll(",");
            try writer.writeAll("\"");
            try writer.writeAll(entry.key_ptr.*);
            try writer.writeAll("\":{\"type\":\"");
            try writer.writeAll(entry.value_ptr.type);
            try writer.writeAll("\"");
            if (entry.value_ptr.description) |desc| {
                try writer.writeAll(",\"description\":\"");
                try writeJsonEscaped(writer, desc);
                try writer.writeAll("\"");
            }
            try writer.writeAll("}");
            prop_idx += 1;
        }

        try writer.writeAll("}}}");
    }
}
