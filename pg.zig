const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Error = error{
    Unsupported,
    Protocol,
    Uninitialized,
    QueryError,
    ParseError,
};

const OIDs = struct {
    int2: i32 = 0,
    int4: i32 = 0,
    int8: i32 = 0,
    float4: i32 = 0,
    float8: i32 = 0,
    text: i32 = 0,
};

const Message = struct {
    ident: u8,
    data: []u8,
};

const Stmt = struct {
    name: u64,
};

pub const Cursor = struct {
    conn: *Connection,
    numColumns: u16,

    pub fn str(cur: Cursor, column: usize) []u8 {
        assert(column < cur.numColumns);
        const data = cur.conn.msgData;

        var ix: u32 = 2; // skip the num columns
        var i: u32 = 0;
        while (true) {
            const dataSize = std.mem.readVarInt(u32, data[ix .. ix + 4], .big);
            if (i == column) {
                return data[ix + 4 .. ix + 4 + dataSize];
            }
            ix += 4 + dataSize;
            i += 1;
        }
    }

    pub fn col(cur: Cursor, as: type, column: usize) !as {
        const asStr = cur.str(column);

        switch (as) {
            u8, u16, u32, u64, i8, i16, i32, i64 => return try std.fmt.parseInt(as, asStr, 10),
            f32, f64 => return try std.fmt.parseFloat(as, asStr),
            []u8, []const u8 => return asStr,
            else => {
                std.debug.print("Unsupported type: {}\n", .{as});
                return Error.Unsupported;
            },
        }
    }

    pub fn readNext(cur: *Cursor, ResultType: type) !?ResultType {
        assert(@typeInfo(ResultType).@"struct".fields.len == cur.numColumns);
        while (true) {
            const msg = try cur.conn.readMessage();

            if (msg.ident == 'D') {
                var result: ResultType = undefined;
                inline for (@typeInfo(ResultType).@"struct".fields, 0..) |field, i| {
                    @field(result, field.name) = try cur.col(field.type, i);
                }
                return result;
            } else if (msg.ident == 'C') {
                std.debug.print("Command completed...\n", .{});
            } else if (msg.ident == 'Z') {
                // TODO: Do we really need to wait here for this or can we move this somewhere?
                std.debug.print("Ready for next query...\n", .{});
                return null;
            }
        }
    }

    pub fn next(cur: *Cursor) !bool {
        while (true) {
            const msg = try cur.conn.readMessage();

            if (msg.ident == 'D') {
                return true;
            } else if (msg.ident == 'C') {
                std.debug.print("Command completed...\n", .{});
            } else if (msg.ident == 'Z') {
                // TODO: Do we really need to wait here for this or can we move this somewhere?
                std.debug.print("Ready for next query...\n", .{});
                return false;
            }
        }
    }
};

pub const Connection = struct {
    stream: std.net.Stream,
    allocator: Allocator,
    reader: std.io.BufferedReader(4096, std.net.Stream.Reader),
    msgData: []u8,

    oids: OIDs = .{},
    stmtCount: u64 = 0,

    fn ensureMsgSize(conn: *Connection, required: u32) !void {
        if (conn.msgData.len < required) {
            conn.msgData = try conn.allocator.realloc(conn.msgData, required);
        }
    }

    fn readMessage(conn: *Connection) !Message {
        const msg = try conn.reader.reader().readByte();
        const len = try conn.reader.reader().readInt(u32, .big) - 4;

        try conn.ensureMsgSize(len);

        _ = try conn.reader.reader().readAll(conn.msgData[0..len]);

        //std.debug.print("MSG [{c}]: {any}\n", .{ msg, conn.msgData[0..len] });

        return Message{ .ident = msg, .data = conn.msgData[0..len] };
    }

    fn sendQuery(conn: *Connection, queryStr: []const u8) !void {
        var bufWriter = std.io.bufferedWriter(conn.stream.writer());
        const writer = bufWriter.writer();

        const len = 5 + queryStr.len;
        try writer.writeByte('Q');
        try writer.writeInt(u32, @intCast(len), .big);
        try writer.writeAll(queryStr);
        try writer.writeByte(0);
        try bufWriter.flush();
    }

    pub fn init(stream: std.net.Stream, allocator: Allocator) !Connection {
        const reader = std.io.bufferedReader(stream.reader());
        const msgData = try allocator.alloc(u8, 4096);
        var conn = Connection{ .stream = stream, .allocator = allocator, .reader = reader, .msgData = msgData };

        var cursor = try conn.query("select oid, typname from pg_type;");
        while (try cursor.next()) {
            const name = cursor.str(1);
            inline for (@typeInfo(OIDs).@"struct".fields) |field| {
                if (std.mem.eql(u8, name, field.name)) {
                    @field(conn.oids, field.name) = try std.fmt.parseInt(i32, cursor.str(0), 10);
                }
            }
        }

        return conn;
    }

    pub fn query(conn: *Connection, queryStr: []const u8) !Cursor {
        try conn.sendQuery(queryStr);
        while (true) {
            const msg = try conn.readMessage();
            if (msg.ident == 'T') {
                const numColumns = std.mem.readVarInt(u16, msg.data[0..2], .big);
                // TODO: read and keep row description
                return Cursor{ .conn = conn, .numColumns = numColumns };
            }
        }
    }

    pub fn execute(conn: *Connection, queryStr: []const u8) !void {
        try conn.sendQuery(queryStr);

        var errorOccurred = false;
        while (true) {
            const msg = try conn.readMessage();

            if (msg.ident == 'Z') {
                if (errorOccurred) {
                    return Error.QueryError;
                } else {
                    return;
                }
            } else if (msg.ident == 'E') {
                // TODO: Keep error data around
                errorOccurred = true;
            }
        }
    }

    fn sendStatement(conn: *Connection, stmt: Stmt, params: anytype) !void {
        var bufWriter = std.io.bufferedWriter(conn.stream.writer());
        const writer = bufWriter.writer();

        var numParams: u16 = 0;
        var paramLen: usize = 0;
        inline for (params) |param| {
            // TODO: Handle other types
            paramLen += 4 + param.len;
            numParams += 1;
        }

        // 4: size
        // 1: unnamed portal
        // digits + 1: hex statement name
        // 2: default format -> all text
        // 2: num parameters
        // parameter data
        // 2: default result formats -> all text
        const len = 4 + 1 + hexDigits(stmt.name) + 1 + 2 + 2 + paramLen + 2;

        try writer.writeByte('B');
        try writer.writeInt(u32, @intCast(len), .big);

        // unnamed portal + statement name
        try writer.print("\x00{x}\x00", .{stmt.name});

        // num format codes
        try writer.writeInt(u16, 0, .big);

        // num params
        try writer.writeInt(u16, numParams, .big);

        inline for (params) |param| {
            // TODO: Handle other types
            try writer.writeInt(u32, @intCast(param.len), .big);
            try writer.writeAll(param);
        }

        // num result formats
        try writer.writeInt(u16, 0, .big);

        try writer.writeByte('D');
        try writer.writeInt(u32, 6, .big);
        try writer.writeByte('P');
        try writer.writeByte(0);

        //
        // Execute
        //
        try writer.writeByte('E');
        try writer.writeInt(u32, 9, .big);
        try writer.writeByte(0);
        try writer.writeInt(u32, 0, .big);

        try writer.writeByte('S');
        try writer.writeInt(u32, 4, .big);

        try bufWriter.flush();
    }

    pub fn queryStatement(conn: *Connection, stmt: Stmt, params: anytype) !Cursor {
        try conn.sendStatement(stmt, params);

        // TODO: Errors !
        while (true) {
            const msg = try conn.readMessage();
            if (msg.ident == 'T') {
                const numColumns = std.mem.readVarInt(u16, msg.data[0..2], .big);
                // TODO: read and keep row description
                return Cursor{ .conn = conn, .numColumns = numColumns };
            }
        }
    }

    pub fn executeStatement(conn: *Connection, stmt: Stmt, params: anytype) !void {
        try conn.sendStatement(stmt, params);

        while (true) {
            const msg = try conn.readMessage();
            if (msg.ident == 'Z') {
                return;
            } else if (msg.ident == 'E') {
                std.debug.print("Error!!!\n", .{});
                return Error.QueryError;
            }
        }
    }

    pub fn parse(conn: *Connection, queryStr: []const u8) !Stmt {
        var bufWriter = std.io.bufferedWriter(conn.stream.writer());
        const writer = bufWriter.writer();

        const name = conn.stmtCount;
        const nameDigits = hexDigits(name);

        const len = 6 + nameDigits + queryStr.len + 2;
        try writer.writeByte('P');
        try writer.writeInt(u32, @intCast(len), .big);
        try writer.print("{x}\x00", .{conn.stmtCount});
        try writer.writeAll(queryStr);
        try writer.writeByte(0);
        try writer.writeInt(u16, 0, .big);

        try writer.writeByte('S');
        try writer.writeInt(u32, 4, .big);

        try bufWriter.flush();

        conn.stmtCount += 1;

        var err = false;
        while (true) {
            const msg = try conn.readMessage();
            if (msg.ident == 'Z') {
                // TODO: Should we ensure '1' message was sent?
                return Stmt{ .name = conn.stmtCount - 1 };
            } else if (msg.ident == 'E') {
                std.debug.print("Error!!!\n", .{});
                err = true;
            }
        }
    }
};

pub fn connect(allocator: Allocator, user: []const u8, db: []const u8) !Connection {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 5432);
    var stream = try std.net.tcpConnectToAddress(addr);

    const reader = stream.reader();

    const startup = try buildStartupMessage(allocator, user, db);
    defer allocator.free(startup);
    try stream.writeAll(startup);

    // Read messages until we receive 'ReadyForQuery' (Z)
    while (true) {
        const msg = try reader.readByte();
        const len = try reader.readInt(u32, .big) - 4;
        if (msg == 'R') {
            const authType = try reader.readInt(i32, .big);
            if (authType == 0) {
                if (len != 4) {
                    return Error.Protocol;
                }
            } else {
                return Error.Unsupported;
            }
        } else if (msg == 'Z') {
            if (len != 1) {
                return Error.Protocol;
            }
            _ = try reader.readByte();
            break;
        } else {
            try reader.skipBytes(len, .{});
        }
    }
    return Connection.init(stream, allocator);
}

fn buildStartupMessage(allocator: Allocator, user: []const u8, database: []const u8) ![]u8 {
    // size(4) + version(4) + "user\0"(5) + "postgres\0"(9) + "\0\0\0"(3) = 25
    const size = 25 + user.len + database.len;

    const buf = try allocator.alloc(u8, size);
    var stream = std.io.fixedBufferStream(buf);

    const writer = stream.writer();
    try writer.writeInt(i32, @intCast(size), .big);
    try writer.writeInt(i32, 196608, .big);
    try writer.writeAll("user\x00");
    try writer.writeAll(user);
    try writer.writeAll("\x00database\x00");
    try writer.writeAll(database);
    try writer.writeByte(0);
    try writer.writeByte(0);
    return buf;
}

fn buildSimpleQueryMessage(allocator: Allocator, queryStr: []const u8) ![]u8 {
    const size = 5 + queryStr.len;

    const buf = try allocator.alloc(u8, size + 1);
    var stream = std.io.fixedBufferStream(buf);

    const writer = stream.writer();
    try writer.writeByte('Q');
    try writer.writeInt(i32, @intCast(size), .big);
    try writer.writeAll(queryStr);
    try writer.writeByte(0);
    return buf;
}

fn hexDigits(number: u64) u32 {
    var num: u64 = number;
    var n: u32 = 1;
    while (num > 0x0F) {
        n += 1;
        num /= 16;
    }
    return n;
}
