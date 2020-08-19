const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("zapata", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    const has_vendored_wren = if (std.fs.cwd().access("vendor/wren", .{ .read = true })) |_| true else |_| false;

    if (has_vendored_wren) {
        lib.addIncludeDir("vendor/wren/include");
        lib.addLibPath("vendor/wren/lib");
    }
    lib.linkSystemLibrary("wren");

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    if (has_vendored_wren) {
        main_tests.addIncludeDir("vendor/wren/include");
        main_tests.addLibPath("vendor/wren/lib");
    }
    main_tests.linkSystemLibrary("wren");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
