//! test_server.zig is a tiny HTTP server used only by the unit tests of
//! fetch.zig and bench.zig, so they never touch the real network. It listens
//! on a free localhost port and answers every request with a fixed body. The
//! tests run it as a concurrent task next to the client code being tested.

const std = @import("std");
const Io = std.Io;

/// The body sent in reply to every request.
pub const response_body = "hello from the test server\n";

/// A listening socket plus the logic to answer requests on it.
pub const TestServer = struct {
    listener: Io.net.Server,

    /// Starts listening on 127.0.0.1 with a port chosen by the OS.
    pub fn start(io: Io) !TestServer {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .listener = try address.listen(io, .{}) };
    }

    /// Stops listening.
    pub fn stop(self: *TestServer, io: Io) void {
        self.listener.deinit(io);
    }

    /// Writes "http://127.0.0.1:<port>/" into `buffer` and returns it.
    pub fn url(self: *const TestServer, buffer: []u8) ![]const u8 {
        const port = self.listener.socket.address.getPort();
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/", .{port});
    }

    /// Accepts `connection_count` connections, answers one request on each,
    /// and returns. Meant to be started with `io.concurrent`.
    pub fn serve(self: *TestServer, io: Io, connection_count: usize) !void {
        for (0..connection_count) |_| {
            const stream = try self.listener.accept(io);
            defer stream.close(io);

            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var stream_reader = stream.reader(io, &read_buffer);
            var stream_writer = stream.writer(io, &write_buffer);

            var http_server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);
            var request = try http_server.receiveHead();
            // `keep_alive = false` makes the client open a new connection for
            // each request, which keeps the connection count predictable.
            try request.respond(response_body, .{
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "x-test", .value = "yes" }},
            });
        }
    }
};
