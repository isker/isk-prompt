const std = @import("std");

// This is my prompt. There are many like it, but this one is mine.
//
// Like hydro, but without busted regexes.
// Like starship, but with almost none of the billion modules, and even those
// subtly tweaked.
//
// And it does no heap allocations :^).
pub fn main() !void {
    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    const output = bw.writer();
    // We don't detect the config as somehow the way fish is calling this
    // function results in `isTty` being false, so there is no natural color
    // support. It's a shell prompt; there is a TTY.
    const tty_config = std.io.tty.Config.escape_codes;

    // Lead with an empty line to better distinguish the prompt.
    try output.writeByte('\n');

    // PWD is supposed to always be defined, and is superior to `getcwd` for our
    // purposes in that it does not resolve symbolic links.
    const cwd = std.os.getenv("PWD") orelse unreachable;
    // Likewise HOME is supposed to always be defined.
    const home = std.os.getenv("HOME") orelse unreachable;

    // I don't want branches with names longer than this anyway.
    var git_head_buf: [80]u8 = undefined;
    const git_state = try findGitState(cwd, &git_head_buf);

    try renderPath(cwd, home, if (git_state) |s| s.dir else null, tty_config, output);

    if (git_state) |value| {
        try renderGitHead(value.head, output);
    }

    if (std.os.getenv("CMD_DURATION")) |value| {
        try renderCmdDuration(value, output);
    }

    if (std.os.getenv("PIPESTATUS")) |pipestatus| {
        try renderStatusCode(pipestatus, tty_config, output);
    }

    try output.writeAll("\nλ ");

    try bw.flush();
}

/// Walks up the cwd path, looking for usage of the world's most misapplied
/// version control system, interrogating its on-disk layout for the state
/// of HEAD, which is much faster than spawning a process to ask about it.
fn findGitState(cwd: []const u8, buf: []u8) !?GitState {
    var components = try std.fs.path.componentIterator(cwd);
    var git_dir = components.last();
    return while (git_dir) |value| : ({
        git_dir = components.previous();
    }) {
        // `catch break null` throughout because if we don't want to proceed
        // past a repo that we just aren't properly permissioned to talk to.
        var dir = std.fs.openDirAbsolute(value.path, .{}) catch break null;
        defer dir.close();
        var file = dir.openFile(".git/HEAD", .{}) catch |err| {
            switch (err) {
                std.fs.File.OpenError.FileNotFound => continue,
                else => break null,
            }
        };
        defer file.close();

        const end_index = file.readAll(buf) catch break null;
        const contents = std.mem.trimRight(u8, buf[0..end_index], "\n");
        const head = if (std.mem.startsWith(u8, contents, "ref: refs/heads/"))
            GitHead{ .branch = contents["ref: refs/heads/".len..] }
        else
            GitHead{ .commit = contents };
        return GitState{ .head = head, .dir = value.path };
    } else null;
}

/// The kind of thing you can find in .git/HEAD.
const GitHeadKind = enum {
    branch,
    commit,
};
const GitHead = union(GitHeadKind) {
    branch: []const u8,
    commit: []const u8,
};
const GitState = struct {
    head: GitHead,
    dir: []const u8,
};

fn renderPath(cwd: []const u8, home: []const u8, git_repo_dir: ?[]const u8, tty: std.io.tty.Config, output: anytype) !void {
    var components = try std.fs.path.componentIterator(cwd);
    // HOME prefix -> ~
    const visible_path = if (!std.mem.eql(u8, home, "/") and std.mem.startsWith(u8, cwd, home)) blk: {
        try output.writeAll("~");
        // advance iterator past home
        while (components.next().?.path.len != home.len) {}
        break :blk cwd[home.len..];
    } else cwd;

    if (visible_path.len == 0) {
        // If there's nothing left after stripping the home prefix, exit early
        // so that we only render a tilde without a trailing slash.
        return;
    }

    // If the visible path is too long, we are going to abbreviate some
    // segments like fish does natively.
    const abbreviate = std.mem.count(u8, visible_path, "/") > 3;

    try output.writeAll(components.root().?);
    while (components.next()) |value| {
        try tty.setColor(output, .bold);
        if (abbreviate and
            // Git root does not get abbreviated.
            (git_repo_dir == null or value.path.len != git_repo_dir.?.len) and
            // Final component does not get abbreviated.
            value.path.len != components.path.len)
        {
            // Abbreviate to first character length. Does not handle
            // characters longer than 4 bytes; if you're using anything other
            // than ASCII you're already weird.
            const end = std.unicode.utf8ByteSequenceLength(value.name[0]) catch value.name.len;
            try output.writeAll(value.name[0..end]);
        } else {
            try output.writeAll(value.name);
        }
        try tty.setColor(output, .reset);
        if (value.path.len != components.path.len) {
            try output.writeAll("/");
        }
    }
}

test "`renderPath` renders short paths" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderPath("/etc/ssh/authorized_keys.d", "/home/isker", null, std.io.tty.Config.no_color, list.writer());
    try std.testing.expectEqualStrings("/etc/ssh/authorized_keys.d", list.items);
}

test "`renderPath` bolds path segments" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderPath("/etc/ssh/authorized_keys.d", "/home/isker", null, std.io.tty.Config.escape_codes, list.writer());
    try std.testing.expectEqualStrings("/\x1b[1metc\x1b[0m/\x1b[1mssh\x1b[0m/\x1b[1mauthorized_keys.d\x1b[0m", list.items);
}

test "`renderPath` abbreviates long paths" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderPath("/etc/ただ/Åland/linux/drivers/interconnect/qcom", "/home/isker", "/etc/ただ/Åland/linux", std.io.tty.Config.no_color, list.writer());
    try std.testing.expectEqualStrings("/e/た/Å/linux/d/i/qcom", list.items);
}

test "`renderPath` renders the home directory as a tilde" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderPath("/home/isker/.doom.d/weather-machine", "/home/isker", null, std.io.tty.Config.no_color, list.writer());
    // Abbreviation calc also only includes visible path segments, so this does
    // not get abbreviated.
    try std.testing.expectEqualStrings("~/.doom.d/weather-machine", list.items);
}

test "`renderPath` renders only a tilde when we are in the home directory" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderPath("/home/isker", "/home/isker", null, std.io.tty.Config.no_color, list.writer());
    try std.testing.expectEqualStrings("~", list.items);
}

fn renderGitHead(head: GitHead, output: anytype) !void {
    switch (head) {
        GitHeadKind.branch => |branch| {
            try output.writeAll(" ");
            try output.writeAll(branch);
        },
        GitHeadKind.commit => |commit| {
            try output.writeAll(" @");
            try output.writeAll(commit[0..8]);
        },
    }
}

test "`renderGitHead` renders branches" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderGitHead(GitHead{ .branch = "master" }, list.writer());
    try std.testing.expectEqualStrings(" master", list.items);
}

test "`renderGitHead` renders commits" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderGitHead(GitHead{ .commit = "accb64187cd3148a7f6139f7ea68e145a987bc6c" }, list.writer());
    try std.testing.expectEqualStrings(" @accb6418", list.items);
}

fn renderCmdDuration(cmd_duration: []const u8, output: anytype) !void {
    const duration_ms = std.fmt.parseUnsigned(u64, cmd_duration, 10) catch 0;
    // Only render "long" commands.
    if (duration_ms >= 3000) {
        try output.writeAll(" ");
        var ms_remaining = duration_ms;
        var first = true;
        inline for (.{
            .{ .ms = std.time.ms_per_day, .sep = 'd', .width = 0 },
            .{ .ms = std.time.ms_per_hour, .sep = 'h', .width = 2 },
            .{ .ms = std.time.ms_per_min, .sep = 'm', .width = 2 },
            .{ .ms = std.time.ms_per_s, .sep = 's', .width = 2 },
            // We simply truncate at seconds. Too much precision is bad.
        }) |unit| {
            if (ms_remaining >= unit.ms) {
                const units = ms_remaining / unit.ms;
                try std.fmt.formatInt(units, 10, .lower, .{
                    // Do not pad the first unit to be printed.
                    .width = if (first) blk: {
                        first = false;
                        break :blk 0;
                    } else unit.width,
                    .fill = '0',
                }, output);
                try output.writeByte(unit.sep);
                ms_remaining -= units * unit.ms;
            }
        }
    }
}

test "`renderCmdDuration` renders command duration" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    const long_duration = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{std.math.maxInt(u32)});
    defer std.testing.allocator.free(long_duration);
    try renderCmdDuration(long_duration, list.writer());
    try std.testing.expectEqualStrings(" 49d17h02m47s", list.items);
}

test "`renderCmdDuration` doesn't pad zeros on the first unit to be rendered" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderCmdDuration("325000", list.writer());
    try std.testing.expectEqualStrings(" 5m25s", list.items);
}

fn renderStatusCode(pipestatus: []const u8, tty: std.io.tty.Config, output: anytype) !void {
    var statuses = std.mem.tokenizeScalar(u8, pipestatus, ' ');
    while (statuses.next()) |status| {
        if (!std.mem.eql(u8, status, "0")) {
            // There was a nonzero status.
            break;
        }
    } else {
        // All statuses were 0.
        return;
    }

    statuses.reset();
    try output.writeAll(" ");
    try tty.setColor(output, .red);
    while (statuses.next()) |status| {
        try output.writeAll(status);
        if (statuses.peek() != null) {
            try output.writeAll(" | ");
        }
    }
    try tty.setColor(output, .reset);
}

test "`renderStatusCode` does nothing for status 0" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderStatusCode("0", std.io.tty.Config.no_color, list.writer());
    try std.testing.expectEqualStrings("", list.items);
}

test "`renderStatusCode` does nothing for a pipeline with all statuses 0" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderStatusCode("0 0 0", std.io.tty.Config.no_color, list.writer());
    try std.testing.expectEqualStrings("", list.items);
}

test "`renderStatusCode` renders statuses without colors" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderStatusCode("0 1", std.io.tty.Config.no_color, list.writer());
    try std.testing.expectEqualStrings(" 0 | 1", list.items);
}

test "`renderStatusCode` renders statuses with colors" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try renderStatusCode("0 1", std.io.tty.Config.escape_codes, list.writer());
    try std.testing.expectEqualStrings(" \x1b[31m0 | 1\x1b[0m", list.items);
}
