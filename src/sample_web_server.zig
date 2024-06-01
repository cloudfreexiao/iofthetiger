const std = @import("std");
const builtin = @import("builtin");

const Atomic = std.atomic.Value;
const debug = std.debug;
const fifo = std.fifo;
const heap = std.heap;
const log = std.log.scoped(.server);
const mem = std.mem;
const posix = std.posix;
const Thread = std.Thread;

const IO = @import("io").IO;

pub const Config = struct {
    pub const kernel_backlog = 16;
    pub const io_entries = 128;
    pub const server_ip = "127.0.0.1";
    pub const server_port = 9527;
    pub const worker_threads = 5;

    pub const accept_buf_len = 128;
    pub const client_buf_len = 1024 * 512;
    pub const recv_buf_len = 1024;
};

const Queue = fifo.LinearFifo(posix.socket_t, .{ .Static = Config.accept_buf_len });

var running = Atomic(bool).init(true);

const Acceptor = struct {
    accepting: bool,
    mutex: *Thread.Mutex,
    queue: *Queue,
};

pub fn main() !void {
    if (builtin.target.isBSD() or builtin.target.os.tag == .linux) {
        // Handle OS signals for graceful shutdown.
        try addSignalHandlers();
    }

    // Cross-platform IO setup.
    var io = try IO.init(Config.io_entries, 0);
    defer io.deinit();

    // Listener setup
    const address = try std.net.Address.parseIp4(Config.server_ip, Config.server_port);
    const listener = try io.open_socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(listener);
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, Config.kernel_backlog);

    log.info("server listening on IP {s} port {}. CTRL+C to shutdown.", .{ Config.server_ip, Config.server_port });

    // Client socket queue setup.
    var queue_mutex = Thread.Mutex{};
    var queue = Queue.init();

    // Setup thread pool.
    var handles: [Config.worker_threads]Thread = undefined;
    defer for (handles) |h| h.join();
    for (&handles) |*h| h.* = try Thread.spawn(.{}, logError, .{ &queue_mutex, &queue });

    // Accept context setup.
    var acceptor = Acceptor{
        .accepting = true,
        .mutex = &queue_mutex,
        .queue = &queue,
    };

    while (running.load(.monotonic)) {
        // Start accepting.
        var acceptor_completion: IO.Completion = undefined;
        io.accept(*Acceptor, &acceptor, acceptCallback, &acceptor_completion, listener);

        // Wait while accepting.
        while (acceptor.accepting) try io.tick();

        // Reset accepting flag.
        acceptor.accepting = true;
    }
}

fn acceptCallback(
    acceptor_ptr: *Acceptor,
    completion: *IO.Completion,
    result: IO.AcceptError!posix.socket_t,
) void {
    _ = completion;
    const accepted_sock = result catch @panic("accept error");
    log.debug("Accepted socket fd: {}", .{accepted_sock});

    // Dispatch
    {
        acceptor_ptr.mutex.lock();
        defer acceptor_ptr.mutex.unlock();
        acceptor_ptr.queue.writeItem(accepted_sock) catch @panic("queue.writeItem");
    }

    // Signal we're done.
    acceptor_ptr.accepting = false;
}

fn logError(queue_mutex: *Thread.Mutex, queue: *Queue) void {
    handleClient(queue_mutex, queue) catch |err| {
        std.log.err("error handling client request: {}", .{err});
    };
}

const Client = struct {
    allocator: mem.Allocator,
    completion: IO.Completion,
    io: *IO,
    recv_buf: [Config.recv_buf_len]u8,
    socket: posix.socket_t,
    thread_id: Thread.Id,
};

fn handleClient(queue_mutex: *Thread.Mutex, queue: *Queue) !void {
    const thread_id = Thread.getCurrentId();

    // Cross-platform IO setup.
    var io = try IO.init(Config.io_entries, 0);
    defer io.deinit();

    // Per thread allocator
    var client_buf: [Config.client_buf_len]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&client_buf);
    const allocator = fba.allocator();

    while (running.load(.monotonic)) {
        // Get next accepted client socket.
        const maybe_socket: ?posix.socket_t = blk: {
            queue_mutex.lock();
            defer queue_mutex.unlock();
            break :blk queue.readItem();
        };

        if (maybe_socket) |socket| {
            // Allocate and init new client.
            var client_ptr = try allocator.create(Client);
            client_ptr.allocator = allocator;
            client_ptr.io = &io;
            client_ptr.completion = undefined;
            client_ptr.recv_buf = undefined;
            client_ptr.socket = socket;
            client_ptr.thread_id = thread_id;

            // Receive from client.
            io.recv(
                *Client,
                client_ptr,
                recvCallback,
                &client_ptr.completion,
                socket,
                &client_ptr.recv_buf,
            );
        }

        try io.tick();
    }
}

fn recvCallback(
    client_ptr: *Client,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    const received = result catch |err| blk: {
        log.err("recvCallback error: {}", .{err});
        break :blk 0;
    };
    log.debug("{}: Received {} bytes from {}", .{ client_ptr.thread_id, received, client_ptr.socket });

    if (received == 0) {
        // Client connection closed.
        client_ptr.io.close(
            *Client,
            client_ptr,
            closeCallback,
            completion,
            client_ptr.socket,
        );

        return;
    }

    const response =
        \\HTTP/1.1 200 OK
        \\Connection: Keep-Alive
        \\Keep-Alive: timeout=1
        \\Content-Type: text/plain
        \\Content-Length: 6
        \\Server: server/0.1.0
        \\
        \\Hello
        \\
    ;

    client_ptr.io.send(
        *Client,
        client_ptr,
        sendCallback,
        completion,
        client_ptr.socket,
        response,
    );
}

fn sendCallback(
    client_ptr: *Client,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    const sent = result catch @panic("sendCallback");
    log.debug("{}: Sent {} to {}", .{ client_ptr.thread_id, sent, client_ptr.socket });

    // Try to receive from client again (keep-alive).
    client_ptr.io.recv(
        *Client,
        client_ptr,
        recvCallback,
        completion,
        client_ptr.socket,
        &client_ptr.recv_buf,
    );
}

fn closeCallback(
    client_ptr: *Client,
    completion: *IO.Completion,
    result: IO.CloseError!void,
) void {
    _ = completion;
    _ = result catch @panic("closeCallback");
    log.debug("{}: Closed {}", .{ client_ptr.thread_id, client_ptr.socket });
    client_ptr.allocator.destroy(client_ptr);
}

fn addSignalHandlers() !void {
    // Ignore broken pipes
    {
        var act = posix.Sigaction{
            .handler = .{
                .handler = posix.SIG.IGN,
            },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        try posix.sigaction(posix.SIG.PIPE, &act, null);
    }

    // Catch SIGINT/SIGTERM for proper shutdown
    {
        var act = posix.Sigaction{
            .handler = .{
                .handler = struct {
                    fn wrapper(sig: c_int) callconv(.C) void {
                        log.info("Caught signal {d}; Shutting down...", .{sig});
                        running.store(false, .release);
                    }
                }.wrapper,
            },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        try posix.sigaction(posix.SIG.TERM, &act, null);
        try posix.sigaction(posix.SIG.INT, &act, null);
    }
}
