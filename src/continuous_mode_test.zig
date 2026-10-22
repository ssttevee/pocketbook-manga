const std = @import("std");
const f = @import("fabrum");
const lib = @import("library.zig");
const Root = @import("ui.zig");
const Session = @import("session.zig").Session;
const Regions = @import("region_service.zig");
const Vips = @import("vips.zig");
const fixture: lib.Library = .{ .manga = &.{
    .{ .id = "webtoon", .title = "Webtoon", .chapters = &.{.{ .id = "chapter", .title = "Chapter", .pages = &.{ "first.png", "strip.png", "last.png" } }} },
    .{ .id = "manga", .title = "Manga", .chapters = &.{.{ .id = "other", .title = "Other", .pages = &.{"other.png"} }} },
} };
const view: lib.viewport.Size = .{ .width = 300, .height = 400 };
const geometry = lib.viewport.Geometry.init(view, view, false);

test "continuous viewing mode persists per series while legacy preferences stay paged" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .prefs = .{ .reader_mode_next = 255 } };
    defer model.deinit();
    try std.testing.expectEqual(.paged, model.readingMode());
    try model.dispatch(.{ .reader_mode = .vertical });
    try std.testing.expect(model.dirty);
    try std.testing.expectEqual(.vertical, model.prefs.reader_modes[127].?.mode);
    try std.testing.expectEqual(@as(u8, 0), model.prefs.reader_mode_next);
    try model.dispatch(.{ .open = 1 });
    try std.testing.expectEqual(.paged, model.readingMode());
    try model.dispatch(.{ .open = 0 });
    try std.testing.expectEqual(.vertical, model.readingMode());
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, model.prefs, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(lib.Preferences, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    var resumed: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .prefs = parsed.value };
    defer resumed.deinit();
    try std.testing.expectEqual(.vertical, resumed.readingMode());
    try resumed.dispatch(.{ .reader_mode = .paged });
    for (resumed.prefs.reader_modes) |entry| if (entry) |value| try std.testing.expectEqual(.paged, value.mode);
    const legacy = try std.json.parseFromSlice(lib.Preferences, std.testing.allocator, "{\"rtl\":false}", .{});
    defer legacy.deinit();
    resumed.prefs = legacy.value;
    try std.testing.expectEqual(.paged, resumed.readingMode());
}

test "continuous turns use screenful pixels and page jumps reset pending motion" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_requires_presentation = true };
    defer model.deinit();
    try model.dispatch(.{ .reader_mode = .vertical });
    try model.dispatch(.{ .read = 0 });
    try model.presentContinuous(0, 0, geometry, false, false);
    try model.dispatch(.{ .turn = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 360), model.reader_scroll_delta, 0.000001);
    try std.testing.expectEqual(@as(usize, 0), model.page);
    try std.testing.expect(!model.reader_presented);
    try model.dispatch(.{ .pan = -45 });
    try std.testing.expectApproxEqAbs(@as(f64, 315), model.reader_scroll_delta, 0.000001);
    try model.dispatch(.{ .turn = -1 });
    try std.testing.expectApproxEqAbs(@as(f64, -45), model.reader_scroll_delta, 0.000001);
    try model.dispatch(.{ .pan = std.math.inf(f64) });
    try std.testing.expectApproxEqAbs(@as(f64, -45), model.reader_scroll_delta, 0.000001);
    try model.dispatch(.{ .jump_page = 1 });
    try std.testing.expectEqual(@as(usize, 1), model.page);
    try std.testing.expectEqual(@as(f64, 0), model.reader_scroll_delta);
    try std.testing.expectEqual(@as(f64, 0), model.reader_position);
    try std.testing.expect(model.reader_geometry == null);
    try std.testing.expect(!model.readerAtEnd());
}

test "continuous completion follows the visible bottom even with an earlier top anchor" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_requires_presentation = true };
    defer model.deinit();
    try model.dispatch(.{ .reader_mode = .vertical });
    try model.dispatch(.{ .read = 0 });
    try model.presentContinuous(1, 0.5, geometry, false, true);
    try std.testing.expect(!model.readState(fixture.manga[0].chapters[0]).read);
    try std.testing.expect(model.reader_waiting);
    try model.dispatch(.{ .turn = 1 });
    try std.testing.expect(!model.readerAtEnd());
    // The final strip fits together with the preceding source image. The top
    // anchor need not be the final file for the visible chapter to be complete.
    try model.presentContinuous(1, 0.75, geometry, true, false);
    try std.testing.expect(model.readerAtEnd());
    try std.testing.expect(model.readState(fixture.manga[0].chapters[0]).read);
    try std.testing.expectEqual(@as(u32, 1), model.readState(fixture.manga[0].chapters[0]).page);
}

test "continuous anchors survive JSON and resizing without reusing paged positions" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_requires_presentation = true };
    defer model.deinit();
    try model.dispatch(.{ .reader_mode = .vertical });
    try model.dispatch(.{ .read = 0 });
    try model.presentContinuous(1, 0.4, geometry, false, false);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, model.prefs, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(lib.Preferences, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    var resumed = model;
    resumed.reading = .empty;
    try resumed.reading.put(std.testing.allocator, "chapter", model.readState(fixture.manga[0].chapters[0]));
    resumed.prefs = parsed.value;
    defer resumed.deinit();
    try resumed.dispatch(.{ .read = 0 });
    try std.testing.expectEqual(@as(usize, 1), resumed.page);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), resumed.reader_position, 0.000001);
    const smaller = lib.viewport.Geometry.init(.{ .width = 200, .height = 300 }, .{ .width = 200, .height = 300 }, false);
    try resumed.presentContinuous(1, resumed.reader_position, smaller, false, false);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), resumed.reader_position, 0.000001);
    try resumed.dispatch(.{ .reader_mode = .paged });
    try resumed.dispatch(.{ .read = 0 });
    try std.testing.expectEqual(@as(f64, 0), resumed.reader_position);
    const legacy_anchor = try std.json.parseFromSlice(lib.ReaderAnchor, std.testing.allocator, "{\"chapter_key\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],\"page\":1,\"progress\":100}", .{});
    defer legacy_anchor.deinit();
    try std.testing.expectEqual(.paged, legacy_anchor.value.mode);
}

fn invalidate(session: *Session, _: []const u8) !void {
    session.clearRegionImage();
    session.region_epoch +%= 1;
}
fn writePng(dir: std.Io.Dir, name: []const u8, comptime encoded: []const u8) !void {
    var data: [std.base64.standard.Decoder.calcSizeForSlice(encoded) catch unreachable]u8 = undefined;
    try std.base64.standard.Decoder.decode(&data, encoded);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = &data });
}

// Generated original grayscale PNGs: a black 100x200 page, gray 100x10 footer,
// and white 100x200 page. Solid colors make seams and scaling measurable.
fn writeFixtures(dir: std.Io.Dir) !void {
    try writePng(dir, "first.png", "iVBORw0KGgoAAAANSUhEUgAAAGQAAADICAAAAAA7VxsdAAAAKklEQVR42u3BMQEAAADCoPVPbQlPoAAAAAAAAAAAAAAAAAAAAAAAAADgZ07oAAHDBjF+AAAAAElFTkSuQmCC");
    try writePng(dir, "strip.png", "iVBORw0KGgoAAAANSUhEUgAAAGQAAAAKCAAAAABnd6SiAAAAFklEQVR42mNwoANgGLVk1JJRSwaHJQBK1foBQoiOKgAAAABJRU5ErkJggg==");
    try writePng(dir, "last.png", "iVBORw0KGgoAAAANSUhEUgAAAGQAAADICAAAAAA7VxsdAAAAX0lEQVR42u3NMQEAAAwCIPuX1hZ7BgVID0QikUgkEolEIpFIJBKJRCKRSCQSiUQikUgkEolEIpFIJBKJRCKRSCQSiUQikUgkEolEIpFIJBKJRCKRSCQSiUQikUgkX5IBeHjWZI7eCDAAAAAASUVORK5CYII=");
}

test "production reader joins footer strips and serves prepared continuous turns immediately" {
    const path = std.c.getenv("POCKETMANGA_IMAGE_TEST_LIBRARY") orelse return error.SkipZigTest;
    var codecs = try Vips.Library.load(std.mem.span(path));
    defer codecs.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(tmp.dir);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    var service: Regions.Service = undefined;
    service.init(std.testing.allocator, &codecs, try std.fs.path.join(arena.allocator(), &.{ root, "cache" }));
    defer service.deinit();
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_requires_presentation = true };
    defer model.deinit();
    model.prefs.full_refresh = false;
    try model.dispatch(.{ .reader_mode = .vertical });
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io, .region_service = &service, .load_image = invalidate };
    defer session.deinit();
    try session.act(.{ .read = 0 });
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.runTasks();
    try std.testing.expect(session.regionCurrent());
    try session.act(.{ .turn = 1 });
    try h.frame();
    try std.testing.expect(session.regionCurrent());
    try std.testing.expect(h.findText("Loading page…") == null);
    const updates = h.state().reader_updates;
    try h.runTasks();
    // A cache hit is presented once; the worker only prepares future views.
    try std.testing.expectEqual(updates, h.state().reader_updates);
    try session.act(.{ .jump_page = 1 });
    try h.frame();
    try h.runTasks();
    try std.testing.expect(session.regionCurrent());
    try std.testing.expectEqual(@as(usize, 1), model.page);
    const pixels = session.image.?.pixels;
    try std.testing.expectEqual(@as(u8, 64), pixels[0]);
    try std.testing.expectEqual(@as(u8, 64), pixels[343 * 32]);
    try std.testing.expectEqual(@as(u8, 255), pixels[343 * 35]);
    // A result from the old mode cannot be installed after a user changes mode.
    const old_request: Regions.Request = .{ .mode = .vertical, .pages = fixture.manga[0].chapters[0].pages, .root = root, .relative = "strip.png", .chapter = "chapter", .page = model.page, .epoch = session.region_epoch, .viewport = session.region_viewport, .position = model.reader_position, .backward = false, .rtl = model.prefs.rtl };
    try session.act(.{ .reader_mode = .paged });
    const rejected = try session.acceptRegion(.{ .request = old_request, .value = .{ .frame = .{ .source = view, .geometry = geometry, .position = 0, .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .pixels = @constCast(&[_]u8{17}), .revision = 1 } } });
    try std.testing.expect(!rejected);
    try std.testing.expect(session.image == null);
    try h.frame();
    try h.runTasks();
    try std.testing.expect(session.regionCurrent());
    try std.testing.expectEqual(.page, model.reader_geometry.?.axis);
    // The mode is selected directly through the native settings menu.
    try session.act(.settings);
    try h.frame();
    const mode_button = h.findElement(h.root().element("reader-mode")).?.bbox;
    const quit_button = h.findElement(h.root().element("quit")).?.bbox;
    try std.testing.expect(mode_button.y >= 0 and mode_button.y + mode_button.h <= 464);
    try std.testing.expect(quit_button.y >= mode_button.y + mode_button.h);
    try std.testing.expect(quit_button.y + quit_button.h <= 464);
    try h.clickElement(h.root().element("reader-mode"));
    try h.chooseMenuItem(1);
    try std.testing.expectEqual(.vertical, model.readingMode());
    try h.clickElement(h.root().element("reader-mode"));
    try h.chooseMenuItem(null);
    try std.testing.expectEqual(.vertical, model.readingMode());
}

test "continuous reader refreshes missing footer pages when background downloads arrive" {
    const path = std.c.getenv("POCKETMANGA_IMAGE_TEST_LIBRARY") orelse return error.SkipZigTest;
    var codecs = try Vips.Library.load(std.mem.span(path));
    defer codecs.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(tmp.dir);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    var service: Regions.Service = undefined;
    service.init(std.testing.allocator, &codecs, try std.fs.path.join(arena.allocator(), &.{ root, "cache" }));
    defer service.deinit();
    var chapter = fixture.manga[0].chapters[0];
    chapter.pages = &.{};
    var manga = fixture.manga[0];
    manga.chapters = &.{chapter};
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = .{ .manga = &.{manga} }, .region_reader = true, .reader_requires_presentation = true, .online_chapter = "chapter", .online_pages = &.{ "first.png", "", "" } };
    defer model.deinit();
    try model.dispatch(.{ .reader_mode = .vertical });
    var session: Session = .{ .model = &model, .root = root, .io = std.testing.io, .region_service = &service, .load_image = invalidate, .reader_download_done = 1, .reader_download_total = 3 };
    defer session.deinit();
    try session.act(.{ .read = 0 });
    var h: f.app.testing.Harness(.{}, Root) = try .init(.{}, .{ .viewport = .init(343, 464), .provide = &.{f.app.RootValue.of(&session)}, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.runTasks();
    try session.act(.{ .pan = 500 });
    try h.frame();
    try h.runTasks();
    try std.testing.expect(session.regionCurrent());
    try std.testing.expect(model.reader_waiting);
    try std.testing.expect(!model.readerAtEnd());
    try std.testing.expectEqual(@as(u8, 0), session.image.?.pixels[0]);
    try std.testing.expectEqual(@as(u8, 255), session.image.?.pixels[343 * 200]);
    const stale_request: Regions.Request = .{ .mode = .vertical, .revision = 1, .pages = model.online_pages, .root = root, .relative = "first.png", .chapter = "chapter", .page = model.page, .epoch = session.region_epoch, .viewport = session.region_viewport, .position = model.reader_position, .backward = false, .rtl = model.prefs.rtl };
    model.online_pages = fixture.manga[0].chapters[0].pages;
    session.reader_download_done = 3;
    try std.testing.expect(!session.regionCurrent()); // The displayed view predates these pages.
    try std.testing.expect(!try session.acceptRegion(.{ .request = stale_request, .value = .{ .failure = "old missing page" } }));
    try h.frame();
    try h.runTasks();
    try std.testing.expect(session.regionCurrent());
    try std.testing.expect(!model.reader_waiting);
    try std.testing.expectEqual(@as(u8, 0), session.image.?.pixels[0]);
    try std.testing.expectEqual(@as(u8, 64), session.image.?.pixels[343 * 200]);
    try std.testing.expectEqual(@as(u8, 255), session.image.?.pixels[343 * 230]);
    try std.testing.expect(h.findText("Waiting for next page…") == null);
}

test "reader latency ignores ineffective inputs and preserves the pending request timestamp" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_requires_presentation = true };
    defer model.deinit();
    var session: Session = .{ .model = &model, .root = "", .io = std.testing.io };
    defer session.deinit();
    try session.act(.{ .reader_mode = .vertical });
    try session.act(.{ .read = 0 });
    try session.act(.{ .turn = 1 }); // Initial geometry is not ready yet.
    try std.testing.expect(session.reader_requested_at == null);
    try model.presentContinuous(0, 0, geometry, false, false);
    try session.act(.{ .turn = 1 });
    const requested_at = session.reader_requested_at.?;
    try session.act(.{ .pan = std.math.nan(f64) });
    try std.testing.expectEqual(requested_at, session.reader_requested_at.?);
    try session.act(.back);
    try std.testing.expect(session.reader_requested_at == null);
}
