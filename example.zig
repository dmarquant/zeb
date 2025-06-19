const std = @import("std");
const Server = @import("server.zig").Server;
const http = @import("http.zig");
const routing = @import("routing.zig");

const match = routing.match;
const GET = routing.GET;
const POST = routing.POST;

pub fn main() !void {
    var server = try Server.init(.{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);

        const ctx = try server.next(arena.allocator());
        defer ctx.conn.stream.close();

        if (match("/hello", GET, ctx.request)) |_| {
            const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello";
            try ctx.conn.stream.writeAll(response);
        } else if (match("/echo", POST, ctx.request)) |_| {
            if (try ctx.body()) |body| {
                const writer = ctx.conn.stream.writer();
                try writer.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", .{body.len});
                try writer.writeAll(body);
            } else {
                const response = "HTTP/1.1 400 Bad Request\r\n\r\n";
                try ctx.conn.stream.writeAll(response);
            }
        } else if (match("/user/{name}", GET, ctx.request)) |params| {
            const writer = ctx.conn.stream.writer();
            try writer.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", .{6 + params.name.len});
            try writer.print("Hello {s}", .{params.name});
        } else {
            const response = "HTTP/1.1 404 Not Found\r\n\r\n";
            try ctx.conn.stream.writeAll(response);
        }
    }
}
