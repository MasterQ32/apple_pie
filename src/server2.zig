const std = @import("std");
const req = @import("request.zig");
const resp = @import("response.zig");
const net = std.net;
const os = std.os;
const log = std.log.scoped(.apple_pie);
const Response = resp.Response;
const Request = req.Request;
const Allocator = std.mem.Allocator;
const Queue = std.atomic.Queue;

/// User API function signature of a request handler
pub const RequestHandler = fn handle(*Response, Request) anyerror!void;

pub fn listenAndServe(
    /// Memory allocator, for general usage.
    /// Will be used to setup an arena to free any request/response data.
    gpa: *Allocator,
    /// Address the server is listening at
    address: net.Address,
    /// User defined `Request`/`Response` handler
    comptime handler: RequestHandler,
) !void {
    var stream = net.StreamServer.init(.{ .reuse_address = true });
    defer stream.deinit();

    // client queue to clean up clients after connection is broken/finished
    const Client = ClientFn(handler);
    var clients = Queue(*Client).init();

    try stream.listen(address);

    while (true) {
        var connection = stream.accept() catch |err| switch (err) {
            error.ConnectionResetByPeer, error.ConnectionAborted => {
                log.err("Could not accept connection: '{s}'", .{@errorName(err)});
                continue;
            },
            else => return err,
        };

        // setup client connection and handle it
        const client = try gpa.create(Client);
        client.* = Client{
            .stream = connection.stream,
            .frame = async client.run(gpa, &clients),
        };

        while (clients.get()) |node| {
            const data = node.data;
            await data.frame;
            data.stream.close();
            gpa.destroy(data);
        }
    }
}

/// Generic Client handler wrapper around the given `T` of `RequestHandler`.
/// Allows us to wrap our client connection base around the given user defined handler
/// without allocating data on the heap for it
fn ClientFn(comptime T: RequestHandler) type {
    return struct {
        const Self = @This();

        /// Frame of the client, used to ensure its lifetime along the Client's
        frame: @Frame(run),
        /// Streaming connection to the peer
        stream: net.Stream,

        /// Handles the client connection. First parses the client into a `Request`, and then calls the user defined
        /// client handler defined in `T`, and finally sends the final `Response` to the client.
        /// If the connection is below version HTTP1/1, the connection will be broken and no keep-alive is supported.
        /// Same for blocking instances, to ensure multiple clients can connect (synchronously).
        /// NOTE: This is a wrapper function around `handle` so we can catch any errors and handle them accordingly
        /// as we do not want to crash the server when an error occurs.
        fn run(self: *Self, gpa: *Allocator, clients: *Queue(*Self)) void {
            self.handle(gpa, clients) catch |err| {
                log.err("An error occured handling request: '{s}'", .{@errorName(err)});
            };
        }

        /// Call `run` and not this function
        fn handle(self: *Self, gpa: *Allocator, clients: *Queue(*Self)) !void {
            var node: Queue(*Self).Node = .{ .data = self };
            defer clients.put(&node);

            while (true) {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();

                const buffer_size: usize = 4096;
                var stack_allocator = std.heap.stackFallback(buffer_size, &arena.allocator);

                const parsed_request = req.parse(
                    stack_allocator.get(),
                    self.stream.reader(),
                    buffer_size,
                ) catch |err| switch (err) {
                    // not an error, client disconnected
                    error.EndOfStream, error.ConnectionResetByPeer => return,
                    else => return err,
                };

                var body = std.ArrayList(u8).init(stack_allocator.get());
                defer body.deinit();

                var response = Response{
                    .headers = resp.Headers.init(stack_allocator.get()),
                    .socket_writer = std.io.bufferedWriter(self.stream.writer()),
                    .is_flushed = false,
                    .body = body.writer(),
                };
                defer response.headers.deinit();

                try T(&response, parsed_request);

                if (parsed_request.protocol == .http1_1 and parsed_request.host == null) {
                    return response.writeHeader(.BadRequest);
                }

                if (!response.is_flushed) try response.flush();

                if (parsed_request.should_close) return; // close connection
            }
        }
    };
}
