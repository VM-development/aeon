const std = @import("std");
const http = @import("../utils/http.zig");
const llm = @import("llm_client.zig");

const DEFAULT_BASE_URL = "https://api.openai.com/v1";
const COMPLETIONS_ENDPOINT = "/chat/completions";

// OpenAI API request structures
const OpenAIMessage = struct {
    role: []const u8,
    content: ?[]const u8, // nullable for assistant messages with only tool_calls
    tool_calls: ?[]const OpenAIToolCall = null, // For assistant messages
    tool_call_id: ?[]const u8 = null, // For tool response messages
};

const OpenAIToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

const OpenAIToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: struct {
        type: []const u8 = "object",
        properties: std.json.Value,
        required: []const []const u8 = &.{},
    },
};

const OpenAITool = struct {
    type: []const u8 = "function",
    function: OpenAIToolFunction,
};

const OpenAIRequest = struct {
    model: []const u8,
    messages: []const OpenAIMessage,
    max_tokens: u32,
    temperature: f32,
    stream: bool,
    tools: ?[]const OpenAITool = null,
};

pub const OpenAIError = error{
    ApiError,
    InvalidResponse,
    StreamError,
    JsonError,
};

pub const OpenAIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    http_client: http.HttpClient,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !*OpenAIClient {
        const client = try allocator.create(OpenAIClient);
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

    /// Create LlmClient interface from OpenAIClient
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

    /// Stream completion from OpenAI
    pub fn streamCompletion(
        self: *Self,
        request: llm.CompletionRequest,
        callback: llm.StreamCallback,
    ) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ self.base_url, COMPLETIONS_ENDPOINT },
        );
        defer self.allocator.free(url);

        // Build request body
        const body = try self.buildRequestBody(request, true);
        defer self.allocator.free(body);

        // Prepare headers
        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.api_key},
        );
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        // Create streaming context
        var context = StreamContext{
            .allocator = self.allocator,
            .callback = callback,
            .line_buffer = llm.SseLineBuffer.init(self.allocator),
        };
        defer context.line_buffer.deinit();

        const status = try self.http_client.streamRequest(
            .POST,
            url,
            &headers,
            body,
            &context,
            streamChunkHandler,
        );

        if (status != .ok) {
            return OpenAIError.ApiError;
        }

        // Send done event
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
            .{ self.base_url, COMPLETIONS_ENDPOINT },
        );
        defer self.allocator.free(url);

        // Build request body
        const body = try self.buildRequestBody(request, false);
        defer self.allocator.free(body);

        // Prepare headers
        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.api_key},
        );
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var response = try self.http_client.post(url, &headers, body);
        defer response.deinit();

        if (response.status != .ok) {
            return OpenAIError.ApiError;
        }

        return try self.parseCompletionResponse(response.body);
    }

    /// Build OpenAI-specific request body JSON
    fn buildRequestBody(
        self: *Self,
        request: llm.CompletionRequest,
        stream: bool,
    ) ![]u8 {
        // Convert messages to OpenAI format
        var messages: std.ArrayList(OpenAIMessage) = .{};
        defer messages.deinit(self.allocator);

        // For tool_calls, we need to convert them to OpenAI format
        var tool_calls_storage: std.ArrayList([]const OpenAIToolCall) = .{};
        defer {
            for (tool_calls_storage.items) |tc_slice| {
                self.allocator.free(tc_slice);
            }
            tool_calls_storage.deinit(self.allocator);
        }

        for (request.messages) |msg| {
            var openai_msg = OpenAIMessage{
                .role = msg.role.toString(),
                .content = if (msg.content.len > 0) msg.content else null,
                .tool_call_id = msg.tool_call_id,
            };

            // Convert tool_calls for assistant messages
            if (msg.tool_calls) |tcs| {
                var tc_list: std.ArrayList(OpenAIToolCall) = .{};
                for (tcs) |tc| {
                    try tc_list.append(self.allocator, .{
                        .id = tc.id,
                        .function = .{
                            .name = tc.name,
                            .arguments = tc.arguments,
                        },
                    });
                }
                const tc_slice = try tc_list.toOwnedSlice(self.allocator);
                try tool_calls_storage.append(self.allocator, tc_slice);
                openai_msg.tool_calls = tc_slice;
            }

            try messages.append(self.allocator, openai_msg);
        }

        // Convert tools to OpenAI format if present
        var openai_tools: ?[]const OpenAITool = null;
        var tools_list: std.ArrayList(OpenAITool) = .{};
        defer tools_list.deinit(self.allocator);

        // Storage for required field arrays to keep them alive during serialization
        var required_storage: std.ArrayList([]const []const u8) = .{};
        defer {
            for (required_storage.items) |req| {
                self.allocator.free(req);
            }
            required_storage.deinit(self.allocator);
        }

        if (request.tools) |tools| {
            for (tools) |tool| {
                // Build properties JSON object and collect required fields
                // NOTE: Do NOT defer deinit here — the ObjectMap data is referenced
                // by tools_list entries and must survive until after serialization.
                var props_map = std.json.ObjectMap.init(self.allocator);
                var required_list: std.ArrayList([]const u8) = .{};

                var iter = tool.parameters.iterator();
                while (iter.next()) |entry| {
                    var prop_obj = std.json.ObjectMap.init(self.allocator);
                    // Do NOT defer — data is moved into props_map

                    try prop_obj.put("type", .{ .string = entry.value_ptr.type });
                    if (entry.value_ptr.description) |desc| {
                        try prop_obj.put("description", .{ .string = desc });
                    }

                    try props_map.put(entry.key_ptr.*, .{ .object = prop_obj });

                    // Track required fields
                    if (entry.value_ptr.required) {
                        try required_list.append(self.allocator, entry.key_ptr.*);
                    }
                }

                const required_slice = try required_list.toOwnedSlice(self.allocator);
                try required_storage.append(self.allocator, required_slice);

                try tools_list.append(self.allocator, .{
                    .function = .{
                        .name = tool.name,
                        .description = tool.description,
                        .parameters = .{
                            .properties = .{ .object = props_map },
                            .required = required_slice,
                        },
                    },
                });
            }
            openai_tools = try tools_list.toOwnedSlice(self.allocator);
        }
        defer {
            // Clean up tool JSON objects after serialization
            if (openai_tools) |ot| {
                for (ot) |*t| {
                    var props = t.function.parameters.properties.object;
                    var pit = props.iterator();
                    while (pit.next()) |entry| {
                        var obj = entry.value_ptr.object;
                        obj.deinit();
                    }
                    props.deinit();
                }
                self.allocator.free(ot);
            }
        }

        const openai_request = OpenAIRequest{
            .model = request.model,
            .messages = try messages.toOwnedSlice(self.allocator),
            .max_tokens = request.max_tokens,
            .temperature = request.temperature,
            .stream = stream,
            .tools = openai_tools,
        };
        defer self.allocator.free(openai_request.messages);

        // Serialize to JSON
        var body: std.ArrayList(u8) = .{};
        defer body.deinit(self.allocator);

        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(openai_request, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    fn parseCompletionResponse(self: *Self, body: []const u8) !llm.CompletionResponse {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            body,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;
        const choices = root.get("choices").?.array;
        const choice = choices.items[0].object;
        const message = choice.get("message").?.object;

        const content = if (message.get("content")) |c|
            if (c == .string)
                try self.allocator.dupe(u8, c.string)
            else
                null
        else
            null;

        const finish_reason = choice.get("finish_reason").?.string;

        // Parse tool_calls if present
        var tool_calls: ?[]const llm.ToolCall = null;
        if (message.get("tool_calls")) |tc_value| {
            if (tc_value == .array) {
                var tc_list: std.ArrayList(llm.ToolCall) = .{};
                for (tc_value.array.items) |tc_item| {
                    if (tc_item != .object) continue;
                    const tc_obj = tc_item.object;

                    const id = if (tc_obj.get("id")) |id_val|
                        if (id_val == .string) id_val.string else continue
                    else
                        continue;

                    const func = tc_obj.get("function") orelse continue;
                    if (func != .object) continue;

                    const name = if (func.object.get("name")) |n|
                        if (n == .string) n.string else continue
                    else
                        continue;

                    const arguments = if (func.object.get("arguments")) |a|
                        if (a == .string) a.string else "{}"
                    else
                        "{}";

                    try tc_list.append(self.allocator, .{
                        .id = try self.allocator.dupe(u8, id),
                        .name = try self.allocator.dupe(u8, name),
                        .arguments = try self.allocator.dupe(u8, arguments),
                    });
                }
                if (tc_list.items.len > 0) {
                    tool_calls = try tc_list.toOwnedSlice(self.allocator);
                } else {
                    tc_list.deinit(self.allocator);
                }
            }
        }

        return llm.CompletionResponse{
            .content = content,
            .tool_calls = tool_calls,
            .finish_reason = try self.allocator.dupe(u8, finish_reason),
        };
    }
};

// ─────────────────────────────────────────────────────────────
// OpenAI SSE stream handling
// ─────────────────────────────────────────────────────────────

const StreamContext = struct {
    allocator: std.mem.Allocator,
    callback: llm.StreamCallback,
    line_buffer: llm.SseLineBuffer,
};

fn streamChunkHandler(context: *StreamContext, chunk: []const u8) !void {
    try context.line_buffer.feed(chunk, handleSseLine, @ptrCast(context));
}

/// Process a single SSE line in the OpenAI format:
///   data: {"choices":[{"delta":{"content":"Hello"}}]}
///   data: [DONE]
fn handleSseLine(line: []const u8, ctx: *anyopaque) anyerror!void {
    const context: *StreamContext = @ptrCast(@alignCast(ctx));

    // Skip empty lines
    if (line.len == 0) return;

    // Extract data payload
    const data = llm.parseSseDataLine(line) orelse return;

    // Check for [DONE]
    if (std.mem.eql(u8, data, "[DONE]")) return;

    // Parse JSON
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        context.allocator,
        data,
        .{},
    ) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const choices = root.get("choices") orelse return;
    if (choices.array.items.len == 0) return;

    const choice = choices.array.items[0].object;
    const delta = choice.get("delta") orelse return;

    if (delta.object.get("content")) |content| {
        if (content == .string) {
            try context.callback(.{ .text_delta = content.string });
        }
    }

    // Handle tool_calls in delta - OpenAI sends index to identify which tool call
    if (delta.object.get("tool_calls")) |tool_calls_value| {
        if (tool_calls_value == .array) {
            for (tool_calls_value.array.items) |tool_call_item| {
                if (tool_call_item != .object) continue;

                const tc_obj = tool_call_item.object;

                // Extract index to identify which tool call this delta belongs to
                const index: ?usize = if (tc_obj.get("index")) |idx_val|
                    if (idx_val == .integer) @as(usize, @intCast(idx_val.integer)) else null
                else
                    null;

                // Extract id (only in first chunk)
                const id: ?[]const u8 = if (tc_obj.get("id")) |id_val|
                    if (id_val == .string) id_val.string else null
                else
                    null;

                // Extract function name and arguments
                var name: ?[]const u8 = null;
                var arguments: ?[]const u8 = null;

                if (tc_obj.get("function")) |func_val| {
                    if (func_val == .object) {
                        if (func_val.object.get("name")) |n|
                            if (n == .string) {
                                name = n.string;
                            };
                        if (func_val.object.get("arguments")) |a|
                            if (a == .string) {
                                arguments = a.string;
                            };
                    }
                }

                // Emit tool_call_delta event with index
                try context.callback(.{
                    .tool_call_delta = .{
                        .index = index,
                        .id = id,
                        .name = name,
                        .arguments = arguments,
                    },
                });
            }
        }
    }
}
