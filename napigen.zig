const std = @import("std");
const trait = std.meta.trait;
const napi = @import("napi.zig");

// export the whole napi
pub usingnamespace napi;

// define error types
pub const NapiError = error{ napi_invalid_arg, napi_object_expected, napi_string_expected, napi_name_expected, napi_function_expected, napi_number_expected, napi_boolean_expected, napi_array_expected, napi_generic_failure, napi_pending_exception, napi_cancelled, napi_escape_called_twice, napi_handle_scope_mismatch, napi_callback_scope_mismatch, napi_queue_full, napi_closing, napi_bigint_expected, napi_date_expected, napi_arraybuffer_expected, napi_detachable_arraybuffer_expected, napi_would_deadlock };
pub const Error = std.mem.Allocator.Error || error{InvalidArgumentCount} || NapiError;

/// translate napi_status > 0 to NapiError with the same name
pub fn check(status: napi.napi_status) Error!void {
    if (status != napi.napi_ok) {
        inline for (comptime std.meta.fieldNames(NapiError)) |f| {
            if (status == @field(napi, f)) return @field(NapiError, f);
        } else @panic("unknown napi err");
    }
}

pub const allocator = std.heap.c_allocator;

pub fn defineModule(comptime init_fn: fn (*JsContext, napi.napi_value) Error!napi.napi_value) void {
    const register = (struct {
        fn register(env: napi.napi_env, exports: napi.napi_value) callconv(.C) napi.napi_value {
            var cx = JsContext.init(env) catch @panic("could not init JS context");
            return init_fn(cx, exports) catch |e| cx.throw(e);
        }
    }).register;

    @export(register, .{ .name = "napi_register_module_v1", .linkage = .Strong });
}

// TODO: strings are only valid during the function call
// threadlocal var arena: ?std.heap.ArenaAllocator = null;
var TEMP_GPA = std.heap.GeneralPurposeAllocator(.{}){};
pub const TEMP = TEMP_GPA.allocator();

pub const JsContext = struct {
    env: napi.napi_env,
    refs: std.AutoHashMapUnmanaged(*anyopaque, napi.napi_ref) = .{},

    pub fn init(env: napi.napi_env) Error!*JsContext {
        var self = try allocator.create(JsContext);
        try check(napi.napi_set_instance_data(env, self, finalize, null));
        self.* = .{ .env = env };
        return self;
    }

    pub fn deinit(self: *JsContext) void {
        allocator.destroy(self);
    }

    fn getInstance(env: napi.napi_env) *JsContext {
        var res: *JsContext = undefined;
        check(napi.napi_get_instance_data(env, @ptrCast([*c]?*anyopaque, &res))) catch @panic("could not get JS context");
        return res;
    }

    fn finalize(env: napi.napi_env, _: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
        getInstance(env).deinit();
    }

    pub fn typeOf(self: *JsContext, val: napi.napi_value) Error!napi.napi_valuetype {
        var res: napi.napi_valuetype = undefined;
        try check(napi.napi_typeof(self.env, val, &res));
        return res;
    }

    pub fn throw(self: *JsContext, err: anyerror) napi.napi_value {
        const msg = @ptrCast([*c]const u8, @errorName(err));
        check(napi.napi_throw_error(self.env, null, msg)) catch |e| {
            if (e != error.napi_pending_exception) std.debug.panic("throw failed {s} {any}", .{ msg, e });
        };
        return self.undefined() catch @panic("throw return undefined");
    }

    pub fn @"undefined"(self: *JsContext) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_get_undefined(self.env, &res));
        return res;
    }

    pub fn @"null"(self: *JsContext) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_get_null(self.env, &res));
        return res;
    }

    pub fn createBoolean(self: *JsContext, val: bool) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_get_boolean(self.env, val, &res));
        return res;
    }

    pub fn readBoolean(self: *JsContext, val: napi.napi_value) Error!bool {
        var res: bool = undefined;
        try check(napi.napi_get_value_bool(self.env, val, &res));
        return res;
    }

    pub fn createNumber(self: *JsContext, val: anytype) Error!napi.napi_value {
        var res: napi.napi_value = undefined;

        switch (@TypeOf(val)) {
            u8, u16, u32 => try check(napi.napi_create_uint32(self.env, val, &res)),
            i8, i16, i32 => try check(napi.napi_create_int32(self.env, val, &res)),
            @TypeOf(0), i64 => try check(napi.napi_create_int64(self.env, val, &res)),
            @TypeOf(0.0), f16, f32, f64 => try check(napi.napi_create_double(self.env, val, &res)),
            else => @compileError("not supported"),
        }

        return res;
    }

    pub fn readNumber(self: *JsContext, comptime T: type, val: napi.napi_value) Error!T {
        var res: T = undefined;

        switch (T) {
            u8, u16 => res = @truncate(T, self.read(u32, val)),
            u32 => try check(napi.napi_get_value_uint32(self.env, val, &res)),
            i8, i16 => res = @truncate(T, self.read(i32, val)),
            i32 => try check(napi.napi_get_value_int32(self.env, val, &res)),
            i64 => try check(napi.napi_get_value_int64(self.env, val, &res)),
            f16, f32 => res = @floatCast(T, try self.readNumber(f64, val)),
            f64 => try check(napi.napi_get_value_double(self.env, val, &res)),
            else => @compileError("not supported"),
        }

        return res;
    }

    pub fn createString(self: *JsContext, val: []const u8) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_create_string_utf8(self.env, @ptrCast([*c]const u8, val), val.len, &res));
        return res;
    }

    pub fn readString(self: *JsContext, val: napi.napi_value) Error![]const u8 {
        var len: usize = undefined;
        try check(napi.napi_get_value_string_utf8(self.env, val, null, 0, &len));
        var buf = try TEMP.alloc(u8, len + 1);
        try check(napi.napi_get_value_string_utf8(self.env, val, @ptrCast([*c]u8, buf), buf.len, &len));
        return buf[0..len];
    }

    pub fn createOptional(self: *JsContext, val: anytype) Error!napi.napi_value {
        return if (val) |v| self.write(v) else self.null();
    }

    pub fn readOptional(self: *JsContext, comptime T: type, val: napi.napi_value) Error!?T {
        return if (try self.typeOf(val) == napi.napi_null) null else self.read(T, val);
    }

    pub fn createArray(self: *JsContext) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_create_array(self.env, &res));
        return res;
    }

    pub fn createArrayWithLength(self: *JsContext, length: u32) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_create_array_with_length(self.env, length, &res));
        return res;
    }

    pub fn getArrayLength(self: *JsContext, array: napi.napi_value) Error!u32 {
        var res: u32 = undefined;
        try check(napi.napi_get_array_length(self.env, array, &res));
        return res;
    }

    pub fn getElement(self: *JsContext, array: napi.napi_value, index: u32) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_get_element(self.env, array, index, &res));
        return res;
    }

    pub fn setElement(self: *JsContext, array: napi.napi_value, index: u32, value: napi.napi_value) Error!void {
        try check(napi.napi_set_element(self.env, array, index, value));
    }

    pub fn createTuple(self: *JsContext, val: anytype) Error!napi.napi_value {
        const fields = std.meta.fields(@TypeOf(val));
        var res = try self.createArrayWithLength(fields.len);
        inline for (fields, 0..) |f, i| {
            const v = try self.write(@field(val, f.name));
            try self.setElement(res, @truncate(u32, i), v);
        }
        return res;
    }

    pub fn readTuple(self: *JsContext, comptime T: type, val: napi.napi_value) Error!T {
        const fields = std.meta.fields(T);
        var res: T = undefined;
        inline for (fields, 0..) |f, i| {
            const v = try self.getElement(val, @truncate(u32, i));
            @field(res, f.name) = try self.read(f.type, v);
        }
        return res;
    }

    pub fn createEmptyObject(self: *JsContext) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_create_object(self.env, &res));
        return res;
    }

    pub fn createObject(self: *JsContext, val: anytype) Error!napi.napi_value {
        var res: napi.napi_value = try self.createEmptyObject();
        inline for (std.meta.fields(@TypeOf(val))) |f| {
            var v = try self.write(@field(val, f.name));
            try self.setNamedProperty(res, f.name ++ "", v);
        }
        return res;
    }

    pub fn readObject(self: *JsContext, comptime T: type, val: napi.napi_value) Error!T {
        var res: T = undefined;
        inline for (std.meta.fields(T)) |f| {
            var v = try self.getNamedProperty(val, f.name ++ "");
            @field(res, f.name) = try self.read(f.type, v);
        }
        return res;
    }

    pub fn getNamedProperty(self: *JsContext, object: napi.napi_value, prop_name: [*:0]const u8) Error!napi.napi_value {
        var res: napi.napi_value = undefined;
        try check(napi.napi_get_named_property(self.env, object, prop_name, &res));
        return res;
    }

    pub fn setNamedProperty(self: *JsContext, object: napi.napi_value, prop_name: [*:0]const u8, value: napi.napi_value) Error!void {
        try check(napi.napi_set_named_property(self.env, object, prop_name, value));
    }

    pub fn wrapPtr(self: *JsContext, val: anytype) Error!napi.napi_value {
        if (comptime trait.isPtrTo(.Fn)(@TypeOf(val))) @compileError("use createFunction() to export functions");

        var res: napi.napi_value = undefined;

        if (self.refs.get(val)) |ref| {
            if (napi.napi_get_reference_value(self.env, ref, &res) == napi.napi_ok) {
                return res;
            } else {
                _ = napi.napi_delete_reference(self.env, ref);
            }
        }

        var ref: napi.napi_ref = undefined;
        res = try self.createEmptyObject();
        try check(napi.napi_wrap(self.env, res, val, &deleteRef, val, &ref));
        try self.refs.put(allocator, val, ref);

        return res;
    }

    fn deleteRef(env: napi.napi_env, _: ?*anyopaque, ptr: ?*anyopaque) callconv(.C) void {
        var js = JsContext.getInstance(env);

        if (js.refs.get(ptr.?)) |ref| {
            // not sure if this is really needed but if we have a new ref and it's valid, we want to skip this
            var val: napi.napi_value = undefined;
            if (napi.napi_get_reference_value(env, ref, &val) == napi.napi_ok) return;

            _ = napi.napi_delete_reference(env, ref);
            _ = js.refs.remove(ptr.?);
        }
    }

    pub fn readPtr(self: *JsContext, comptime T: type, val: napi.napi_value) Error!*T {
        var res: *T = undefined;
        try check(napi.napi_unwrap(self.env, val, @ptrCast([*c]?*anyopaque, &res)));
        return res;
    }

    pub fn read(self: *JsContext, comptime T: type, val: napi.napi_value) Error!T {
        // TODO: custom mappings

        if (T == napi.napi_value) return val;
        if (comptime trait.isZigString(T)) return self.readString(val);

        return switch (@typeInfo(T)) {
            .Void => void{},
            .Null => null,
            .Bool => self.readBool(val),
            .Int, .ComptimeInt, .Float, .ComptimeFloat => self.readNumber(T, val),
            .Enum => std.meta.intToEnum(T, self.read(u32, val)),
            .Struct => if (std.meta.trait.isTuple(T)) self.readTuple(T, val) else self.readObject(T, val),
            .Optional => |info| self.readOptional(info.child, val),
            .Pointer => |info| self.readPtr(info.child, val),
            else => @compileError("reading " ++ @tagName(@typeInfo(T)) ++ " is not supported"),
        };
    }

    pub fn write(self: *JsContext, val: anytype) Error!napi.napi_value {
        const T = @TypeOf(val);

        // TODO: custom mappings

        if (T == napi.napi_value) return val;
        if (comptime trait.isZigString(T)) return self.createString(val);

        return switch (@typeInfo(T)) {
            .Void => self.undefined(),
            .Null => self.null(),
            .Bool => self.createBool(val),
            .Int, .ComptimeInt, .Float, .ComptimeFloat => self.createNumber(val),
            .Enum => self.createNumber(@as(u32, @enumToInt(val))),
            .Struct => if (std.meta.trait.isTuple(T)) self.createTuple(val) else self.createObject(val),
            .Optional => self.createOptional(val),
            .Pointer => self.wrapPtr(val),
            else => @compileError("writing " ++ @tagName(@typeInfo(T)) ++ " is not supported"),
        };
    }

    pub fn createFunction(self: *JsContext, comptime fun: anytype) Error!napi.napi_value {
        const F = @TypeOf(fun);
        const Args = std.meta.ArgsTuple(F);
        const Res = @typeInfo(F).Fn.return_type.?;

        const Helper = struct {
            fn call(env: napi.napi_env, cb_info: napi.napi_callback_info) callconv(.C) napi.napi_value {
                var js = getInstance(env);
                const args = readArgs(js, cb_info) catch |e| return js.throw(e);
                const res = @call(.auto, fun, args);

                if (comptime trait.is(.ErrorUnion)(Res)) {
                    return if (res) |r| js.write(r) catch |e| js.throw(e) else |e| js.throw(e);
                } else {
                    return js.write(res) catch |e| js.throw(e);
                }
            }

            fn readArgs(js: *JsContext, cb_info: napi.napi_callback_info) Error!Args {
                var args: Args = undefined;
                var argc: usize = args.len;
                var argv: [args.len]napi.napi_value = undefined;
                try check(napi.napi_get_cb_info(js.env, cb_info, &argc, &argv, null, null));

                var i: usize = 0;
                inline for (std.meta.fields(Args)) |f| {
                    if (comptime f.type == *JsContext) {
                        @field(args, f.name) = js;
                        continue;
                    }

                    @field(args, f.name) = try js.read(f.type, argv[i]);
                    i += 1;
                }

                if (i != argc) {
                    std.debug.print("Expected {d} args\n", .{i});
                    return error.InvalidArgumentCount;
                }

                return args;
            }
        };

        var res: napi.napi_value = undefined;
        try check(napi.napi_create_function(self.env, "", napi.NAPI_AUTO_LENGTH, &Helper.call, null, &res));
        return res;
    }

    pub fn callFunction(self: *JsContext, recv: napi.napi_value, fun: napi.napi_value, args: anytype) Error!napi.napi_value {
        const Args = @TypeOf(args);
        var argv: [std.meta.fields(Args).len]napi.napi_value = undefined;
        inline for (std.meta.fields(Args), 0..) |f, i| {
            argv[i] = try self.write(@field(args, f.name));
        }

        var res: napi.napi_value = undefined;
        try check(napi.napi_call_function(self.env, recv, fun, argv.len, &argv, &res));
        return res;
    }
};
