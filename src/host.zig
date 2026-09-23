const std = @import("std");
const abi = @import("abi.zig");
const types = @import("types.zig");

pub const Error = error{
    InvalidArgument,
    HyperlightFailure,
    CallbackFailure,
    BridgePanic,
    TypeMismatch,
};

fn bytesView(value: []const u8) abi.Bytes {
    return .{
        .data = if (value.len == 0) null else value.ptr,
        .len = value.len,
    };
}

fn statusError(status: abi.Status) Error {
    return switch (status) {
        .ok => unreachable,
        .invalid_argument => error.InvalidArgument,
        .hyperlight_error => error.HyperlightFailure,
        .callback_error => error.CallbackFailure,
        .panic => error.BridgePanic,
    };
}

fn checkStatus(status: abi.Status, bridge_error: *abi.Error) Error!void {
    defer abi.hlz_error_deinit(bridge_error);
    if (status == .ok) return;

    if (bridge_error.data) |data| {
        std.log.err("Hyperlight: {s}", .{data[0..bridge_error.len]});
    }
    return statusError(status);
}

fn callbackPayload(comptime Return: type) type {
    return switch (@typeInfo(Return)) {
        .error_union => |info| info.payload,
        else => Return,
    };
}

fn callbackReturnType(comptime function: anytype) abi.Type {
    const function_info = @typeInfo(@TypeOf(function));
    if (function_info != .@"fn") {
        @compileError("Hyperlight host callback must be a function");
    }
    const Return = function_info.@"fn".return_type orelse
        @compileError("Hyperlight host callback must have a return type");
    return types.wireType(callbackPayload(Return));
}

fn callbackParameterTypes(comptime function: anytype, comptime context_count: usize) type {
    const function_info = @typeInfo(@TypeOf(function));
    if (function_info != .@"fn") {
        @compileError("Hyperlight host callback must be a function");
    }
    const params = function_info.@"fn".params;
    if (params.len < context_count) {
        @compileError("Hyperlight host callback is missing its context parameter");
    }
    return [params.len - context_count]abi.Type;
}

fn makeCallbackParameterTypes(
    comptime function: anytype,
    comptime context_count: usize,
) callbackParameterTypes(function, context_count) {
    const params = @typeInfo(@TypeOf(function)).@"fn".params;
    var result: [params.len - context_count]abi.Type = undefined;
    inline for (params[context_count..], 0..) |param, index| {
        const Param = param.type orelse
            @compileError("generic parameters are not supported in Hyperlight callbacks");
        result[index] = types.wireType(Param);
    }
    return result;
}

fn Callback(
    comptime function: anytype,
    comptime Context: type,
) type {
    return struct {
        fn invoke(
            raw_context: ?*anyopaque,
            raw_args: ?[*]const abi.Value,
            args_len: usize,
            result: *abi.Value,
            callback_error: *abi.Bytes,
        ) callconv(.c) abi.Status {
            const function_info = @typeInfo(@TypeOf(function)).@"fn";
            const context_count: usize = if (Context == void) 0 else 1;
            const expected_args = function_info.params.len - context_count;
            if (args_len != expected_args) {
                callback_error.* = bytesView("host callback argument count mismatch");
                return .invalid_argument;
            }
            const args = if (args_len == 0)
                &.{}
            else
                (raw_args orelse {
                    callback_error.* = bytesView("host callback arguments are null");
                    return .invalid_argument;
                })[0..args_len];

            var call_args: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            if (Context != void) {
                const context = raw_context orelse {
                    callback_error.* = bytesView("host callback context is null");
                    return .invalid_argument;
                };
                call_args[0] = @ptrCast(@alignCast(context));
            }
            inline for (function_info.params[context_count..], 0..) |param, index| {
                const Param = param.type orelse unreachable;
                call_args[index + context_count] =
                    types.fromAbiBorrowed(Param, args[index]) catch {
                        callback_error.* = bytesView("host callback argument type mismatch");
                        return .invalid_argument;
                    };
            }

            const Return = function_info.return_type.?;
            const Payload = callbackPayload(Return);
            const payload: Payload = switch (@typeInfo(Return)) {
                .error_union => @call(.auto, function, call_args) catch |err| {
                    callback_error.* = bytesView(@errorName(err));
                    return .callback_error;
                },
                else => @call(.auto, function, call_args),
            };
            result.* = if (Payload == void)
                abi.Value.initVoid()
            else
                types.toAbi(payload);
            return .ok;
        }
    };
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    handle: *abi.Builder,

    pub fn initFromFile(allocator: std.mem.Allocator, path: []const u8) !Builder {
        var handle: ?*abi.Builder = null;
        var bridge_error = abi.Error.init();
        try checkStatus(
            abi.hlz_builder_from_file(bytesView(path), &handle, &bridge_error),
            &bridge_error,
        );
        return .{
            .allocator = allocator,
            .handle = handle orelse return error.InvalidArgument,
        };
    }

    pub fn deinit(self: *Builder) void {
        abi.hlz_builder_deinit(self.handle);
        self.* = undefined;
    }

    pub fn hostFunction(
        self: *Builder,
        name: []const u8,
        comptime function: anytype,
    ) !void {
        const parameter_types = makeCallbackParameterTypes(function, 0);
        var bridge_error = abi.Error.init();
        try checkStatus(
            abi.hlz_builder_host_function(
                self.handle,
                bytesView(name),
                if (parameter_types.len == 0) null else &parameter_types,
                parameter_types.len,
                callbackReturnType(function),
                &Callback(function, void).invoke,
                null,
                &bridge_error,
            ),
            &bridge_error,
        );
    }

    pub fn hostFunctionWithContext(
        self: *Builder,
        name: []const u8,
        context: anytype,
        comptime function: anytype,
    ) !void {
        const Context = @TypeOf(context);
        if (@typeInfo(Context) != .pointer) {
            @compileError("Hyperlight callback context must be a pointer");
        }
        const function_info = @typeInfo(@TypeOf(function));
        if (function_info != .@"fn" or function_info.@"fn".params.len == 0) {
            @compileError("context callback must accept the context as its first parameter");
        }
        const First = function_info.@"fn".params[0].type orelse
            @compileError("generic callback context is not supported");
        if (First != Context) {
            @compileError("callback context pointer does not match its first parameter");
        }

        const parameter_types = makeCallbackParameterTypes(function, 1);
        var bridge_error = abi.Error.init();
        try checkStatus(
            abi.hlz_builder_host_function(
                self.handle,
                bytesView(name),
                if (parameter_types.len == 0) null else &parameter_types,
                parameter_types.len,
                callbackReturnType(function),
                &Callback(function, Context).invoke,
                @ptrCast(context),
                &bridge_error,
            ),
            &bridge_error,
        );
    }

    pub fn build(self: *Builder) !Sandbox {
        var handle: ?*abi.Sandbox = null;
        var bridge_error = abi.Error.init();
        try checkStatus(
            abi.hlz_builder_build(self.handle, &handle, &bridge_error),
            &bridge_error,
        );
        return .{
            .allocator = self.allocator,
            .handle = handle orelse return error.InvalidArgument,
        };
    }
};

pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    handle: *abi.Sandbox,

    pub fn deinit(self: *Sandbox) void {
        abi.hlz_sandbox_deinit(self.handle);
        self.* = undefined;
    }

    pub fn call(
        self: *Sandbox,
        comptime Return: type,
        function_name: []const u8,
        args: anytype,
    ) !types.WireResult(Return) {
        const Args = @TypeOf(args);
        const info = @typeInfo(Args);
        if (info != .@"struct" or !info.@"struct".is_tuple) {
            @compileError("Hyperlight arguments must be a tuple");
        }
        const fields = info.@"struct".fields;
        var values: [fields.len]abi.Value = undefined;
        inline for (fields, 0..) |field, index| {
            values[index] = types.toAbi(@field(args, field.name));
        }

        var result = abi.Value.initVoid();
        defer abi.hlz_value_deinit(&result);
        var bridge_error = abi.Error.init();
        try checkStatus(
            abi.hlz_sandbox_call(
                self.handle,
                bytesView(function_name),
                types.wireType(Return),
                if (values.len == 0) null else &values,
                values.len,
                &result,
                &bridge_error,
            ),
            &bridge_error,
        );
        return types.fromAbiOwned(self.allocator, Return, result);
    }

    pub fn snapshot(self: *Sandbox) !Snapshot {
        var handle: ?*abi.Snapshot = null;
        var bridge_error = abi.Error.init();
        try checkStatus(
            abi.hlz_sandbox_snapshot(self.handle, &handle, &bridge_error),
            &bridge_error,
        );
        return .{ .handle = handle orelse return error.InvalidArgument };
    }

    pub fn restore(self: *Sandbox, snapshot_value: *const Snapshot) !void {
        var bridge_error = abi.Error.init();
        try checkStatus(
            abi.hlz_sandbox_restore(
                self.handle,
                snapshot_value.handle,
                &bridge_error,
            ),
            &bridge_error,
        );
    }
};

pub const Snapshot = struct {
    handle: *abi.Snapshot,

    pub fn deinit(self: *Snapshot) void {
        abi.hlz_snapshot_deinit(self.handle);
        self.* = undefined;
    }
};

test "comptime callback trampoline converts parameters and result" {
    const Functions = struct {
        fn add(a: i32, b: i32) !i32 {
            return a + b;
        }
    };
    const callback = Callback(Functions.add, void).invoke;
    const args = [_]abi.Value{
        types.toAbi(@as(i32, 20)),
        types.toAbi(@as(i32, 22)),
    };
    var result = abi.Value.initVoid();
    var callback_error = bytesView("");
    try std.testing.expectEqual(
        abi.Status.ok,
        callback(null, &args, args.len, &result, &callback_error),
    );
    try std.testing.expectEqual(@as(i32, 42), try types.fromAbiBorrowed(i32, result));
}

test "comptime callback trampoline supports context and errors" {
    const Context = struct { calls: usize = 0 };
    const Functions = struct {
        fn fail(context: *Context, _: bool) !void {
            context.calls += 1;
            return error.ExpectedFailure;
        }
    };
    var context = Context{};
    const callback = Callback(Functions.fail, *Context).invoke;
    const args = [_]abi.Value{types.toAbi(true)};
    var result = abi.Value.initVoid();
    var callback_error = bytesView("");
    try std.testing.expectEqual(
        abi.Status.callback_error,
        callback(&context, &args, args.len, &result, &callback_error),
    );
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqualStrings(
        "ExpectedFailure",
        callback_error.data.?[0..callback_error.len],
    );
}
