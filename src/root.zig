const std = @import("std");

// const mkfifo = @extern(fn (path: [*:0]const u8, mode: u32) callconv(.C) c_int);

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
});

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

pub fn selectSession(allocator: std.mem.Allocator, sessions: []KakSession) !?KakSession {
    var fzf_input = std.ArrayList([]const u8).init(allocator);
    var mapping = std.StringHashMap(KakSession).init(allocator);
    for (sessions) |session| {
        const line = try session.formatForFzf(allocator);
        try fzf_input.append(line);
        try mapping.put(line, session);
    }

    var fzf = std.process.Child.init(&[_][]const u8{"fzf"}, allocator);
    fzf.stdout_behavior = .Pipe;
    fzf.stdin_behavior = .Pipe;
    try fzf.spawn();
    const stdin = fzf.stdin.?;
    const stdout = fzf.stdout.?;

    for (fzf_input.items) |line| {
        try stdin.writeAll(line);
        try stdin.writeAll("\n");
    }
    const selection = try stdout.readToEndAlloc(allocator, 1024);
    const chomped_selection = selection[0 .. selection.len - 1];
    _ = try fzf.wait();
    return mapping.get(chomped_selection);
}

pub fn execKak(allocator: std.mem.Allocator, session: ?KakSession) !void {
    if (session) |s| {
        const envp = try std.process.getEnvMap(allocator);
        const kak_args = &[_][]const u8{
            "kak",
            "-c",
            s.name,
        };
        return std.process.execve(allocator, kak_args, &envp);
    } else {
        std.debug.print("oh no! no session provided\n", .{});
    }
}

pub fn kakSessions(allocator: std.mem.Allocator) ![]KakSession {
    // var sessions_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var sessions_path: []const u8 = undefined;
    const xdg = try std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR");
    defer allocator.free(xdg);

    if (xdg.len > 0) {
        sessions_path = std.fs.path.join(allocator, &.{ xdg, "kakoune" }) catch unreachable;
    } else {
        sessions_path = "/tmp/kakoune";
    }

    const parent_dir = if (xdg.len > 0) xdg else "/tmp";
    sessions_path = try std.fs.path.join(allocator, &.{ parent_dir, "kakoune" });
    defer allocator.free(sessions_path);

    var dir = try std.fs.openDirAbsolute(sessions_path, .{ .iterate = true });
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
