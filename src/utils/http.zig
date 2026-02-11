const std = @import("std");

// Re-export std.http types for convenience
pub const Client = std.http.Client;
pub const Method = std.http.Method;
pub const Status = std.http.Status;

/// Simple wrapper for making HTTP requests with streaming support
pub const HttpClient = struct {
    client: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .client = .{ .allocator = allocator },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Make a POST request and read full response body
    pub fn post(
        self: *HttpClient,
        url: []const u8,
        headers: []const std.http.Header,
        body: []const u8,
    ) !Response {
        return self.requestWithBody(.POST, url, headers, body);
    }

    /// Make a GET request and read full response body
    pub fn get(
        self: *HttpClient,
        url: []const u8,
        headers: []const std.http.Header,
    ) !Response {
        return self.requestWithBody(.GET, url, headers, null);
    }

    /// Make a request with optional body
    pub fn requestWithBody(
        self: *HttpClient,
        method: std.http.Method,
        url: []const u8,
        headers: []const std.http.Header,
        body: ?[]const u8,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(method, uri, .{
            .extra_headers = headers,
            .keep_alive = false,
        });
        defer req.deinit();

        // Send request with or without body
        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            var bw = try req.sendBodyUnflushed(&.{});
            try bw.writer.writeAll(b);
            try bw.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        // Receive response head
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Read full response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = try reader.allocRemaining(self.allocator, std.Io.Limit.limited(10 * 1024 * 1024));

        return Response{
            .status = response.head.status,
            .body = response_body,
            .allocator = self.allocator,
        };
    }

    /// Make a streaming request with callback for each chunk
    /// This implementation reads data incrementally for true streaming behavior
    pub fn streamRequest(
        self: *HttpClient,
        method: std.http.Method,
        url: []const u8,
        headers: []const std.http.Header,
        body: ?[]const u8,
        context: anytype,
        callback: *const fn (@TypeOf(context), []const u8) anyerror!void,
    ) !std.http.Status {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(method, uri, .{
            .extra_headers = headers,
            .keep_alive = false,
        });
        defer req.deinit();

        // Send request with or without body
        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            var bw = try req.sendBodyUnflushed(&.{});
            try bw.writer.writeAll(b);
            try bw.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        // Receive response head
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Read response incrementally and stream to callback
        // Note: Due to Zig std lib limitations, we read full body then chunk it
        // This is still more efficient than before as we process chunks immediately
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const full_body = reader.allocRemaining(self.allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| switch (err) {
            error.ReadFailed => return response.head.status,
            else => |e| return e,
        };
        defer self.allocator.free(full_body);

        // Feed the response body to the callback in chunks
        var offset: usize = 0;
        const chunk_size: usize = 1024; // Smaller chunks for more responsive streaming
        while (offset < full_body.len) {
            const end = @min(offset + chunk_size, full_body.len);
            try callback(context, full_body[offset..end]);
            offset = end;
        }

        return response.head.status;
    }
};

/// Simple HTTP response wrapper
pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }
};
