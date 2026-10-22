const std = @import("std");
const UiModules = struct {
    fabrum: *std.Build.Module,
    platform: *std.Build.Module,
    image: *std.Build.Module,
    tachi: *std.Build.Module,
    fn imports(self: UiModules) [4]std.Build.Module.Import {
        return .{
            .{ .name = "fabrum", .module = self.fabrum },
            .{ .name = "fabrum-platform-inkview", .module = self.platform },
            .{ .name = "reader-image", .module = self.image },
            .{ .name = "tachi", .module = self.tachi },
        };
    }
};
fn uiModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) UiModules {
    const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
    const platform = b.dependency("inkview", .{ .target = target, .optimize = optimize }).module("fabrum-platform-inkview");
    @import("inkview").addFabrum(platform, fabrum);
    const base = b.dependency("renderer", .{ .target = target, .optimize = optimize }).module("fabrum-renderer-z2d");
    base.addImport("fabrum", fabrum);
    const image = b.createModule(.{ .root_source_file = b.path("src/image.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "fabrum", .module = fabrum }} });
    const renderer = b.createModule(.{ .root_source_file = b.path("src/renderer.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "fabrum", .module = fabrum }, .{ .name = "base", .module = base }, .{ .name = "reader-image", .module = image } } });
    platform.addImport("fabrum-renderer-z2d", renderer);
    // The UI process uses libtachi's engine, library and downloads; only the
    // worker ever loads the JVM.
    const tachi = b.dependency("tachi", .{ .target = target, .optimize = optimize }).module("tachi");
    return .{ .fabrum = fabrum, .platform = platform, .image = image, .tachi = tachi };
}

fn runtimeCommand(b: *std.Build, command: []const u8, glibc: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("tools/runtime_cache.py"));
    run.addArgs(&.{ command, "--glibc", glibc });
    for ([_][]const u8{ "tools/runtime-packages.json", "tools/build_jre.py", "tools/release_manifest.py" }) |input| run.addFileInput(b.path(input));
    return run;
}

fn runtimeBuild(b: *std.Build, component: []const u8, glibc: []const u8, inputs: []const []const u8) std.Build.LazyPath {
    const run = runtimeCommand(b, "build", glibc);
    run.setName(b.fmt("Build {s} runtime for glibc {s}", .{ component, glibc }));
    run.addArgs(&.{ "--component", component, "--output" });
    for (inputs) |input| run.addFileInput(b.path(input));
    return run.addOutputDirectoryArg2(component, .{});
}

fn hostJar(host: *std.Build.Dependency) std.Build.LazyPath {
    // libtachi's public host step currently exports an install step rather
    // than a named LazyPath. Reuse its generated input, avoiding zig-out as
    // an intermediate input and respecting custom install prefixes.
    const step = &host.builder.top_level_steps.get("host").?.step;
    var source: ?std.Build.LazyPath = null;
    for (step.dependencies.items) |dependency| {
        if (dependency.cast(std.Build.Step.InstallFile)) |file| {
            if (std.mem.eql(u8, file.dest_rel_path, "tachi-host.jar")) {
                std.debug.assert(source == null);
                source = file.source;
            }
        }
    }
    return source orelse @panic("libtachi host step must export tachi-host.jar");
}

fn installRuntimeTree(b: *std.Build, source: std.Build.LazyPath, destination: []const u8) *std.Build.Step {
    // Zig 0.17's InstallDir skips symlinks, including libvips's SONAME links.
    // Use a preserving installer for generated runtime and release trees.
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("tools/install_tree.py"));
    run.addArg("--source");
    run.addDirectoryArg2(source, .{});
    run.addArg("--destination");
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = destination } }, .{});
    run.has_side_effects = true;
    return &run.step;
}

fn runtimeAndPackageSteps(b: *std.Build, glibc: []const u8, device: *std.Build.Step.Compile, worker: *std.Build.Step.Compile, host: *std.Build.Dependency, zstd: *std.Build.Dependency, target_metadata: std.Build.LazyPath) void {
    const jre = runtimeBuild(b, "jre", glibc, &.{ "tools/jre/Dockerfile", "tools/jre/build-jdk.sh", "tools/jre/crosstool.config" });
    const images = runtimeBuild(b, "images", glibc, &.{
        ".dockerignore",        "tools/build_images.py",         "tools/image/Dockerfile",  "tools/image/sources.json", "tools/image/fetch.py",
        "tools/image/build.sh", "tools/image/cross.ini",         "tools/image/cross.cmake", "tools/image/prune.py",     "tools/image/decoder_only.py",
        "tools/image/smoke.c",  "tools/image/smoke_fixtures.py", "src/vips_bridge.c",       "src/vips_bridge.h",
    });
    const manifest_run = runtimeCommand(b, "manifest", glibc);
    manifest_run.addArg("--jre");
    manifest_run.addDirectoryArg2(jre, .{});
    manifest_run.addArg("--images");
    manifest_run.addDirectoryArg2(images, .{});
    // Snapshot provenance for these producer identities, not for mutations of
    // their cached outputs. A real input change gives a new generated path.
    // In particular, rehashing CDS as an input here would silently approve a
    // corrupted cached CDS by generating a new manifest for the damaged file.
    const runtime_files = [_]std.Build.LazyPath{
        jre.path(b, "pocketmanga-jre.tar"), jre.path(b, "classes.jsa"), images.path(b, "pocketmanga-image.tar"),
    };
    manifest_run.addArg("--output");
    const manifest = manifest_run.addOutputFileArg2("runtime-manifest.json", .{});
    const verify = runtimeCommand(b, "verify", glibc);
    verify.setName("Verify cached runtimes against reviewed checksums");
    verify.has_side_effects = true;
    verify.addArg("--jre");
    verify.addDirectoryArg2(jre, .{});
    verify.addArg("--images");
    verify.addDirectoryArg2(images, .{});
    verify.addArg("--manifest");
    verify.addFileArg(manifest);
    // Run even on producer cache hits: generated output directories themselves
    // are not integrity checked by Zig's Run cache.
    const runtimes = b.step("runtimes", "Build, cache and verify the selected PocketBook runtimes");
    inline for (.{ .{ jre, "runtimes/jre" }, .{ images, "runtimes/images" } }) |entry| {
        const install_runtime = installRuntimeTree(b, entry[0], entry[1]);
        install_runtime.dependOn(&verify.step);
        runtimes.dependOn(install_runtime);
    }
    const install_manifest = b.addInstallFile(manifest, "runtimes/runtime-manifest.json");
    install_manifest.step.dependOn(&verify.step);
    runtimes.dependOn(&install_manifest.step);

    const package = b.addSystemCommand(&.{"python3"});
    package.addFileArg(b.path("tools/package_device.py"));
    package.addArgs(&.{ "--glibc", glibc, "--runtime-manifest" });
    package.addFileArg(manifest);
    package.addArg("--jre");
    package.addFileArg(runtime_files[0]);
    package.addArg("--images");
    package.addFileArg(runtime_files[2]);
    package.addFileInput(runtime_files[1]);
    package.addArg("--ui-binary");
    package.addArtifactArg(device);
    package.addArg("--worker-binary");
    package.addArtifactArg(worker);
    package.addArg("--target-metadata");
    package.addFileArg(target_metadata);
    package.addArg("--host-jar");
    package.addFileArg(hostJar(host));
    package.addArg("--zstd-library");
    package.addFileArg(zstd.namedLazyPath("pocketmanga-zstd"));
    package.addArg("--zstd-license");
    package.addFileArg(zstd.namedLazyPath("zstd-license"));
    for ([_][]const u8{
        "tools/runtime-packages.json",         "tools/release_manifest.py", "tools/image/sources.json",  "tools/BuildTrustStore.java",
        "tools/RUNTIME-NOTICE",                "tools/pocketmanga.app",     "tools/pocketmanga-log.app", "tools/runtime-licenses/gcc-COPYING.RUNTIME",
        "tools/runtime-licenses/gcc-COPYING3",
    }) |input| package.addFileInput(b.path(input));
    package.step.dependOn(&verify.step);
    package.addArg("--output");
    const output = package.addOutputDirectoryArg2("release", .{});
    const install_package = installRuntimeTree(b, output, "release");
    const package_step = b.step("package", "Build a complete PocketBook installation bundle with cached runtimes");
    package_step.dependOn(install_package);
    package_step.dependOn(runtimes);
}
pub fn build(b: *std.Build) error{LazyDependencyNeeded}!void {
    const optimize = b.standardOptimizeOption(.{});
    const jdk = b.option([]const u8, "jdk", "JDK for JNI headers (default: JAVA_HOME); explicit paths also identify cached configurations");
    const glibc = b.option(enum { @"2.23", @"2.39" }, "glibc", "PocketBook firmware glibc (2.23 for 6.8–6.9, 2.39 for 6.10)") orelse .@"2.23";
    const glibc_minor: u32 = switch (glibc) {
        .@"2.23" => 23,
        .@"2.39" => 39,
    };
    const host = b.dependency("tachi", .{});
    b.step("host", "Build and install the Java extension host for packaging").dependOn(&host.builder.top_level_steps.get("host").?.step);
    const host_ui = uiModules(b, b.graph.host, optimize);
    const host_imports = host_ui.imports();
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &host_imports,
        .link_libc = true,
    }) });
    tests.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    b.step("test", "Test storage, navigation, UI and fake InkView host").dependOn(&b.addRunArtifact(tests).step);
    const preview = b.addExecutable(.{ .name = "pocketmanga-preview", .root_module = b.createModule(.{
        .root_source_file = b.path("src/preview.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &host_imports,
        .link_libc = true,
    }) });
    preview.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    b.step("preview", "Render sample screens through fake InkView into preview/").dependOn(&b.addRunArtifact(preview).step);
    const device_target = b.resolveTargetQuery(.{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabi, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 }, .glibc_version = .{ .major = 2, .minor = glibc_minor, .patch = 0 } });
    const device_ui = uiModules(b, device_target, optimize);
    const device_imports = device_ui.imports();
    const device = b.addExecutable(.{ .name = "pocketmanga.app", .root_module = b.createModule(.{
        .root_source_file = b.path("src/inkview.zig"),
        .target = device_target,
        .optimize = optimize,
        .imports = &device_imports,
        .link_libc = true,
    }) });
    device.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    // The worker's JVM is built for the same glibc, so it runs on the reader's own.
    const worker_target = device_target;
    const worker = b.addExecutable(.{ .name = "pocketmanga-worker", .root_module = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = worker_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tachi", .module = device_ui.tachi }},
        .link_libc = true,
    }) });
    worker.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    const probe = b.addExecutable(.{ .name = "pocketmanga-runtime-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("src/runtime_probe.zig"),
        .target = device_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tachi", .module = device_ui.tachi }},
        .link_libc = true,
    }) });
    probe.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    b.step("runtime-probe", "Build ARM UI/worker protocol diagnostic").dependOn(&b.addInstallArtifact(probe, .{}).step);
    const wake_probe = b.addExecutable(.{ .name = "pocketmanga-wake-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("src/wake_probe.zig"),
        .target = device_target,
        .optimize = optimize,
        .imports = &device_imports,
        .link_libc = true,
    }) });
    wake_probe.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    b.step("wake-probe", "Build the standalone reader wake diagnostic").dependOn(&b.addInstallArtifact(wake_probe, .{}).step);
    const install = b.addInstallArtifact(device, .{});
    const launcher = b.addInstallFile(b.path("tools/pocketmanga-log.app"), "bin/pocketmanga-log.app");
    const device_step = b.step("device", "Build native PocketBook UI and isolated JVM worker");
    // Packaging checks this alongside the runtime manifest, preventing a
    // reused zig-out directory from silently mixing firmware targets.
    const target_metadata = b.addWriteFiles().add("build-target.json", b.fmt("{{\"cpu\":\"armv7\",\"abi\":\"softfp\",\"glibc\":\"{s}\"}}\n", .{@tagName(glibc)}));
    device_step.dependOn(&b.addInstallFile(target_metadata, "share/pocketmanga/build-target.json").step);
    device_step.dependOn(&install.step);
    device_step.dependOn(&b.addInstallArtifact(worker, .{}).step);
    device_step.dependOn(&launcher.step);
    // The worker JVM's okhttp3.zstd decoder, built from libtachi's pinned
    // libzstd source for the Verse's ARMv7 with strict alignment.
    const zstd_target = b.resolveTargetQuery(.{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabi, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 }, .cpu_features_add = std.Target.arm.featureSet(&.{.strict_align}), .glibc_version = .{ .major = 2, .minor = 17, .patch = 0 } });
    const zstd = if (jdk) |path|
        b.dependency("tachi", .{ .target = zstd_target, .optimize = .ReleaseFast, .jdk = path })
    else
        b.dependency("tachi", .{ .target = zstd_target, .optimize = .ReleaseFast });
    // A dependency can return before registering its named exports while
    // discovering lazy packages. Let Zig fetch them and rerun configuration
    // before requiring those exports, including for later target instances.
    if (b.graph.needed_lazy_dependencies.count() != 0) return error.LazyDependencyNeeded;
    device_step.dependOn(&b.addInstallLibFile(zstd.namedLazyPath("pocketmanga-zstd"), "libpocketmanga-zstd.so").step);
    device_step.dependOn(&b.addInstallFile(zstd.namedLazyPath("zstd-license"), "share/licenses/zstd-LICENSE.txt").step);
    runtimeAndPackageSteps(b, @tagName(glibc), device, worker, host, zstd, target_metadata);
    b.getInstallStep().dependOn(device_step);
}
