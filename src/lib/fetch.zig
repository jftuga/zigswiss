//! fetch.zig performs a single HTTP or HTTPS request with `std.http.Client`
//! and returns the status, headers and body. It uses the lower-level request
//! API instead of the one-shot `client.fetch` helper because only the
//! lower-level API exposes the response headers.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Settings for `fetch`.
pub const Options = struct {
    method: std.http.Method = .GET,
    /// Request body. When set, it is sent with a Content-Length header.
    body: ?[]const u8 = null,
};

/// The parts of an HTTP response that the caller is interested in. All memory
/// is owned by this struct; release it with `deinit`.
pub const Response = struct {
    status: std.http.Status,
    /// Response headers, one "Name: value\n" line per header.
    headers: []u8,
    body: []u8,

    pub fn deinit(self: *Response, gpa: Allocator) void {
        gpa.free(self.headers);
        gpa.free(self.body);
    }
};

/// Sends one request to `url` and reads the whole response into memory.
/// Redirects are followed for requests without a body.
pub fn fetch(io: Io, gpa: Allocator, url: []const u8, options: Options) !Response {
    // Struct literals may skip any field that has a default value. The client
    // has many; `allocator` and `io` are the two without defaults.
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var request = try client.request(options.method, uri, .{});
    defer request.deinit();

    if (options.body) |body| {
        // `sendBodyComplete` wants a mutable slice, so send a copy.
        const body_copy = try gpa.dupe(u8, body);
        defer gpa.free(body_copy);
        request.transfer_encoding = .{ .content_length = body_copy.len };
        try request.sendBodyComplete(body_copy);
    } else {
        try request.sendBodiless();
    }

    // The buffer is scratch space for following redirects.
    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    // Copy the headers BEFORE asking for the body reader. The header strings
    // point into the connection's read buffer, and reading the body reuses it.
    const status = response.head.status;
    const headers = try copyHeaders(gpa, response.head);
    errdefer gpa.free(headers);

    // `readerDecompressing` transparently undoes gzip/deflate/zstd content
    // encoding. It needs a window buffer large enough for any of them.
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buffer = try gpa.alloc(u8, std.compress.zstd.default_window_len);
    defer gpa.free(decompress_buffer);
    const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const body = try body_reader.allocRemaining(gpa, .unlimited);

    return .{ .status = status, .headers = headers, .body = body };
}

fn copyHeaders(gpa: Allocator, head: std.http.Client.Response.Head) ![]u8 {
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        try output.writer.print("{s}: {s}\n", .{ header.name, header.value });
    }
    return output.toOwnedSlice();
}

test "fetch returns status, headers and body" {
    const TestServer = @import("test_server.zig").TestServer;
    const expected_body = @import("test_server.zig").response_body;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.stop(io);
    var url_buffer: [64]u8 = undefined;
    const url = try server.url(&url_buffer);

    // `io.concurrent` starts the function as a task that runs at the same
    // time as the code below. It returns a future; `await` waits for the task
    // and gives back its return value.
    var server_task = try io.concurrent(TestServer.serve, .{ &server, io, 1 });
    // If `fetch` fails below, this stops the server task instead of leaving
    // it blocked in `accept` forever. After a successful `await` it is a no-op.
    defer server_task.cancel(io) catch {};

    var response = try fetch(io, gpa, url, .{});
    defer response.deinit(gpa);
    try server_task.await(io);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings(expected_body, response.body);
    try std.testing.expect(std.mem.indexOf(u8, response.headers, "x-test: yes\n") != null);
}

test "fetch rejects a malformed url" {
    try std.testing.expectError(error.InvalidFormat, fetch(std.testing.io, std.testing.allocator, "not a url", .{}));
}
