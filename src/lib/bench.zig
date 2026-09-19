//! bench.zig load-tests an HTTP endpoint: it sends a number of GET requests
//! from several concurrent tasks and reports latency percentiles. It is the
//! concurrency example of this project, showing `Io.Group` (like Go's
//! sync.WaitGroup plus goroutines), `Io.Mutex` and atomic counters.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Settings for `run`.
pub const Options = struct {
    url: []const u8,
    /// Total number of requests, split across the workers.
    requests: usize = 100,
    /// Number of workers sending requests at the same time.
    concurrency: usize = 10,
};

/// Latency summary in nanoseconds.
pub const Stats = struct {
    min: u64,
    max: u64,
    mean: u64,
    p50: u64,
    p90: u64,
    p99: u64,
};

/// State shared by all workers. Every field that more than one task touches
/// is either atomic or protected by the mutex.
const Shared = struct {
    client: *std.http.Client,
    url: []const u8,
    /// Atomics are for single values that can be updated in one CPU step.
    succeeded: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(usize) = .init(0),
    /// An ArrayList is several fields (pointer, length, capacity) that must
    /// change together, so it needs a lock rather than an atomic.
    mutex: Io.Mutex = .init,
    latencies: std.ArrayList(u64) = .empty,
};

/// Runs the benchmark and writes a report to `out`.
pub fn run(io: Io, gpa: Allocator, out: *Io.Writer, options: Options) !void {
    if (options.requests == 0) return error.InvalidRequestCount;
    if (options.concurrency == 0) return error.InvalidConcurrency;
    // Fail early on a bad URL instead of reporting N failed requests.
    _ = try std.Uri.parse(options.url);

    // One client is shared by all workers. It is safe to use from several
    // tasks at once and pools connections between them.
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var shared: Shared = .{ .client = &client, .url = options.url };
    defer shared.latencies.deinit(gpa);
    // Reserve room for every result now, so workers can record a latency with
    // `appendAssumeCapacity`, which cannot fail and never allocates.
    try shared.latencies.ensureTotalCapacity(gpa, options.requests);

    const worker_count = @min(options.concurrency, options.requests);
    const start = Io.Timestamp.now(io, .awake);

    var group: Io.Group = .init;
    // If starting a worker fails, cancel the ones already running.
    errdefer group.cancel(io);
    for (0..worker_count) |index| {
        // Split the requests evenly; the first workers take the remainder.
        const extra: usize = if (index < options.requests % worker_count) 1 else 0;
        const request_count = options.requests / worker_count + extra;
        // `concurrent` guarantees the worker runs at the same time as the
        // others. The arguments are passed as a tuple: `.{ a, b, c }`.
        try group.concurrent(io, worker, .{ io, &shared, request_count });
    }
    // Blocks until every worker in the group has returned.
    try group.await(io);

    const elapsed = start.untilNow(io, .awake);
    try writeReport(out, options, worker_count, elapsed, &shared);
}

/// The body of one worker task. A function started in a group must return
/// `Io.Cancelable!void`, meaning its only allowed error is `error.Canceled`.
fn worker(io: Io, shared: *Shared, request_count: usize) Io.Cancelable!void {
    for (0..request_count) |_| {
        const start = Io.Timestamp.now(io, .awake);
        const result = shared.client.fetch(.{ .location = .{ .url = shared.url } });
        const elapsed = start.untilNow(io, .awake);

        if (result) |response| {
            // `fetchAdd` is an atomic "+= 1" that is safe across tasks.
            if (response.status.class() == .success) {
                _ = shared.succeeded.fetchAdd(1, .monotonic);
            } else {
                _ = shared.failed.fetchAdd(1, .monotonic);
            }
        } else |err| {
            // Cancellation must be passed on, never swallowed.
            if (err == error.Canceled) return error.Canceled;
            _ = shared.failed.fetchAdd(1, .monotonic);
            continue;
        }

        try shared.mutex.lock(io);
        defer shared.mutex.unlock(io);
        shared.latencies.appendAssumeCapacity(@intCast(elapsed.toNanoseconds()));
    }
}

/// Computes the summary. Sorts `latencies` in place. Returns null when there
/// is nothing to summarize.
pub fn summarize(latencies: []u64) ?Stats {
    if (latencies.len == 0) return null;
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));

    var total: u64 = 0;
    for (latencies) |latency| total += latency;

    return .{
        .min = latencies[0],
        .max = latencies[latencies.len - 1],
        .mean = total / latencies.len,
        .p50 = percentile(latencies, 50),
        .p90 = percentile(latencies, 90),
        .p99 = percentile(latencies, 99),
    };
}

/// Nearest-rank percentile of an ascending, non-empty slice.
fn percentile(sorted: []const u64, percent: usize) u64 {
    // `divCeil` only fails for division by zero, which cannot happen here.
    const rank = std.math.divCeil(usize, percent * sorted.len, 100) catch unreachable;
    return sorted[@max(rank, 1) - 1];
}

fn writeReport(out: *Io.Writer, options: Options, worker_count: usize, elapsed: Io.Duration, shared: *Shared) !void {
    const succeeded = shared.succeeded.load(.monotonic);
    const failed = shared.failed.load(.monotonic);
    // Zig has no implicit int-to-float conversion. `@floatFromInt` converts,
    // taking the destination type from the declared type of the variable.
    const elapsed_ns: f64 = @floatFromInt(elapsed.toNanoseconds());
    const completed: f64 = @floatFromInt(succeeded + failed);
    const elapsed_seconds = elapsed_ns / std.time.ns_per_s;

    try out.print("url:          {s}\n", .{options.url});
    try out.print("requests:     {d} (2xx: {d}, other or failed: {d})\n", .{ options.requests, succeeded, failed });
    try out.print("concurrency:  {d}\n", .{worker_count});
    try out.print("total time:   {d:.3}s\n", .{elapsed_seconds});
    try out.print("requests/sec: {d:.1}\n", .{completed / elapsed_seconds});

    const stats = summarize(shared.latencies.items) orelse return;
    try out.writeAll("latency:\n");
    try writeLatency(out, "min", stats.min);
    try writeLatency(out, "mean", stats.mean);
    try writeLatency(out, "p50", stats.p50);
    try writeLatency(out, "p90", stats.p90);
    try writeLatency(out, "p99", stats.p99);
    try writeLatency(out, "max", stats.max);
}

fn writeLatency(out: *Io.Writer, label: []const u8, nanoseconds: u64) !void {
    const as_float: f64 = @floatFromInt(nanoseconds);
    try out.print("  {s:<5} {d:.2}ms\n", .{ label, as_float / std.time.ns_per_ms });
}

test "summarize" {
    var latencies = [_]u64{ 50, 10, 40, 20, 30, 100, 90, 80, 70, 60 };
    const stats = summarize(&latencies).?;
    try std.testing.expectEqual(10, stats.min);
    try std.testing.expectEqual(100, stats.max);
    try std.testing.expectEqual(55, stats.mean);
    try std.testing.expectEqual(50, stats.p50);
    try std.testing.expectEqual(90, stats.p90);
    try std.testing.expectEqual(100, stats.p99);

    var empty = [_]u64{};
    try std.testing.expectEqual(null, summarize(&empty));
}

test "run validates its options" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var buffer: [16]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.InvalidRequestCount, run(io, gpa, &writer, .{ .url = "http://x/", .requests = 0 }));
    try std.testing.expectError(error.InvalidConcurrency, run(io, gpa, &writer, .{ .url = "http://x/", .concurrency = 0 }));
    try std.testing.expectError(error.InvalidFormat, run(io, gpa, &writer, .{ .url = "not a url" }));
}

test "run against the local test server" {
    const TestServer = @import("test_server.zig").TestServer;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.stop(io);
    var url_buffer: [64]u8 = undefined;
    const url = try server.url(&url_buffer);

    const request_count = 6;
    var server_task = try io.concurrent(TestServer.serve, .{ &server, io, request_count });
    defer server_task.cancel(io) catch {};

    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try run(io, gpa, &output.writer, .{ .url = url, .requests = request_count, .concurrency = 3 });
    try server_task.await(io);

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "requests:     6 (2xx: 6, other or failed: 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "  p99 ") != null);
}
