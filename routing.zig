const std = @import("std");
const http = @import("http.zig");

const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

pub const Methods = struct {
    GET: bool = false,
    HEAD: bool = false,
    POST: bool = false,
    PUT: bool = false,
    DELETE: bool = false,
    OPTIONS: bool = false,
    PATCH: bool = false,
};

pub const GET = Methods{ .GET = true };
pub const POST = Methods{ .GET = true };

pub fn match(comptime rule: []const u8, comptime methods: Methods, req: http.Request) ?checkUrlResultType(rule) {
    const methodMatch = switch (req.method) {
        .GET => methods.GET,
        .HEAD => methods.HEAD,
        .POST => methods.POST,
        .PUT => methods.PUT,
        .DELETE => methods.DELETE,
        .OPTIONS => methods.OPTIONS,
        .PATCH => methods.PATCH,
    };
    if (!methodMatch) {
        return null;
    }
    return matchUrl(rule, req.url);
}

pub fn matchRoute(comptime rule: []const u8, req: http.Request) ?checkUrlResultType(rule) {
    return matchUrl(rule, req.url);
}

fn makeName(comptime str: []const u8) [:0]const u8 {
    comptime var sentinel: [str.len:0]u8 = undefined;

    comptime var i = 0;
    inline while (i < str.len) : (i += 1) {
        sentinel[i] = str[i];
    }
    return &sentinel;
}

const UrlRulePart = union(enum) { constant: []const u8, variable: struct { name: []const u8, type: type } };

fn parseUrlRule(comptime rule: []const u8) []const UrlRulePart {
    comptime var i = 0;
    comptime var numParts = 1;
    inline while (i < rule.len) : (i += 1) {
        // TODO: Do correct computation
        if (rule[i] == '{')
            numParts += 2;
    }
    if (rule[rule.len - 1] == '}')
        numParts -= 1;

    var parts: [numParts]UrlRulePart = undefined;

    i = 0;

    comptime var iPart = 0;
    inline while (i < rule.len) : (i += 1) {
        comptime var start = i;

        inline while (i < rule.len) : (i += 1) {
            switch (rule[i]) {
                '{', '}' => break,
                else => {},
            }
        }

        if (start < i) {
            parts[iPart] = .{ .constant = rule[start..i] };
            iPart += 1;
        }

        if (i >= rule.len)
            break;

        // TODO: Handle '}'

        comptime assert(rule[i] == '{');
        i += 1;

        start = i;
        inline while (i < rule.len) : (i += 1) {
            switch (rule[i]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                else => break,
            }
        }

        comptime assert(start < i);
        parts[iPart] = .{ .variable = .{ .name = rule[start..i], .type = []const u8 } };
        iPart += 1;

        comptime assert(rule[i] == '}');
    }
    return &parts;
}

fn checkUrlResultType(comptime rule: []const u8) type {
    const parts = parseUrlRule(rule);
    comptime var numParams = 0;

    for (parts) |part| {
        switch (part) {
            .constant => {},
            .variable => numParams += 1,
        }
    }

    comptime var iParam = 0;
    var paramDefs: [numParams]std.builtin.Type.StructField = undefined;
    for (parts) |part| {
        switch (part) {
            .constant => {},
            .variable => |variable| {
                paramDefs[iParam] = .{ .name = makeName(variable.name), .type = variable.type, .default_value = null, .is_comptime = false, .alignment = 0 };
                iParam += 1;
            },
        }
    }
    return @Type(.{ .Struct = .{ .layout = .auto, .fields = paramDefs[0..], .decls = &[_]std.builtin.Type.Declaration{}, .is_tuple = false } });
}

fn matchUrl(comptime rule: []const u8, url: []const u8) ?checkUrlResultType(rule) {
    var result: checkUrlResultType(rule) = undefined;
    const parts = parseUrlRule(rule);

    var i: usize = 0;

    comptime var iResult = 0;
    inline for (parts) |part| {
        switch (part) {
            .constant => |constant| {
                comptime var j = 0;
                inline while (j < constant.len) : (j += 1) {
                    if (i >= url.len)
                        return null;
                    if (url[i] != constant[j])
                        return null;
                    i += 1;
                }

                if (j < constant.len)
                    return null;
            },
            .variable => |variable| {
                const start = i;
                while (i < url.len and url[i] != '/') {
                    i += 1;
                }
                @field(result, variable.name) = url[start..i];
                iResult += 1;
            },
        }
    }
    return result;
}

test "matching constant rule" {
    const isMatch = matchUrl("/index.html", "/index.html");
    try expect(isMatch != null);

    const noMatch = matchUrl("/index.html", "/home");
    try expect(noMatch == null);
}

test "matching a variable part" {
    const m = matchUrl("/val/{id}/op", "/val/1234/op");
    try expect(m != null);

    if (m) |params| {
        try expectEqualSlices(u8, params.id, "1234");
    }
}

test "matching a variable part at the end" {
    const m = matchUrl("/val/{id}", "/val/1234");
    try expect(m != null);

    if (m) |params| {
        try expectEqualSlices(u8, params.id, "1234");
    }
}

test "matching multiple variable parts" {
    const m = matchUrl("/venues/{venueId}/bookings/{bookingId}/messages/{messageId}", "/venues/1234/bookings/AAAA-24123/messages/12");
    try expect(m != null);

    if (m) |params| {
        try expectEqualSlices(u8, params.venueId, "1234");
        try expectEqualSlices(u8, params.bookingId, "AAAA-24123");
        try expectEqualSlices(u8, params.messageId, "12");
    }
}
