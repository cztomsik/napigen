const std = @import("std");
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

// when (nested) function(s) are invoked, they might need to copy JS strings somewhere
// so it can be passed to native, such strings are only valid during the invocation
// TODO: freeing
// TODO: maybe we could just roll-over after some time? or every function invocation
//       could increase/decrease atomic int and if we're at root, we can reuse?
// TODO: thread-safety: this should be thread-local and set-up during dlopen()
var TEMP_GPA = std.heap.GeneralPurposeAllocator(.{}){};
pub const TEMP = TEMP_GPA.allocator();

pub fn wrap(env: napi.napi_env, val: anytype) Error!napi.napi_value {
    var res: napi.napi_value = undefined;

    switch (@TypeOf(val)) {
        napi.napi_value => res = val,
        napi.napi_callback => try check(napi.napi_create_function(env, null, napi.NAPI_AUTO_LENGTH, val, null, &res)),
        void => try check(napi.napi_get_undefined(env, &res)),
        bool => try check(napi.napi_get_boolean(env, val, &res)),
        u8, u16, u32 => try check(napi.napi_create_uint32(env, val, &res)),
        i8, i16, i32 => try check(napi.napi_create_int32(env, val, &res)),
        @TypeOf(0), i64 => try check(napi.napi_create_int64(env, val, &res)),
        @TypeOf(0.0), f16, f32, f64 => try check(napi.napi_create_double(env, val, &res)),
        []const u8 => try check(napi.napi_create_string_utf8(env, @ptrCast([*c]const u8, val), val.len, &res)),
        else => |T| {
            if (comptime std.meta.trait.isZigString(T)) {
                return wrap(env, @as([]const u8, val));
            }

            if (comptime std.meta.trait.isTuple(T)) {
                return objectAssign(env, try wrap(env, [_]void{}), val);
            }

            if (comptime std.meta.trait.isIndexable(T)) {
                try check(napi.napi_create_array(env, &res));
                for (val) |v, i| try check(napi.napi_set_element(env, res, @truncate(u32, i), try wrap(env, v)));
                return res;
            }

            switch (@typeInfo(T)) {
                .Optional => {
                    if (val)
                        res = wrap(env, val)
                    else
                        try check(napi.napi_get_null(env, &res));
                },

                .Struct => {
                    try check(napi.napi_create_object(env, &res));
                    return objectAssign(env, res, val);
                },

                else => @compileError("TODO " ++ @typeName(T)),
            }
        },
    }

    return res;
}

pub fn unwrap(comptime T: type, env: napi.napi_env, val: napi.napi_value) Error!T {
    var res: T = undefined;

    switch (T) {
        napi.napi_value => res = val,
        void => return,
        bool => try check(napi.napi_get_value_bool(env, val, &res)),
        u8, u16 => @truncate(T, unwrap(u32, env, val)),
        u32 => try check(napi.napi_get_value_uint32(env, val, &res)),
        i8, i16 => @truncate(T, unwrap(i32, env, val)),
        i32 => try check(napi.napi_get_value_int32(env, val, &res)),
        i64 => try check(napi.napi_get_value_int64(env, val, &res)),
        f16, f32 => @floatCast(T, unwrap(f64, env, val)),
        f64 => try check(napi.napi_get_value_double(env, val, &res)),
        []const u8 => {
            var len: usize = undefined;
            try check(napi.napi_get_value_string_utf8(env, val, null, 0, &len));
            var buf = try TEMP.alloc(u8, len + 1);
            try check(napi.napi_get_value_string_utf8(env, val, @ptrCast([*c]u8, buf), buf.len, &len));
            res = buf[0..len];
        },
        else => |T| switch (@typeInfo(T)) {
            .Optional => |info| {
                var tp: napi.napi_valuetype = undefined;
                try check(napi.napi_typeof(env, val, &tp));

                if (tp == napi.napi_null)
                    res = null
                else
                    res = try unwrap(info.child, env, val);
            },

            .Struct => |info| {
                inline for (info.fields) |f| {
                    var js_val: napi.napi_value = undefined;
                    try check(napi.napi_get_named_property(env, val, f.name ++ "", &js_val));
                    @field(res, f.name) = try unwrap(f.field_type, env, js_val);
                }
            },

            .Pointer => {
                try check(napi.napi_get_value_external(env, val, @ptrCast([*c]?*anyopaque, &res)));
            },
            else => @compileError("TODO " ++ @typeName(T)),
        },
    }

    return res;
}

fn objectAssign(env: napi.napi_env, target: napi.napi_value, source: anytype) Error!napi.napi_value {
    inline for (std.meta.fields(@TypeOf(source))) |f| {
        try check(napi.napi_set_named_property(env, target, f.name ++ "", try wrap(env, @field(source, f.name))));
    }

    return target;
}

pub fn call(comptime R: type, env: napi.napi_env, fun: napi.napi_value, args: anytype) Error!R {
    const Args = @TypeOf(args);
    const fields = std.meta.fields(Args);

    var argv: [fields.len]napi.napi_value = undefined;
    inline for (fields) |f, i| {
        argv[i] = try wrap(env, @field(args, f.name));
    }

    var res: napi.napi_value = undefined;
    try check(napi.napi_call_function(env, try wrap(env, void{}), fun, fields.len, &argv, &res));
    return try unwrap(R, env, res);
}

// for exporting, comptime only
pub fn wrapFn(comptime fun: anytype) napi.napi_callback {
    return &(struct {
        fn call(env: napi.napi_env, cb_info: napi.napi_callback_info) callconv(.C) napi.napi_value {
            const Args = std.meta.ArgsTuple(@TypeOf(fun.*));
            comptime var fields = std.meta.fields(Args);
            var args: Args = undefined;

            // napi_env special-case for callbacks
            if (fields.len > 0 and fields[0].field_type == napi.napi_env) {
                args.@"0" = env;
                fields = fields[1..];
            }

            var argc: usize = fields.len;
            var argv: [fields.len]napi.napi_value = undefined;
            _ = napi.napi_get_cb_info(env, cb_info, &argc, &argv, null, null);

            if (argc != fields.len) {
                @panic("args");
            }

            inline for (fields) |f, i| {
                @field(args, f.name) = unwrap(f.field_type, env, argv[i]) catch @panic("TODO");
            }

            return wrap(env, @call(.{}, fun, args)) catch @panic("TODO");
        }
    }).call;
}

pub fn throw(env: napi.napi_env, err: anyerror) void {
    _ = napi.napi_throw_error(env, null, @ptrCast([*]const u8, @errorName(err)));
}
