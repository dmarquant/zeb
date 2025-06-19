const std = @import("std");

const Error = error{
    AllocationFailure,
    IoError,
    UnexpectedEof,
    UnexpectedChar,
};

pub const Request = struct {
    data: []const u8,

    method: []const u8,
    url: []const u8,
    headerData: []const u8,

    bodyStart: []const u8,

    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        var ix: usize = 0;
        while (ix < r.headerData.len) {
            var match = true;
            var i: usize = 0;
            while (isHeaderChar(r.headerData[ix])) {
                if (name[i] != r.headerData[ix]) {
                    match = false;
                }
                i += 1;
                ix += 1;
            }

            ix += 1; // skip ':'

            while (r.headerData[ix] == ' ') {
                ix += 1;
            }
            const start = ix;
            while (isHeaderValueChar(r.headerData[ix])) {
                ix += 1;
            }
            if (match) {
                return r.headerData[start..ix];
            }
            ix += 2;
        }
        return null;
    }
};

// TODO: Why separate bits?
pub const GET = 0x01;
pub const HEAD = 0x02;
pub const POST = 0x04;
pub const PUT = 0x08;
pub const DELETE = 0x0F;
pub const OPTIONS = 0x10;
pub const PATCH = 0x20;

pub fn parse(reader: anytype, allocator: std.mem.Allocator) Error!Request {
    var parser = Parser(@TypeOf(reader)).init(reader, allocator);
    return try parser.parse();
}

fn Parser(comptime ReaderType: type) type {
    return struct {
        reader: ReaderType,
        allocator: std.mem.Allocator,

        buf: []u8 = &.{},

        nread: u32 = 0,
        ix: u32 = 0,

        const Self = @This();

        fn init(reader: ReaderType, allocator: std.mem.Allocator) Self {
            return .{ .reader = reader, .allocator = allocator };
        }

        fn parse(p: *Self) Error!Request {
            errdefer p.allocator.free(p.buf);

            const method = try p.takeWhile(isMethodChar);

            try p.expect(' ');

            const url = try urlDecodeInplace(try p.takeWhile(isUrlChar));
            // TODO: Url decoding

            try p.expect(' ');

            _ = try p.takeWhile(isVersionChar);

            try p.expect('\r');
            try p.expect('\n');

            const headerStart = p.ix;
            while (try p.peek() != '\r') {
                _ = try p.takeWhile(isHeaderChar);
                try p.expect(':');
                _ = try p.takeWhile(isHeaderValueChar);
                try p.expect('\r');
                try p.expect('\n');
            }
            const headerData = p.buf[headerStart..p.ix];

            try p.expect('\r');
            try p.expect('\n');

            return Request{
                .data = p.buf,
                .method = method,
                .url = url,
                .headerData = headerData,
                .bodyStart = p.buf[p.ix..p.nread],
            };
        }

        fn peek(p: *Self) Error!u8 {
            if (p.ix >= p.nread) {
                std.debug.print("Need more data\n", .{});

                if (p.nread + 1024 > p.buf.len) {
                    p.buf = p.allocator.realloc(p.buf, p.nread + 4096) catch return Error.AllocationFailure;
                }

                const bytesRead = p.reader.read(p.buf[p.nread..]) catch return Error.IoError;

                std.debug.print("Read {} bytes\n", .{bytesRead});

                if (bytesRead == 0) {
                    return Error.UnexpectedEof;
                }
                p.nread += @intCast(bytesRead);
            }
            return p.buf[p.ix];
        }

        fn expect(p: *Self, ch: u8) Error!void {
            if (try p.peek() == ch) {
                p.ix += 1;
            } else {
                std.debug.print("Expected '{c}' but got '{c}'\n", .{ ch, try p.peek() });
                return Error.UnexpectedChar;
            }
        }

        fn takeWhile(p: *Self, comptime pred: anytype) Error![]u8 {
            const start = p.ix;
            while (pred(try p.peek())) {
                p.ix += 1;
            }
            return p.buf[start..p.ix];
        }
    };
}

fn isMethodChar(c: u8) bool {
    // GET, POST, PUT, DELETE, OPTIONS, HEAD, PATCH
    return switch (c) {
        'A', 'C', 'D', 'E', 'G', 'H', 'I', 'L', 'N', 'O', 'P', 'S', 'T', 'U' => true,
        else => false,
    };
}

fn isUrlChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '%', '/', '.', '-', '_' => true,
        else => false,
    };
}

fn isVersionChar(c: u8) bool {
    return switch (c) {
        'H', 'T', 'P', '/', '1', '0', '.' => true,
        else => false,
    };
}

fn isHeaderChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '-' => true,
        else => false,
    };
}

fn isHeaderValueChar(c: u8) bool {
    return switch (c) {
        '\r', '\n' => false,
        else => true,
    };
}

fn hexVal(c: u8) Error!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => Error.UnexpectedChar,
    };
}

fn urlDecodeInplace(buf: []u8) Error![]u8 {
    var ix: usize = 0;
    var out: usize = 0;
    while (ix < buf.len) {
        if (buf[ix] == '%') {
            if (ix + 2 >= buf.len) {
                return Error.UnexpectedChar;
            } else {
                buf[out] = try hexVal(buf[ix + 1]) * 16 + try hexVal(buf[ix + 2]);
                out += 1;
            }
            ix += 3;
        } else {
            buf[out] = buf[ix];
            out += 1;
            ix += 1;
        }
    }

    return buf[0..out];
}

//
// Tests
//
fn testParse(bytes: []const u8) Error!Request {
    var stream = std.io.fixedBufferStream(bytes);
    const reader = stream.reader();
    return try parse(reader, std.testing.allocator);
}

test "parsing simple request" {
    const req = try testParse("GET /home/page HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualSlices(u8, "GET", req.method);
    try std.testing.expectEqualSlices(u8, "/home/page", req.url);

    std.testing.allocator.free(req.data);
}

test "simple url decoding" {
    const req = try testParse("GET /book%20store HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualSlices(u8, "/book store", req.url);

    std.testing.allocator.free(req.data);
}

test "url decoding with utf escapes" {
    const req = try testParse("GET /book%E2%82%ACstore HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualSlices(u8, "/book€store", req.url);

    std.testing.allocator.free(req.data);
}

test "fails if stream ends during method" {
    const req = testParse("GE");
    try std.testing.expectError(Error.UnexpectedEof, req);
}
