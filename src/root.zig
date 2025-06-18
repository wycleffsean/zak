const std = @import("std");

const KakSession = struct {
    name: []const u8,
};

pub fn selectSession(allocator: std.mem.Allocator, sessions: []KakSession) !?KakSession {
    var fzf_input = std.ArrayList([]const u8).init(allocator);
    var mapping = std.StringHashMap(KakSession).init(allocator);
    for (sessions) |session| {
        const line = try std.fmt.allocPrint(allocator, "Session: {s}", .{session.name});
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
        // const session_info = try describeSession(allocator, session_path);
        if (isSocketAlive(session_path)) try sessions.append(.{ .name = session_name });
    }

    return sessions.toOwnedSlice();
}

fn isSocketAlive(path: []const u8) bool {
    var stream = std.net.connectUnixSocket(path) catch return false;
    defer stream.close();
    return true;
}

fn describeSession(allocator: std.mem.Allocator, session_name: []const u8) ![]const u8 {
    // const kak_cmd = try std.mem.concat(allocator, u8, &.{ "nop %sh{ echo Kakoune session: ", session_name, " } " });
    // defer allocator.free(kak_cmd);
    const kak_cmd =
        \\ {
        \\     echo
        \\     printf "Session: %s\n" "${kak_session}"
        \\     printf "Current working directory: %s\n" "${PWD}"
        \\     eval set -- "${kak_buflist}"
        \\     printf "Buffers (%d):\n" $#
        \\     for bufname in "$@"; do
        \\         printf "\t%s\n" "${bufname}"
        \\     done
        \\     eval set -- "${kak_client_list}"
        \\     printf "Clients (%d):\n" $#
        \\     for clientname in "$@"; do
        \\         printf "\t%s\n" "${clientname}"
        \\     done
        \\ }
    ;

    var process = std.process.Child.init(&[_][]const u8{ "kak", "-p", session_name }, allocator);
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;
    try process.spawn();

    // defer allocator.free(process.stdout);
    // defer allocator.destroy(process.stderr);

    if (process.stdin) |stdin| {
        std.debug.print("writing in\n", .{});
        _ = try stdin.write(kak_cmd);
        stdin.close();
    }

    if (process.stdout) |stdout| {
        std.debug.print("writing out\n", .{});
        return try stdout.readToEndAlloc(allocator, 1024);
    }

    return "no result";
}
