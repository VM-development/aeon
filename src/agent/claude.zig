const std = @import("std");
const http = @import("../utils/http.zig");
const llm = @import("llm_client.zig");

const DEFAULT_BASE_URL = "https://api.anthropic.com";
const MESSAGES_ENDPOINT = "/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";

// Anthropic API request structures
const AnthropicMessage = struct {
    role: []const u8,
    content: std.json.Value,
};

const AnthropicToolInputSchema = struct {
    type: []const u8 = "object",
    properties: std.json.Value,
};

const AnthropicTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: AnthropicToolInputSchema,
};

const AnthropicRequest = struct {
    model: []const u8,
    messages: []const AnthropicMessage,
    max_tokens: u32,
    system: ?[]const u8 = null,
    temperature: ?f32 = null,
    stream: ?bool = null,
    tools: ?[]const AnthropicTool = null,
};

pub const AnthropicError = error{
    ApiError,
    InvalidResponse,
    StreamError,
    JsonError,
    Overloaded,
    RateLimit,
};

pub const AnthropicClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    http_client: http.HttpClient,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !*AnthropicClient {
        const client = try allocator.create(AnthropicClient);
        client.* = .{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, api_key),
            .base_url = DEFAULT_BASE_URL,
            .http_client = http.HttpClient.init(allocator),
        };
        return client;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.api_key);
        self.http_client.deinit();
        self.allocator.destroy(self);
    }

    /// Create LlmClient interface from AnthropicClient
    pub fn asLlmClient(self: *Self) llm.LlmClient {
        const vtable: *const llm.LlmClient.VTable = &.{
            .deinit = deinitVirtual,
            .streamCompletion = streamCompletionVirtual,
            .completion = completionVirtual,
        };

        return llm.LlmClient{
            .allocator = self.allocator,
            .api_key = self.api_key,
            .base_url = self.base_url,
            .vtable = vtable,
            .impl = @ptrCast(self),
        };
    }

    fn deinitVirtual(impl: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(impl));
        self.deinit();
    }

    fn streamCompletionVirtual(
        impl: *anyopaque,
        allocator: std.mem.Allocator,
        request: llm.CompletionRequest,
        callback: llm.StreamCallback,
    ) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(impl));
        _ = allocator;
        try self.streamCompletion(request, callback);
    }

    fn completionVirtual(
        impl: *anyopaque,
        allocator: std.mem.Allocator,
        request: llm.CompletionRequest,
    ) anyerror!llm.CompletionResponse {
        const self: *Self = @ptrCast(@alignCast(impl));
        _ = allocator;
        return try self.completion(request);
    }

    // ─────────────────────────────────────────────────────────
    // Public API
    // ─────────────────────────────────────────────────────────

    /// Stream completion from Anthropic Messages API
    pub fn streamCompletion(
        self: *Self,
        request: llm.CompletionRequest,
        callback: llm.StreamCallback,
    ) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ self.base_url, MESSAGES_ENDPOINT },
        );
        defer self.allocator.free(url);

        const body = try self.buildRequestBody(request, true);
        defer self.allocator.free(body);

        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = ANTHROPIC_VERSION },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var context = StreamContext{
            .allocator = self.allocator,
            .callback = callback,
            .line_buffer = llm.SseLineBuffer.init(self.allocator),
            .tool_input_buf = .{},
            .current_tool_id = null,
            .current_tool_name = null,
        };
        defer context.line_buffer.deinit();
        defer context.tool_input_buf.deinit(self.allocator);

        const status = try self.http_client.streamRequest(
            .POST,
            url,
            &headers,
            body,
            &context,
            streamChunkHandler,
        );

        if (status != .ok) {
            return AnthropicError.ApiError;
        }

        try callback(.done);
    }

    /// Non-streaming completion
    pub fn completion(
        self: *Self,
        request: llm.CompletionRequest,
    ) !llm.CompletionResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ self.base_url, MESSAGES_ENDPOINT },
        );
        defer self.allocator.free(url);

        const body = try self.buildRequestBody(request, false);
        defer self.allocator.free(body);

        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = ANTHROPIC_VERSION },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.post(url, &headers, body);
        defer response.deinit();

        if (response.status != .ok) {
            return AnthropicError.ApiError;
        }

        return try self.parseCompletionResponse(response.body);
    }

    // ─────────────────────────────────────────────────────────
    // Anthropic-specific request body builder
    // ─────────────────────────────────────────────────────────

    /// Build Anthropic Messages API request body.
    ///
    /// Key differences from OpenAI:
    ///   - `system` is a top-level field (not a message role)
    ///   - messages only have "user" / "assistant" roles
    ///   - tools use `input_schema` instead of `parameters`
    fn buildRequestBody(
        self: *Self,
        request: llm.CompletionRequest,
        stream: bool,
    ) ![]u8 {
        // Extract system prompt: prefer explicit field, fall back to first system message
        var system_prompt: ?[]const u8 = request.system_prompt;
        var skip_system_msg = false;
        if (system_prompt == null) {
            for (request.messages) |msg| {
                if (msg.role == .system) {
                    system_prompt = msg.content;
                    skip_system_msg = true;
                    break;
                }
            }
        }

        // Convert messages to Anthropic format
        var messages: std.ArrayList(AnthropicMessage) = .{};
        defer messages.deinit(self.allocator);

        for (request.messages) |msg| {
            if (msg.role == .system and skip_system_msg) continue;

            // Map roles: Anthropic only allows "user" and "assistant"
            const role_str = switch (msg.role) {
                .system => "user",
                .user => "user",
                .assistant => "assistant",
                .tool => "user",
            };

            if (msg.role == .tool) {
                // Tool result as content block array
                var content_array: std.ArrayList(std.json.Value) = .{};
                defer content_array.deinit(self.allocator);

                var tool_result = std.json.ObjectMap.init(self.allocator);
                defer tool_result.deinit();

                try tool_result.put("type", .{ .string = "tool_result" });
                try tool_result.put("tool_use_id", .{ .string = msg.tool_call_id orelse "unknown" });
                try tool_result.put("content", .{ .string = msg.content });

                try content_array.append(self.allocator, .{ .object = tool_result });
                try messages.append(self.allocator, .{
                    .role = role_str,
                    .content = .{ .array = try content_array.toOwnedSlice(self.allocator) },
                });
            } else {
                try messages.append(self.allocator, .{
                    .role = role_str,
                    .content = .{ .string = msg.content },
                });
            }
        }

        // Convert tools to Anthropic format if present
        var anthropic_tools: ?[]const AnthropicTool = null;
        var tools_list: std.ArrayList(AnthropicTool) = .{};
        defer tools_list.deinit(self.allocator);

        if (request.tools) |tools| {
            for (tools) |tool| {
                // Build properties JSON object
                var props_map = std.json.ObjectMap.init(self.allocator);
                defer props_map.deinit();

                var iter = tool.parameters.iterator();
                while (iter.next()) |entry| {
                    var prop_obj = std.json.ObjectMap.init(self.allocator);
                    defer prop_obj.deinit();

                    try prop_obj.put("type", .{ .string = entry.value_ptr.type });
                    if (entry.value_ptr.description) |desc| {
                        try prop_obj.put("description", .{ .string = desc });
                    }

                    try props_map.put(entry.key_ptr.*, .{ .object = prop_obj });
                }

                try tools_list.append(self.allocator, .{
                    .name = tool.name,
                    .description = tool.description,
                    .input_schema = .{
                        .properties = .{ .object = props_map },
                    },
                });
            }
            anthropic_tools = try tools_list.toOwnedSlice(self.allocator);
        }
        defer if (anthropic_tools) |t| self.allocator.free(t);

        const anthropic_request = AnthropicRequest{
            .model = request.model,
            .messages = try messages.toOwnedSlice(self.allocator),
            .max_tokens = request.max_tokens,
            .system = system_prompt,
            .temperature = if (request.temperature != 1.0) request.temperature else null,
            .stream = if (stream) true else null,
            .tools = anthropic_tools,
        };
        defer self.allocator.free(anthropic_request.messages);

        // Serialize to JSON
        var body: std.ArrayList(u8) = .{};
        defer body.deinit(self.allocator);

        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(anthropic_request, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    // ─────────────────────────────────────────────────────────
    // Response parsing
    // ─────────────────────────────────────────────────────────

    /// Parse a non-streaming Anthropic Messages API response.
    ///
    /// Response shape:
    /// ```json
    /// {
    ///   "id": "msg_...",
    ///   "content": [{"type":"text","text":"Hello!"}],
    ///   "stop_reason": "end_turn",
    ///   "usage": {"input_tokens":25,"output_tokens":10}
    /// }
    /// ```
    fn parseCompletionResponse(self: *Self, body: []const u8) !llm.CompletionResponse {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            body,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract text content from content blocks
        var text_buf: std.ArrayList(u8) = .{};
        defer text_buf.deinit(self.allocator);

        if (root.get("content")) |content_val| {
            for (content_val.array.items) |block| {
                const block_obj = block.object;
                const block_type = block_obj.get("type") orelse continue;
                if (block_type != .string) continue;

                if (std.mem.eql(u8, block_type.string, "text")) {
                    if (block_obj.get("text")) |text_val| {
                        if (text_val == .string) {
                            try text_buf.appendSlice(self.allocator, text_val.string);
                        }
                    }
                }
                // TODO: Parse tool_use content blocks
            }
        }

        const content = if (text_buf.items.len > 0)
            try self.allocator.dupe(u8, text_buf.items)
        else
            null;

        // Map Anthropic stop_reason to our finish_reason
        const stop_reason = if (root.get("stop_reason")) |sr|
            if (sr == .string) sr.string else "stop"
        else
            "stop";

        const finish_reason = mapStopReason(stop_reason);

        // Parse usage
        var usage: ?llm.Usage = null;
        if (root.get("usage")) |usage_val| {
            const u_obj = usage_val.object;
            const input = if (u_obj.get("input_tokens")) |v| jsonToU32(v) else 0;
            const output = if (u_obj.get("output_tokens")) |v| jsonToU32(v) else 0;
            usage = .{
                .prompt_tokens = input,
                .completion_tokens = output,
                .total_tokens = input + output,
            };
        }

        return llm.CompletionResponse{
            .content = content,
            .tool_calls = null, // TODO: Parse tool_use blocks
            .finish_reason = try self.allocator.dupe(u8, finish_reason),
            .usage = usage,
        };
    }
};

// ─────────────────────────────────────────────────────────────
// Anthropic SSE stream handling
// ─────────────────────────────────────────────────────────────
//
// Anthropic event flow:
//   event: message_start       → top-level message metadata
//   event: content_block_start → new content block (text / tool_use)
//   event: content_block_delta → text_delta or input_json_delta
//   event: content_block_stop  → block finished
//   event: message_delta       → stop_reason, usage
//   event: message_stop        → end of stream
//   event: ping                → keepalive (ignore)
//   event: error               → error object

const StreamContext = struct {
    allocator: std.mem.Allocator,
    callback: llm.StreamCallback,
    line_buffer: llm.SseLineBuffer,

    // Accumulator for tool_use input_json_delta fragments
    tool_input_buf: std.ArrayList(u8) = .{},
    current_tool_id: ?[]const u8,
    current_tool_name: ?[]const u8,
};

fn streamChunkHandler(context: *StreamContext, chunk: []const u8) !void {
    try context.line_buffer.feed(chunk, handleSseLine, @ptrCast(context));
}

/// Process a single SSE line from the Anthropic stream.
fn handleSseLine(line: []const u8, ctx: *anyopaque) anyerror!void {
    const context: *StreamContext = @ptrCast(@alignCast(ctx));

    if (line.len == 0) return;

    // Extract data payload
    const data = llm.parseSseDataLine(line) orelse return;

    // Parse JSON
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        context.allocator,
        data,
        .{},
    ) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const event_type = root.get("type") orelse return;
    if (event_type != .string) return;
    const etype = event_type.string;

    if (std.mem.eql(u8, etype, "content_block_delta")) {
        try handleContentBlockDelta(context, root);
    } else if (std.mem.eql(u8, etype, "content_block_start")) {
        try handleContentBlockStart(context, root);
    } else if (std.mem.eql(u8, etype, "content_block_stop")) {
        try handleContentBlockStop(context);
    } else if (std.mem.eql(u8, etype, "error")) {
        if (root.get("error")) |err_obj| {
            if (err_obj.object.get("message")) |msg| {
                if (msg == .string) {
                    try context.callback(.{ .@"error" = msg.string });
                }
            }
        }
    }
    // message_start, message_delta, message_stop, ping → ignored for StreamEvent
}

fn handleContentBlockStart(context: *StreamContext, root: std.json.ObjectMap) !void {
    const block = root.get("content_block") orelse return;
    const block_obj = block.object;
    const block_type = block_obj.get("type") orelse return;
    if (block_type != .string) return;

    if (std.mem.eql(u8, block_type.string, "tool_use")) {
        // Capture tool id and name for accumulating input_json_delta
        context.current_tool_id = if (block_obj.get("id")) |v|
            if (v == .string) v.string else null
        else
            null;
        context.current_tool_name = if (block_obj.get("name")) |v|
            if (v == .string) v.string else null
        else
            null;
        context.tool_input_buf.clearRetainingCapacity();

        // Emit tool_call_delta with id and name so the caller knows a tool call started
        try context.callback(.{ .tool_call_delta = .{
            .id = context.current_tool_id,
            .name = context.current_tool_name,
            .arguments = null,
        } });
    }
}

fn handleContentBlockDelta(context: *StreamContext, root: std.json.ObjectMap) !void {
    const delta = root.get("delta") orelse return;
    const delta_obj = delta.object;
    const delta_type = delta_obj.get("type") orelse return;
    if (delta_type != .string) return;

    if (std.mem.eql(u8, delta_type.string, "text_delta")) {
        if (delta_obj.get("text")) |text| {
            if (text == .string) {
                try context.callback(.{ .text_delta = text.string });
            }
        }
    } else if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
        if (delta_obj.get("partial_json")) |pj| {
            if (pj == .string) {
                // Accumulate partial JSON
                try context.tool_input_buf.appendSlice(context.allocator, pj.string);

                // Also forward each fragment so callers can display incremental progress
                try context.callback(.{ .tool_call_delta = .{
                    .id = context.current_tool_id,
                    .name = null,
                    .arguments = pj.string,
                } });
            }
        }
    }
    // thinking_delta, signature_delta → ignored for now
}

fn handleContentBlockStop(context: *StreamContext) !void {
    // If we were accumulating a tool_use block, emit the complete ToolCall
    if (context.current_tool_id != null and context.tool_input_buf.items.len > 0) {
        try context.callback(.{ .tool_call = .{
            .id = context.current_tool_id orelse "unknown",
            .name = context.current_tool_name orelse "unknown",
            .arguments = context.tool_input_buf.items,
        } });

        // Reset
        context.current_tool_id = null;
        context.current_tool_name = null;
        context.tool_input_buf.clearRetainingCapacity();
    }
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

/// Map Anthropic stop_reason values to our unified finish_reason strings.
fn mapStopReason(reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "end_turn")) return "stop";
    if (std.mem.eql(u8, reason, "max_tokens")) return "length";
    if (std.mem.eql(u8, reason, "tool_use")) return "tool_calls";
    if (std.mem.eql(u8, reason, "stop_sequence")) return "stop";
    return reason; // pass through unknown reasons
}

fn jsonToU32(val: std.json.Value) u32 {
    return switch (val) {
        .integer => |i| @intCast(@as(u32, @truncate(@as(u64, @bitCast(i))))),
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}
