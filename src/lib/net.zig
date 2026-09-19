//! net.zig checks whether TCP ports accept connections, using the networking
//! API that moved under `std.Io.net` in Zig 0.16. There is no timeout option:
//! in 0.16.0 the standard library panics with "TODO implement ... with timeout"
//! when a connect timeout is set, so a filtered port waits for the OS default.

const std = @import("std");
const Io = std.Io;

/// Tries each port in turn and writes one line per port. Returns
/// `error.PortNotOpen` when at least one port refused the connection, so that
/// shell scripts can rely on the exit code.
pub fn run(io: Io, out: *Io.Writer, host: []const u8, ports: []const u16) !void {
    if (ports.len == 0) return error.MissingPort;

    var all_open = true;
    for (ports) |port| {
        // Calling a function that returns an error union inside `if` lets you
        // handle both outcomes: `|elapsed|` on success, `|err|` on failure.
        if (check(io, host, port)) |elapsed| {
            try out.print("{s}:{d} open ({d}ms)\n", .{ host, port, elapsed.toMilliseconds() });
        } else |err| {
            all_open = false;
            // `@errorName` gives the name of an error value as a string.
            try out.print("{s}:{d} closed ({s})\n", .{ host, port, @errorName(err) });
        }
        // Flush per port so results appear as they happen, not all at the end.
        try out.flush();
    }
    if (!all_open) return error.PortNotOpen;
}

/// Opens and immediately closes a TCP connection. Returns how long the
/// connection took. `host` may be a DNS name or an IP address.
pub fn check(io: Io, host: []const u8, port: u16) !Io.Duration {
    const host_name = try Io.net.HostName.init(host);

    // `.awake` is the monotonic clock: it never jumps backwards, so it is
    // the right choice for measuring how long something took.
    const start = Io.Timestamp.now(io, .awake);
    const stream = try host_name.connect(io, port, .{ .mode = .stream });
    const elapsed = start.untilNow(io, .awake);
    stream.close(io);
    return elapsed;
}

test "check reports an open port and then a closed one" {
    const io = std.testing.io;

    // Port 0 asks the OS for any free port. The port actually chosen is
    // available afterwards from the socket's address.
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    const port = server.socket.address.getPort();

    _ = try check(io, "127.0.0.1", port);

    server.deinit(io);
    try std.testing.expectError(error.ConnectionRefused, check(io, "127.0.0.1", port));
}

test "run fails when a port is closed" {
    const io = std.testing.io;
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    const port = server.socket.address.getPort();
    server.deinit(io);

    try std.testing.expectError(error.PortNotOpen, run(io, &writer, "127.0.0.1", &.{port}));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "closed (ConnectionRefused)") != null);
    try std.testing.expectError(error.MissingPort, run(io, &writer, "127.0.0.1", &.{}));
}
