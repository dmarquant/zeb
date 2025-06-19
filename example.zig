const std = @import("std");
const Server = @import("server.zig").Server;

pub fn main() !void {
    var server = try Server.init(.{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);

        const ctx = try server.next(arena.allocator());
        defer ctx.conn.stream.close();

        std.debug.print("New request: {s} {s}\n", .{ ctx.request.method, ctx.request.url });

        if (std.mem.eql(u8, ctx.request.url, "/hello")) {
            const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello";
            try ctx.conn.stream.writeAll(response);
        } else if (std.mem.eql(u8, ctx.request.url, "/echo")) {
            if (try ctx.body()) |body| {
                const writer = ctx.conn.stream.writer();
                try writer.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", .{body.len});
                try writer.writeAll(body);
            } else {
                const response = "HTTP/1.1 400 Bad Request\r\n\r\n";
                try ctx.conn.stream.writeAll(response);
            }
        }
    }
}
