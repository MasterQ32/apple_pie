const std = @import("std");
const Url = @import("url.zig").Url;
const Allocator = std.mem.Allocator;
const mem = std.mem;

const Request = @This();

/// GET, POST, PUT, DELETE or PATCH
method: Method,
/// Url object, get be used to retrieve path or query parameters
url: Url,
/// HTTP Request headers data.
raw_header_data: []const u8,
/// Protocol used by the requester, http1.1, http2.0, etc.
protocol: Protocol,
/// Length of requests body
content_length: usize,
/// True if http protocol version 1.0 or invalid request
should_close: bool,
/// Hostname the request was sent to. Includes its port. Required for HTTP/1.1
/// Cannot be null for user when `protocol` is `http1_1`.
host: ?[]const u8,
/// Internal allocator, fed by an arena allocator. Any memory allocated using this
/// allocator will be freed upon the end of a request. It's therefore illegal behaviour
/// to read from/write to its memory after a request and must be duplicated first.
arena: *Allocator,
/// `std.io.Reader` for the current request. Saved and used to retrieve the body of
/// a request when content length != 0. Using this reader directly outside the helper
/// functions such as `bufferedBody` and `body` may cause unwanted side-effects.
reader: AnyReader,

/// HTTP methods as specified in RFC 7231
pub const Method = enum {
    get,
    head,
    post,
    put,
    delete,
    connect,
    options,
    trace,
    patch,
    any,

    fn fromString(method: []const u8) Method {
        return switch (method[0]) {
            'G' => .get,
            'H' => .head,
            'P' => @as(Method, switch (method[1]) {
                'O' => .post,
                'U' => .put,
                else => .patch,
            }),
            'D' => .delete,
            'C' => .connect,
            'O' => .options,
            'T' => .trace,
            else => .any,
        };
    }
};

/// HTTP Protocol version
pub const Protocol = enum {
    http_0_9,
    http_1_0,
    http_1_1,
    http_2_0,

    /// Checks the given string and gives its protocol version
    /// Defaults to HTTP/1.1
    fn fromString(protocol: []const u8) Protocol {
        const eql = std.mem.eql;
        if (eql(u8, protocol, "HTTP/1.1")) return .http_1_1;
        if (eql(u8, protocol, "HTTP/2.0")) return .http_2_0;
        if (eql(u8, protocol, "HTTP/1.0")) return .http_1_0;
        if (eql(u8, protocol, "HTTP/0.9")) return .http_0_9;

        return .http_1_1; // default
    }
};

/// Represents an HTTP Header
pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

/// Alias to StringHashMapUnmanaged([]const u8)
pub const Headers = std.StringHashMapUnmanaged([]const u8);

/// Wrapper struct around any given reader.
/// This will allow us to store any kind of reader without creating a generic
/// or having it be comptime.
const AnyReader = struct {
    const InnerType = opaque {};
    inner: *const InnerType,
    read_fn: fn (self: *const InnerType, buf: []u8) callconv(.Async) anyerror!usize,

    fn init(reader: anytype) AnyReader {
        const T = std.meta.Child(@TypeOf(reader));
        return .{
            .inner = @ptrCast(*const InnerType, reader),
            .read_fn = struct {
                fn read(self: *const InnerType, buf: []u8) callconv(.Async) anyerror!usize {
                    return @ptrCast(*const T, @alignCast(@alignOf(T), self)).read(buf);
                }
            }.read,
        };
    }

    fn read(self: AnyReader, buffer: []u8) anyerror!usize {
        return self.read_fn(self.inner, buffer);
    }
};

/// Iterator to iterate through headers
const Iterator = struct {
    slice: []const u8,
    index: usize,

    /// Searches for the next header.
    /// Parsing cannot be failed as that would have been caught by `parse()`
    pub fn next(self: *Iterator) ?Header {
        if (self.index >= self.slice.len) return null;

        var state: enum { key, value } = .key;

        var header: Header = undefined;
        var start = self.index;
        while (self.index < self.slice.len) : (self.index += 1) {
            const c = self.slice[self.index];
            if (state == .key and c == ':') {
                header.key = self.slice[start..self.index];
                start = self.index + 2;
                state = .value;
            }
            if (state == .value and c == '\r') {
                header.value = self.slice[start..self.index];
                self.index += 2;
                return header;
            }
        }

        return null;
    }
};

/// Creates an iterator to retrieve all headers
/// As the data is known, this does not require any allocations
/// If all headers needs to be known at once, use `headers()`.
pub fn iterator(self: Request) Iterator {
    return Iterator{
        .slice = self.raw_header_data[0..],
        .index = 0,
    };
}

/// Creates an unmanaged Hashmap from the request headers, memory is owned by caller
/// Every header key and value will be allocated for the map and must therefore be freed
/// manually as well.
pub fn headers(self: Request, gpa: *Allocator) !Headers {
    var map = Headers{};

    var it = self.iterator();
    while (it.next()) |header| {
        try map.put(gpa, try gpa.dupe(u8, header.key), try gpa.dupe(u8, header.value));
    }

    return map;
}

/// Parses the body of the request and allocates the contents inside a buffer.
/// Memory must be handled manually by the caller
pub fn body(self: Request, gpa: *Allocator) ![]const u8 {
    if (self.content_length == 0) return "";
    const buffer = try gpa.alloc(u8, self.content_length);
    var i: usize = 0;
    while (i < self.content_length) {
        const len = try self.reader.read(buffer[i..]);
        if (len == 0) return error.EndOfStream;
        i += len;
    }
    return buffer;
}

/// Reads the body of a request into the given `buffer`
/// Returns the length that was written to the buffer.
/// Asserts `buffer` has a size bigger than 0.
pub fn bufferedBody(self: Request, buffer: []u8) !usize {
    std.debug.assert(buffer.len > 0);
    const min = std.math.min(self.content_length, buffer.len);
    return self.reader.read(buffer[0..min]);
}

/// Errors which can occur during the parsing of
/// a HTTP request.
pub const ParseError = error{
    OutOfMemory,
    /// Method is missing or invalid
    InvalidMethod,
    /// URL is missing in status line or invalid
    InvalidUrl,
    /// Protocol in status line is missing or invalid
    InvalidProtocol,
    /// Headers are missing
    MissingHeaders,
    /// Invalid header was found
    IncorrectHeader,
    /// Buffer overflow when parsing an integer
    Overflow,
    /// Invalid character when parsing an integer
    InvalidCharacter,
    /// When the connection has been closed or no more data is available
    EndOfStream,
    /// Provided request's size is bigger than max size (2^32).
    StreamTooLong,
    /// Request headers are too large and do not find in `buffer_size`
    HeadersTooLarge,
    /// Line ending of the requests are corrupted/invalid. According to the http
    /// spec, each line must end with \r\n
    InvalidLineEnding,
    /// When body is incomplete
    InvalidBody,
};

/// Parse accepts an `io.Reader`, it will read all data it contains
/// and tries to parse it into a `Request`. Can return `ParseError` if data is corrupt
/// The memory of the `Request` is owned by the caller and can be freed by using deinit()
/// `buffer_size` is the size that is allocated to parse the request line and headers, any headers
/// bigger than this size will be skipped.
pub fn parse(gpa: *Allocator, reader: anytype, buffer: []u8) (ParseError || @TypeOf(reader).Error)!Request {
    var request: Request = .{
        .method = .get,
        .url = Url{
            .path = "/",
            .raw_path = "/",
            .raw_query = "",
        },
        .raw_header_data = undefined,
        .protocol = .http_1_1,
        .content_length = 0,
        .should_close = false,
        .host = null,
        .arena = gpa,
        .reader = AnyReader.init(&reader),
    };

    var parser = Parser(@TypeOf(reader)).init(buffer, reader);
    while (parser.nextEvent()) |ev| {
        const event = ev orelse break;

        switch (event) {
            .status => |status| {
                request.protocol = Request.Protocol.fromString(status.protocol);
                request.url = Url.init(status.path);
                request.method = Request.Method.fromString(status.method);
            },
            .header => |header| {
                if (request.protocol != .http_1_0 and !request.should_close and std.ascii.eqlIgnoreCase(header.key, "connection")) {
                    if (std.ascii.eqlIgnoreCase(header.value, "close")) request.should_close = true;
                }

                if (request.host == null and std.ascii.eqlIgnoreCase(header.key, "host"))
                    request.host = header.value;
            },
        }
    } else |err| switch (err) {
        else => |e| return e,
    }
    request.content_length = parser.content_length;
    request.raw_header_data = buffer[parser.header_start..parser.header_end];

    return request;
}

fn Parser(ReaderType: anytype) type {
    return struct {
        const Self = @This();

        buffer: []u8,
        index: usize,
        state: std.meta.Tag(Event),
        reader: ReaderType,
        done: bool,
        content_length: usize,
        header_start: usize,
        header_end: usize,

        const Event = union(enum) {
            status: struct {
                method: []const u8,
                path: []const u8,
                protocol: []const u8,
            },
            header: struct {
                key: []const u8,
                value: []const u8,
            },
        };

        const Error = ParseError || ReaderType.Error;

        fn init(buffer: []u8, reader: ReaderType) Self {
            return .{
                .buffer = buffer,
                .reader = reader,
                .state = .status,
                .index = 0,
                .done = false,
                .content_length = 0,
                .header_start = 0,
                .header_end = 0,
            };
        }

        fn nextEvent(self: *Self) Error!?Event {
            if (self.done) return null;

            return switch (self.state) {
                .status => self.parseStatus(),
                .header => self.parseHeader(),
            };
        }

        fn parseStatus(self: *Self) Error!?Event {
            self.state = .header;
            const line = (try self.reader.readUntilDelimiterOrEof(self.buffer, '\n')) orelse return ParseError.EndOfStream;
            self.index += line.len + 1;
            self.header_start = self.index;
            var it = mem.tokenize(try assertLE(line), " ");

            const method = it.next() orelse return ParseError.InvalidMethod;
            const path = it.next() orelse return ParseError.InvalidUrl;
            const protocol = it.next() orelse return ParseError.InvalidProtocol;

            return Event{
                .status = .{
                    .method = method,
                    .path = path,
                    .protocol = protocol,
                },
            };
        }

        fn parseHeader(self: *Self) Error!?Event {
            const line = (try self.reader.readUntilDelimiterOrEof(self.buffer[self.index..], '\n')) orelse return ParseError.EndOfStream;
            self.index += line.len + 1;
            if (line.len == 1 and line[0] == '\r') {
                self.done = true;
                self.header_end = self.index;
                return null;
            }
            var it = mem.tokenize(try assertLE(line), " ");

            const key = try assertKey(it.next() orelse return ParseError.MissingHeaders);
            const value = it.next() orelse return ParseError.IncorrectHeader;

            if (self.content_length == 0 and std.ascii.eqlIgnoreCase("content-length", key))
                self.content_length = try std.fmt.parseInt(usize, value, 10);

            return Event{
                .header = .{
                    .key = key,
                    .value = value,
                },
            };
        }

        fn assertLE(line: []const u8) ParseError![]const u8 {
            if (line.len == 0) return ParseError.InvalidLineEnding;
            const idx = line.len - 1;
            if (line[idx] != '\r') return ParseError.InvalidLineEnding;

            return line[0..idx];
        }

        fn assertKey(key: []const u8) ParseError![]const u8 {
            const idx = key.len - 1;
            if (key[idx] != ':') return ParseError.IncorrectHeader;
            return key[0..idx];
        }
    };
}

test "Basic request parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const contents = "GET /test?test HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "User-Agent: insomnia/7.1.1\r\n" ++
        "Accept: */*\r\n" ++
        "Content-Length: 9\r\n" ++
        "\r\n" ++
        "some body";

    var buf: [4096]u8 = undefined;
    const stream = std.io.fixedBufferStream(contents).reader();
    var request = try parse(&arena.allocator, stream, &buf);

    std.testing.expectEqualStrings("/test", request.url.path);
    std.testing.expectEqual(Request.Protocol.http_1_1, request.protocol);
    std.testing.expectEqual(Request.Method.get, request.method);
    std.testing.expectEqualStrings("some body", try request.body(&arena.allocator));

    var _headers = try request.headers(std.testing.allocator);
    defer {
        var it = _headers.iterator();
        while (it.next()) |header| {
            std.testing.allocator.free(header.key);
            std.testing.allocator.free(header.value);
        }
        _headers.deinit(std.testing.allocator);
    }

    std.testing.expect(_headers.contains("Host"));
    std.testing.expect(_headers.contains("Accept"));
}

test "Request iterator" {
    const _headers = "User-Agent: ApplePieClient/1\r\n" ++
        "Accept: application/json\r\n" ++
        "content-Length: 0\r\n";

    var it = Request.Iterator{
        .slice = _headers,
        .index = 0,
    };
    const header1 = it.next().?;
    const header2 = it.next().?;
    const header3 = it.next().?;
    const header4 = it.next();

    std.testing.expectEqualStrings("User-Agent", header1.key);
    std.testing.expectEqualStrings("ApplePieClient/1", header1.value);
    std.testing.expectEqualStrings("Accept", header2.key);
    std.testing.expectEqualStrings("content-Length", header3.key);
    std.testing.expectEqual(@as(?Request.Header, null), header4);
}
