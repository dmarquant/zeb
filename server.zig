const std = @import("std");
const http = @import("http.zig");

const DEFAULT_PORT: u16 = 8000;

pub const ServerConfig = struct {
    address: std.net.Address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8000),
    kernelBacklog: u31 = 128,
    reuseAddress: bool = false,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    conn: std.net.Server.Connection,
    request: http.Request,

    pub fn body(ctx: Context) !?[]u8 {
        if (ctx.request.header("Content-Length")) |clStr| {
            const len = std.fmt.parseInt(u64, clStr, 10) catch return null;
            const content = try ctx.allocator.alloc(u8, len);
            @memcpy(content[0..ctx.request.bodyStart.len], ctx.request.bodyStart);

            if (content.len > ctx.request.bodyStart.len) {
                // TODO: Does this handle the case if the client closes the connection
                // without sending all the data?
                _ = try ctx.conn.stream.readAll(content[ctx.request.bodyStart.len..]);
            }
            return content;
        } else {
            return null;
        }
    }
};

pub const Server = struct {
    tcpServer: std.net.Server,

    pub fn init(config: ServerConfig) !Server {
        const tcpServer = try config.address.listen(.{ .kernel_backlog = config.kernelBacklog, .reuse_address = config.reuseAddress });

        // TODO: print address
        std.debug.print("Listening...\n", .{});

        return .{ .tcpServer = tcpServer };
    }

    pub fn deinit(server: *Server) void {
        server.tcpServer.deinit();
    }

    pub fn next(server: *Server, allocator: std.mem.Allocator) !Context {
        const connection = try server.tcpServer.accept();
        const reader = connection.stream.reader();
        const request = try http.parse(reader, allocator);
        return .{ .allocator = allocator, .conn = connection, .request = request };
    }
};
