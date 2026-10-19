//! Private protocol v1: little-endian u32 byte length, then UTF-8 JSON.
//! Exactly one request is active. IDs match progress/result/error messages.
const std = @import("std");
const lib = @import("library.zig");
const models = @import("source_models.zig");
pub const version = 3;
const protocol_version = version;
pub const max_frame = 32 << 20;
pub const RepoEntry = struct {
    pkg: []const u8,
    name: []const u8,
    versionName: []const u8,
    versionCode: i64,
    libVersion: []const u8,
    nsfw: bool,
    lang: []const u8,
    jarUrl: ?[]const u8,
    apkUrl: []const u8,
    iconUrl: []const u8,
    supported: bool,
    installed: bool,
    installedVersionCode: ?i64,
    hasUpdate: bool,
    sources: []const RepoSource,
};
pub const RepoSource = struct { id: []const u8, name: []const u8, lang: []const u8, baseUrl: []const u8 };
pub const Request = union(enum) {
    sources,
    extensions,
    scan,
    update_all,
    install: []const u8,
    install_file: []const u8,
    uninstall: []const u8,
    titles: struct { source: i64, query: []const u8 = "", page: i32 = 1, latest: bool = false },
    add: struct { source: i64, manga: models.Manga },
    refresh: lib.Manga,
    download: struct { book: lib.Manga, chapter: lib.Chapter },
    benchmark: struct { book: lib.Manga, chapter: lib.Chapter },
    image: struct { source: i64, page: models.Page, url: []const u8 = "", cookies: []const []const u8 = &.{} },
    preferences: i64,
    set_preference: struct { source: i64, key: []const u8, value: std.json.Value },
};
pub const Result = struct {
    image_requests: ?[]const ImageRequest = null,
    image_base64: ?[]const u8 = null,
    sources: []const models.SourceInfo = &.{},
    extensions: []const RepoEntry = &.{},
    titles: ?models.MangasPage = null,
    preferences: []const models.Preference = &.{},
    library_changed: bool = false,
    open_id: ?[]const u8 = null,
    message: []const u8 = "Ready",
};

pub const Command = struct {
    version: u32 = protocol_version,
    id: u64,
    kind: enum { request, cancel, shutdown, crash },
    request: ?Request = null,
};
pub const Response = struct {
    version: u32 = protocol_version,
    id: u64,
    kind: enum { ready, progress, result, failure },
    result: ?Result = null,
    failure: ?[]const u8 = null,
    pages_done: usize = 0,
    pages_total: usize = 0,
    rss_kib: usize = 0,
};

/// Native image plan, returned by the extension host without transferring image bodies.
pub const ImageRequest = struct {
    page: models.Page,
    url: []const u8,
    method: []const u8,
    headers: []const std.http.Header,
    rates: []const Rate = &.{},
    cookies: []const []const u8 = &.{},
    fallback: ?[]const u8 = null,
};
pub const Rate = struct { key: []const u8, spacingMs: u64, initialWaitMs: u64 };
