//! Optional production-codec/UI integration. Run with
//! POCKETMANGA_IMAGE_TEST_LIBRARY=/absolute/path/to/libpocketmanga-image.dylib.
const std = @import("std");
const f = @import("fabrum");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;
const Regions = @import("region_service.zig");
const Vips = @import("vips.zig");
const Cache = @import("region_cache.zig");
const fixture: lib.Library = .{ .manga = &.{.{ .id = "strips", .title = "Strips", .chapters = &.{.{ .id = "chapter", .title = "Chapter", .pages = &.{ "vertical.png", "horizontal.png" } }} }} };

fn invalidate(session: *Session, _: []const u8) !void {
    session.clearRegionImage();
    session.region_epoch +%= 1;
}

fn writePng(dir: std.Io.Dir, name: []const u8, comptime encoded: []const u8) !void {
    var data: [std.base64.standard.Decoder.calcSizeForSlice(encoded) catch unreachable]u8 = undefined;
    try std.base64.standard.Decoder.decode(&data, encoded);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = &data });
}

const Wake = struct {
    pending: std.atomic.Value(bool) = .init(false),
    fn request(context: *anyopaque) void {
        const self: *Wake = @ptrCast(@alignCast(context));
        self.pending.store(true, .release);
    }
    const vtable: f.app.Platform.VTable = .{ .requestFrame = request };
};

const DelayedPrefetch = struct {
    backend: Cache.Backend,
    entered: std.atomic.Value(bool) = .init(false),
    release: std.Io.Event = .unset,
    once: std.atomic.Value(bool) = .init(true),
    fn self(context: *anyopaque) *DelayedPrefetch {
        return @ptrCast(@alignCast(context));
    }
    fn probe(context: *anyopaque, path: [:0]const u8) !lib.viewport.Size {
        const b = self(context).backend;
        return b.probe(b.context, path);
    }
    fn open(context: *anyopaque, path: [:0]const u8, scale: f64) !lib.viewport.Size {
        const b = self(context).backend;
        return b.open(b.context, path, scale);
    }
    fn read(context: *anyopaque, rect: lib.viewport.Rect, pixels: []u8, stride: usize) !void {
        const delay = self(context);
        if (rect.y >= 512 and delay.once.swap(false, .acq_rel)) {
            delay.entered.store(true, .release);
            delay.release.waitUncancelable(std.testing.io);
        }
        return delay.backend.read(delay.backend.context, rect, pixels, stride);
    }
    fn close(context: *anyopaque) void {
        const b = self(context).backend;
        b.close(b.context);
    }
};

test "real reader cancellation wakes page turns and new chapters without further input" {
    for ([_]bool{ false, true }) |different_chapter| try expectReaderReplacement(different_chapter);
}

fn expectReaderReplacement(different_chapter: bool) !void {
    const library_path = std.c.getenv("POCKETMANGA_IMAGE_TEST_LIBRARY") orelse return error.SkipZigTest;
    var codecs = try Vips.Library.load(std.mem.span(library_path));
    defer codecs.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePng(tmp.dir, "vertical.png", "iVBORw0KGgoAAAANSUhEUgAAABAAAACACAIAAACN9351AAAAOUlEQVR4nO3ToREAMAzEsOy/dMv6uCAgOYkbugp4zieBYHMARP9xAsGcAIj+4wSCOQEQ/ccJBGOCC/q69KbReaZDAAAAAElFTkSuQmCC");
    try writePng(tmp.dir, "horizontal.png", "iVBORw0KGgoAAAANSUhEUgAAAIAAAAAQCAIAAABROuDfAAAAUklEQVR4nO3PwQkAAAjEMPdfWmc48GHADhBoVViHvb/r8wO6zw/oPj+g+/yA7vMDus8P6D4/oPv8gO7zA7rPD+g+P6D7/IDu8wO6zw/oPj9wzR805/SmQxmfZAAAAABJRU5ErkJggg==");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    var service: Regions.Service = undefined;
    service.init(std.testing.allocator, &codecs, try std.fs.path.join(arena.allocator(), &.{ root, "cache" }));
    defer service.deinit();
    var delay: DelayedPrefetch = .{ .backend = service.tiles.backend };
    service.tiles.backend = .{ .context = &delay, .probe = DelayedPrefetch.probe, .open = DelayedPrefetch.open, .read = DelayedPrefetch.read, .close = DelayedPrefetch.close };
    const chapters: lib.Library = .{ .manga = &.{.{ .id = "strips", .title = "Strips", .chapters = &.{
        fixture.manga[0].chapters[0],
        .{ .id = "next-chapter", .title = "Next chapter", .pages = &.{"horizontal.png"} },
    } }} };
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = if (different_chapter) chapters else fixture, .region_reader = true, .reader_requires_presentation = true };
    defer model.deinit();
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io, .region_service = &service, .load_image = invalidate };
    defer session.deinit();
    try session.act(.{ .read = 0 });
    var wake: Wake = .{};
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    defer delay.release.set(std.testing.io);
    h.runtime.core.tasks.queued = false;
    h.runtime.core.platform = .{ .ptr = &wake, .vtable = &Wake.vtable };
    try h.frame();
    for (0..5000) |_| {
        if (delay.entered.load(.acquire)) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(delay.entered.load(.acquire));
    try h.frame(); // Consume the visible frame while its prefetch is blocked.
    try std.testing.expect(session.regionCurrent());
    if (different_chapter) {
        try session.act(.{ .open_chapter = .{ .manga = 0, .chapter = 1 } });
    } else {
        try session.act(.{ .pan = 1 });
        try session.act(.{ .turn = 1 });
    }
    try h.frame(); // Cancel the old prefetch; replacement waits for its exit.
    try std.testing.expectEqual(@as(usize, if (different_chapter) 0 else 1), model.page);
    try std.testing.expectEqual(@as(usize, if (different_chapter) 1 else 0), model.chapter);
    try std.testing.expect(!session.regionCurrent());
    const retired = h.runtime.core.tasks.records.items[0];
    wake.pending.store(false, .release);
    delay.release.set(std.testing.io);
    for (0..5000) |_| {
        if (retired.reaped.load(.acquire)) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(retired.reaped.load(.acquire));
    // Cancellation completion has no result message. Its wake must still
    // make the host collect the old task and launch the pending page.
    try std.testing.expect(h.runtime.nextFrame() != null);
    try h.frame();
    for (0..5000) |_| {
        if (wake.pending.swap(false, .acq_rel)) {
            // The actual host runs a frame only when nextFrame says work is
            // ready. Forcing h.frame/runTasks here would hide a lost wakeup.
            if (h.runtime.nextFrame() != null) try h.frame();
        }
        if (session.regionCurrent()) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(session.regionCurrent());
    try std.testing.expectEqual(lib.viewport.Axis.horizontal, model.reader_geometry.?.axis);
    try std.testing.expectEqualStrings(if (different_chapter) "next-chapter" else "chapter", model.current().?.id);
}

test "accepted region pixels remain owned when saving preferences runs out of memory" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_requires_presentation = true };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    const source: lib.viewport.Size = .{ .width = 1, .height = 10 };
    const viewport: lib.viewport.Size = .{ .width = 1, .height = 1 };
    try model.configureReader(source, viewport);
    // Warm model bookkeeping first. The frame copy succeeds, then every
    // allocation fails, including the save-error diagnostic after ownership
    // has transferred into Session.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    model.gpa = failing.allocator();
    model.dirty = true;
    var session: Session = .{
        .model = &model,
        .root = ".",
        .io = std.testing.io,
        .save_path = "/dev/null/progress.json",
        .region_viewport = viewport,
    };
    defer session.deinit();
    const geometry = lib.viewport.Geometry.init(source, viewport, model.prefs.rtl);
    const result: Regions.Result = .{
        .request = .{
            .root = ".",
            .relative = "vertical.png",
            .chapter = "chapter",
            .page = 0,
            .epoch = 0,
            .viewport = viewport,
            .position = 0,
            .backward = false,
            .rtl = model.prefs.rtl,
        },
        .value = .{ .frame = .{
            .source = source,
            .geometry = geometry,
            .position = 0,
            .rect = geometry.region(0),
            .pixels = @constCast(&[_]u8{123}),
            .revision = 1,
        } },
    };
    try std.testing.expectError(error.OutOfMemory, session.acceptRegion(result));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqualSlices(u8, &.{123}, session.region_pixels.?);
    try std.testing.expectEqual(session.region_pixels.?.ptr, session.image.?.pixels.ptr);
    session.clearRegionImage();
    try std.testing.expect(session.region_pixels == null);
    // Deferred Session teardown must not free the frame a second time.
}

test "production codecs drive vertical and horizontal reader tasks and reject stale frames" {
    const library_path = std.c.getenv("POCKETMANGA_IMAGE_TEST_LIBRARY") orelse return error.SkipZigTest;
    var codecs = try Vips.Library.load(std.mem.span(library_path));
    defer codecs.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Original generated PNGs: alternating black/white bands, 16x128/128x16.
    try writePng(tmp.dir, "vertical.png", "iVBORw0KGgoAAAANSUhEUgAAABAAAACACAIAAACN9351AAAAOUlEQVR4nO3ToREAMAzEsOy/dMv6uCAgOYkbugp4zieBYHMARP9xAsGcAIj+4wSCOQEQ/ccJBGOCC/q69KbReaZDAAAAAElFTkSuQmCC");
    try writePng(tmp.dir, "horizontal.png", "iVBORw0KGgoAAAANSUhEUgAAAIAAAAAQCAIAAABROuDfAAAAUklEQVR4nO3PwQkAAAjEMPdfWmc48GHADhBoVViHvb/r8wO6zw/oPj+g+/yA7vMDus8P6D4/oPv8gO7zA7rPD+g+P6D7/IDu8wO6zw/oPj9wzR805/SmQxmfZAAAAABJRU5ErkJggg==");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const cache = try std.fs.path.join(arena.allocator(), &.{ root, "cache" });
    var service: Regions.Service = undefined;
    service.init(std.testing.allocator, &codecs, cache);
    defer service.deinit();
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_requires_presentation = true };
    defer model.deinit();
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io, .region_service = &service, .load_image = invalidate };
    defer session.deinit();
    try session.act(.{ .read = 0 });
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try std.testing.expect(h.taskStarted("reader-region"));
    try std.testing.expect(session.image == null);
    try h.runTasks();
    try std.testing.expect(session.regionCurrent());
    try std.testing.expectEqual(lib.viewport.Axis.vertical, model.reader_geometry.?.axis);
    try std.testing.expectEqual(@as(usize, 343), session.image.?.width);
    try std.testing.expectEqual(@as(usize, 380), session.image.?.height);
    const old_pixels = try arena.allocator().dupe(u8, session.region_pixels.?);
    const stale_request: Regions.Request = .{
        .root = root,
        .relative = "vertical.png",
        .chapter = "chapter",
        .page = 0,
        .epoch = session.region_epoch,
        .viewport = session.region_viewport,
        .position = model.reader_position,
        .backward = false,
        .rtl = model.prefs.rtl,
    };
    const old_geometry = model.reader_geometry.?;
    try h.click("Next");
    try std.testing.expect(!session.regionCurrent());
    try std.testing.expect(!try session.acceptRegion(.{ .request = stale_request, .value = .{ .frame = .{
        .source = old_geometry.source,
        .geometry = old_geometry,
        .position = 0,
        .rect = old_geometry.region(0),
        .pixels = old_pixels,
        .revision = 1,
    } } }));
    try h.runTasks();
    try std.testing.expect(session.regionCurrent());
    try std.testing.expect(model.reader_position > 0);
    try std.testing.expectEqual(@as(usize, 0), model.page);

    // A superseded queued task must not decode or publish its previous region.
    try session.act(.{ .pan = 1 });
    try h.frame();
    try session.act(.{ .turn = 1 });
    try h.frame();
    try std.testing.expectEqual(@as(usize, 1), model.page);
    try std.testing.expect(!model.readState(fixture.manga[0].chapters[0]).read);
    try h.runTasks();
    try std.testing.expect(session.regionCurrent());
    try std.testing.expectEqual(lib.viewport.Axis.horizontal, model.reader_geometry.?.axis);
    const first_x = model.reader_geometry.?.region(model.reader_position).x;
    try std.testing.expect(first_x > 0); // Default right-to-left reading.
    try h.click("Next");
    try h.runTasks();
    try std.testing.expect(model.reader_geometry.?.region(model.reader_position).x < first_x);
    try std.testing.expect(!model.readState(fixture.manga[0].chapters[0]).read);
    try session.act(.{ .pan = 1 });
    try h.frame();
    try std.testing.expect(!model.readState(fixture.manga[0].chapters[0]).read);
    try h.runTasks();
    try std.testing.expect(session.regionCurrent());
    try std.testing.expectEqual(@as(u32, 0), model.reader_geometry.?.region(model.reader_position).x);
    try std.testing.expect(model.readState(fixture.manga[0].chapters[0]).read);

    // Leaving the reader removes its declaration and cancels pending work.
    try session.act(.{ .pan = -0.4 });
    try h.frame();
    try session.act(.back);
    try h.frame();
    try h.runTasks();
    try std.testing.expect(!h.taskStarted("reader-region"));
    try std.testing.expectEqual(lib.Screen.chapters, model.screen);
}
