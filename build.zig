const std = @import("std");
const rlz = @import("raylib_zig");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .raudio = true, // necessary for audio in either desktop or wasm!
    });
    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    exe_mod.addImport("raylib", raylib);

    const run_step = b.step("run", "Run the app");

    //web exports are completely separate
    if (target.query.os_tag == .emscripten) {
        const emsdk = rlz.emsdk;
        const wasm = b.addLibrary(.{
            .name = "yourname",
            .root_module = exe_mod,
        });

        // This translate_c block is to get access to emsdk http fetch (async) api in wasm land.
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/c.h"),
            .target = target,
            .optimize = optimize,
        });
        const emsdk_dep = raylib_dep.builder.dependency("emsdk", .{});
        translate_c.addIncludePath(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));
        exe_mod.addImport("c", translate_c.createModule());

        const install_dir: std.Build.InstallDir = .{ .custom = "web" };
        var emcc_flags = emsdk.emccDefaultFlags(
            b.allocator,
            .{
                .optimize = optimize,
                .asyncify = true,
            },
        );
        // Additionally, add in this flag, to get the ability to use the http fetch async api.
        try emcc_flags.put("-sFETCH", {});

        // webgl 2.0?
        try emcc_flags.put("-sUSE_WEBGL2", {});

        const emcc_settings = emsdk.emccDefaultSettings(
            b.allocator,
            .{ .optimize = optimize },
        );

        const emcc_step = emsdk.emccStep(b, raylib_artifact, wasm, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            //.shell_file_path = emsdk.shell(raylib_dep),
            .install_dir = install_dir,
            // Bundles up files from resources/ so WASM builds have access to it.
            .embed_paths = &.{.{ .src_path = "resources/" }},
        });
        b.getInstallStep().dependOn(emcc_step);

        const html_filename = try std.fmt.allocPrint(b.allocator, "{s}.html", .{wasm.name});
        const emrun_step = emsdk.emrunStep(
            b,
            b.getInstallPath(install_dir, html_filename),
            &.{},
        );

        emrun_step.dependOn(emcc_step);
        run_step.dependOn(emrun_step);
    } else {
        const exe = b.addExecutable(.{
            .name = "DrSbaitsoUI",
            .root_module = exe_mod,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        run_step.dependOn(&run_cmd.step);
    }
}
