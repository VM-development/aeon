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
            "Execute a shell command and return its output",
            &.{
                .{ .name = "command", .type = "string", .description = "Shell command to execute", .required = true },
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

    const argv = [_][]const u8{ "/bin/sh", "-c", command };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        return ToolResult{
            .success = false,
            .output = std.fmt.allocPrint(allocator, "Failed to spawn command: {}", .{err}) catch return errorResult(),
            .error_msg = allocator.dupe(u8, "Spawn error") catch null,
        };
    };

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
        allocator.free(stdout);
        allocator.free(stderr);
        return ToolResult{
            .success = false,
            .output = std.fmt.allocPrint(allocator, "Failed to wait for command: {}", .{err}) catch return errorResult(),
            .error_msg = allocator.dupe(u8, "Wait error") catch null,
        };
    };

    const success = result.Exited == 0;

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

fn errorResult() ToolResult {
    return ToolResult{
        .success = false,
        .output = "Internal error: allocation failure",
        .error_msg = null,
    };
}
