const std = @import("std");
const llm = @import("llm_client.zig");

// ─────────────────────────────────────────────────────────────
// Tool execution types
// ─────────────────────────────────────────────────────────────

/// Result of executing a tool
pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_msg: ?[]const u8 = null,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.error_msg) |msg| {
            allocator.free(msg);
        }
    }
};

/// Context passed to tool execution functions
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    working_dir: ?[]const u8 = null,
};

/// Function signature for tool execution
pub const ToolExecuteFn = *const fn (allocator: std.mem.Allocator, arguments: std.json.Value, ctx: ToolContext) ToolResult;

/// A registered tool with its definition and executor
pub const RegisteredTool = struct {
    definition: llm.Tool,
    execute: ToolExecuteFn,
};

// ─────────────────────────────────────────────────────────────
// Tool Registry
// ─────────────────────────────────────────────────────────────

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(RegisteredTool),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(RegisteredTool).init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        // Free duplicated tool definition parameters
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            var def = entry.value_ptr.definition;
            def.parameters.deinit();
        }
        self.tools.deinit();
    }

    /// Register a new tool
    pub fn register(self: *ToolRegistry, name: []const u8, description: []const u8, params: []const ParamDef, execute: ToolExecuteFn) !void {
        var parameters = std.StringHashMap(llm.ToolParameter).init(self.allocator);
        for (params) |p| {
            try parameters.put(p.name, .{
                .type = p.type,
                .description = p.description,
                .required = p.required,
            });
        }

        try self.tools.put(name, .{
            .definition = .{
                .name = name,
                .description = description,
                .parameters = parameters,
            },
            .execute = execute,
        });
    }

    /// Get a registered tool by name
    pub fn get(self: *ToolRegistry, name: []const u8) ?RegisteredTool {
        return self.tools.get(name);
    }

    /// Get all tool definitions for LLM requests
    pub fn getToolDefinitions(self: *ToolRegistry) ![]llm.Tool {
        var defs: std.ArrayList(llm.Tool) = .{};
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            try defs.append(self.allocator, entry.value_ptr.definition);
        }
        return try defs.toOwnedSlice(self.allocator);
    }

    /// Execute a tool by name with JSON arguments
    pub fn executeTool(self: *ToolRegistry, name: []const u8, arguments_json: []const u8, ctx: ToolContext) !ToolResult {
        const tool = self.tools.get(name) orelse {
            return ToolResult{
                .success = false,
                .output = try std.fmt.allocPrint(self.allocator, "Unknown tool: {s}", .{name}),
                .error_msg = try self.allocator.dupe(u8, "Tool not found"),
            };
        };

        // Parse arguments JSON
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            arguments_json,
            .{},
        ) catch {
            return ToolResult{
                .success = false,
                .output = try self.allocator.dupe(u8, "Failed to parse tool arguments"),
                .error_msg = try self.allocator.dupe(u8, "Invalid JSON"),
            };
        };
        defer parsed.deinit();

        return tool.execute(self.allocator, parsed.value, ctx);
    }

    /// Register all built-in tools
    pub fn registerBuiltins(self: *ToolRegistry) !void {
        try self.register(
            "file_read",
            "Read the contents of a file at the given path",
            &.{
                .{ .name = "path", .type = "string", .description = "Path to the file to read", .required = true },
            },
            fileReadExecute,
        );

        try self.register(
            "file_write",
            "Write content to a file at the given path. Creates the file if it doesn't exist, overwrites if it does.",
            &.{
                .{ .name = "path", .type = "string", .description = "Path to the file to write", .required = true },
                .{ .name = "content", .type = "string", .description = "Content to write to the file", .required = true },
            },
            fileWriteExecute,
        );

        try self.register(
            "exec",
            "Execute a shell command and return its output. For commands that require password/input, provide it via the stdin parameter. Commands that require interaction will fail if no stdin is provided.",
            &.{
                .{ .name = "command", .type = "string", .description = "Shell command to execute", .required = true },
                .{ .name = "stdin", .type = "string", .description = "Optional input to provide to the command's stdin (e.g., password for sudo -S)", .required = false },
                .{ .name = "timeout_ms", .type = "integer", .description = "Optional timeout in milliseconds. Default is 60000 (60 seconds). Use 0 for no timeout.", .required = false },
            },
            execExecute,
        );
    }
};

/// Helper for defining tool parameters inline
pub const ParamDef = struct {
    name: []const u8,
    type: []const u8,
    description: ?[]const u8 = null,
    required: bool = false,
};

// ─────────────────────────────────────────────────────────────
// Built-in tool implementations
// ─────────────────────────────────────────────────────────────

fn fileReadExecute(allocator: std.mem.Allocator, arguments: std.json.Value, ctx: ToolContext) ToolResult {
    _ = ctx;
    const path = getStringArg(arguments, "path") orelse {
        return ToolResult{
            .success = false,
            .output = allocator.dupe(u8, "Missing required parameter: path") catch return errorResult(),
            .error_msg = allocator.dupe(u8, "Missing parameter") catch null,
        };
    };

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return ToolResult{
            .success = false,
            .output = std.fmt.allocPrint(allocator, "Failed to open file '{s}': {}", .{ path, err }) catch return errorResult(),
            .error_msg = allocator.dupe(u8, "File open error") catch null,
        };
    };
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(&read_buf);
    const content = reader.interface.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        return ToolResult{
            .success = false,
            .output = std.fmt.allocPrint(allocator, "Failed to read file '{s}': {}", .{ path, err }) catch return errorResult(),
            .error_msg = allocator.dupe(u8, "File read error") catch null,
        };
    };

    return ToolResult{
        .success = true,
        .output = content,
    };
}

fn fileWriteExecute(allocator: std.mem.Allocator, arguments: std.json.Value, ctx: ToolContext) ToolResult {
    _ = ctx;
    const path = getStringArg(arguments, "path") orelse {
        return ToolResult{
            .success = false,
            .output = allocator.dupe(u8, "Missing required parameter: path") catch return errorResult(),
            .error_msg = allocator.dupe(u8, "Missing parameter") catch null,
        };
    };

    const content = getStringArg(arguments, "content") orelse {
        return ToolResult{
            .success = false,
            .output = allocator.dupe(u8, "Missing required parameter: content") catch return errorResult(),
            .error_msg = allocator.dupe(u8, "Missing parameter") catch null,
        };
    };

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        return ToolResult{
            .success = false,
            .output = std.fmt.allocPrint(allocator, "Failed to create file '{s}': {}", .{ path, err }) catch return errorResult(),
            .error_msg = allocator.dupe(u8, "File create error") catch null,
        };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return ToolResult{
            .success = false,
            .output = std.fmt.allocPrint(allocator, "Failed to write to file '{s}': {}", .{ path, err }) catch return errorResult(),
            .error_msg = allocator.dupe(u8, "File write error") catch null,
        };
    };

    return ToolResult{
        .success = true,
        .output = std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to '{s}'", .{ content.len, path }) catch return errorResult(),
    };
}

fn execExecute(allocator: std.mem.Allocator, arguments: std.json.Value, ctx: ToolContext) ToolResult {
    _ = ctx;
    const command = getStringArg(arguments, "command") orelse {
        return ToolResult{
            .success = false,
            .output = allocator.dupe(u8, "Missing required parameter: command") catch return errorResult(),
            .error_msg = allocator.dupe(u8, "Missing parameter") catch null,
        };
    };

    // Get optional stdin input
    const stdin_input = getStringArg(arguments, "stdin");

    // Get optional timeout (default 60 seconds)
    const timeout_ms = getIntArg(arguments, "timeout_ms") orelse 60000;

    const argv = [_][]const u8{ "/bin/sh", "-c", command };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // Use Pipe for stdin so we can control it - if no input provided, closing immediately
    // causes interactive commands to get EOF and fail fast instead of hanging
    child.stdin_behavior = .Pipe;

    child.spawn() catch |err| {
        return ToolResult{
            .success = false,
            .output = std.fmt.allocPrint(allocator, "Failed to spawn command: {}", .{err}) catch return errorResult(),
            .error_msg = allocator.dupe(u8, "Spawn error") catch null,
        };
    };

    // Write stdin input if provided, then close stdin
    if (child.stdin) |stdin| {
        if (stdin_input) |input| {
            stdin.writeAll(input) catch {};
            // Add newline if not present (for password prompts)
            if (input.len == 0 or input[input.len - 1] != '\n') {
                stdin.writeAll("\n") catch {};
            }
        }
        stdin.close();
        child.stdin = null;
    }

    // For timeout, we'll use a simple approach: spawn a thread that kills the process
    var killed_by_timeout = false;
    var timeout_thread: ?std.Thread = null;

    if (timeout_ms > 0) {
        const TimeoutContext = struct {
            child_id: std.process.Child.Id,
            timeout_ns: u64,
            killed: *bool,
        };

        const timeout_ctx = allocator.create(TimeoutContext) catch null;
        if (timeout_ctx) |tc| {
            tc.* = .{
                .child_id = child.id,
                .timeout_ns = @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms,
                .killed = &killed_by_timeout,
            };

            timeout_thread = std.Thread.spawn(.{}, struct {
                fn run(context: *TimeoutContext) void {
                    std.Thread.sleep(context.timeout_ns);
                    // Try to kill the process if still running
                    std.posix.kill(context.child_id, std.posix.SIG.KILL) catch {};
                    context.killed.* = true;
                }
            }.run, .{tc}) catch null;
        }
    }

    // Read stdout
    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(&stdout_buf);
    const stdout = stdout_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch {
        return ToolResult{
            .success = false,
            .output = allocator.dupe(u8, "Failed to read stdout") catch return errorResult(),
            .error_msg = null,
        };
    };

    // Read stderr
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(&stderr_buf);
    const stderr = stderr_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch {
        allocator.free(stdout);
        return ToolResult{
            .success = false,
            .output = allocator.dupe(u8, "Failed to read stderr") catch return errorResult(),
            .error_msg = null,
        };
    };

    const result = child.wait() catch |err| {
        // Cancel timeout thread if it exists
        if (timeout_thread) |t| {
            t.detach();
        }
        allocator.free(stdout);
        allocator.free(stderr);
        return ToolResult{
            .success = false,
            .output = std.fmt.allocPrint(allocator, "Failed to wait for command: {}", .{err}) catch return errorResult(),
            .error_msg = allocator.dupe(u8, "Wait error") catch null,
        };
    };

    // Detach timeout thread since process completed
    if (timeout_thread) |t| {
        t.detach();
    }

    // Check if killed by timeout
    if (killed_by_timeout) {
        allocator.free(stdout);
        allocator.free(stderr);
        return ToolResult{
            .success = false,
            .output = std.fmt.allocPrint(allocator, "Command timed out after {d}ms. If the command requires interactive input (password, confirmation), provide it via the 'stdin' parameter.", .{timeout_ms}) catch return errorResult(),
            .error_msg = allocator.dupe(u8, "Timeout") catch null,
        };
    }

    // Safely check exit status - handle all termination types
    const success = switch (result) {
        .Exited => |code| code == 0,
        .Signal, .Stopped, .Unknown => false,
    };

    // Combine stdout + stderr
    if (stderr.len > 0 and stdout.len > 0) {
        const combined = std.fmt.allocPrint(allocator, "{s}\n--- stderr ---\n{s}", .{ stdout, stderr }) catch {
            allocator.free(stderr);
            return ToolResult{ .success = success, .output = stdout };
        };
        allocator.free(stdout);
        allocator.free(stderr);
        return ToolResult{ .success = success, .output = combined };
    } else if (stderr.len > 0) {
        allocator.free(stdout);
        return ToolResult{
            .success = success,
            .output = stderr,
            .error_msg = if (!success) allocator.dupe(u8, "Command failed") catch null else null,
        };
    } else {
        allocator.free(stderr);
        return ToolResult{ .success = success, .output = stdout };
    }
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

fn getStringArg(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const val = args.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn getIntArg(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const val = args.object.get(key) orelse return null;
    if (val != .integer) return null;
    return val.integer;
}

fn errorResult() ToolResult {
    return ToolResult{
        .success = false,
        .output = "Internal error: allocation failure",
        .error_msg = null,
    };
}
