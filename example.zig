const std = @import("std");
const server = @import("server.zig");
const http = @import("http.zig");
const routing = @import("routing.zig");

const match = routing.match;
const GET = routing.GET;
const POST = routing.POST;

// Example global storage

var commonWordStorage: [100]u8 = undefined;
var commonWord: ?[]const u8 = null;

fn writeErrorResponse(writer: std.net.Stream.Writer, status: u16, message: []const u8) !void {
    try writer.print("HTTP/1.1 {} {s}\r\n\r\n", .{ status, message });
}

fn handleCommonWord(ctx: server.Context) !void {
    const writer = ctx.conn.stream.writer();
    if (ctx.request.method == .GET) {
        if (commonWord) |word| {
            try writer.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", .{word.len});
            try writer.writeAll(word);
        } else {
            try writeErrorResponse(writer, 404, "Not Found");
        }
    } else if (ctx.request.method == .PUT or ctx.request.method == .POST) {
        if (try ctx.body()) |body| {
            if (body.len > commonWordStorage.len) {
                try writeErrorResponse(writer, 400, "Bad Request");
            } else {
                @memcpy(commonWordStorage[0..body.len], body);
                commonWord = commonWordStorage[0..body.len];
                try writer.writeAll("HTTP/1.1 201 Created\r\n\r\n");
            }
        } else {
            try writeErrorResponse(writer, 400, "Bad Request");
        }
    } else if (ctx.request.method == .DELETE) {
        commonWord = null;
        try writer.writeAll("HTTP/1.1 201 OK\r\n\r\n");
    }
}

// Example key value store

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const keyValueAllocator = gpa.allocator();

var keyValueStore = std.StringHashMap([]const u8).init(keyValueAllocator);

fn handleKeyValue(ctx: server.Context, key: []const u8) !void {
    const writer = ctx.conn.stream.writer();
    if (ctx.request.method == .GET) {
        if (keyValueStore.get(key)) |value| {
            try writer.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{s}", .{ value.len, value });
        } else {
            try writeErrorResponse(writer, 404, "Not Found");
        }
    } else if (ctx.request.method == .PUT or ctx.request.method == .POST) {
        if (try ctx.body()) |body| {
            if (body.len > 10000) {
                try writeErrorResponse(writer, 400, "Bad Request");
            } else {
                const value = try keyValueAllocator.alloc(u8, body.len);
                @memcpy(value, body);

                const keyCopy = try keyValueAllocator.alloc(u8, key.len);
                @memcpy(keyCopy, key);

                // TODO: Handle error and return 500
                try keyValueStore.put(keyCopy, value);
                try writer.writeAll("HTTP/1.1 201 Created\r\n\r\n");
            }
        } else {
            try writeErrorResponse(writer, 400, "Bad Request");
        }
    } else if (ctx.request.method == .DELETE) {
        if (keyValueStore.fetchRemove(key)) |kv| {
            keyValueAllocator.free(kv.key);
            keyValueAllocator.free(kv.value);
        }
        try writer.writeAll("HTTP/1.1 201 OK\r\n\r\n");
    }
}

pub fn main() !void {
    var httpServer = try server.Server.init(.{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);

        const ctx = try httpServer.next(arena.allocator());
        defer ctx.conn.stream.close();

        if (match("/hello", GET, ctx.request)) |_| {
            const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello";
            try ctx.conn.stream.writeAll(response);
        } else if (match("/echo", POST, ctx.request)) |_| {
            const writer = ctx.conn.stream.writer();
            if (try ctx.body()) |body| {
                try writer.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", .{body.len});
                try writer.writeAll(body);
            } else {
                try writeErrorResponse(writer, 400, "Bad Request");
            }
        } else if (match("/user/{name}", GET, ctx.request)) |params| {
            const writer = ctx.conn.stream.writer();
            try writer.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", .{6 + params.name.len});
            try writer.print("Hello {s}", .{params.name});
        } else if (match("/commonword", .{ .GET = true, .POST = true, .PUT = true, .DELETE = true }, ctx.request)) |_| {
            try handleCommonWord(ctx);
        } else if (match("/kv/{key}", .{ .GET = true, .POST = true, .PUT = true, .DELETE = true }, ctx.request)) |params| {
            try handleKeyValue(ctx, params.key);
        } else {
            const writer = ctx.conn.stream.writer();
            try writeErrorResponse(writer, 404, "Not Found");
        }
    }
}
