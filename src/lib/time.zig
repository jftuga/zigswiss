//! time.zig converts between Unix epoch seconds and ISO 8601 UTC timestamps.
//! The standard library has no date formatter or time zone database, only the
//! calendar arithmetic in `std.time.epoch`, so the formatting and parsing here
//! are done by hand. In Zig 0.16 the current time comes from the `Io` interface.

const std = @import("std");
const Io = std.Io;
const epoch = std.time.epoch;

/// What the time command should do.
pub const Mode = enum {
    now,
    fromepoch,
    toepoch,
};

/// Runs one time conversion and writes the result to `out`. `value` is the
/// epoch number or the ISO timestamp, and is not used by `.now`.
pub fn run(io: Io, out: *Io.Writer, mode: Mode, value: ?[]const u8) !void {
    switch (mode) {
        .now => {
            // `.real` is the wall clock. `.awake` is the monotonic clock you
            // would use for measuring elapsed time (see bench.zig).
            const seconds = Io.Timestamp.now(io, .real).toSeconds();
            try out.print("epoch: {d}\nutc:   ", .{seconds});
            try formatIso(seconds, out);
            try out.writeByte('\n');
        },
        .fromepoch => {
            const text = value orelse return error.MissingValue;
            const seconds = try std.fmt.parseInt(i64, text, 10);
            try formatIso(seconds, out);
            try out.writeByte('\n');
        },
        .toepoch => {
            const text = value orelse return error.MissingValue;
            try out.print("{d}\n", .{try parseIso(text)});
        },
    }
}

/// Writes `seconds` since the Unix epoch as "YYYY-MM-DDTHH:MM:SSZ".
pub fn formatIso(seconds: i64, out: *Io.Writer) !void {
    if (seconds < 0) return error.BeforeEpoch;
    // Zig never converts between integer types implicitly when information
    // could be lost. `@intCast` is the checked conversion; the destination
    // type is inferred from where the result is used.
    const epoch_seconds: epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    // `{d:0>2}` means decimal, right-aligned, zero-padded to width 2.
    try out.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// Parses "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SS" (a space may replace the "T",
/// and a trailing "Z" is allowed) into seconds since the Unix epoch. The
/// timestamp is always treated as UTC.
pub fn parseIso(text: []const u8) !i64 {
    var body = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.endsWith(u8, body, "Z")) body = body[0 .. body.len - 1];

    const date_length = "YYYY-MM-DD".len;
    const full_length = "YYYY-MM-DDTHH:MM:SS".len;
    if (body.len != date_length and body.len != full_length) return error.InvalidTimestamp;
    if (body[4] != '-' or body[7] != '-') return error.InvalidTimestamp;

    const year = try std.fmt.parseInt(epoch.Year, body[0..4], 10);
    const month = try std.fmt.parseInt(u4, body[5..7], 10);
    const day = try std.fmt.parseInt(u5, body[8..10], 10);
    if (year < epoch.epoch_year) return error.BeforeEpoch;
    if (month < 1 or month > 12) return error.InvalidTimestamp;
    // `@enumFromInt` turns the number into the `Month` enum. The range check
    // above matters: an out-of-range value would be illegal behavior.
    const month_enum: epoch.Month = @enumFromInt(month);
    if (day < 1 or day > epoch.getDaysInMonth(year, month_enum)) return error.InvalidTimestamp;

    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    if (body.len == full_length) {
        if (body[10] != 'T' and body[10] != ' ') return error.InvalidTimestamp;
        if (body[13] != ':' or body[16] != ':') return error.InvalidTimestamp;
        hour = try std.fmt.parseInt(u5, body[11..13], 10);
        minute = try std.fmt.parseInt(u6, body[14..16], 10);
        second = try std.fmt.parseInt(u6, body[17..19], 10);
        if (hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    }

    return daysBeforeDate(year, month, day) * epoch.secs_per_day + hour * 3600 + minute * 60 + second;
}

/// Counts the days from 1970-01-01 up to (not including) the given date.
fn daysBeforeDate(year: epoch.Year, month: u4, day: u5) i64 {
    var days: i64 = 0;
    // A `while` loop with a "continue expression" after the colon is Zig's
    // version of a C-style for loop.
    var y: epoch.Year = epoch.epoch_year;
    while (y < year) : (y += 1) {
        days += epoch.getDaysInYear(y);
    }
    var m: u4 = 1;
    while (m < month) : (m += 1) {
        days += epoch.getDaysInMonth(year, @enumFromInt(m));
    }
    return days + day - 1;
}

/// Test helper: formats into a stack buffer and returns the text.
fn isoOf(buffer: []u8, seconds: i64) ![]const u8 {
    var writer: Io.Writer = .fixed(buffer);
    try formatIso(seconds, &writer);
    return writer.buffered();
}

test "formatIso" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", try isoOf(&buffer, 0));
    try std.testing.expectEqualStrings("2001-09-09T01:46:40Z", try isoOf(&buffer, 1_000_000_000));
    try std.testing.expectEqualStrings("2024-02-29T12:30:45Z", try isoOf(&buffer, 1_709_209_845));
    try std.testing.expectError(error.BeforeEpoch, isoOf(&buffer, -1));
}

test "parseIso" {
    try std.testing.expectEqual(0, try parseIso("1970-01-01"));
    try std.testing.expectEqual(1_000_000_000, try parseIso("2001-09-09T01:46:40Z"));
    try std.testing.expectEqual(1_709_209_845, try parseIso("2024-02-29 12:30:45\n"));
}

test "parseIso rejects malformed input" {
    try std.testing.expectError(error.InvalidTimestamp, parseIso("not a date"));
    try std.testing.expectError(error.InvalidTimestamp, parseIso("2023-02-29"));
    try std.testing.expectError(error.InvalidTimestamp, parseIso("2024-13-01"));
    try std.testing.expectError(error.InvalidTimestamp, parseIso("2024-01-01T24:00:00"));
    try std.testing.expectError(error.BeforeEpoch, parseIso("1969-12-31"));
}

test "parse and format are inverses" {
    var buffer: [32]u8 = undefined;
    const text = "2026-09-18T19:03:14Z";
    try std.testing.expectEqualStrings(text, try isoOf(&buffer, try parseIso(text)));
}
