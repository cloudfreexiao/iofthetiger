const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;
const assert = std.debug.assert;
const log = std.log.scoped(.io);

const constants = @import("../constants.zig");
const FIFO = @import("../fifo.zig").FIFO;
const Time = @import("../time.zig").Time;
const bufferLimit = @import("../io.zig").bufferLimit;
const DirectIO = @import("../io.zig").DirectIO;

pub const IO = struct {
    iocp: windows.HANDLE,
    timer: Time = .{},
    io_pending: usize = 0,
    timeouts: FIFO(Completion) = .{ .name = "io_timeouts" },
    completed: FIFO(Completion) = .{ .name = "io_completed" },

    pub fn init(entries: u12, flags: u32) !IO {
        _ = entries;
        _ = flags;

        _ = try windows.WSAStartup(2, 2);
        errdefer windows.WSACleanup() catch unreachable;

        const iocp = try windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 0);
        return IO{ .iocp = iocp };
    }

    pub fn deinit(self: *IO) void {
        assert(self.iocp != windows.INVALID_HANDLE_VALUE);
        windows.CloseHandle(self.iocp);
        self.iocp = windows.INVALID_HANDLE_VALUE;

        windows.WSACleanup() catch unreachable;
    }

    pub fn tick(self: *IO) !void {
        return self.flush(.non_blocking);
    }

    pub fn run_for_ns(self: *IO, nanoseconds: u63) !void {
        const Callback = struct {
            fn on_timeout(timed_out: *bool, completion: *Completion, result: TimeoutError!void) void {
                _ = result catch unreachable;
                _ = completion;
                timed_out.* = true;
            }
        };

        var timed_out = false;
        var completion: Completion = undefined;
        self.timeout(*bool, &timed_out, Callback.on_timeout, &completion, nanoseconds);

        while (!timed_out) {
            try self.flush(.blocking);
        }
    }

    const FlushMode = enum {
        blocking,
        non_blocking,
    };

    fn flush(self: *IO, mode: FlushMode) !void {
        if (self.completed.empty()) {
            // Compute how long to poll by flushing timeout completions.
            // NOTE: this may push to completed queue
            var timeout_ms: ?windows.DWORD = null;
            if (self.flush_timeouts()) |expires_ns| {
                // 0ns expires should have been completed not returned
                assert(expires_ns != 0);
                // Round up sub-millisecond expire times to the next millisecond
                const expires_ms = (expires_ns + (std.time.ns_per_ms / 2)) / std.time.ns_per_ms;
                // Saturating cast to DWORD milliseconds
                const expires = std.math.cast(windows.DWORD, expires_ms) orelse std.math.maxInt(windows.DWORD);
                // max DWORD is reserved for INFINITE so cap the cast at max - 1
                timeout_ms = if (expires == windows.INFINITE) expires - 1 else expires;
            }

            // Poll for IO iff theres IO pending and flush_timeouts() found no ready completions
            if (self.io_pending > 0 and self.completed.empty()) {
                // In blocking mode, we're always waiting at least until the timeout by run_for_ns.
                // In non-blocking mode, we shouldn't wait at all.
                const io_timeout = switch (mode) {
                    .blocking => timeout_ms orelse @panic("IO.flush blocking unbounded"),
                    .non_blocking => 0,
                };

                var events: [64]windows.OVERLAPPED_ENTRY = undefined;
                const num_events: u32 = windows.GetQueuedCompletionStatusEx(
                    self.iocp,
                    &events,
                    io_timeout,
                    false, // non-alertable wait
                ) catch |err| switch (err) {
                    error.Timeout => 0,
                    error.Aborted => unreachable,
                    else => |e| return e,
                };

                assert(self.io_pending >= num_events);
                self.io_pending -= num_events;

                for (events[0..num_events]) |event| {
                    const raw_overlapped = event.lpOverlapped;
                    const overlapped: *Completion.Overlapped = @fieldParentPtr("raw", raw_overlapped);
                    const completion = overlapped.completion;
                    completion.next = null;
                    self.completed.push(completion);
                }
            }
        }

        // Dequeue and invoke all the completions currently ready.
        // Must read all `completions` before invoking the callbacks
        // as the callbacks could potentially submit more completions.
        var completed = self.completed;
        self.completed.reset();
        while (completed.pop()) |completion| {
            (completion.callback)(Completion.Context{
                .io = self,
                .completion = completion,
            });
        }
    }

    fn flush_timeouts(self: *IO) ?u64 {
        var min_expires: ?u64 = null;
        var current_time: ?u64 = null;
        var timeouts: ?*Completion = self.timeouts.peek();

        // iterate through the timeouts, returning min_expires at the end
        while (timeouts) |completion| {
            timeouts = completion.next;

            // lazily get the current time
            const now = current_time orelse self.timer.monotonic();
            current_time = now;

            // move the completion to completed if it expired
            if (now >= completion.operation.timeout.deadline) {
                self.timeouts.remove(completion);
                self.completed.push(completion);
                continue;
            }

            // if it's still waiting, update min_timeout
            const expires = completion.operation.timeout.deadline - now;
            if (min_expires) |current_min_expires| {
                min_expires = @min(expires, current_min_expires);
            } else {
                min_expires = expires;
            }
        }

        return min_expires;
    }

    /// This struct holds the data needed for a single IO operation
    pub const Completion = struct {
        next: ?*Completion,
        context: ?*anyopaque,
        callback: *const fn (Context) void,
        operation: Operation,

        const Context = struct {
            io: *IO,
            completion: *Completion,
        };

        const Overlapped = struct {
            raw: windows.OVERLAPPED,
            completion: *Completion,
        };

        const Transfer = struct {
            socket: posix.socket_t,
            buf: windows.ws2_32.WSABUF,
            overlapped: Overlapped,
            pending: bool,
        };

        const Operation = union(enum) {
            accept: struct {
                overlapped: Overlapped,
                listen_socket: posix.socket_t,
                client_socket: posix.socket_t,
                addr_buffer: [(@sizeOf(std.net.Address) + 16) * 2]u8 align(4),
            },
            connect: struct {
                socket: posix.socket_t,
                address: std.net.Address,
                overlapped: Overlapped,
                pending: bool,
            },
            send: Transfer,
            recv: Transfer,
            read: struct {
                fd: posix.fd_t,
                buf: [*]u8,
                len: u32,
                offset: u64,
            },
            write: struct {
                fd: posix.fd_t,
                buf: [*]const u8,
                len: u32,
                offset: u64,
            },
            close: struct {
                fd: posix.fd_t,
            },
            timeout: struct {
                deadline: u64,
            },
        };
    };

    fn submit(
        self: *IO,
        context: anytype,
        comptime callback: anytype,
        completion: *Completion,
        comptime op_tag: std.meta.Tag(Completion.Operation),
        op_data: anytype,
        comptime OperationImpl: type,
    ) void {
        const Callback = struct {
            fn onComplete(ctx: Completion.Context) void {
                // Perform the operation and get the result
                const data = &@field(ctx.completion.operation, @tagName(op_tag));
                const result = OperationImpl.do_operation(ctx, data);

                // For OVERLAPPED IO, error.WouldBlock assumes that it will be completed by IOCP.
                switch (op_tag) {
                    .accept, .read, .recv, .connect, .write, .send => {
                        _ = result catch |err| switch (err) {
                            error.WouldBlock => {
                                ctx.io.io_pending += 1;
                                return;
                            },
                            else => {},
                        };
                    },
                    else => {},
                }

                // The completion is finally ready to invoke the callback
                callback(
                    @ptrCast(@alignCast(ctx.completion.context)),
                    ctx.completion,
                    result,
                );
            }
        };

        // Setup the completion with the callback wrapper above
        completion.* = .{
            .next = null,
            .context = @as(?*anyopaque, @ptrCast(context)),
            .callback = Callback.onComplete,
            .operation = @unionInit(Completion.Operation, @tagName(op_tag), op_data),
        };

        // Submit the completion onto the right queue
        switch (op_tag) {
            .timeout => self.timeouts.push(completion),
            else => self.completed.push(completion),
        }
    }

    pub const AcceptError = posix.AcceptError || posix.SetSockOptError;

    pub fn accept(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: AcceptError!posix.socket_t,
        ) void,
        completion: *Completion,
        socket: posix.socket_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .accept,
            .{
                .overlapped = undefined,
                .listen_socket = socket,
                .client_socket = INVALID_SOCKET,
                .addr_buffer = undefined,
            },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) AcceptError!posix.socket_t {
                    var flags: windows.DWORD = undefined;
                    var transferred: windows.DWORD = undefined;

                    const rc = switch (op.client_socket) {
                        // When first called, the client_socket is invalid so we start the op.
                        INVALID_SOCKET => blk: {
                            // Create the socket that will be used for accept.
                            op.client_socket = ctx.io.open_socket(
                                posix.AF.INET,
                                posix.SOCK.STREAM,
                                posix.IPPROTO.TCP,
                            ) catch |err| switch (err) {
                                error.AddressFamilyNotSupported, error.ProtocolNotSupported => unreachable,
                                else => |e| return e,
                            };

                            var sync_bytes_read: windows.DWORD = undefined;
                            op.overlapped = .{
                                .raw = std.mem.zeroes(windows.OVERLAPPED),
                                .completion = ctx.completion,
                            };

                            // Start the asynchronous accept with the created socket.
                            break :blk windows.ws2_32.AcceptEx(
                                op.listen_socket,
                                op.client_socket,
                                &op.addr_buffer,
                                0,
                                @sizeOf(std.net.Address) + 16,
                                @sizeOf(std.net.Address) + 16,
                                &sync_bytes_read,
                                &op.overlapped.raw,
                            );
                        },
                        // Called after accept was started, so get the result
                        else => windows.ws2_32.WSAGetOverlappedResult(
                            op.listen_socket,
                            &op.overlapped.raw,
                            &transferred,
                            windows.FALSE, // dont wait
                            &flags,
                        ),
                    };

                    // return the socket if we succeed in accepting.
                    if (rc != windows.FALSE) {
                        // enables getsockopt, setsockopt, getsockname, getpeername
                        _ = windows.ws2_32.setsockopt(
                            op.client_socket,
                            windows.ws2_32.SOL.SOCKET,
                            windows.ws2_32.SO.UPDATE_ACCEPT_CONTEXT,
                            null,
                            0,
                        );

                        return op.client_socket;
                    }

                    // destroy the client_socket we created if we get a non WouldBlock error
                    errdefer |err| switch (err) {
                        error.WouldBlock => {},
                        else => {
                            posix.close(op.client_socket);
                            op.client_socket = INVALID_SOCKET;
                        },
                    };

                    return switch (windows.ws2_32.WSAGetLastError()) {
                        .WSA_IO_PENDING, .WSAEWOULDBLOCK, .WSA_IO_INCOMPLETE => error.WouldBlock,
                        .WSANOTINITIALISED => unreachable, // WSAStartup() was called
                        .WSAENETDOWN => unreachable, // WinSock error
                        .WSAENOTSOCK => error.FileDescriptorNotASocket,
                        .WSAEOPNOTSUPP => error.OperationNotSupported,
                        .WSA_INVALID_HANDLE => unreachable, // we dont use hEvent in OVERLAPPED
                        .WSAEFAULT, .WSA_INVALID_PARAMETER => unreachable, // params should be ok
                        .WSAECONNRESET => error.ConnectionAborted,
                        .WSAEMFILE => unreachable, // we create our own descriptor so its available
                        .WSAENOBUFS => error.SystemResources,
                        .WSAEINTR, .WSAEINPROGRESS => unreachable, // no blocking calls
                        else => |err| windows.unexpectedWSAError(err),
                    };
                }
            },
        );
    }

    pub const CloseError = error{
        FileDescriptorInvalid,
        DiskQuota,
        InputOutput,
        NoSpaceLeft,
    } || posix.UnexpectedError;

    pub const ConnectError = posix.ConnectError || error{FileDescriptorNotASocket};

    pub fn connect(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ConnectError!void,
        ) void,
        completion: *Completion,
        socket: posix.socket_t,
        address: std.net.Address,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .connect,
            .{
                .socket = socket,
                .address = address,
                .overlapped = undefined,
                .pending = false,
            },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) ConnectError!void {
                    var flags: windows.DWORD = undefined;
                    var transferred: windows.DWORD = undefined;

                    const rc = blk: {
                        // Poll for the result if we've already started the connect op.
                        if (op.pending) {
                            break :blk windows.ws2_32.WSAGetOverlappedResult(
                                op.socket,
                                &op.overlapped.raw,
                                &transferred,
                                windows.FALSE, // dont wait
                                &flags,
                            );
                        }

                        // ConnectEx requires the socket to be initially bound (INADDR_ANY)
                        const inaddr_any = std.mem.zeroes([4]u8);
                        const bind_addr = std.net.Address.initIp4(inaddr_any, 0);
                        posix.bind(
                            op.socket,
                            &bind_addr.any,
                            bind_addr.getOsSockLen(),
                        ) catch |err| switch (err) {
                            error.AccessDenied => unreachable,
                            error.SymLinkLoop => unreachable,
                            error.NameTooLong => unreachable,
                            error.NotDir => unreachable,
                            error.ReadOnlyFileSystem => unreachable,
                            error.NetworkSubsystemFailed => unreachable,
                            error.AlreadyBound => unreachable,
                            else => |e| return e,
                        };

                        const LPFN_CONNECTEX = *const fn (
                            Socket: windows.ws2_32.SOCKET,
                            SockAddr: *const windows.ws2_32.sockaddr,
                            SockLen: posix.socklen_t,
                            SendBuf: ?*const anyopaque,
                            SendBufLen: windows.DWORD,
                            BytesSent: *windows.DWORD,
                            Overlapped: *windows.OVERLAPPED,
                        ) callconv(windows.WINAPI) windows.BOOL;

                        // Find the ConnectEx function by dynamically looking it up on the socket.
                        // TODO: use `windows.loadWinsockExtensionFunction` once the function
                        //       pointer is no longer required to be comptime.
                        var connect_ex: LPFN_CONNECTEX = undefined;
                        var num_bytes: windows.DWORD = undefined;
                        const guid = windows.ws2_32.WSAID_CONNECTEX;
                        switch (windows.ws2_32.WSAIoctl(
                            op.socket,
                            windows.ws2_32.SIO_GET_EXTENSION_FUNCTION_POINTER,
                            @as(*const anyopaque, @ptrCast(&guid)),
                            @sizeOf(windows.GUID),
                            @as(*anyopaque, @ptrCast(&connect_ex)),
                            @sizeOf(LPFN_CONNECTEX),
                            &num_bytes,
                            null,
                            null,
                        )) {
                            windows.ws2_32.SOCKET_ERROR => switch (windows.ws2_32.WSAGetLastError()) {
                                .WSAEOPNOTSUPP => unreachable,
                                .WSAENOTSOCK => unreachable,
                                else => |err| return windows.unexpectedWSAError(err),
                            },
                            else => assert(num_bytes == @sizeOf(LPFN_CONNECTEX)),
                        }

                        op.pending = true;
                        op.overlapped = .{
                            .raw = std.mem.zeroes(windows.OVERLAPPED),
                            .completion = ctx.completion,
                        };

                        // Start the connect operation.
                        break :blk (connect_ex)(
                            op.socket,
                            &op.address.any,
                            op.address.getOsSockLen(),
                            null,
                            0,
                            &transferred,
                            &op.overlapped.raw,
                        );
                    };

                    // return if we succeeded in connecting
                    if (rc != windows.FALSE) {
                        // enables getsockopt, setsockopt, getsockname, getpeername
                        _ = windows.ws2_32.setsockopt(
                            op.socket,
                            windows.ws2_32.SOL.SOCKET,
                            windows.ws2_32.SO.UPDATE_CONNECT_CONTEXT,
                            null,
                            0,
                        );

                        return;
                    }

                    return switch (windows.ws2_32.WSAGetLastError()) {
                        .WSA_IO_PENDING, .WSAEWOULDBLOCK, .WSA_IO_INCOMPLETE, .WSAEALREADY => error.WouldBlock,
                        .WSANOTINITIALISED => unreachable, // WSAStartup() was called
                        .WSAENETDOWN => unreachable, // network subsystem is down
                        .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                        .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                        .WSAECONNREFUSED => error.ConnectionRefused,
                        .WSAEFAULT => unreachable, // all addresses should be valid
                        .WSAEINVAL => unreachable, // invalid socket type
                        .WSAEHOSTUNREACH, .WSAENETUNREACH => error.NetworkUnreachable,
                        .WSAENOBUFS => error.SystemResources,
                        .WSAENOTSOCK => unreachable, // socket is not bound or is listening
                        .WSAETIMEDOUT => error.ConnectionTimedOut,
                        .WSA_INVALID_HANDLE => unreachable, // we dont use hEvent in OVERLAPPED
                        else => |err| windows.unexpectedWSAError(err),
                    };
                }
            },
        );
    }

    pub const SendError = posix.SendError;

    pub fn send(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: SendError!usize,
        ) void,
        completion: *Completion,
        socket: posix.socket_t,
        buffer: []const u8,
    ) void {
        const transfer = Completion.Transfer{
            .socket = socket,
            .buf = windows.ws2_32.WSABUF{
                .len = @as(u32, @intCast(bufferLimit(buffer.len))),
                .buf = @constCast(buffer.ptr),
            },
            .overlapped = undefined,
            .pending = false,
        };

        self.submit(
            context,
            callback,
            completion,
            .send,
            transfer,
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) SendError!usize {
                    var flags: windows.DWORD = undefined;
                    var transferred: windows.DWORD = undefined;

                    const rc = blk: {
                        // Poll for the result if we've already started the send op.
                        if (op.pending) {
                            break :blk windows.ws2_32.WSAGetOverlappedResult(
                                op.socket,
                                &op.overlapped.raw,
                                &transferred,
                                windows.FALSE, // dont wait
                                &flags,
                            );
                        }

                        op.pending = true;
                        op.overlapped = .{
                            .raw = std.mem.zeroes(windows.OVERLAPPED),
                            .completion = ctx.completion,
                        };

                        // Start the send operation.
                        break :blk switch (windows.ws2_32.WSASend(
                            op.socket,
                            @as([*]windows.ws2_32.WSABUF, @ptrCast(&op.buf)),
                            1, // one buffer
                            &transferred,
                            0, // no flags
                            &op.overlapped.raw,
                            null,
                        )) {
                            windows.ws2_32.SOCKET_ERROR => @as(windows.BOOL, windows.FALSE),
                            0 => windows.TRUE,
                            else => unreachable,
                        };
                    };

                    // Return bytes transferred on success.
                    if (rc != windows.FALSE)
                        return transferred;

                    return switch (windows.ws2_32.WSAGetLastError()) {
                        .WSA_IO_PENDING, .WSAEWOULDBLOCK, .WSA_IO_INCOMPLETE => error.WouldBlock,
                        .WSANOTINITIALISED => unreachable, // WSAStartup() was called
                        .WSA_INVALID_HANDLE => unreachable, // we dont use OVERLAPPED.hEvent
                        .WSA_INVALID_PARAMETER => unreachable, // parameters are fine
                        .WSAECONNABORTED => error.ConnectionResetByPeer,
                        .WSAECONNRESET => error.ConnectionResetByPeer,
                        .WSAEFAULT => unreachable, // invalid buffer
                        .WSAEINTR => unreachable, // this is non blocking
                        .WSAEINPROGRESS => unreachable, // this is non blocking
                        .WSAEINVAL => unreachable, // invalid socket type
                        .WSAEMSGSIZE => error.MessageTooBig,
                        .WSAENETDOWN => error.NetworkSubsystemFailed,
                        .WSAENETRESET => error.ConnectionResetByPeer,
                        .WSAENOBUFS => error.SystemResources,
                        .WSAENOTCONN => error.FileDescriptorNotASocket,
                        .WSAEOPNOTSUPP => unreachable, // we dont use MSG_OOB or MSG_PARTIAL
                        .WSAESHUTDOWN => error.BrokenPipe,
                        .WSA_OPERATION_ABORTED => unreachable, // operation was cancelled
                        else => |err| windows.unexpectedWSAError(err),
                    };
                }
            },
        );
    }

    pub const RecvError = posix.RecvFromError;

    pub fn recv(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: RecvError!usize,
        ) void,
        completion: *Completion,
        socket: posix.socket_t,
        buffer: []u8,
    ) void {
        const transfer = Completion.Transfer{
            .socket = socket,
            .buf = windows.ws2_32.WSABUF{
                .len = @as(u32, @intCast(bufferLimit(buffer.len))),
                .buf = buffer.ptr,
            },
            .overlapped = undefined,
            .pending = false,
        };

        self.submit(
            context,
            callback,
            completion,
            .recv,
            transfer,
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) RecvError!usize {
                    var flags: windows.DWORD = 0; // used both as input and output
                    var transferred: windows.DWORD = undefined;

                    const rc = blk: {
                        // Poll for the result if we've already started the recv op.
                        if (op.pending) {
                            break :blk windows.ws2_32.WSAGetOverlappedResult(
                                op.socket,
                                &op.overlapped.raw,
                                &transferred,
                                windows.FALSE, // dont wait
                                &flags,
                            );
                        }

                        op.pending = true;
                        op.overlapped = .{
                            .raw = std.mem.zeroes(windows.OVERLAPPED),
                            .completion = ctx.completion,
                        };

                        // Start the recv operation.
                        break :blk switch (windows.ws2_32.WSARecv(
                            op.socket,
                            @as([*]windows.ws2_32.WSABUF, @ptrCast(&op.buf)),
                            1, // one buffer
                            &transferred,
                            &flags,
                            &op.overlapped.raw,
                            null,
                        )) {
                            windows.ws2_32.SOCKET_ERROR => @as(windows.BOOL, windows.FALSE),
                            0 => windows.TRUE,
                            else => unreachable,
                        };
                    };

                    // Return bytes received on success.
                    if (rc != windows.FALSE)
                        return transferred;

                    return switch (windows.ws2_32.WSAGetLastError()) {
                        .WSA_IO_PENDING, .WSAEWOULDBLOCK, .WSA_IO_INCOMPLETE => error.WouldBlock,
                        .WSANOTINITIALISED => unreachable, // WSAStartup() was called
                        .WSA_INVALID_HANDLE => unreachable, // we dont use OVERLAPPED.hEvent
                        .WSA_INVALID_PARAMETER => unreachable, // parameters are fine
                        .WSAECONNABORTED => error.ConnectionRefused,
                        .WSAECONNRESET => error.ConnectionResetByPeer,
                        .WSAEDISCON => unreachable, // we only stream sockets
                        .WSAEFAULT => unreachable, // invalid buffer
                        .WSAEINTR => unreachable, // this is non blocking
                        .WSAEINPROGRESS => unreachable, // this is non blocking
                        .WSAEINVAL => unreachable, // invalid socket type
                        .WSAEMSGSIZE => error.MessageTooBig,
                        .WSAENETDOWN => error.NetworkSubsystemFailed,
                        .WSAENETRESET => error.ConnectionResetByPeer,
                        .WSAENOTCONN => error.SocketNotConnected,
                        .WSAEOPNOTSUPP => unreachable, // we dont use MSG_OOB or MSG_PARTIAL
                        .WSAESHUTDOWN => error.SocketNotConnected,
                        .WSAETIMEDOUT => error.ConnectionRefused,
                        .WSA_OPERATION_ABORTED => unreachable, // operation was cancelled
                        else => |err| windows.unexpectedWSAError(err),
                    };
                }
            },
        );
    }

    pub const ReadError = error{
        WouldBlock,
        NotOpenForReading,
        ConnectionResetByPeer,
        Alignment,
        InputOutput,
        IsDir,
        SystemResources,
        Unseekable,
        ConnectionTimedOut,
    } || posix.UnexpectedError;

    pub fn read(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ReadError!usize,
        ) void,
        completion: *Completion,
        fd: posix.fd_t,
        buffer: []u8,
        offset: u64,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .read,
            .{
                .fd = fd,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(bufferLimit(buffer.len))),
                .offset = offset,
            },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) ReadError!usize {
                    // Do a synchronous read for now.
                    _ = ctx;
                    return posix.pread(op.fd, op.buf[0..op.len], op.offset) catch |err| switch (err) {
                        error.OperationAborted => unreachable,
                        error.BrokenPipe => unreachable,
                        error.ConnectionTimedOut => unreachable,
                        error.AccessDenied => error.InputOutput,
                        error.NetNameDeleted => unreachable,
                        else => |e| e,
                    };
                }
            },
        );
    }

    pub const WriteError = posix.PWriteError;

    pub fn write(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: WriteError!usize,
        ) void,
        completion: *Completion,
        fd: posix.fd_t,
        buffer: []const u8,
        offset: u64,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .write,
            .{
                .fd = fd,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(bufferLimit(buffer.len))),
                .offset = offset,
            },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) WriteError!usize {
                    // Do a synchronous write for now.
                    _ = ctx;
                    return posix.pwrite(op.fd, op.buf[0..op.len], op.offset);
                }
            },
        );
    }

    pub fn close(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CloseError!void,
        ) void,
        completion: *Completion,
        fd: posix.fd_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .close,
            .{ .fd = fd },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) CloseError!void {
                    _ = ctx;

                    // Check if the fd is a SOCKET by seeing if getsockopt() returns ENOTSOCK
                    // https://stackoverflow.com/a/50981652
                    const socket: posix.socket_t = @ptrCast(op.fd);
                    getsockoptError(socket) catch |err| switch (err) {
                        error.FileDescriptorNotASocket => return windows.CloseHandle(op.fd),
                        else => {},
                    };

                    posix.close(socket);
                }
            },
        );
    }

    pub const TimeoutError = error{Canceled} || posix.UnexpectedError;

    pub fn timeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: TimeoutError!void,
        ) void,
        completion: *Completion,
        nanoseconds: u63,
    ) void {
        // Special case a zero timeout as a yield.
        if (nanoseconds == 0) {
            completion.* = .{
                .next = null,
                .context = @ptrCast(context),
                .operation = undefined,
                .callback = struct {
                    fn on_complete(ctx: Completion.Context) void {
                        const _context: Context = @ptrCast(@alignCast(ctx.completion.context));
                        callback(_context, ctx.completion, {});
                    }
                }.on_complete,
            };

            self.completed.push(completion);
            return;
        }

        self.submit(
            context,
            callback,
            completion,
            .timeout,
            .{ .deadline = self.timer.monotonic() + nanoseconds },
            struct {
                fn do_operation(ctx: Completion.Context, op: anytype) TimeoutError!void {
                    _ = ctx;
                    _ = op;
                    return;
                }
            },
        );
    }

    pub const INVALID_SOCKET = windows.ws2_32.INVALID_SOCKET;

    /// Creates a socket that can be used for async operations with the IO instance.
    pub fn open_socket(self: *IO, family: u32, sock_type: u32, protocol: u32) !posix.socket_t {
        // SOCK_NONBLOCK | SOCK_CLOEXEC
        var flags: windows.DWORD = 0;
        flags |= windows.ws2_32.WSA_FLAG_OVERLAPPED;
        flags |= windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;

        const socket = try windows.WSASocketW(
            @as(i32, @bitCast(family)),
            @as(i32, @bitCast(sock_type)),
            @as(i32, @bitCast(protocol)),
            null,
            0,
            flags,
        );
        errdefer posix.close(socket);

        const socket_iocp = try windows.CreateIoCompletionPort(socket, self.iocp, 0, 0);
        assert(socket_iocp == self.iocp);

        // Ensure that synchronous IO completion doesn't queue an unneeded overlapped
        // and that the event for the socket (WaitForSingleObject) doesn't need to be set.
        var mode: windows.BYTE = 0;
        mode |= windows.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS;
        mode |= windows.FILE_SKIP_SET_EVENT_ON_HANDLE;

        const handle = @as(windows.HANDLE, @ptrCast(socket));
        try windows.SetFileCompletionNotificationModes(handle, mode);

        return socket;
    }

    /// Opens a directory with read only access.
    pub fn open_dir(dir_path: []const u8) !posix.fd_t {
        const dir = try std.fs.cwd().openDir(dir_path, .{});
        return dir.fd;
    }

    pub const INVALID_FILE = windows.INVALID_HANDLE_VALUE;

    fn open_file_handle(relative_path: []const u8, method: enum { create, open }) !posix.fd_t {
        const path_w = try windows.sliceToPrefixedFileW(relative_path);

        // FILE_CREATE = O_CREAT | O_EXCL
        var creation_disposition: windows.DWORD = 0;
        switch (method) {
            .create => {
                creation_disposition = windows.FILE_CREATE;
                log.info("creating \"{s}\"...", .{relative_path});
            },
            .open => {
                creation_disposition = windows.OPEN_EXISTING;
                log.info("opening \"{s}\"...", .{relative_path});
            },
        }

        // O_EXCL
        const shared_mode: windows.DWORD = 0;

        // O_RDWR
        var access_mask: windows.DWORD = 0;
        access_mask |= windows.GENERIC_READ;
        access_mask |= windows.GENERIC_WRITE;

        // O_DIRECT | O_DSYNC
        var attributes: windows.DWORD = 0;
        attributes |= windows.FILE_FLAG_NO_BUFFERING;
        attributes |= windows.FILE_FLAG_WRITE_THROUGH;

        // This is critical as we rely on O_DSYNC for fsync() whenever we write to the file:
        assert((attributes & windows.FILE_FLAG_WRITE_THROUGH) > 0);

        // TODO: Add ReadFileEx/WriteFileEx support.
        // Not currently needed for O_DIRECT disk IO.
        // attributes |= windows.FILE_FLAG_OVERLAPPED;

        const handle = windows.kernel32.CreateFileW(
            path_w.span(),
            access_mask,
            shared_mode,
            null, // no security attributes required
            creation_disposition,
            attributes,
            null, // no existing template file
        );

        if (handle == windows.INVALID_HANDLE_VALUE) {
            return switch (windows.kernel32.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .SHARING_VIOLATION, .ACCESS_DENIED => error.AccessDenied,
                else => |err| {
                    log.warn("CreateFileW(): {}", .{err});
                    return windows.unexpectedError(err);
                },
            };
        }

        return handle;
    }

    /// Opens or creates a journal file:
    /// - For reading and writing.
    /// - For Direct I/O (required on windows).
    /// - Obtains an advisory exclusive lock to the file descriptor.
    /// - Allocates the file contiguously on disk if this is supported by the file system.
    /// - Ensures that the file data is durable on disk.
    ///   The caller is responsible for ensuring that the parent directory inode is durable.
    /// - Verifies that the file size matches the expected file size before returning.
    pub fn open_file(
        dir_handle: posix.fd_t,
        relative_path: []const u8,
        size: u64,
        method: enum { create, create_or_open, open },
        direct_io: DirectIO,
    ) !posix.fd_t {
        assert(relative_path.len > 0);
        assert(size % constants.sector_size == 0);
        // On windows, assume that Direct IO is always available.
        _ = direct_io;

        const handle = switch (method) {
            .open => try open_file_handle(relative_path, .open),
            .create => try open_file_handle(relative_path, .create),
            .create_or_open => open_file_handle(relative_path, .open) catch |err| switch (err) {
                error.FileNotFound => try open_file_handle(relative_path, .create),
                else => return err,
            },
        };
        errdefer windows.CloseHandle(handle);

        // Obtain an advisory exclusive lock
        // even when we haven't given shared access to other processes.
        fs_lock(handle, size) catch |err| switch (err) {
            error.WouldBlock => @panic("another process holds the data file lock"),
            else => return err,
        };

        // Ask the file system to allocate contiguous sectors for the file (if possible):
        if (method == .create) {
            log.info("allocating {}...", .{std.fmt.fmtIntSizeBin(size)});
            fs_allocate(handle, size) catch {
                log.warn("file system failed to preallocate the file memory", .{});
                log.info("allocating by writing to the last sector of the file instead...", .{});
                const sector_size = constants.sector_size;
                const sector: [sector_size]u8 align(sector_size) = [_]u8{0} ** sector_size;

                // Handle partial writes where the physical sector is less than a logical sector:
                const write_offset = size - sector.len;
                var written: usize = 0;
                while (written < sector.len) {
                    written += try posix.pwrite(handle, sector[written..], write_offset + written);
                }
            };
        }

        // The best fsync strategy is always to fsync before reading because this prevents us from
        // making decisions on data that was never durably written by a previously crashed process.
        // We therefore always fsync when we open the path, also to wait for any pending O_DSYNC.
        // Thanks to Alex Miller from FoundationDB for diving into our source and pointing this out.
        try posix.fsync(handle);

        // We cannot fsync the directory handle on Windows.
        // We have no way to open a directory with write access.
        //
        // try posix.fsync(dir_handle);
        _ = dir_handle;

        const file_size = try windows.GetFileSizeEx(handle);
        if (file_size < size) @panic("data file inode size was truncated or corrupted");

        return handle;
    }

    fn fs_lock(handle: posix.fd_t, size: u64) !void {
        // TODO: Look into using SetFileIoOverlappedRange() for better unbuffered async IO perf
        // NOTE: Requires SeLockMemoryPrivilege.

        const kernel32 = struct {
            const LOCKFILE_EXCLUSIVE_LOCK = 0x2;
            const LOCKFILE_FAIL_IMMEDIATELY = 0x1;

            extern "kernel32" fn LockFileEx(
                hFile: windows.HANDLE,
                dwFlags: windows.DWORD,
                dwReserved: windows.DWORD,
                nNumberOfBytesToLockLow: windows.DWORD,
                nNumberOfBytesToLockHigh: windows.DWORD,
                lpOverlapped: ?*windows.OVERLAPPED,
            ) callconv(windows.WINAPI) windows.BOOL;
        };

        // hEvent = null
        // Offset & OffsetHigh = 0
        var lock_overlapped = std.mem.zeroes(windows.OVERLAPPED);

        // LOCK_EX | LOCK_NB
        var lock_flags: windows.DWORD = 0;
        lock_flags |= kernel32.LOCKFILE_EXCLUSIVE_LOCK;
        lock_flags |= kernel32.LOCKFILE_FAIL_IMMEDIATELY;

        const locked = kernel32.LockFileEx(
            handle,
            lock_flags,
            0, // reserved param is always zero
            @as(u32, @truncate(size)), // low bits of size
            @as(u32, @truncate(size >> 32)), // high bits of size
            &lock_overlapped,
        );

        if (locked == windows.FALSE) {
            return switch (windows.kernel32.GetLastError()) {
                .IO_PENDING => error.WouldBlock,
                else => |err| windows.unexpectedError(err),
            };
        }
    }

    fn fs_allocate(handle: posix.fd_t, size: u64) !void {
        // TODO: Look into using SetFileValidData() instead
        // NOTE: Requires SE_MANAGE_VOLUME_NAME privilege

        // Move the file pointer to the start + size
        const seeked = windows.kernel32.SetFilePointerEx(
            handle,
            @as(i64, @intCast(size)),
            null, // no reference to new file pointer
            windows.FILE_BEGIN,
        );

        if (seeked == windows.FALSE) {
            return switch (windows.kernel32.GetLastError()) {
                .INVALID_HANDLE => unreachable,
                .INVALID_PARAMETER => unreachable,
                else => |err| windows.unexpectedError(err),
            };
        }

        // Mark the moved file pointer (start + size) as the physical EOF.
        const allocated = windows.kernel32.SetEndOfFile(handle);
        if (allocated == windows.FALSE) {
            const err = windows.kernel32.GetLastError();
            return windows.unexpectedError(err);
        }
    }
};

// TODO: use posix.getsockoptError when fixed for windows in stdlib
fn getsockoptError(socket: posix.socket_t) IO.ConnectError!void {
    var err_code: u32 = undefined;
    var size: i32 = @sizeOf(u32);
    const rc = windows.ws2_32.getsockopt(
        socket,
        posix.SOL.SOCKET,
        posix.SO.ERROR,
        std.mem.asBytes(&err_code),
        &size,
    );

    if (rc != 0) {
        switch (windows.ws2_32.WSAGetLastError()) {
            .WSAENETDOWN => return error.NetworkUnreachable,
            .WSANOTINITIALISED => unreachable, // WSAStartup() was never called
            .WSAEFAULT => unreachable, // The address pointed to by optval or optlen is not in a valid part of the process address space.
            .WSAEINVAL => unreachable, // The level parameter is unknown or invalid
            .WSAENOPROTOOPT => unreachable, // The option is unknown at the level indicated.
            .WSAENOTSOCK => return error.FileDescriptorNotASocket,
            else => |err| return windows.unexpectedWSAError(err),
        }
    }

    assert(size == 4);
    if (err_code == 0)
        return;

    const ws_err = @as(windows.ws2_32.WinsockError, @enumFromInt(@as(u16, @intCast(err_code))));
    return switch (ws_err) {
        .WSAEACCES => error.PermissionDenied,
        .WSAEADDRINUSE => error.AddressInUse,
        .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
        .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
        .WSAEALREADY => error.ConnectionPending,
        .WSAEBADF => unreachable,
        .WSAECONNREFUSED => error.ConnectionRefused,
        .WSAEFAULT => unreachable,
        .WSAEISCONN => unreachable, // error.AlreadyConnected,
        .WSAENETUNREACH => error.NetworkUnreachable,
        .WSAENOTSOCK => error.FileDescriptorNotASocket,
        .WSAEPROTOTYPE => unreachable,
        .WSAETIMEDOUT => error.ConnectionTimedOut,
        .WSAECONNRESET => error.ConnectionResetByPeer,
        else => |e| windows.unexpectedWSAError(e),
    };
}