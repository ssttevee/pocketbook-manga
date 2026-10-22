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
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
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
    const zstd = b.dependency("tachi", .{ .target = zstd_target, .optimize = .ReleaseFast });
    device_step.dependOn(&b.addInstallLibFile(zstd.namedLazyPath("pocketmanga-zstd"), "libpocketmanga-zstd.so").step);
    device_step.dependOn(&b.addInstallFile(zstd.namedLazyPath("zstd-license"), "share/licenses/zstd-LICENSE.txt").step);
    b.getInstallStep().dependOn(device_step);
}
