const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const wren = @import("./wren.zig");
const WrenError = @import("./error.zig").WrenError;
const allocatorWrapper = @import("./allocator_wrapper.zig").allocatorWrapper;

pub const ErrorType = enum { Compile, Runtime, StackTrace };

pub fn AllocatedMemory(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: *Allocator,
        data: []T,

        pub fn init(allocator: *Allocator, len: usize) Self {
            // In the future, not panicking might be nice. But failing
            // allocations here put the VM in an irrecoverable state.
            const data = allocator.alloc(T, len) catch |e| std.debug.panic("could not allocate memory but really need it", .{});
            return Self{ .allocator = allocator, .data = data };
        }
    };
}

const AllocatedBytes = AllocatedMemory(u8);

pub const WriteFn = fn (*Vm, []const u8) void;
pub const ErrorFn = fn (*Vm, ErrorType, ?[]const u8, ?u32, []const u8) void;
pub const ResolveModuleFn = fn (*Vm, []const u8, []const u8) AllocatedBytes;
pub const LoadModuleFn = fn (*Vm, []const u8) AllocatedBytes;

pub const Configuration = struct {
    const Self = @This();

    allocator: ?*Allocator = null,
    resolveModuleFn: ?ResolveModuleFn = null,
    loadModuleFn: ?LoadModuleFn = null,
    writeFn: ?WriteFn = null,
    errorFn: ?ErrorFn = null,
    initialHeapSize: ?usize = null,
    minHeapSize: ?usize = null,
    heapGrowthPercent: ?u8 = null,

    // This will be much nicer when https://github.com/ziglang/zig/issues/2765 is done.
    pub fn newVmInPlace(self: Self, comptime UserData: type, result: *Vm, user_data: ?*UserData) WrenError!void {
        var cfg: wren.Configuration = undefined;
        wren.initConfiguration(&cfg);

        if (self.allocator) |a| {
            cfg.reallocateFn = allocatorWrapper;
        }

        if (self.resolveModuleFn) |f| {
            cfg.resolveModuleFn = resolveModuleWrapper;
        }

        if (self.loadModuleFn) |f| {
            cfg.loadModuleFn = loadModuleWrapper;
        }

        if (self.writeFn) |f| {
            cfg.writeFn = writeWrapper;
        }

        if (self.errorFn) |f| {
            cfg.errorFn = errorWrapper;
        }

        if (self.initialHeapSize) |i| {
            cfg.initialHeapSize = i;
        }
        if (self.minHeapSize) |i| {
            cfg.minHeapSize = i;
        }
        if (self.heapGrowthPercent) |i| {
            cfg.heapGrowthPercent = i;
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

    fn zigVmFromCVm(vm: ?*wren.Vm) *Vm {
        const udptr = wren.getUserData(vm);
        assert(udptr != null);
        return @ptrCast(*Vm, @alignCast(@alignOf(*Vm), udptr));
    }

    fn cStrToSlice(str: [*c]const u8) []const u8 {
        return str[0..std.mem.lenZ(str)];
    }

    fn writeWrapper(cvm: ?*wren.Vm, ctext: [*c]const u8) callconv(.C) void {
        const vm = zigVmFromCVm(cvm);
        const writeFn = vm.writeFn orelse std.debug.panic("writeWrapper must only be installed when writeFn is set", .{});
        writeFn(vm, cStrToSlice(ctext));
    }

    fn errorWrapper(cvm: ?*wren.Vm, cerr_type: wren.ErrorType, cmodule: [*c]const u8, cline: c_int, cmessage: [*c]const u8) callconv(.C) void {
        const vm = zigVmFromCVm(cvm);
        const errorFn = vm.errorFn orelse std.debug.panic("errorWrapper must only be installed when errorFn is set", .{});
        const err_type: ErrorType = switch (cerr_type) {
            .WREN_ERROR_COMPILE => .Compile,
            .WREN_ERROR_RUNTIME => .Runtime,
            .WREN_ERROR_STACK_TRACE => .StackTrace,
            else => std.debug.panic("unknown error type: {}", .{cerr_type}),
        };
        errorFn(vm, err_type, if (cmodule != null) cStrToSlice(cmodule) else null, if (cline >= 0) @intCast(u32, cline) else null, cStrToSlice(cmessage));
    }

    fn resolveModuleWrapper(cvm: ?*wren.Vm, cimporter: [*c]const u8, cname: [*c]const u8) callconv(.C) [*c]u8 {
        const vm = zigVmFromCVm(cvm);
        const resolveModuleFn = vm.resolveModuleFn orelse std.debug.panic("resolveModuleWrapper must only be installed when resolveModuleFn is set", .{});
        const mem = resolveModuleFn(vm, cStrToSlice(cimporter), cStrToSlice(cname));
        assert(mem.allocator == if (vm.allocator == null) std.heap.c_allocator else vm.allocator);
        return mem.data.ptr;
    }

    fn loadModuleWrapper(cvm: ?*wren.Vm, cname: [*c]const u8) callconv(.C) [*c]u8 {
        const vm = zigVmFromCVm(cvm);
        const loadModuleFn = vm.loadModuleFn orelse std.debug.panic("loadModuleWrapper must only be installed when loadModuleFn is set", .{});
        const mem = loadModuleFn(vm, cStrToSlice(cname));
        assert(mem.allocator == if (vm.allocator == null) std.heap.c_allocator else vm.allocator);
        return mem.data.ptr;
    }
};

pub const Vm = struct {
    const Self = @This();

    vm: *wren.Vm,
    allocator: ?*Allocator,
    resolveModuleFn: ?ResolveModuleFn,
    loadModuleFn: ?LoadModuleFn,
    writeFn: ?WriteFn,
    errorFn: ?ErrorFn,
    user_data_ptr: ?usize,

    // This will be much nicer when https://github.com/ziglang/zig/issues/2765 is done.
    pub fn initInPlace(comptime UserData: type, result: *Self, vm: *wren.Vm, conf: Configuration, user_data: ?*UserData) void {
        result.vm = vm;
        result.allocator = conf.allocator;
        result.resolveModuleFn = conf.resolveModuleFn;
        result.loadModuleFn = conf.loadModuleFn;
        result.writeFn = conf.writeFn;
        result.errorFn = conf.errorFn;
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

fn printError(vm: *Vm, error_type: ErrorType, module: ?[]const u8, line: ?u32, message: []const u8) void {
    std.debug.print("error_type={}, module={}, line={}, message={}\n", .{ error_type, module, line, message });
}

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

var testLoadModuleSuccess = false;
fn testLoadModule(vm: *Vm, name: []const u8) AllocatedBytes {
    testing.expect(std.mem.eql(u8, name, "my_module"));
    testLoadModuleSuccess = true;
    const source = "System.print(\"I am running in a VM!\")";
    var mem = AllocatedMemory(u8).init(std.heap.c_allocator, source.len + 1);
    std.mem.copy(u8, mem.data, source);
    mem.data[source.len] = 0;
    return mem;
}

test "loadModuleFn" {
    var config = Configuration{};
    config.loadModuleFn = testLoadModule;

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();
    try vm.interpret("main", "import \"my_module\"");
    testing.expect(testLoadModuleSuccess == true);
}

var testCompileErrorCount: i32 = 0;
var testRuntimeErrorCount: i32 = 0;
var testStackTraceErrorCount: i32 = 0;
fn testError(vm: *Vm, error_type: ErrorType, module: ?[]const u8, line: ?u32, message: []const u8) void {
    if (error_type == .Compile) {
        testCompileErrorCount += 1;
    }
    if (error_type == .Runtime) {
        testRuntimeErrorCount += 1;
    }
    if (error_type == .StackTrace) {
        testStackTraceErrorCount += 1;
    }
}

test "errorFn" {
    var config = Configuration{};
    config.errorFn = testError;

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);

    vm.interpret("main", "zimport \"my_module\"") catch |e| {};
    testing.expectEqual(testCompileErrorCount, 2);

    vm.interpret("main", "import \"blob\"") catch |e| {};
    testing.expectEqual(@intCast(i32, 1), testRuntimeErrorCount);
    testing.expectEqual(@intCast(i32, 1), testStackTraceErrorCount);
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
