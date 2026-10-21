const std = @import("std");
const lib = @import("library.zig");
const vp = @import("reader_viewport.zig");
const fixture: lib.Library = .{ .manga = &.{.{ .id = "m", .title = "M", .chapters = &.{.{ .id = "c", .title = "C", .pages = &.{ "1.png", "2.png" } }} }} };
const tall: vp.Size = .{ .width = 1000, .height = 12000 };
const view: vp.Size = .{ .width = 758, .height = 900 };

test "region turns reach the edge before advancing or completing the chapter" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    try std.testing.expect(!model.readerAtEnd());
    try model.configureReader(tall, view);
    try model.dispatch(.{ .turn = 1 });
    try std.testing.expectEqual(@as(usize, 0), model.page);
    try std.testing.expect(model.reader_position > 0);
    try model.dispatch(.{ .pan = 1 });
    try model.dispatch(.{ .turn = 1 });
    try std.testing.expectEqual(@as(usize, 1), model.page);
    try std.testing.expect(!model.readState(fixture.manga[0].chapters[0]).read);
    try model.configureReader(tall, view);
    try std.testing.expect(!model.readState(fixture.manga[0].chapters[0]).read);
    try model.dispatch(.{ .pan = 1 });
    try std.testing.expect(model.readState(fixture.manga[0].chapters[0]).read);
    try model.dispatch(.{ .pan = -1 });
    try model.dispatch(.{ .turn = -1 });
    try std.testing.expectEqual(@as(usize, 0), model.page);
    try model.configureReader(tall, view);
    try std.testing.expectEqual(@as(f64, 1), model.reader_position);
}

test "saved region positions survive JSON, reopening and viewport changes" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    try model.configureReader(tall, view);
    try model.dispatch(.{ .pan = 0.4 });
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, model.prefs, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(lib.Preferences, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    var resumed: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .prefs = parsed.value, .region_reader = true };
    defer resumed.deinit();
    try resumed.dispatch(.{ .read = 0 });
    try resumed.configureReader(tall, .{ .width = 600, .height = 700 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), resumed.reader_position, 0.000001);
    try std.testing.expect(!resumed.dirty);
    try std.testing.expectEqual(@as(usize, 32), resumed.prefs.reader_positions.len);
}

test "wide RTL reading reaches left edge and a normal page completes immediately" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    try model.configureReader(.{ .width = 12000, .height = 1000 }, view);
    const start = model.reader_geometry.?.region(model.reader_position);
    try model.dispatch(.{ .turn = 1 });
    try std.testing.expect(model.reader_geometry.?.region(model.reader_position).x < start.x);
    try model.dispatch(.{ .pan = 1 });
    try std.testing.expectEqual(@as(u32, 0), model.reader_geometry.?.region(model.reader_position).x);
    try model.dispatch(.{ .turn = 1 });
    try model.configureReader(.{ .width = 700, .height = 1000 }, view);
    try std.testing.expect(model.readerAtEnd());
    try std.testing.expect(model.readState(fixture.manga[0].chapters[0]).read);
}

test "partial last-image progress remains unfinished when dimensions are pending" {
    var stored = fixture;
    var chapter = fixture.manga[0].chapters[0];
    chapter.last_page_read = 1;
    var manga = fixture.manga[0];
    manga.chapters = &.{chapter};
    stored.manga = &.{manga};
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = stored, .region_reader = true };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    try std.testing.expectEqual(@as(usize, 1), model.page);
    try std.testing.expect(!model.readState(chapter).read);
    try model.dispatch(.{ .turn = 1 });
    try std.testing.expectEqual(@as(usize, 1), model.page);
    try model.configureReader(tall, view);
    try std.testing.expect(!model.readState(chapter).read);
}

test "region anchor storage is bounded and ordinary pages do not consume entries" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    try model.configureReader(.{ .width = 700, .height = 1000 }, view);
    for (model.prefs.reader_positions) |entry| try std.testing.expect(entry == null);
    // Treat each generated chapter as a distinct visited title. The model owns
    // no anchor strings, so ids can disappear immediately after each visit.
    for (0..40) |i| {
        var id: [32]u8 = undefined;
        const chapter_id = try std.fmt.bufPrint(&id, "chapter-{d}", .{i});
        var chapter = fixture.manga[0].chapters[0];
        chapter.id = chapter_id;
        var manga = fixture.manga[0];
        manga.chapters = &.{chapter};
        model.library.manga = &.{manga};
        model.clearReading();
        try model.dispatch(.{ .read = 0 });
        try model.configureReader(tall, view);
        try model.dispatch(.{ .pan = 0.25 });
    }
    for (model.prefs.reader_positions) |entry| try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u8, 8), model.prefs.reader_position_next);
    model.clearReading();
}

test "asynchronous readers complete only after the final region is presented" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_requires_presentation = true };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    try model.configureReader(tall, view);
    try model.dispatch(.{ .pan = 1 });
    try std.testing.expect(!model.reader_presented);
    try model.dispatch(.{ .turn = 1 });
    try model.configureReader(tall, view);
    try model.dispatch(.{ .pan = 1 });
    try std.testing.expect(model.readerAtEnd());
    try std.testing.expect(!model.reader_presented);
    try std.testing.expect(!model.readState(fixture.manga[0].chapters[0]).read);
    try model.configureReader(tall, view);
    try std.testing.expect(model.reader_presented);
    try std.testing.expect(model.readState(fixture.manga[0].chapters[0]).read);
    try model.dispatch(.{ .pan = -1 });
    try std.testing.expect(!model.reader_presented);
    try model.dispatch(.{ .turn = -1 });
    try std.testing.expect(!model.reader_presented);
    try std.testing.expect(model.reader_geometry == null);
}

test "private reading moves the viewport without storing region anchors" {
    var model: lib.Model = .{ .gpa = std.testing.allocator, .library = fixture, .region_reader = true, .reader_record_positions = false };
    defer model.deinit();
    try model.dispatch(.{ .read = 0 });
    try model.configureReader(tall, view);
    try model.dispatch(.{ .pan = 0.5 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), model.reader_position, 0.00001);
    for (model.prefs.reader_positions) |anchor| try std.testing.expect(anchor == null);
    try std.testing.expect(!model.dirty);
}
