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
    const is_web = target.query.os_tag == .emscripten;

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .raudio = true, // necessary for audio in either desktop or wasm!
        // Web: build raylib for GLES3 so it uses WebGL2's native VAOs. As GLES2 on
        // a WebGL2 context it finds no VAO extension and rebinds attributes every
        // draw, flooding the console with "index out of range" WebGL errors.
        .opengl_version = if (is_web) "gles_3" else "auto",
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

    // With an explicit -Dtarget (e.g. `make macos-app` building both arm64 and
    // x86_64) Zig skips detecting the macOS SDK, so the frameworks raylib links
    // can't be found. Point the exe at the host's SDK.
    if (target.result.os.tag == .macos and !target.query.isNative()) {
        const sdk = std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), " \r\n");
        exe_mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        exe_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    }

    // The Dr. Sbaitso speech engine (libsbaitso_native.a, the native Zig
    // synthesizer -- not the emulator-based libsbaitso.a) is built by the
    // separate DrSbaitsoLib project and referenced from there; it must never be
    // copied into this repo. Native builds use zig-out/lib, web builds
    // zig-out/native-emscripten/lib (DrSbaitsoLib: `make native-lib` and
    // `make native-lib-emscripten` respectively).
    const sbaitso_lib_dir = b.option([]const u8, "sbaitso-lib", "Path to the DrSbaitsoLib project") orelse "../DrSbaitsoLib";
    // -Dsbaitso-lib-file picks an exact .a, e.g. one cross-compiled per arch for `make macos-app`.
    const sbaitso_lib = b.option([]const u8, "sbaitso-lib-file", "Path to libsbaitso_native.a (overrides -Dsbaitso-lib)") orelse
        b.pathJoin(&.{ sbaitso_lib_dir, if (is_web) "zig-out/native-emscripten/lib/libsbaitso_native.a" else "zig-out/lib/libsbaitso_native.a" });
    std.Io.Dir.cwd().access(b.graph.io, b.pathFromRoot(sbaitso_lib), .{}) catch {
        std.debug.print("error: {s} not found; build it in DrSbaitsoLib first ({s}).\n", .{
            b.pathFromRoot(sbaitso_lib),
            if (is_web) "make native-lib-emscripten" else "make native-lib",
        });
        return error.SbaitsoLibNotFound;
    };

    const run_step = b.step("run", "Run the app");

    //web exports are completely separate
    if (is_web) {
        const emsdk = rlz.emsdk;
        const wasm = b.addLibrary(.{
            .name = "DrSbaitsoUI",
            .root_module = exe_mod,
        });

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

        // Link the speech engine into the final wasm.
        try emcc_flags.put(b.pathFromRoot(sbaitso_lib), {});

        var emcc_settings = emsdk.emccDefaultSettings(
            b.allocator,
            .{ .optimize = optimize, .es3 = true },
        );
        // Emscripten's default 64KB stack is too small for the native synth
        // (its frontend keeps a 64KB pitch buffer on the stack).
        try emcc_settings.put("STACK_SIZE", "1048576");

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

        // Our own page that loads DrSbaitsoUI.js/.wasm (served from zig-out/web/).
        const page = b.addInstallFileWithDir(b.path("index.html"), install_dir, "index.html");
        page.step.dependOn(emcc_step);
        b.getInstallStep().dependOn(&page.step);

        const html_filename = try std.fmt.allocPrint(b.allocator, "{s}.html", .{wasm.name});
        const emrun_step = emsdk.emrunStep(
            b,
            b.getInstallPath(install_dir, html_filename),
            &.{},
        );

        emrun_step.dependOn(emcc_step);
        run_step.dependOn(emrun_step);
    } else {
        exe_mod.addObjectFile(.{ .cwd_relative = b.pathFromRoot(sbaitso_lib) });

        const exe = b.addExecutable(.{
            .name = "DrSbaitsoUI",
            .root_module = exe_mod,
        });
        if (target.result.os.tag == .windows) {
            // A GUI app: no console window opening behind the game window.
            exe.subsystem = .windows;

            // Icon + version info (assets/windows/DrSbaitso.rc). The version is
            // "major.minor.patch", stamped as FILEVERSION major,minor,patch,0.
            const app_version = b.option([]const u8, "app-version", "Version stamped into the Windows .exe") orelse "1.0.0";
            var nums = [_]u16{ 0, 0, 0, 0 };
            var it = std.mem.splitScalar(u8, app_version, '.');
            for (&nums) |*n| n.* = std.fmt.parseInt(u16, it.next() orelse break, 10) catch 0;
            exe_mod.addWin32ResourceFile(.{
                .file = b.path("assets/windows/DrSbaitso.rc"),
                .flags = &.{
                    b.fmt("/dAPP_VERSION={d},{d},{d},{d}", .{ nums[0], nums[1], nums[2], nums[3] }),
                    b.fmt("/dAPP_VERSION_STR=\"{s}\"", .{app_version}),
                },
            });
        }
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        run_step.dependOn(&run_cmd.step);

        // Unit tests: runs all tests reachable from src/main.zig (utility.zig,
        // threadsafe/queue.zig, etc. are pulled in transitively via imports).
        const exe_tests = b.addTest(.{
            .root_module = exe_mod,
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        const run_exe_tests = b.addRunArtifact(exe_tests);
        // Some tests load resources/json/* so they must run from the project root.
        run_exe_tests.setCwd(b.path("."));
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_exe_tests.step);
    }
}
