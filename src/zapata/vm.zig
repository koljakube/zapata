const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const wren = @import("./wren.zig");
const WrenError = @import("./error.zig").WrenError;
const allocatorWrapper = @import("./allocator_wrapper.zig").allocatorWrapper;

pub const WriteFn = fn (*Vm, []const u8) void;

pub const Configuration = struct {
    const Self = @This();

    allocator: ?*Allocator = null,
    writeFn: ?WriteFn = null,

    // This will be much nicer when https://github.com/ziglang/zig/issues/2765 is done.
    pub fn newVmInPlace(self: Self, comptime UserData: type, result: *Vm, user_data: ?*UserData) WrenError!void {
        var cfg: wren.Configuration = undefined;
        wren.initConfiguration(&cfg);

        if (self.allocator) |a| {
            cfg.reallocateFn = allocatorWrapper;
        }

        if (self.writeFn) |f| {
            cfg.writeFn = writeWrapper;
        }

        // This is slightly hacky, but even the VM creation needs the
        // allocator.  Create a temporary pseudo-userdata with only the
        // allocator set, it will be replaced after being used once.
        var pseudo_vm: Vm = undefined;
        std.mem.set(u8, std.mem.asBytes(&Vm), 0);
        pseudo_vm.allocator = self.allocator;
        cfg.userData = &pseudo_vm;

        const ptr = wren.newVm(&cfg) orelse return WrenError.VmCreationFailed;
        Vm.initInPlace(UserData, result, ptr, self, user_data);
    }

    fn writeWrapper(vm: ?*wren.Vm, text: [*c]const u8) callconv(.C) void {
        const udptr = wren.getUserData(vm);
        assert(udptr != null);
        const zvm = @ptrCast(*Vm, @alignCast(@alignOf(*Vm), udptr));
        const writeFn = zvm.writeFn orelse std.debug.panic("writeWrapper must only be installed when writeFn is set", .{});
        const ztext = text[0..std.mem.lenZ(text)];
        writeFn(zvm, ztext);
    }
};

pub const Vm = struct {
    const Self = @This();

    vm: *wren.Vm,
    allocator: ?*Allocator,
    writeFn: ?WriteFn,
    user_data_ptr: ?usize,

    // This will be much nicer when https://github.com/ziglang/zig/issues/2765 is done.
    pub fn initInPlace(comptime UserData: type, result: *Self, vm: *wren.Vm, conf: Configuration, user_data: ?*UserData) void {
        result.vm = vm;
        result.allocator = conf.allocator;
        result.writeFn = conf.writeFn;
        result.user_data_ptr = if (@sizeOf(UserData) > 0 and user_data != null) @ptrToInt(user_data) else null;
        result.registerWithWren();
    }

    pub fn deinit(self: *Self) void {
        wren.freeVm(self.vm);
    }

    fn registerWithWren(self: *Vm) void {
        wren.setUserData(self.vm, self);
    }

    pub fn getUserData(self: Self, comptime UserData: type) *UserData {
        const udp = self.user_data_ptr orelse std.debug.panic("user data pointer is null", .{});
        return @intToPtr(*UserData, udp);
    }

    pub fn interpret(self: *Self, module: []const u8, code: []const u8) WrenError!void {
        const res = wren.interpret(self.vm, @ptrCast([*c]const u8, module), @ptrCast([*c]const u8, code));
        if (res == .WREN_RESULT_COMPILE_ERROR) {
            return WrenError.CompileError;
        }
        if (res == .WREN_RESULT_RUNTIME_ERROR) {
            return WrenError.RuntimeError;
        }
    }
};

const testing = std.testing;

const EmptyUserData = struct {};
const TestUserData = struct {
    i: i32,
};

test "init vm" {
    var user_data = TestUserData{ .i = 23 };
    var config = Configuration{};
    var vm: Vm = undefined;
    try config.newVmInPlace(TestUserData, &vm, &user_data);
    defer vm.deinit();

    const ud = vm.getUserData(TestUserData);
    testing.expectEqual(@as(i32, 23), ud.i);
}

var testPrintSuccess = false;
fn testPrint(vm: *Vm, text: []const u8) void {
    testPrintSuccess = true;
}

test "writeFn" {
    var config = Configuration{};
    config.writeFn = testPrint;

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    testing.expect(!testPrintSuccess);
    try vm.interpret("main", "System.print(\"I am running in a VM!\")");
    testing.expect(testPrintSuccess);
}

test "allocators" {
    const alloc = std.testing.allocator;
    // const alloc = std.heap.c_allocator;
    var config = Configuration{};
    config.allocator = alloc;

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();
    try vm.interpret("main", "System.print(\"I am running in a VM!\")");
}
