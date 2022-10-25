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

pub const JsContext = struct {
    env: napi.napi_env,

    // custom_hook, custom_read, custom_write fn ptrs?
    // generated at comptime during init()?

    const Self = @This();

    pub fn read(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        // TODO: custom mappings

        if (T == *Self) return self;
        if (T == napi.napi_value) return val;
        if (comptime trait.isZigString(T)) return self.readString(val);
        if (comptime trait.isPtrTo(.Fn)(T)) return self.readFnPtr(T, val);

        return switch (@typeInfo(T)) {
            .Void => self.readVoid(val),
            .Null => self.readNull(val),
            .Bool => self.readBool(val),
            .Int, .ComptimeInt => self.readInt(T, val),
            .Float, .ComptimeFloat => self.readFloat(T, val),
            .Enum => self.readEnum(T, val),
            .Struct => if (std.meta.trait.isTuple(T)) self.readTuple(T, val) else self.readStruct(T, val),
            .Optional => |info| self.readOptional(info.child, val),
            .Pointer => |info| self.readPtr(info.child, val),
            .ErrorUnion, .ErrorSet, .Union, .Array, .Vector, .EnumLiteral => |info| @compileError("TODO: " ++ @tagName(info)),
            // Undefined, Type, Opaque, Fn, BoundFn, Frame, AnyFrame, NoReturn
            else => @compileError("not supported"),
        };
    }

    pub fn write(self: *Self, val: anytype) Error!napi.napi_value {
        const T = @TypeOf(val);

        // TODO: custom mappings

        if (T == napi.napi_value) return val;
        if (comptime trait.isZigString(T)) return self.writeString(val);
        if (comptime trait.isPtrTo(.Fn)(T)) return self.writeFnPtr(val);

        return switch (@typeInfo(T)) {
            .Void => self.writeVoid(),
            .Null => self.writeNull(),
            .Bool => self.writeBool(val),
            .Int, .ComptimeInt => self.writeInt(val),
            .Float, .ComptimeFloat => self.writeFloat(val),
            .Enum => self.writeEnum(val),
            .Struct => if (std.meta.trait.isTuple(T)) self.writeTuple(val) else self.writeStruct(val),
            .Optional => self.writeOptional(val),
            .Pointer => self.writePtr(val),
            .ErrorUnion, .ErrorSet, .Union, .Array, .Vector, .EnumLiteral => |info| @compileError("TODO: " ++ @tagName(info)),
            // Undefined, Type, Opaque, Fn, BoundFn, Frame, AnyFrame, NoReturn
            else => @compileError("not supported"),
        };
    }

    pub fn readVoid(_: *Self, _: napi.napi_value) Error!void {
        // TODO: I'm not sure yet, it might be consistent & convenient for prototyping
        //       but it might also hide a potential bug
        // return if (self.typeOf(val) == napi.napi_undefined) null else error.napi_invalid_arg;
        @compileError("TODO: read void?");
    }

    pub fn writeVoid(self: *Self) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_get_undefined(self.env, &res));
        return res;
    }

    pub fn readNull(_: *Self, _: napi.napi_value) Error!null {
        // TODO: I'm not sure yet, it might be consistent & convenient for prototyping
        //       but it might also hide a potential bug
        // return if (self.typeOf(val) == napi.napi_null) null else error.napi_invalid_arg;
        @compileError("TODO: read null?");
    }

    pub fn writeNull(self: *Self) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_get_null(self.env, &res));
        return res;
    }

    pub fn readBool(self: *Self, val: napi.napi_value) Error!bool {
        var res: bool = undefined;
        try check(napi.napi_get_value_bool(self.env, val, &res));
        return res;
    }

    pub fn writeBool(self: *Self, val: bool) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_get_boolean(self.env, val, &res));
        return res;
    }

    pub fn readInt(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        var res: T = undefined;

        switch (T) {
            u8, u16 => res = @truncate(T, self.read(u32, val)),
            u32 => try check(napi.napi_get_value_uint32(self.env, val, &res)),
            i8, i16 => res = @truncate(T, self.read(i32, val)),
            i32 => try check(napi.napi_get_value_int32(self.env, val, &res)),
            i64 => try check(napi.napi_get_value_int64(self.env, val, &res)),
            else => @compileError("TODO: arbitrary ints"),
        }

        return res;
    }

    pub fn writeInt(self: *Self, val: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;

        switch (@TypeOf(val)) {
            u8, u16, u32 => try check(napi.napi_create_uint32(self.env, val, &res)),
            i8, i16, i32 => try check(napi.napi_create_int32(self.env, val, &res)),
            @TypeOf(0), i64 => try check(napi.napi_create_int64(self.env, val, &res)),
            else => @compileError("TODO: arbitrary ints"),
        }

        return res;
    }

    pub fn readFloat(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        var res: T = undefined;

        switch (T) {
            f16, f32 => res = @floatCast(T, try self.read(f64, val)),
            f64 => try check(napi.napi_get_value_double(self.env, val, &res)),
            else => @compileError("TODO: arbitrary floats"),
        }

        return res;
    }

    pub fn writeFloat(self: *Self, val: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;

        switch (@TypeOf(val)) {
            @TypeOf(0.0), f16, f32, f64 => try check(napi.napi_create_double(self.env, val, &res)),
            else => @compileError("TODO: arbitrary floats"),
        }

        return res;
    }

    pub fn readEnum(self: *Self, comptime T: type, val: napi.napi_value) Error!T {
        return std.meta.intToEnum(T, self.read(u32, val));
    }

    pub fn writeEnum(self: *Self, val: anytype) Error!napi.napi_value {
        return self.write(@as(u32, @enumToInt(val)));
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

    pub fn readOptional(self: *Self, comptime T: type, val: napi.napi_value) Error!?T {
        return if (self.isNull(val)) null else self.read(T, val);
    }

    pub fn writeOptional(self: *Self, val: anytype) Error!napi.napi_value {
        return if (val) |v| self.write(v) else self.write(null);
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
                var js = JsContext{ .env = env };

                var args: std.meta.ArgsTuple(F) = undefined;
                var argc: usize = args.len;
                var argv: [args.len]napi.napi_value = undefined;
                var fun: *const F = undefined;
                check(napi.napi_get_cb_info(env, cb_info, &argc, &argv, null, @ptrCast(
                    [*c]?*anyopaque,
                    &fun,
                ))) catch |e| return js.throw(e);

                if (argc != args.len) {
                    // TODO: throw
                    std.debug.panic("Expected {d} args", .{argv.len});
                }

                // TODO: compiler crashes on this (check again)
                // inline for (std.meta.fields(@TypeOf(args))) |f, i| {
                //     const v = js.read(f.field_type, argv[i]) catch |e| return js.throw(e);
                //     @field(args, f.name) = v;
                // }
                inline for (comptime std.meta.fieldNames(@TypeOf(args))) |f, i| {
                    const v = js.read(@TypeOf(@field(args, f)), argv[i]) catch |e| return js.throw(e);
                    @field(args, f) = v;
                }

                var res = @call(.{}, fun, args);

                if (comptime std.meta.trait.is(.ErrorUnion)(@TypeOf(res))) {
                    if (res) |r| {
                        return js.write(r) catch |e| return js.throw(e);
                    } else |e| {
                        return js.throw(e);
                    }
                } else {
                    return js.write(res) catch |e| return js.throw(e);
                }
            }
        }).call;
    }

    pub fn typeOf(self: *Self, val: napi.napi_value) Error!napi.napi_typeof {
        var res: napi.napi_valuetype = undefined;
        try check(napi.napi_typeof(self.env, val, &res));
        return res;
    }

    pub fn call(self: *Self, fun: napi.napi_value, args: anytype) Error!napi.napi_value {
        const Args = @TypeOf(args);
        const fields = std.meta.fields(Args);

        var argv: [fields.len]napi.napi_value = undefined;
        inline for (fields) |f, i| {
            argv[i] = try self.write(@field(args, f.name));
        }

        var res: napi.napi_value = undefined;
        try check(napi.napi_call_function(self.env, try self.write(void{}), fun, fields.len, &argv, &res));
        return res;
    }

    pub fn throw(self: *Self, err: anyerror) napi.napi_value {
        const msg = @ptrCast([*c]const u8, @errorName(err));
        check(napi.napi_throw_error(self.env, null, msg)) catch |e| {
            if (e != error.napi_pending_exception) std.debug.panic("throw failed {s} {any}", .{ msg, e });
        };
        return self.write(void{}) catch @panic("throw return undefined");
    }
};
