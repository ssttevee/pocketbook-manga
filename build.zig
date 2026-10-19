const std = @import("std");
const UiModules = struct {
    fabrum: *std.Build.Module,
    platform: *std.Build.Module,
    image: *std.Build.Module,
    fn imports(self: UiModules, b: *std.Build) []const std.Build.Module.Import {
        return b.allocator.dupe(std.Build.Module.Import, &.{
            .{ .name = "fabrum", .module = self.fabrum },
            .{ .name = "fabrum-platform-inkview", .module = self.platform },
            .{ .name = "reader-image", .module = self.image },
        }) catch @panic("OOM");
    }
};
fn uiModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) UiModules {
    const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
    const platform = b.dependency("inkview", .{ .target = target, .optimize = optimize }).module("fabrum-platform-inkview");
    @import("inkview").addFabrum(platform, fabrum);
    const base = platform.import_table.get("fabrum-renderer-z2d").?;
    const image = b.createModule(.{ .root_source_file = b.path("src/image.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "fabrum", .module = fabrum }} });
    const renderer = b.createModule(.{ .root_source_file = b.path("src/renderer.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "fabrum", .module = fabrum }, .{ .name = "base", .module = base }, .{ .name = "reader-image", .module = image } } });
    platform.addImport("fabrum-renderer-z2d", renderer);
    return .{ .fabrum = fabrum, .platform = platform, .image = image };
}
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const host_ui = uiModules(b, b.graph.host, optimize);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = host_ui.imports(b),
        .link_libc = true,
    }) });
    tests.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    b.step("test", "Test storage, navigation, UI and fake InkView host").dependOn(&b.addRunArtifact(tests).step);
    const preview = b.addExecutable(.{ .name = "pocketmanga-preview", .root_module = b.createModule(.{
        .root_source_file = b.path("src/preview.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = host_ui.imports(b),
        .link_libc = true,
    }) });
    preview.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    b.step("preview", "Render sample screens through fake InkView into preview/").dependOn(&b.addRunArtifact(preview).step);
    const device_target = b.resolveTargetQuery(.{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabi, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 }, .glibc_version = .{ .major = 2, .minor = 23, .patch = 0 } });
    const device_ui = uiModules(b, device_target, optimize);
    const device = b.addExecutable(.{ .name = "pocketmanga.app", .root_module = b.createModule(.{
        .root_source_file = b.path("src/inkview.zig"),
        .target = device_target,
        .optimize = optimize,
        .imports = device_ui.imports(b),
        .link_libc = true,
    }) });
    device.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    const worker_target = b.resolveTargetQuery(.{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabi, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 }, .glibc_version = .{ .major = 2, .minor = 39, .patch = 0 } });
    const worker = b.addExecutable(.{ .name = "pocketmanga-worker", .root_module = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = worker_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tachi", .module = b.dependency("tachi", .{ .target = worker_target, .optimize = optimize }).module("tachi") }},
        .link_libc = true,
    }) });
    worker.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    const probe = b.addExecutable(.{ .name = "pocketmanga-runtime-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("src/runtime_probe.zig"),
        .target = device_target,
        .optimize = optimize,
        .imports = &.{},
        .link_libc = true,
    }) });
    probe.root_module.addCSourceFile(.{ .file = b.path("src/posix_compat.c"), .flags = &.{} });
    b.step("runtime-probe", "Build ARM UI/worker protocol diagnostic").dependOn(&b.addInstallArtifact(probe, .{}).step);
    const install = b.addInstallArtifact(device, .{});
    const launcher = b.addInstallFile(b.path("tools/pocketmanga-log.app"), "bin/pocketmanga-log.app");
    const device_step = b.step("device", "Build native Verse 6.8+ UI and isolated JVM worker");
    device_step.dependOn(&install.step);
    device_step.dependOn(&b.addInstallArtifact(worker, .{}).step);
    device_step.dependOn(&launcher.step);
    b.getInstallStep().dependOn(device_step);
}
