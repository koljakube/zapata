const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("zabata", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    lib.addIncludeDir("/usr/local/include");
    lib.linkSystemLibrary("wren");

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    main_tests.addIncludeDir("/usr/local/include");
    main_tests.linkSystemLibrary("wren");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
