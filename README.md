## Zapata is a wrapper around the [Wren](https://wren.io) scripting language written in [Zig](https://ziglang.org)

See it in action:

```zig
const std = @import("std");

const zapata = @import("./src/main.zig");
const Configuration = zapata.Configuration;
const Vm = zapata.Vm;
const ForeignClass = zapata.ForeignClass;
const Method = zapata.Method;

const EmptyUserData = struct {};

const ToWrenAndBack = struct {
    const Self = @This();

    n: i32,

    pub fn initialize1(self: *Self, vm: *Vm, n: i32) void {
        self.n = n;
    }

    pub fn call(self: *Self, vm: *Vm, message: []const u8) []const u8 {
        if (self.n == 42 and std.mem.eql(u8, "Though Wren to Zig...", message)) {
            std.debug.print("{s}\n", .{message});
            return "...and back!";
        }
        return "";
    }
};

pub fn main() !void {
    var config = Configuration{};
    config.registerForeignClasses(.{
        ForeignClass("ToWrenAndBack", ToWrenAndBack),
    });

    var vm: Vm = undefined;
    try config.newVmInPlace(EmptyUserData, &vm, null);
    defer vm.deinit();

    try vm.interpret("main",
        \\foreign class ToWrenAndBack {
        \\  construct new(n) {}
        \\  foreign call(message)
        \\}
        \\
        \\var twab = ToWrenAndBack.new(42)
    );

    const receiver = vm.makeReceiver("main", "twab");
    defer receiver.deinit();
    const call_sig = vm.makeCallHandle("call(_)");
    defer call_sig.deinit();

    const call = Method([]const u8, .{[]const u8}).init(receiver, call_sig);

    std.debug.print("{s}\n", .{try call.call(.{"Though Wren to Zig..."})});
}
```

### Status

The library is usable, but some Wren features are missing. Current (known)
unsupported features are lists, maps, and per-module foreign classes.

### Building

Currently, Zapata depends on a [as-of-yet unaccepted patch to
Wren](https://github.com/wren-lang/wren/pull/788) to enable per-VM allocators.
Because of this, simply put `wren.h` into `vendor/wren/include` and `libwren.a`
into `vendor/wren/lib`. If `vendor/wren` exists, it will be used automatically,
otherwise a system-wide installation of Wren is used.

If you've got a compatible Wren available, building the library is just a

```bash
zig build
```

away.

### Documentation

Is lacking.

### Contributing

Fixes, improvements, and added tests are very welcome. Major style changes
would need to be discussed – Wren is simple enough to embed that a wrapper is
not strictly necessary, so this library will keep a slightly opinionated style
designed for specific use cases.

### Name

Zapata is named after a species of wren that begins with a 'z'. That's it.
