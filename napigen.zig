const std = @import("std");
const trait = std.meta.trait;
const napi = @import("napi.zig");

// export the whole napi
pub usingnamespace napi;

// define error types
pub const NapiError = error{ napi_invalid_arg, napi_object_expected, napi_string_expected, napi_name_expected, napi_function_expected, napi_number_expected, napi_boolean_expected, napi_array_expected, napi_generic_failure, napi_pending_exception, napi_cancelled, napi_escape_called_twice, napi_handle_scope_mismatch, napi_callback_scope_mismatch, napi_queue_full, napi_closing, napi_bigint_expected, napi_date_expected, napi_arraybuffer_expected, napi_detachable_arraybuffer_expected, napi_would_deadlock };
pub const Error = std.mem.Allocator.Error || NapiError;

/// translate napi_status > 0 to NapiError with the same name
pub fn check(status: napi.napi_status) Error!void {
    if (status != napi.napi_ok) {
        inline for (comptime std.meta.fieldNames(NapiError)) |f| {
            if (status == @field(napi, f)) return @field(NapiError, f);
        } else @panic("unknown napi err");
    }
}

pub const allocator = std.heap.c_allocator;

// TODO: strings are only valid during the function call
// threadlocal var arena: ?std.heap.ArenaAllocator = null;
var TEMP_GPA = std.heap.GeneralPurposeAllocator(.{}){};
pub const TEMP = TEMP_GPA.allocator();

// TODO: per-env instance state (napi_set_instance_data)
var refs = std.AutoHashMap(*anyopaque, napi.napi_ref).init(allocator);

fn deleteRef(_: napi.napi_env, _: ?*anyopaque, ptr: ?*anyopaque) callconv(.C) void {
    _ = refs.remove(ptr.?);
}

pub const Context = struct {
    env: napi.napi_env,

    // custom_hook, custom_read, custom_write fn ptrs?
    // generated at comptime during init()?

    const Self = @This();

    pub fn read(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        // TODO: custom mappings

        if (T == *Self) return self;
        if (T == napi.napi_value) return val;
        if (comptime trait.isPtrTo(.Fn)(T)) return self.readFnPtr(T, val);
        if (comptime trait.isZigString(T)) return self.readString(val);
        if (comptime trait.is(.Enum)(T)) return self.readEnum(T, val);
        if (comptime trait.is(.Optional)(T)) return self.readOptional(std.meta.Child(T), val);
        if (comptime trait.isTuple(T)) return self.readTuple(T, val);
        if (comptime trait.is(.Struct)(T)) return self.readStruct(T, val);
        if (comptime trait.is(.Pointer)(T)) return self.readPtr(std.meta.Child(T), val);

        return self.readPrimitive(T, val);
    }

    pub fn write(self: *Self, val: anytype) Error!napi.napi_value {
        const T = @TypeOf(val);

        // TODO: custom mappings

        if (T == *Self) return self;
        if (T == napi.napi_value) return val;
        if (comptime trait.isPtrTo(.Fn)(T)) return self.writeFnPtr(val);
        if (comptime trait.isZigString(T)) return self.writeString(val);
        if (comptime trait.is(.Enum)(T)) return self.writeEnum(val);
        if (comptime trait.is(.Optional)(T)) return self.writeOptional(val);
        if (comptime trait.isTuple(T)) return self.writeTuple(val);
        if (comptime trait.is(.Struct)(T)) return self.writeStruct(val);
        if (comptime trait.is(.Pointer)(T)) return self.writePtr(val);

        return self.writePrimitive(val);
    }

    pub fn readPrimitive(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        var res: T = undefined;

        switch (T) {
            void => return void{},
            @TypeOf(null) => return null{},
            bool => try check(napi.napi_get_value_bool(self.env, val, &res)),
            u8, u16 => @truncate(T, self.read(u32, val)),
            u32 => try check(napi.napi_get_value_uint32(self.env, val, &res)),
            i8, i16 => @truncate(T, self.read(i32, val)),
            i32 => try check(napi.napi_get_value_int32(self.env, val, &res)),
            i64 => try check(napi.napi_get_value_int64(self.env, val, &res)),
            f16, f32 => @floatCast(T, self.read(f64, val)),
            f64 => try check(napi.napi_get_value_double(self.env, val, &res)),
            else => @compileError("No JS mapping for type " ++ @typeName(T)),
        }

        return res;
    }

    pub fn writePrimitive(self: *Self, val: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;

        switch (@TypeOf(val)) {
            void => try check(napi.napi_get_undefined(self.env, &res)),
            @TypeOf(null) => try check(napi.napi_get_null(self.env, &res)),
            bool => try check(napi.napi_get_boolean(self.env, val, &res)),
            u8, u16, u32 => try check(napi.napi_create_uint32(self.env, val, &res)),
            i8, i16, i32 => try check(napi.napi_create_int32(self.env, val, &res)),
            @TypeOf(0), i64 => try check(napi.napi_create_int64(self.env, val, &res)),
            @TypeOf(0.0), f16, f32, f64 => try check(napi.napi_create_double(self.env, val, &res)),
            else => |T| @compileError("No JS mapping for type " ++ @typeName(T)),
        }

        return res;
    }

    pub fn readEnum(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        return std.meta.intToEnum(T, self.read(u32, val));
    }

    pub fn writeEnum(self: *Self, val: anytype) Error!napi.napi_value {
        return self.write(@as(u32, @enumToInt(val)));
    }

    pub fn readOptional(self: *Self, comptime T: type, val: napi.napi_value) Error!?T {
        var t: napi.napi_valuetype = undefined;
        try check(napi.napi_typeof(self.env, val, &t));

        return if (t == napi.napi_null) null else self.read(T, val);
    }

    pub fn writeOptional(self: *Self, val: anytype) Error!napi.napi_value {
        return if (val) |v| self.write(v) else self.write(null);
    }

    pub fn readStruct(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        var res: T = undefined;
        inline for (std.meta.fields(T)) |f| {
            var v: napi.napi_value = undefined;
            try check(napi.napi_get_named_property(self.env, val, f.name ++ "", &v));
            @field(res, f.name) = try self.read(f.field_type, v);
        }
        return res;
    }

    pub fn writeStruct(self: *Self, val: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_create_object(self.env, &res));
        inline for (std.meta.fields(@TypeOf(val))) |f| {
            var v = try self.write(@field(val, f.name));
            try check(napi.napi_set_named_property(self.env, res, f.name ++ "", v));
        }
        return res;
    }

    pub fn readTuple(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        return self.readStruct(T, val);
    }

    pub fn writeTuple(self: *Self, val: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        const fields = std.meta.fields(@TypeOf(val));
        try check(napi.napi_create_array_with_length(self.env, fields.len, &res));
        inline for (fields) |f, i| {
            const v = try self.write(@field(val, f.name));
            try check(napi.napi_set_element(self.env, res, @truncate(u32, i), v));
        }
        return res;
    }

    pub fn readPtr(self: *Self, comptime T: type, val: napi.napi_value) Error!*T {
        var res: *T = undefined;
        try check(napi.napi_unwrap(self.env, val, @ptrCast([*c]?*anyopaque, &res)));
        return res;
    }

    pub fn writePtr(self: *Self, val: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;

        if (refs.get(val)) |ref| {
            try check(napi.napi_get_reference_value(self.env, ref, &res));
        } else {
            var ref: napi.napi_ref = undefined;
            try check(napi.napi_create_object(self.env, &res));
            try check(napi.napi_wrap(self.env, res, val, &deleteRef, val, &ref));
            try refs.put(val, ref);
        }

        return res;
    }

    pub fn readString(self: *Self, val: napi.napi_value) Error![]const u8 {
        var len: usize = undefined;
        try check(napi.napi_get_value_string_utf8(self.env, val, null, 0, &len));
        var buf = try TEMP.alloc(u8, len + 1);
        try check(napi.napi_get_value_string_utf8(self.env, val, @ptrCast([*c]u8, buf), buf.len, &len));
        return buf[0..len];
    }

    pub fn writeString(self: *Self, val: []const u8) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_create_string_utf8(self.env, @ptrCast([*c]const u8, val), val.len, &res));
        return res;
    }

    pub fn readFnPtr(_: *Self, comptime T: type, _: napi.napi_value) Error!T {
        @compileError("reading fn ptrs is not supported");
    }

    pub fn writeFnPtr(self: *Self, fun: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        const ptr = @intToPtr(*anyopaque, @ptrToInt(fun));

        if (refs.get(ptr)) |ref| {
            try check(napi.napi_get_reference_value(self.env, ref, &res));
        } else {
            var ref: napi.napi_ref = undefined;
            try check(napi.napi_create_function(self.env, null, napi.NAPI_AUTO_LENGTH, self.trampoline(std.meta.Child(@TypeOf(fun))), ptr, &res));
            try check(napi.napi_add_finalizer(self.env, res, null, &deleteRef, ptr, &ref));
            try refs.put(ptr, ref);
        }

        return res;
    }

    fn trampoline(self: *Self, comptime F: type) napi.napi_callback {
        _ = self;

        return &(struct {
            fn call(env: napi.napi_env, cb_info: napi.napi_callback_info) callconv(.C) napi.napi_value {
                var cx = Context{ .env = env };

                var args: std.meta.ArgsTuple(F) = undefined;
                var argc: usize = args.len;
                var argv: [args.len]napi.napi_value = undefined;
                var fun: *const F = undefined;
                check(napi.napi_get_cb_info(env, cb_info, &argc, &argv, null, @ptrCast(
                    [*c]?*anyopaque,
                    &fun,
                ))) catch |e| return cx.throw(e);

                if (argc != args.len) {
                    // TODO: throw
                    std.debug.panic("Expected {d} args", .{argv.len});
                }

                // TODO: compiler crashes on this
                // inline for (std.meta.fields(@TypeOf(args))) |f, i| {
                //     const v = cx.read(f.field_type, argv[i]) catch |e| return cx.throw(e);
                //     @field(args, f.name) = v;
                // }
                inline for (comptime std.meta.fieldNames(@TypeOf(args))) |f, i| {
                    const v = cx.read(@TypeOf(@field(args, f)), argv[i]) catch |e| return cx.throw(e);
                    @field(args, f) = v;
                }

                var res = @call(.{}, fun, args);

                if (comptime std.meta.trait.is(.ErrorUnion)(@TypeOf(res))) {
                    if (res) |r| {
                        return cx.write(r) catch |e| return cx.throw(e);
                    } else |e| {
                        return cx.throw(e);
                    }
                } else {
                    return cx.write(res) catch |e| return cx.throw(e);
                }
            }
        }).call;
    }

    pub fn call(self: *Self, comptime R: type, fun: napi.napi_value, args: anytype) Error!R {
        const Args = @TypeOf(args);
        const fields = std.meta.fields(Args);

        var argv: [fields.len]napi.napi_value = undefined;
        inline for (fields) |f, i| {
            argv[i] = try self.write(@field(args, f.name));
        }

        var res: napi.napi_value = undefined;
        try check(napi.napi_call_function(self.env, try self.write(void{}), fun, fields.len, &argv, &res));
        return try self.read(R, res);
    }

    pub fn throw(self: *Self, err: anyerror) napi.napi_value {
        const msg = @ptrCast([*c]const u8, @errorName(err));
        check(napi.napi_throw_error(self.env, null, msg)) catch |e| std.debug.panic("throw failed {s} {any}", .{ msg, e });
        return self.write(void{}) catch @panic("throw return undefined");
    }
};
