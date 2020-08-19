pub usingnamespace @import("./zapata/call.zig");
pub usingnamespace @import("./zapata/error.zig");
pub usingnamespace @import("./zapata/foreign.zig");
pub usingnamespace @import("./zapata/function_handle.zig");
pub usingnamespace @import("./zapata/handle.zig");
pub usingnamespace @import("./zapata/vm.zig");

test "zapata" {
    _ = @import("./zapata/allocator_wrapper.zig");
    _ = @import("./zapata/call.zig");
    _ = @import("./zapata/error.zig");
    _ = @import("./zapata/foreign.zig");
    _ = @import("./zapata/function_handle.zig");
    _ = @import("./zapata/handle.zig");
    _ = @import("./zapata/vm.zig");
    _ = @import("./zapata/wren.zig");
}
