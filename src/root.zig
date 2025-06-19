const std = @import("std");
const fatal = std.process.fatal;
const exit = std.process.exit;

const KakSession = struct {
    name: []const u8,
    cwd: []const u8,
    buffers: [][]const u8,
    clients: [][]const u8,

    const Self = @This();

    fn formatForFzf(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        const project = std.fs.path.basename(self.cwd);
        return std.fmt.allocPrint(allocator, "{s} · name[{s}] · buffers[{d}] · clients[{d}]", .{ project, self.name, self.buffers.len, self.clients.len });
    }
};

const KakSessionOrName = union(enum) {
    session: KakSession,
    name: []const u8,
};

pub fn selectSession(allocator: std.mem.Allocator, sessions: []KakSession) !KakSessionOrName {
    var fzf_input = std.ArrayList([]const u8).init(allocator);
    var mapping = std.StringHashMap(KakSession).init(allocator);
    for (sessions) |session| {
        const line = try session.formatForFzf(allocator);
        try fzf_input.append(line);
        try mapping.put(line, session);
    }

    var fzf = std.process.Child.init(&[_][]const u8{
        "fzf",
        "--expect=enter",
        "--expect=space",
        "--print-query",
    }, allocator);
    fzf.stdout_behavior = .Pipe;
    fzf.stdin_behavior = .Pipe;
    try fzf.spawn();
    const stdin = fzf.stdin.?;
    const stdout = fzf.stdout.?;
    const reader = stdout.reader();

    for (fzf_input.items) |line| {
        try stdin.writeAll(line);
        try stdin.writeAll("\n");
    }
    const query_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024);
    // key line
    _ = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024);
    const match_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024);

    // Handle result
    const term = try fzf.wait();
    if (term.Exited == 130) {
        exit(0); // user quit
    } else if (term.Exited == 1) {
        // off-list selection
        if (query_line) |line| return .{ .name = line };
    } else if (match_line) |line| {
        if (mapping.get(line)) |session| {
            return .{ .session = session };
        } else {
            return .{ .name = line };
        }
    }
    return .{ .name = "" };
}

pub fn execKak(allocator: std.mem.Allocator, session_or_name: KakSessionOrName) !void {
    const envp = try std.process.getEnvMap(allocator);
    switch (session_or_name) {
        .session => |session| {
            const kak_args = &[_][]const u8{
                "kak",
                "-c",
                session.name,
            };
            return std.process.execve(allocator, kak_args, &envp);
        },
        .name => |name| {
            const kak_args = if (name.len == 0)
                &[_][]const u8{"kak"}
            else
                &[_][]const u8{
                    "kak",
                    "-s",
                    name,
                };
            return std.process.execve(allocator, kak_args, &envp);
        },
    }
}

pub fn kakSessionPath(allocator: std.mem.Allocator) ![]const u8 {
    // 1. Try $XDG_RUNTIME_DIR/kakoune
    if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "kakoune" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    // 2. Try $TMPDIR/kakoune-$USER
    const tmpdir = std.process.getEnvVarOwned(allocator, "TMPDIR") catch null;
    defer if (tmpdir) |t| allocator.free(t);
    const tmp = tmpdir orelse "/tmp";

    const user = std.process.getEnvVarOwned(allocator, "USER") catch null;
    defer if (user) |u| allocator.free(u);

    if (user) |username| {
        const tmp_user = try std.fmt.allocPrint(allocator, "{s}/kakoune-{s}", .{ tmp, username });
        return tmp_user;
    }

    // 3. Fallback to /tmp/kakoune
    return std.fs.path.join(allocator, &.{ "/tmp", "kakoune" });
}

pub fn kakSessions(allocator: std.mem.Allocator) ![]KakSession {
    const sessions_path = try kakSessionPath(allocator);
    defer allocator.free(sessions_path);

    var dir = std.fs.openDirAbsolute(sessions_path, .{ .iterate = true }) catch |e| {
        switch (e) {
            error.FileNotFound => fatal("kakoune sessions not found in search path: {s}", .{sessions_path}),
            error.NotDir => fatal("kakoune sessions search path is not a directory: {s}", .{sessions_path}),
            else => return e,
        }
    };
    defer dir.close();

    var sessions = std.ArrayList(KakSession).init(allocator);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .unix_domain_socket) continue;

        const session_name = try allocator.dupe(u8, entry.name);
        const session_path = try std.fs.path.join(allocator, &.{ sessions_path, session_name });
        defer allocator.free(session_path);
        if (isSocketAlive(session_path)) try sessions.append(try describeSession(allocator, session_name));
    }

    return sessions.toOwnedSlice();
}

fn isSocketAlive(path: []const u8) bool {
    var stream = std.net.connectUnixSocket(path) catch return false;
    defer stream.close();
    return true;
}

fn describeSession(allocator: std.mem.Allocator, session_name: []const u8) !KakSession {
    const fifo_path = "/tmp/zak_session_info_fifo";
    _ = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "mkfifo", fifo_path },
    });
    defer std.fs.deleteFileAbsolute(fifo_path) catch {};

    const kak_script = try std.fmt.allocPrint(allocator,
        \\nop %sh{{
        \\  {{
        \\    printf '{{'
        \\    printf '"name":"%s",' "$kak_session"
        \\    printf '"cwd":"%s",' "$PWD"
        \\
        \\    eval set -- "$kak_buflist"
        \\    printf '"buffers":['
        \\    first=1
        \\    for buf in "$@"; do
        \\      [ "$first" -eq 1 ] && first=0 || printf ','
        \\      printf '"%s"' "$buf"
        \\    done
        \\    printf '],'
        \\
        \\    eval set -- "$kak_client_list"
        \\    printf '"clients":['
        \\    first=1
        \\    for client in "$@"; do
        \\      [ "$first" -eq 1 ] && first=0 || printf ','
        \\      printf '"%s"' "$client"
        \\    done
        \\    printf ']}}'
        \\  }} > {s}
        \\}}
    , .{fifo_path});

    var process = std.process.Child.init(&[_][]const u8{ "kak", "-p", session_name }, allocator);
    process.stdin_behavior = .Pipe;
    try process.spawn();
    const stdin = process.stdin.?;

    _ = try stdin.write(kak_script);
    stdin.close();
    process.stdin = null; // we closed it ourselves; avoid a panic

    const fifo_file = try std.fs.openFileAbsolute(fifo_path, .{});
    defer fifo_file.close();
    const json = try fifo_file.readToEndAlloc(allocator, 1024);

    // std.debug.print("result: '{s}'\n", .{json});
    const session = try std.json.parseFromSlice(KakSession, allocator, json, .{});
    defer session.deinit();

    _ = try process.wait();

    return session.value;
}
