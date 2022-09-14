const std = @import("std");
const napi = @import("napi.zig");

pub usingnamespace napi;

// when (nested) function(s) are invoked, they might need to copy JS strings somewhere
// so it can be passed to native, such strings are only valid during the invocation
// TODO: freeing
// TODO: maybe we could just roll-over after some time? or every function invocation
//       could increase/decrease atomic int and if we're at root, we can reuse?
// TODO: thread-safety: this should be thread-local and set-up during dlopen()
var TEMP_GPA = std.heap.GeneralPurposeAllocator(.{}){};
pub const TEMP = TEMP_GPA.allocator();

const DEFAULT_WRAPPER = Wrapper(.{});

pub usingnamespace DEFAULT_WRAPPER;

// TODO: support some per-type customization (hooks? nested-cfg-structs?)
pub fn Wrapper(comptime _: anytype) type {
    return struct {
        pub fn wrap(env: napi.napi_env, val: anytype) napi.napi_value {
            var res: napi.napi_value = undefined;

            switch (@TypeOf(val)) {
                napi.napi_value => res = val,
                napi.napi_callback => _ = napi.napi_create_function(env, null, napi.NAPI_AUTO_LENGTH, val, null, &res),
                void => _ = napi.napi_get_undefined(env, &res),
                bool => _ = napi.napi_get_boolean(env, val, &res),
                u32 => _ = napi.napi_create_uint32(env, val, &res),
                i32 => _ = napi.napi_create_int32(env, val, &res),
                i64 => _ = napi.napi_create_int64(env, val, &res),
                f64 => _ = napi.napi_create_double(env, val, &res),
                []const u8 => _ = napi.napi_create_string_utf8(env, @ptrCast([*c]const u8, val), val.len, &res),
                else => |T| switch (@typeInfo(T)) {
                    .Optional => {
                        if (val) res = wrap(env, val) else _ = napi.napi_get_null(env, &res);
                    },

                    .Struct => |info| {
                        _ = napi.napi_create_object(env, &res);

                        inline for (info.fields) |f| {
                            _ = napi.napi_set_named_property(env, res, f.name ++ "", wrap(env, @field(val, f.name)));
                        }
                    },

                    else => @compileError("TODO " ++ @typeName(T)),
                },
            }

            return res;
        }

        pub fn unwrap(comptime T: type, env: napi.napi_env, val: napi.napi_value) T {
            var res: T = undefined;

            switch (T) {
                void => return,
                bool => _ = napi.napi_get_value_bool(env, val, &res),
                u32 => _ = napi.napi_get_value_uint32(env, val, &res),
                i32 => _ = napi.napi_get_value_int32(env, val, &res),
                i64 => _ = napi.napi_get_value_int64(env, val, &res),
                f64 => _ = napi.napi_get_value_double(env, val, &res),
                []const u8 => {
                    var len: usize = undefined;
                    _ = napi.napi_get_value_string_utf8(env, val, null, 0, &len);
                    var buf = TEMP.alloc(u8, len + 1) catch @panic("OOM");
                    _ = napi.napi_get_value_string_utf8(env, val, @ptrCast([*c]u8, buf), buf.len, &len);
                    res = buf[0..len];
                },
                else => |T| switch (@typeInfo(T)) {
                    .Pointer => {
                        _ = napi.napi_get_value_external(env, val, &res);
                    },
                    else => @compileError("TODO " ++ @typeName(T)),
                },
            }

            return res;
        }

        // for exporting, comptime only
        pub fn wrapFn(comptime fun: anytype) napi.napi_callback {
            return &(struct {
                fn call(env: napi.napi_env, cb_info: napi.napi_callback_info) callconv(.C) napi.napi_value {
                    const Args = std.meta.ArgsTuple(@TypeOf(fun.*));
                    const fields = std.meta.fields(Args);
                    var args: Args = undefined;

                    var argc: usize = fields.len;
                    var argv: [fields.len]napi.napi_value = undefined;
                    _ = napi.napi_get_cb_info(env, cb_info, &argc, &argv, null, null);

                    std.debug.assert(argc == fields.len);

                    inline for (fields) |f, i| {
                        @field(args, f.name) = unwrap(f.field_type, env, argv[i]);
                    }

                    return wrap(env, @call(.{}, fun, args));
                }
            }).call;
        }
    };
}
