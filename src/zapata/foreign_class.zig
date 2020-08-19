const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;
const testing = std.testing;

const wren = @import("./wren.zig");
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
    const arg_offset = 2;
    // See https://github.com/ziglang/zig/issues/229
    return struct {
        // See https://github.com/ziglang/zig/issues/2930
        fn call(vm: *Vm, args: anytype) (if (Fn.return_type) |rt| rt else void) {
            if (Fn.args.len == args.len) {
                return @call(.{}, func, args);
            } else {
                const i = args.len;
                const a = vm.getSlot(Fn.args[i].arg_type.?, 1 + i - arg_offset);
                return @call(.{ .modifier = .always_inline }, call, .{ vm, args ++ .{a} });
            }
        }

        fn thunk(cvm: ?*wren.Vm) callconv(.C) void {
            const vm = Vm.fromC(cvm);
            const instance = vm.getSlot(*Class, 0);

            const result = @call(.{ .modifier = .always_inline }, call, .{ vm, .{ instance, vm } });
            const return_type = @TypeOf(result);
            if (return_type != void) {
                if (@typeInfo(return_type) == .ErrorUnion) {
                    if (result) |success| {
                        if (@TypeOf(success) != void) {
                            vm.setSlot(0, success);
                        }
                    } else |err| {
                        vm.abortFiber(0, @errorName(err));
                    }
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
                const a = vm.getSlot(Fn.args[i].arg_type.?, 1 + i - arg_offset);
                return @call(.{ .modifier = .always_inline }, call, .{ vm, args ++ .{a} });
            }
        }

        fn thunk(cvm: ?*wren.Vm) callconv(.C) void {
            const vm = Vm.fromC(cvm);

            const foreign = wren.setSlotNewForeign(cvm, 0, 0, @sizeOf(Class));
            assert(foreign != null);
            const instance = @ptrCast(*Class, @alignCast(@alignOf(Class), foreign));

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

const MethodDesc = struct { name: []const u8, argument_count: usize, method: WrappedFn };

pub fn ForeignClass(class_name: []const u8, comptime Class: anytype) type {
    const ti = @typeInfo(Class);

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

        pub fn isInstanceMethod(comptime decl: std.builtin.TypeInfo.Declaration) bool {
            if (isInitialize(decl) or isFinalize(decl)) return false;

            const fn_type_info = @typeInfo(decl.data.Fn.fn_type);
            // At least self and vm must be present.
            if (fn_type_info.Fn.args.len < 2) return false;
            if (fn_type_info.Fn.args[0].arg_type.? != *Class) return false;
            if (fn_type_info.Fn.args[1].arg_type.? != *Vm) return false;

            return true;
        }

        pub fn isStaticMethod(comptime decl: std.builtin.TypeInfo.Declaration) bool {
            if (isInitialize(decl) or isFinalize(decl)) return false;

            const fn_type_info = @typeInfo(decl.data.Fn.fn_type);
            // At least the vm must be present.
            if (fn_type_info.Fn.args.len < 1) return false;
            if (fn_type_info.Fn.args[0].arg_type.? != *Vm) return false;

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

        pub fn countInstanceMethods(comptime strct: std.builtin.TypeInfo.Struct) comptime_int {
            comptime var method_count = 0;
            inline for (strct.decls) |decl| {
                switch (decl.data) {
                    .Fn => {
                        if (isInstanceMethod(decl)) {
                            method_count += 1;
                        }
                    },
                    else => {},
                }
            }
            return method_count;
        }

        pub fn countStaticMethods(comptime strct: std.builtin.TypeInfo.Struct) comptime_int {
            comptime var method_count = 0;
            inline for (strct.decls) |decl| {
                switch (decl.data) {
                    .Fn => {
                        if (isStaticMethod(decl)) {
                            method_count += 1;
                        }
                    },
                    else => {},
                }
            }
            return method_count;
        }
    };

    // TODO: Check back when https://github.com/ziglang/zig/issues/6084 is fixed.
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
    comptime var instance_method_count = 0;
    inline for (ti.Struct.decls) |decl| {
        comptime {
            switch (decl.data) {
                .Fn => {
                    if (meta.isInstanceMethod(decl)) {
                        instance_method_count += 1;
                    }
                },
                else => {},
            }
        }
    }
    // comptime const instance_method_count = meta.countInstanceMethods(ti.Struct);
    comptime var static_method_count = 0;
    inline for (ti.Struct.decls) |decl| {
        comptime {
            switch (decl.data) {
                .Fn => {
                    if (meta.isStaticMethod(decl)) {
                        static_method_count += 1;
                    }
                },
                else => {},
            }
        }
        // comptime const static_method_count = meta.countStaticMethods(ti.Struct);
    }

    // One of the zero-arg initializer.
    comptime var initializers: [max_initializer_args + 1]WrappedFn = undefined;
    std.mem.set(WrappedFn, initializers[0..], null);
    comptime var finalizer: WrappedFinalizeFn = null;
    comptime var instance_methods: [instance_method_count]MethodDesc = undefined;
    comptime var instance_method_index = 0;
    comptime var static_methods: [static_method_count]MethodDesc = undefined;
    comptime var static_method_index = 0;

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
                    if (meta.isInstanceMethod(decl)) {
                        instance_methods[instance_method_index] = MethodDesc{
                            .name = decl.name,
                            .argument_count = @typeInfo(decl.data.Fn.fn_type).Fn.args.len - 2,
                            .method = wrap(Class, @field(Class, decl.name)),
                        };
                        instance_method_index += 1;
                    }
                    if (meta.isStaticMethod(decl)) {
                        static_methods[static_method_index] = MethodDesc{
                            .name = decl.name,
                            .argument_count = @typeInfo(decl.data.Fn.fn_type).Fn.args.len - 1,
                            .method = wrap(Class, @field(Class, decl.name)),
                        };
                        static_method_index += 1;
                    }
                },
                else => {},
            }
        }
    }

    return struct {
        const name: []const u8 = class_name;

        fn allocate(cvm: ?*wren.Vm) callconv(.C) void {
            const vm = Vm.fromC(cvm);
            // There is always one slot for the class itself.
            // TODO: Check this is set.
            initializers[vm.getSlotCount() - 1].?(cvm);
        }

        pub fn bindForeignClass(cvm: ?*wren.Vm, module_name: [*c]const u8, class_name_: [*c]const u8) callconv(.C) wren.ForeignClassMethods {
            assert(std.mem.eql(u8, name, std.mem.span(class_name_)));
            return wren.ForeignClassMethods{
                .allocate = allocate,
                .finalize = finalizer,
            };
        }

        pub fn bindForeignMethod(cvm: ?*wren.Vm, module_name: [*c]const u8, class_name_: [*c]const u8, is_static: bool, signature: [*c]const u8) callconv(.C) wren.ForeignMethodFn {
            assert(std.mem.eql(u8, name, std.mem.span(class_name_)));
            var method_name: []const u8 = undefined;
            method_name.ptr = signature;
            method_name.len = 0;
            comptime var arg_count = 0;
            for (std.mem.span(signature)) |c, i| {
                if (c == '(') method_name.len = i;
                if (c == '_') arg_count += 1;
            }

            print("class_name = {s}\n", .{class_name_});
            print("static_methods.len = {}\n", .{static_methods.len});

            const methods = if (is_static) static_methods else instance_methods;
            for (methods) |method| {
                if (std.mem.eql(u8, method.name, std.mem.span(method_name)) and method.argument_count == arg_count) {
                    return method.method;
                }
            }
            return null;
        }
    };
}

pub fn ForeignClassInterface(comptime Classes: anytype) type {
    if (@typeInfo(@TypeOf(Classes)) != .Struct or (@typeInfo(@TypeOf(Classes)) == .Struct and !@typeInfo(@TypeOf(Classes)).Struct.is_tuple)) {
        @compileError("foreign classes must be passed as a tuple");
    }

    const ClassDesc = struct {
        name: []const u8,
        bindForeignClassFn: wren.BindForeignClassFn,
        bindForeignMethodFn: wren.BindForeignMethodFn,
    };

    comptime var classes: [Classes.len]ClassDesc = undefined;
    comptime var class_index = 0;

    comptime {
        inline for (Classes) |Class| {
            classes[class_index] = ClassDesc{
                .name = Class.name,
                .bindForeignClassFn = Class.bindForeignClass,
                .bindForeignMethodFn = Class.bindForeignMethod,
            };
            class_index += 1;
        }
    }

    return struct {
        pub fn bindForeignClass(cvm: ?*wren.Vm, module_name: [*c]const u8, class_name: [*c]const u8) callconv(.C) wren.ForeignClassMethods {
            for (classes) |class| {
                if (std.mem.eql(u8, class.name, std.mem.span(class_name))) {
                    return class.bindForeignClassFn.?(cvm, module_name, class_name);
                }
            }
            std.debug.panic("can not bind unknown class {s}", .{class_name});
        }
        pub fn bindForeignMethod(cvm: ?*wren.Vm, module_name: [*c]const u8, class_name: [*c]const u8, is_static: bool, signature: [*c]const u8) callconv(.C) wren.ForeignMethodFn {
            for (classes) |class| {
                if (std.mem.eql(u8, class.name, std.mem.span(class_name))) {
                    return class.bindForeignMethodFn.?(cvm, module_name, class_name, is_static, signature);
                }
            }
            std.debug.panic("can not bind unknown function {s}.{s}", .{ class_name, signature });
        }
    };
}

pub fn registerForeignClasses(config: *Configuration, comptime Classes: anytype) void {
    const interface = ForeignClassInterface(Classes);
    config.bindForeignClassFn = interface.bindForeignClass;
    config.bindForeignMethodFn = interface.bindForeignMethod;
}

const EmptyUserData = struct {};

fn vmPrintError(vm: *Vm, error_type: ErrorType, module: ?[]const u8, line: ?u32, message: []const u8) void {
    std.debug.print("error_type={}, module={}, line={}, message={}\n", .{ error_type, module, line, message });
}

fn vmPrint(vm: *Vm, msg: []const u8) void {
    std.debug.print("{}", .{msg});
}

var test_class_was_allocated = false;
var test_class_was_allocated_with_3_params = false;
var test_class_was_called = false;
var test_class_was_finalized = false;

const TestClass = struct {
    const Self = @This();

    // Make the struct have a size > 0.
    data: [4]u8,

    pub fn initialize0(self: *Self, vm: *Vm) !void {
        test_class_was_allocated = true;
    }

    pub fn initialize3(self: *Self, vm: *Vm, x: i32, y: i32, z: i32) !void {
        test_class_was_allocated_with_3_params = true;
    }

    pub fn finalize(self: *Self) void {
        test_class_was_finalized = true;
    }

    pub fn call(self: *Self, vm: *Vm, str: []const u8) void {
        if (std.mem.eql(u8, str, "lemon")) {
            test_class_was_called = true;
        }
    }
};

var adder_works = false;

const Adder = struct {
    const Self = @This();

    summand: u32,

    pub fn initialize1(self: *Self, vm: *Vm, summand: u32) void {
        self.summand = summand;
    }

    pub fn add(self: *Self, vm: *Vm, summand: u32) void {
        if (self.summand == 5 and summand == 3) {
            adder_works = true;
        }
    }
};

const Namespace = struct {
    pub fn multiply(vm: *Vm, a: i32, b: i32) i32 {
        if (a == 6 and b == 9) {
            return 42;
        }
        return a * b;
    }
};

test "accessing foreign classes" {
    const allocator = std.testing.allocator;
    var config = Configuration{};
    config.errorFn = vmPrintError;
    config.writeFn = vmPrint;
    config.registerForeignClasses(.{
        ForeignClass("TestClass", TestClass),
        ForeignClass("Adder", Adder),
        ForeignClass("Namespace", Namespace),
    });
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    try vm.interpret("test",
        \\foreign class TestClass {
        \\  construct new() {}
        \\  construct new(a, b, c) {}
        \\  foreign call(s)
        \\}
        \\var tc = TestClass.new()
        \\tc.call("lemon")
        \\
        \\var tc2 = TestClass.new(1, 2, 3)
        \\
        \\foreign class Adder {
        \\  construct new(summand) {}
        \\  foreign add(summand)
        \\}
        \\var adder = Adder.new(5)
        \\adder.add(3)
        \\
        \\foreign class Namespace {
        \\  foreign static multiply(a, b)
        \\}
        \\
        \\var product = Namespace.multiply(6, 9)
    );

    vm.getVariable("test", "product", 0);
    const product = vm.getSlot(i32, 0);
    testing.expectEqual(@as(i32, 42), product);

    vm.deinit();

    testing.expect(test_class_was_allocated);
    testing.expect(test_class_was_finalized);
    testing.expect(test_class_was_called);
    testing.expect(test_class_was_allocated_with_3_params);
    testing.expect(adder_works);
}
