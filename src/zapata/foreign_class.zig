const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

const wren = @import("./wren.zig");
const c_wrappers = @import("./c_wrappers.zig");
const Configuration = @import("./vm.zig").Configuration;
const Vm = @import("./vm.zig").Vm;
const ErrorType = @import("./vm.zig").ErrorType;

pub const ForeignClassRegistry = StringHashMap(ForeignClassDesc);

pub const ForeignMethodDesc = struct {};

pub const ForeignClassDesc = struct {};

const WrappedFn = wren.ForeignMethodFn;
const WrappedFinalizeFn = wren.FinalizeFn;

// "Inspired" by
// https://github.com/daurnimator/zig-autolua/blob/5bc7194124a7d7a14e6efe5033c75c7ad4b19cb8/src/autolua.zig#L185-L210
// Used with permission.
fn wrap(comptime Class: type, comptime func: anytype) WrappedFn {
    const Fn = @typeInfo(@TypeOf(func)).Fn;
    const arg_offset = 1;
    // See https://github.com/ziglang/zig/issues/229
    return struct {
        // See https://github.com/ziglang/zig/issues/2930
        fn call(args: anytype, arg_offset: usize) (if (Fn.return_type) |rt| rt else void) {
            if (Fn.args.len == args.len) {
                return @call(.{}, func, args);
            } else {
                const i = args.len;
                const a = vm.getSlot(Fn.args[i - arg_offset].arg_type.?, i);
                return @call(.{ .modifier = .always_inline }, call, .{args ++ .{a}});
            }
        }

        fn thunk(cvm: ?*wren.Vm) callconv(.C) void {
            const vm = Vm.fromC(cvm);
            const instance = vm.getSlot(*Class, 0);

            // TODO: Can the call be deduplicated?
            const result = @call(.{ .modifier = .always_inline }, call, .{ vm, .{vm} });
            const return_type = @TypeOf(result);
            if (return_type != void) {
                if (@typeInfo(return_type) == .ErrorUnion) {
                    vm.abortFiber(0, @errorName(e));
                } else {
                    vm.setSlot(0, result);
                }
            }
        }
    }.thunk;
}
fn wrapInitialize(comptime Class: type, comptime func: anytype) WrappedFn {
    const Fn = @typeInfo(@TypeOf(func)).Fn;

    const arg_offset = 2;
    // See https://github.com/ziglang/zig/issues/229
    return struct {
        // See https://github.com/ziglang/zig/issues/2930
        fn call(vm: *Vm, args: anytype) (if (Fn.return_type) |rt| rt else void) {
            if (Fn.args.len == args.len) {
                return @call(.{}, func, args);
            } else {
                const i = args.len;
                const a = vm.getSlot(Fn.args[i].arg_type.?, i - arg_offset);
                return @call(.{ .modifier = .always_inline }, call, .{ vm, args ++ .{a} });
            }
        }

        fn thunk(cvm: ?*wren.Vm) callconv(.C) void {
            const vm = Vm.fromC(cvm);

            const foreign = wren.setSlotNewForeign(cvm, 0, 0, @sizeOf(Class));
            assert(foreign != null);
            const instance = @ptrCast(*Class, foreign);

            // TODO: Can the call be deduplicated?
            const return_type = Fn.return_type.?;
            if (@typeInfo(return_type) == .ErrorUnion) {
                const result = @call(.{ .modifier = .always_inline }, call, .{ vm, .{ instance, vm } }) catch |e| {
                    vm.abortFiber(0, @errorName(e));
                    return;
                };
                if (@typeInfo(return_type).ErrorUnion.payload != void) {
                    vm.setSlot(0, result);
                }
            } else {
                const result = @call(.{ .modifier = .always_inline }, call, .{ vm, .{ instance, vm } });
                if (return_type != void) {
                    vm.setSlot(0, result);
                }
            }
        }
    }.thunk;
}
fn wrapFinalize(comptime Class: type, comptime func: anytype) WrappedFinalizeFn {
    const Fn = @typeInfo(@TypeOf(func)).Fn;

    // See https://github.com/ziglang/zig/issues/229
    return struct {
        fn thunk(ptr: ?*c_void) callconv(.C) void {
            const instance = @ptrCast(*Class, ptr);
            const result = @call(.{ .modifier = .always_inline }, func, .{instance});
        }
    }.thunk;
}

pub fn ForeignClass(name: []const u8, comptime Class: anytype) type {
    const ti = @typeInfo(Class);

    const print = std.debug.print;

    const meta = struct {
        pub fn isInitialize(comptime decl: std.builtin.TypeInfo.Declaration) bool {
            comptime {
                const name_base = "initialize";
                if (!std.mem.startsWith(u8, decl.name, name_base)) return false;
                // @compileLog(name_base.len);
                // @compileLog(decl.name.len);
                if (decl.name.len <= name_base.len) return false;
                const digits = decl.name[name_base.len..];
                const num = std.fmt.parseInt(usize, digits, 10) catch |e| {
                    return false;
                };

                const fn_type_info = @typeInfo(decl.data.Fn.fn_type);
                if (fn_type_info.Fn.args.len != 2 + num) return false;

                const arg1_info = @typeInfo(fn_type_info.Fn.args[0].arg_type orelse unreachable);
                if (arg1_info != .Pointer) return false;
                if (arg1_info.Pointer.child != Class) return false;

                const arg2_info = @typeInfo(fn_type_info.Fn.args[1].arg_type orelse unreachable);
                if (arg2_info != .Pointer) return false;
                if (arg2_info.Pointer.child != Vm) return false;

                const ret_info = @typeInfo(fn_type_info.Fn.return_type orelse unreachable);
                if (ret_info != .Void and (ret_info != .ErrorUnion or ret_info.ErrorUnion.payload != void)) return false;

                return true;
            }
        }

        pub fn isFinalize(comptime decl: std.builtin.TypeInfo.Declaration) bool {
            if (!std.mem.eql(u8, "finalize", decl.name)) return false;

            const fn_type_info = @typeInfo(decl.data.Fn.fn_type);
            if (fn_type_info.Fn.args.len != 1) return false;

            const arg1_info = @typeInfo(fn_type_info.Fn.args[0].arg_type orelse unreachable);
            if (arg1_info != .Pointer) return false;
            if (arg1_info.Pointer.child != Class) return false;

            const ret_info = @typeInfo(fn_type_info.Fn.return_type orelse unreachable);
            // No access to the VM, so no way to signal errors to it.
            if (ret_info != .Void) return false;

            return true;
        }

        pub fn isMethod(comptime decl: std.builtin.TypeInfo.Declaration) bool {
            if (isInitialize(decl) or isFinalize(decl)) return false;

            const fn_type_info = @typeInfo(decl.data.Fn.fn_type);
            // At least self and vm must be present.
            if (fn_type_info.Fn.args.len < 2) return false;

            return true;
        }

        pub fn countInitializers(comptime strct: std.builtin.TypeInfo.Struct) comptime_int {
            comptime var initializer_count = 0;
            inline for (strct.decls) |decl| {
                switch (decl.data) {
                    .Fn => {
                        if (isInitialize(decl)) {
                            initializer_count += 1;
                        }
                    },
                    else => {},
                }
            }
            return initializer_count;
        }

        pub fn calcMaxInitializerArgs(comptime strct: std.builtin.TypeInfo.Struct) comptime_int {
            comptime var max = 0;
            inline for (strct.decls) |decl| {
                switch (decl.data) {
                    .Fn => {
                        if (isInitialize(decl)) {
                            const fn_type_info = @typeInfo(decl.data.Fn.fn_type);
                            const count = fn_type_info.Fn.args.len - 2;
                            max = std.math.max(max, count);
                        }
                    },
                    else => {},
                }
            }
            return max;
        }

        pub fn countMethods(comptime strct: std.builtin.TypeInfo.Struct) comptime_int {
            comptime var method_count = 0;
            inline for (strct.decls) |decl| {
                switch (decl.data) {
                    .Fn => {
                        if (isMethod(decl)) {
                            method_count += 1;
                        }
                    },
                    else => {},
                }
            }
            return method_count;
        }
    };

    return struct {
        pub fn printInfo(allocator: *Allocator) void {
            comptime var max_initializer_args = 0;
            inline for (ti.Struct.decls) |decl| {
                comptime {
                    switch (decl.data) {
                        .Fn => {
                            if (meta.isInitialize(decl)) {
                                const fn_type_info = @typeInfo(decl.data.Fn.fn_type);
                                const count = fn_type_info.Fn.args.len - 2;
                                max_initializer_args = std.math.max(max_initializer_args, @as(comptime_int, count));
                            }
                        },
                        else => {},
                    }
                }
            }
            // comptime const max_initializer_args = meta.calcMaxInitializerArgs(ti.Struct);
            comptime var method_count = 0;
            inline for (ti.Struct.decls) |decl| {
                comptime {
                    switch (decl.data) {
                        .Fn => {
                            if (meta.isMethod(decl)) {
                                method_count += 1;
                            }
                        },
                        else => {},
                    }
                }
            }
            // comptime const method_count = meta.countInitializers(ti.Struct);

            const Method = struct { name: []const u8, method: WrappedFn };
            const ClassMetadata = struct {
                initializers: [max_initializer_args + 1]?WrappedFn = undefined,
                finalizer: ?WrappedFinalizeFn,
                methods: [method_count]Method,
            };
            // One of the zero-arg initializer.
            comptime var initializers: [max_initializer_args + 1]?WrappedFn = undefined;
            comptime var finalizer: ?WrappedFinalizeFn = undefined;
            comptime var methods: [method_count]Method = undefined;
            comptime var method_index = 0;

            inline for (ti.Struct.decls) |decl| {
                comptime {
                    switch (decl.data) {
                        .Fn => {
                            if (meta.isInitialize(decl)) {
                                initializers[@typeInfo(decl.data.Fn.fn_type).Fn.args.len - 2] = wrapInitialize(Class, @field(Class, decl.name));
                            }
                            if (meta.isFinalize(decl)) {
                                finalizer = wrapFinalize(Class, @field(Class, decl.name));
                            }
                            if (meta.isMethod(decl)) {
                                methods[method_index] = Method{ .name = decl.name, .method = wrap(Class, @field(Class, decl.name)) };
                                method_index += 1;
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    };
}

// pub fn registerForeignClass(config: *Configuration, name: []const u8, comptime Class: anytype) void {
//     const allocator = config.metadata_allocator orelse std.debug.panic("registering foreign classes depends on a metadata allocator\n", .{});
//     if (config.foreign_classes == null) {
//         config.foreign_classes = allocator.create(ForeignClassRegistry).init(allocator);
//     }
//     const fcr = config.foreign_classes orelse unreachable;
//     fcr.put(name, Foreign)
// }
//
// pub fn registerForeignClasses(vm: *Vm, comptime Classes: anytype) void {
//     if (@typeInfo(@TypeOf(Classes)) != .Struct or (@typeInfo(@TypeOf(Classes)) == .Struct and !@typeInfo(@TypeOf(Classes)).Struct.is_tuple)) {
//         @compileError("foreign classes must be passed as a tuple");
//     }
//
//     inline for (Classes) |Class| {}
// }

const EmptyUserData = struct {};

fn vmPrintError(vm: *Vm, error_type: ErrorType, module: ?[]const u8, line: ?u32, message: []const u8) void {
    std.debug.print("error_type={}, module={}, line={}, message={}\n", .{ error_type, module, line, message });
}

fn vmPrint(vm: *Vm, msg: []const u8) void {
    std.debug.print("{}", .{msg});
}

var test_class_was_allocated = false;
var test_class_was_called: bool = false;
var test_class_was_finalized: bool = false;

const TestClass = struct {
    const Self = @This();

    // Make the struct have a size > 0.
    data: [4]u8,

    pub fn initialize(self: *Self, vm: *Vm) !void {
        test_class_was_allocated = true;
    }

    pub fn initialize0(self: *Self, vm: *Vm) !void {
        test_class_was_allocated = true;
    }

    pub fn initialize3(self: *Self, vm: *Vm, x: i32, y: i32, z: i32) !void {
        test_class_was_allocated = true;
    }

    pub fn finalize(self: *Self) void {}

    pub fn call(self: *Self, vm: *Vm, str: []const u8) void {
        if (std.mem.eql(u8, str, "lemon")) {
            test_class_was_called = true;
        }
    }
};

test "accessing foreign classes" {
    const allocator = std.testing.allocator;
    // var config = Configuration{};
    // config.metadata_allocator = allocator;
    // config.errorFn = printError;
    // config.writeFn = print;
    // regsiterForeignClass(&config, "TestClass", TestClass);
    // var vm: Vm = undefined;
    // try config.newVmInPlace(EmptyUserData, &vm, null);

    ForeignClass("TestClass", TestClass).printInfo(allocator);

    // try vm.interpret("test",
    //     \\foreign class TestClass {
    //     \\  construct new() {}
    //     \\  foreign call(s)
    //     \\}
    //     \\var tc = TestClass.new()
    //     \\tc.call("lemon")
    // );
    //
    // testing.expect(test_class_was_allocated);
}
