//! What served HTML gets: the `labelle run` options script right after the
//! doctype, and the live-reload client before `</body>`.
const std = @import("std");

// ── Live reload / watch (cli#208) ────────────────────────────────────

/// Reserved request path the injected client polls for the build version.
const livereload_path = "/__labelle_livereload";
/// The `web_dir`-relative form `resolveTarget` yields for that path.
pub const livereload_rel = "__labelle_livereload";

/// The reload client spliced into served HTML in a watch session. It starts
/// from `generation`, the publication the page was served from, and polls
/// the version endpoint once a second; any other value reloads the page. A
/// generation published between serving the page and its first poll is
/// therefore a reload, not a new baseline. Plain ES5 + `fetch`.
fn reloadClient(allocator: std.mem.Allocator, generation: u64) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\<script>
        \\(function () {{
        \\  var current = "{d}";
        \\  function poll() {{
        \\    fetch("/__labelle_livereload", {{ cache: "no-store" }})
        \\      .then(function (r) {{ return r.text(); }})
        \\      .then(function (v) {{
        \\        if (v !== current) {{ location.reload(); return; }}
        \\        setTimeout(poll, 1000);
        \\      }})
        \\      .catch(function () {{ setTimeout(poll, 2000); }});
        \\  }}
        \\  poll();
        \\}})();
        \\</script>
        \\
    , .{generation});
}

/// The `labelle run` options (`run.env`: `LABELLE_SCENE`, `LABELLE_PROFILE`,
/// ...) for a page, as a script placed right after the doctype, which the
/// HTML parser makes the first child of `<head>`: it publishes them
/// as `window.LABELLE_RUN_ENV` and adds a `Module.preRun` step copying them
/// into Emscripten's `ENV`, so the game's `getenv` (the engine's
/// `requestedScene()` reads `LABELLE_SCENE`) sees them as on desktop. The
/// Module object is created if absent and otherwise extended, which classic
/// glue (`var Module = typeof Module != "undefined" ? Module : {}`) and
/// `LabelleLoader.install(window.Module || {})` both keep. Null when there
/// are no options. Caller owns the result.
pub fn runEnvScript(allocator: std.mem.Allocator, env: []const RunEnv) !?[]u8 {
    if (env.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    try jws.beginObject();
    for (env) |pair| {
        try jws.objectField(pair.name);
        try jws.write(pair.value);
    }
    try jws.endObject();
    const json = out.written();
    // No `<` may reach the script element: `</script` (any case) would end
    // it and `<!--` changes how it is parsed. The JSON payload has `<` only
    // inside strings, where `\u003c` is the same character.
    const safe = try std.mem.replaceOwned(u8, allocator, json, "<", "\\u003c");
    defer allocator.free(safe);
    return try std.fmt.allocPrint(allocator,
        \\<script>
        \\window.LABELLE_RUN_ENV = {s};
        \\(function (m) {{
        \\  m.preRun = [].concat(m.preRun || []);
        \\  m.preRun.push(function () {{
        \\    var env = typeof ENV !== "undefined" ? ENV : m.ENV;
        \\    if (!env) return;
        \\    for (var k in window.LABELLE_RUN_ENV) env[k] = window.LABELLE_RUN_ENV[k];
        \\  }});
        \\}})(window.Module = window.Module || {{}});
        \\</script>
        \\
    , .{safe});
}

pub const RunEnv = struct { name: []const u8, value: []const u8 };

/// Splice `script` into `html` just before `</body>` (or append it when
/// there's no body tag). Caller owns the returned buffer.
fn injectBeforeBodyEnd(allocator: std.mem.Allocator, html: []const u8, script: []const u8) ![]u8 {
    if (std.mem.lastIndexOf(u8, html, "</body>")) |idx| return std.mem.concat(allocator, u8, &.{ html[0..idx], script, html[idx..] });
    return std.mem.concat(allocator, u8, &.{ html, script });
}

/// Splice `script` right after the leading `<!doctype ...>`, else at the
/// start (just past a leading byte-order mark). Per the HTML parsing spec, a
/// `<script>` ahead of `<html>` becomes the first child of `<head>` (the
/// parser creates `<html>` and `<head>` for it), so it runs before every
/// page script, whatever the page's markup (no `<head>`, early scripts,
/// templates, SVG, ...). After the doctype, not ahead of it, which would put
/// the page in quirks mode.
pub fn injectFirst(allocator: std.mem.Allocator, html: []const u8, script: []const u8) ![]u8 {
    const pos = injectPoint(html).at;
    return std.mem.concat(allocator, u8, &.{ html[0..pos], script, html[pos..] });
}

const InjectPoint = struct {
    at: usize,
    /// Which rule placed it: just past the doctype, or at the start.
    after: enum { doctype, start },
};

/// Where the run.env block goes. Two leading prefixes are skipped first, as
/// fixed prefixes, not by parsing HTML: a UTF-8 byte-order mark (the decoder
/// strips it only at byte 0, so nothing may go ahead of it; #7) and one
/// `<?...>`, such as an XML declaration (a bogus comment to HTML, which its
/// first `>` ends; #7). Then the index just past the `<!doctype ...>`
/// (case-insensitive), skipping only byte-order marks, whitespace and
/// `<!-- ... -->` comments ahead of it; the doctype ends at its first `>`,
/// as the HTML tokenizer ends it. With no such doctype, the start: just past
/// the byte-order mark, else 0.
fn injectPoint(html: []const u8) InjectPoint {
    const bom = "\xEF\xBB\xBF";
    const start: InjectPoint = .{ .at = if (std.mem.startsWith(u8, html, bom)) bom.len else 0, .after = .start };
    var i: usize = start.at;
    if (std.mem.startsWith(u8, html[i..], "<?")) {
        i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse return start) + 1;
    }
    while (i < html.len) {
        if (std.mem.startsWith(u8, html[i..], bom)) {
            i += bom.len;
        } else if (std.ascii.isWhitespace(html[i])) {
            i += 1;
        } else if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const close = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse return start;
            i = close + 3;
        } else break;
    }
    const rest = html[i..];
    if (rest.len < "<!doctype".len or !std.ascii.eqlIgnoreCase(rest[0.."<!doctype".len], "<!doctype")) return start;
    const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse return start;
    return .{ .at = gt + 1, .after = .doctype };
}

/// The reload client for `generation`, before `</body>`.
pub fn injectReloadScript(allocator: std.mem.Allocator, html: []const u8, generation: u64) ![]u8 {
    const client = try reloadClient(allocator, generation);
    defer allocator.free(client);
    return injectBeforeBodyEnd(allocator, html, client);
}

test "injectReloadScript: splices before </body>" {
    const alloc = std.testing.allocator;
    const html = "<html><body><canvas></canvas></body></html>";
    const out = try injectReloadScript(alloc, html, 0);
    defer alloc.free(out);
    // The client script is present...
    try std.testing.expect(std.mem.indexOf(u8, out, "__labelle_livereload") != null);
    // ...and it lands before the closing body tag, not after it.
    const script_at = std.mem.indexOf(u8, out, "location.reload").?;
    const body_at = std.mem.indexOf(u8, out, "</body>").?;
    try std.testing.expect(script_at < body_at);
    // Original content is preserved.
    try std.testing.expect(std.mem.indexOf(u8, out, "<canvas>") != null);
}

test "injectReloadScript: appends when there is no </body>" {
    const alloc = std.testing.allocator;
    const html = "<h1>bare fragment</h1>";
    const out = try injectReloadScript(alloc, html, 0);
    defer alloc.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "<h1>bare fragment</h1>"));
    try std.testing.expect(std.mem.indexOf(u8, out, "__labelle_livereload") != null);
}

test "runEnvScript: no `<` reaches the script element, whatever its case" {
    const alloc = std.testing.allocator;
    const script = (try runEnvScript(alloc, &.{.{ .name = "LABELLE_SCENE", .value = "a</ScRiPt><!--b" }})).?;
    defer alloc.free(script);
    const body = script["<script>".len..std.mem.lastIndexOf(u8, script, "</script>").?];
    try std.testing.expect(std.mem.indexOfScalar(u8, body, '<') == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"a\\u003c/ScRiPt>\\u003c!--b\"") != null);
    // And it is still the same string once parsed as JSON.
    const start = std.mem.indexOf(u8, body, "{").?;
    const json = body[start .. std.mem.indexOf(u8, body, "};").? + 1];
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a</ScRiPt><!--b", parsed.value.object.get("LABELLE_SCENE").?.string);
}

test "injectFirst: right after the leading doctype, else at the start" {
    const alloc = std.testing.allocator;
    for ([_][2][]const u8{
        // Doctype + head: ahead of <html>, so the parser makes it head's first child.
        .{ "<!doctype html><html><head><script>a</script></head></html>", "<!doctype html>S<html><head><script>a</script></head></html>" },
        // No head, an early script: the block comes before it.
        .{ "<!DOCTYPE html><html><script>var Module={};</script><body></body></html>", "<!DOCTYPE html>S<html><script>var Module={};</script><body></body></html>" },
        // BOM, whitespace and comments ahead of the doctype are skipped.
        .{ "\xEF\xBB\xBF<!doctype html><p>x</p>", "\xEF\xBB\xBF<!doctype html>S<p>x</p>" },
        .{ " \r\n\t<!DocType html>\n<p>x</p>", " \r\n\t<!DocType html>S\n<p>x</p>" },
        .{ "\xEF\xBB\xBF <!-- a <!doctype x> in a comment --> <!-- b --><!doctype html><html>", "\xEF\xBB\xBF <!-- a <!doctype x> in a comment --> <!-- b --><!doctype html>S<html>" },
        .{ "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\"><html>", "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\">S<html>" },
        // No doctype (or not leading): at the start.
        .{ "<html><head></head></html>", "S<html><head></head></html>" },
        .{ "<p>fragment</p>", "S<p>fragment</p>" },
        .{ "<p>x</p><!doctype html>", "S<p>x</p><!doctype html>" },
        .{ "<!-- unterminated <!doctype html>", "S<!-- unterminated <!doctype html>" },
        .{ "<!doctype html", "S<!doctype html" },
        .{ "", "S" },
        // A leading BOM with no doctype: just past the BOM, never ahead of it (#7).
        .{ "\xEF\xBB\xBF<title>t</title><p>x</p>", "\xEF\xBB\xBFS<title>t</title><p>x</p>" },
        .{ "\xEF\xBB\xBF", "\xEF\xBB\xBFS" },
        .{ "\xEF\xBB\xBF<!-- unterminated <!doctype html>", "\xEF\xBB\xBFS<!-- unterminated <!doctype html>" },
        // A leading XML declaration is skipped on the way to the doctype (#7)...
        .{ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html><html>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>S<html>" },
        .{ "\xEF\xBB\xBF<?xml version=\"1.0\"?><!-- c --><!doctype html><p>x</p>", "\xEF\xBB\xBF<?xml version=\"1.0\"?><!-- c --><!doctype html>S<p>x</p>" },
        // ...but with no doctype after it, the block goes at the start.
        .{ "<?xml version=\"1.0\"?><html>", "S<?xml version=\"1.0\"?><html>" },
        .{ "\xEF\xBB\xBF<?xml version=\"1.0\"?><html>", "\xEF\xBB\xBFS<?xml version=\"1.0\"?><html>" },
        .{ "<?xml unterminated <!doctype html>", "S<?xml unterminated <!doctype html>" },
        // Only one `<?...>`, and only as the very first thing (after a BOM).
        .{ "<?a?><?b?><!doctype html>", "S<?a?><?b?><!doctype html>" },
        .{ " <?xml version=\"1.0\"?><!doctype html>", "S <?xml version=\"1.0\"?><!doctype html>" },
    }) |case| {
        const got = try injectFirst(alloc, case[0], "S");
        defer alloc.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
    try std.testing.expectEqual(@as(?[]u8, null), try runEnvScript(alloc, &.{}));
}

test "injectPoint: which rule placed the block" {
    const cases = [_]struct { html: []const u8, want: InjectPoint }{
        .{ .html = "<!doctype html><p>", .want = .{ .at = 15, .after = .doctype } },
        .{ .html = "\xEF\xBB\xBF<!doctype html>", .want = .{ .at = 18, .after = .doctype } },
        .{ .html = "<?xml?><!doctype html>", .want = .{ .at = 22, .after = .doctype } },
        .{ .html = "\xEF\xBB\xBF<?xml?>\n<!doctype html>", .want = .{ .at = 26, .after = .doctype } },
        .{ .html = "\xEF\xBB\xBF<p>x</p>", .want = .{ .at = 3, .after = .start } },
        .{ .html = "\xEF\xBB\xBF<?xml?><p>x</p>", .want = .{ .at = 3, .after = .start } },
        .{ .html = "<?xml?><p>x</p>", .want = .{ .at = 0, .after = .start } },
        .{ .html = "<p>x</p>", .want = .{ .at = 0, .after = .start } },
    };
    for (cases) |case| try std.testing.expectEqual(case.want, injectPoint(case.html));
}
