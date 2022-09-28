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

// strings and other allocations are only valid during the function call
// TODO: opt-arena, init if empty, delete at the end of scope
var TEMP_GPA = std.heap.GeneralPurposeAllocator(.{}){};
pub const TEMP = TEMP_GPA.allocator();

pub const Context = struct {
    env: napi.napi_env,

    // custom_hook, custom_read, custom_write fn ptrs?
    // generated at comptime during init()?

    const Self = @This();

    pub fn read(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        // TODO: custom mappings

        if (comptime trait.isZigString(T)) return self.readString(val);
        if (comptime trait.is(.Optional)(T)) @compileError("TODO");
        if (comptime trait.isTuple(T)) return self.readTuple(T, val);
        if (comptime trait.is(.Struct)(T)) return self.readStruct(T, val);
        if (comptime trait.is(.Pointer)(T)) return self.readExternal(@TypeOf(val.*), val);
        // isXxx

        return self.readPrimitive(T, val);
    }

    pub fn write(self: *Self, val: anytype) Error!napi.napi_value {
        const T = @TypeOf(val);

        // TODO: custom mappings

        if (comptime trait.isPtrTo(.Fn)(T)) return self.writeFn(val);
        if (comptime trait.isZigString(T)) return self.writeString(val);
        if (comptime trait.is(.Optional)(T)) @compileError("TODO");
        if (comptime trait.isTuple(T)) return self.writeTuple(val);
        if (comptime trait.is(.Struct)(T)) return self.writeStruct(val);
        if (comptime trait.is(.Pointer)(T)) return self.readExternal(@TypeOf(val.*), val);

        return self.writePrimitive(val);
    }

    pub fn readPrimitive(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        var res: T = undefined;

        switch (T) {
            napi.napi_value => res = val,
            void => return void{},
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
            napi.napi_value => res = val,
            void => try check(napi.napi_get_undefined(self.env, &res)),
            bool => try check(napi.napi_get_boolean(self.env, val, &res)),
            u8, u16, u32 => try check(napi.napi_create_uint32(self.env, val, &res)),
            i8, i16, i32 => try check(napi.napi_create_int32(self.env, val, &res)),
            @TypeOf(0), i64 => try check(napi.napi_create_int64(self.env, val, &res)),
            @TypeOf(0.0), f16, f32, f64 => try check(napi.napi_create_double(self.env, val, &res)),
            else => |T| @compileError("No JS mapping for type " ++ @typeName(T)),
        }

        return res;
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

    pub fn readExternal(self: *Self, comptime T: type, val: napi.napi_value) Error!*T {
        var res: *T = undefined;
        try check(napi.napi_get_value_external(self.env, val, &res));
        return res;
    }

    pub fn writeExternal(self: *Self, val: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_create_external(self.env, val, &res));
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

    pub fn writeFn(self: *Self, fun: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_create_function(
            self.env,
            null,
            napi.NAPI_AUTO_LENGTH,
            self.trampoline(std.meta.Child(@TypeOf(fun))),
            @ptrCast(?*const anyopaque, fun),
            &res,
        ));
        return res;
    }

    fn trampoline(self: *Self, comptime F: type) napi.napi_callback {
        _ = self;

        return &(struct {
            fn call(env: napi.napi_env, cb_info: napi.napi_callback_info) callconv(.C) napi.napi_value {
                var cx = Context{ .env = env };

                const Args = std.meta.ArgsTuple(F);
                var args: Args = undefined;
                const fields = std.meta.fields(Args);
                var argc: usize = fields.len;
                var argv: [fields.len]napi.napi_value = undefined;
                var fun: *const F = undefined;
                check(napi.napi_get_cb_info(env, cb_info, &argc, &argv, null, @ptrCast(
                    [*c]?*anyopaque,
                    &fun,
                ))) catch |e| return cx.throw(e);

                if (argc != fields.len) {
                    @panic("args");
                }

                inline for (std.meta.fields(std.meta.ArgsTuple(F))) |f, i| {
                    const v = cx.read(f.field_type, argv[i]) catch |e| return cx.throw(e);
                    @field(args, f.name) = v;
                }

                return cx.write(@call(.{}, fun, args)) catch |e| return cx.throw(e);
            }
        }).call;
    }

    pub fn throw(self: *Self, err: anyerror) napi.napi_value {
        const msg = @ptrCast([*c]const u8, @errorName(err));
        check(napi.napi_throw_error(self.env, null, msg)) catch |e| std.debug.panic("throw failed {s} {any}", .{ msg, e });
        return self.write(void{}) catch @panic("throw return undefined");
    }
};
