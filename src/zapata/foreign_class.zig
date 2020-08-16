const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const wren = @import("./wren.zig");
const Configuration = @import("./vm.zig").Configuration;
const Vm = @import("./vm.zig").Vm;
const ErrorType = @import("./vm.zig").ErrorType;

pub fn ForeignClass(name: []const u8, comptime Class: anytype) type {
    var has_allocate = false;
    const ti = @typeInfo(Class);

    const parseDecl = struct {
        pub fn call(comptime decl: std.builtin.FnDecl) void {
            const ti = @typeInfo(decl.fn_type);
        }
    };

    inline for (ti.Struct.decls) |decl| {
        switch (decl.data) {
            .Fn => @compileLog(decl.name),
            else => {},
        }
    }
}

pub fn registerForeignClasses(vm: *Vm, comptime Classes: anytype) void {
    if (@typeInfo(@TypeOf(Classes)) != .Struct or (@typeInfo(@TypeOf(Classes)) == .Struct and !@typeInfo(@TypeOf(Classes)).Struct.is_tuple)) {
        @compileError("foreign classes must be passed as a tuple");
    }

    inline for (Classes) |Class| {}
}

const EmptyUserData = struct {};

fn printError(vm: *Vm, error_type: ErrorType, module: ?[]const u8, line: ?u32, message: []const u8) void {
    std.debug.print("error_type={}, module={}, line={}, message={}\n", .{ error_type, module, line, message });
}

fn print(vm: *Vm, msg: []const u8) void {
    std.debug.print("{}", .{msg});
}

var test_class_was_allocated = false;
var test_class_was_called: bool = false;
var test_class_was_finalized: bool = false;

const TestClass = struct {
    const Self = @This();

    // Make the struct have a size > 0.
    data: [4]u8,

    pub fn allocate(self: *Self, vm: *Vm) void {
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
    var config = Configuration{};
    config.errorFn = printError;
    config.writeFn = print;
    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    const classInfo = registerForeignClasses(&vm, .{
        ForeignClass("TestClass", TestClass),
    });

    ForeignClass("TestClass", TestClass).print();

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
