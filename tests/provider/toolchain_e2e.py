"""The web provider's toolchain and browser-watch hooks through a real CLI (contract 1.3.0).

python tests/provider/toolchain_e2e.py --cli /path/to/labelle --zig /path/to/zig

RFC labelle-cli#466 PR W acceptance, against a CLI built from labelle-cli
v2.1.0. Hermetic: a fake assembler generates a tiny wasm-shaped build whose
configure step logs the environment it sees (`configure.log`: optimize,
EMSDK, EM_CONFIG and the first PATH entry, one line per zig invocation), and
a fake `git` on PATH "clones" a fake emsdk whose `install` creates
`upstream/emscripten/emcc` and whose `activate` writes `.emscripten`. No
network, no real emscripten.

Each check asserts the path taken:
- managed: EMSDK unset, the provider installs emsdk into cache_dir and the
  contribution reaches the fingerprint pass (`labelle generate`, which runs
  no compile) and the compile, with the ReleaseSafe target default;
- passthrough: an external EMSDK is used and nothing is cloned;
- `--progress=json` keeps stdout pure NDJSON;
- offline with no cached emsdk fails naming the version; offline with it cached succeeds;
- no Python on PATH fails naming `labelle install python`;
- two concurrent builds end with one install;
- package mode activates every zig-pkg emsdk after generation;
- `doctor --json` prints one capability object; `toolchain which` answers;
- `run --watch`: live reload over HTTP; a failed rebuild keeps serving the
  last output and generation; SIGTERM ends the session with status 0 (POSIX).
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True)
parser.add_argument("--zig", required=True)
options = parser.parse_args()
cli = str(Path(options.cli).resolve())
zig = str(Path(options.zig).resolve())
if os.name == "nt":  # bash's `command -v zig` drops the suffix LABELLE_ZIG needs
    cli, zig = (x if x.lower().endswith(".exe") else x + ".exe" for x in (cli, zig))
repo = Path(__file__).resolve().parents[2]
version = subprocess.check_output([zig, "version"], text=True).strip()
windows = os.name == "nt"
COMMIT = "3bcf1dcd01f040f370e10fe673a092d9ed79ebb5"
WASM = b"\0asm\1\0\0\0"

FAKE_ASSEMBLER = r'''import sys, zlib
from pathlib import Path
argv = sys.argv[1:]
if argv and argv[0] == "--protocol-version":
    print(99)
elif argv and argv[0] == "install":
    print("FIXTURE_INSTALL_DONE", file=sys.stderr, flush=True)
elif argv and argv[0] == "generate":
    root = Path(argv[argv.index("--project-root") + 1])
    backend = argv[argv.index("--backend") + 1]
    platform_name = argv[argv.index("--platform") + 1]
    target = root / ".labelle" / f"{backend}_{platform_name}"
    (target / "web").mkdir(parents=True, exist_ok=True)
    broken = (root / "broken.flag").exists()
    (target / "build.zig").write_text(
        'const std = @import("std");\n'
        'pub fn build(b: *std.Build) void {\n'
        '    const optimize = b.standardOptimizeOption(.{});\n'
        '    const env = &b.graph.environ_map;\n'
        '    const log_path = b.pathFromRoot("configure.log");\n'
        '    const previous = std.Io.Dir.cwd().readFileAlloc(b.graph.io, log_path, b.allocator, .limited(1 << 20)) catch "";\n'
        '    const path_env = env.get("PATH") orelse "";\n'
        '    const head = path_env[0 .. std.mem.indexOfScalar(u8, path_env, std.fs.path.delimiter) orelse path_env.len];\n'
        '    const line = b.fmt("{s}{s}|{s}|{s}|{s}\\n", .{ previous, @tagName(optimize), env.get("EMSDK") orelse "-", env.get("EM_CONFIG") orelse "-", head });\n'
        '    std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = log_path, .data = line }) catch @panic("configure.log");\n'
        + ('    b.getInstallStep().dependOn(&b.addFail("fixture: broken build").step);\n' if broken else '') +
        '    b.installFile("web/game.wasm", "web/game.wasm");\n'
        '    b.installFile("web/game.js", "web/game.js");\n'
        '    b.installFile("web/data.txt", "web/data.txt");\n'
        '}\n')
    # A valid fingerprint for the name `game`, so the CLI's generation-time
    # fingerprint pass (`zig build --list-steps`) configures this build.
    fingerprint = (zlib.crc32(b"game") << 32) | 0x1234ABCD
    (target / "build.zig.zon").write_text(
        '.{ .name = .game, .version = "0.0.0", .fingerprint = 0x%x, .paths = .{""} }\n' % fingerprint)
    (target / "web" / "game.wasm").write_bytes(b"\0asm\1\0\0\0")
    (target / "web" / "game.js").write_text("// fixture glue\n")
    (target / "web" / "data.txt").write_text((root / "assets" / "data.txt").read_text())
    # Package mode: two emsdk checkouts "fetched" into zig-pkg (two hashes).
    if (root / "package-mode.flag").exists():
        template = Path(__file__).parent / "emsdk-template"
        for h in ("emsdk-hash-a", "emsdk-hash-b"):
            dest = target / "zig-pkg" / h
            if not dest.exists():
                import shutil
                shutil.copytree(template, dest)
    print("FIXTURE_GENERATE", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''

# The fake emsdk launcher's body: `install` creates emcc (slowly when asked,
# to widen a race), `activate` writes the EM_CONFIG. Each install is logged.
FAKE_EMSDK = r'''import os, sys, time
from pathlib import Path
root = Path(__file__).resolve().parent
sub, ver = sys.argv[1], sys.argv[2]
log = os.environ.get("FAKE_EMSDK_LOG")
if sub == "install":
    time.sleep(float(os.environ.get("FAKE_EMSDK_SLOW", "0")))
    emcc = root / "upstream" / "emscripten"
    emcc.mkdir(parents=True, exist_ok=True)
    (emcc / "emcc").write_text("#!/bin/sh\n")
    (emcc / "emcc.bat").write_text("@echo off\r\n")
    if log:
        with open(log, "a") as f:
            f.write(f"install {ver} {root}\n")
    print("fake emsdk: installed", ver)  # stdout: must not reach the CLI's stdout
elif sub == "activate":
    (root / ".emscripten").write_text("# fake EM_CONFIG\n")
    print("fake emsdk: activated", ver)
else:
    raise SystemExit(f"fake emsdk: unexpected {sys.argv}")
'''

# `git clone ... <dest>` copies the emsdk template; `git rev-parse HEAD`
# answers the pinned 4.0.9 commit. Every clone is logged.
FAKE_GIT = r'''import os, shutil, sys
from pathlib import Path
argv = sys.argv[1:]
if argv[:1] == ["clone"]:
    shutil.copytree(os.environ["FAKE_EMSDK_TEMPLATE"], argv[-1])
    with open(os.environ["FAKE_GIT_LOG"], "a") as f:
        f.write(" ".join(argv) + "\n")
    print("Cloning into", argv[-1])
elif argv[:2] == ["rev-parse", "HEAD"]:
    print("%s")
else:
    raise SystemExit(f"fake git: unexpected {argv}")
''' % COMMIT


def wrapper(directory, name, script):
    """An executable `name` in `directory` running `script` with this Python."""
    if windows:
        (directory / f"{name}.cmd").write_text(f'@echo off\r\n"{sys.executable}" "{script}" %*\r\nexit /b %ERRORLEVEL%\r\n')
    else:
        path = directory / name
        path.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n')
        path.chmod(0o755)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def http(port, path):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=3) as r:
            return r.read()
    except (OSError, urllib.error.URLError):
        return None


def wait_for(what, predicate, timeout=240):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    raise AssertionError(f"timed out waiting for {what}")


with tempfile.TemporaryDirectory(prefix="web-030-e2e-") as temp:
    base = Path(temp).resolve()
    tools = base / "tools"
    tools.mkdir()
    (tools / "fake_assembler.py").write_text(FAKE_ASSEMBLER)
    template = tools / "emsdk-template"
    template.mkdir()
    (template / "fake_emsdk.py").write_text(FAKE_EMSDK)
    (template / "emsdk.py").write_text("# the emsdk-repo signature file\n")
    (template / "emsdk").write_text('#!/bin/sh\nexec python3 "$(dirname "$0")/fake_emsdk.py" "$@"\n')
    (template / "emsdk").chmod(0o755)
    (template / "emsdk.bat").write_text('@echo off\r\npython "%~dp0fake_emsdk.py" %*\r\nexit /b %ERRORLEVEL%\r\n')
    (tools / "fake_git.py").write_text(FAKE_GIT)
    shims = base / "shims"
    shims.mkdir()
    wrapper(shims, "git", tools / "fake_git.py")
    wrapper(tools, "fake-assembler", tools / "fake_assembler.py")
    assembler = tools / ("fake-assembler.cmd" if windows else "fake-assembler")
    git_log = base / "git.log"
    emsdk_log = base / "emsdk.log"
    # PATH: the fake git first, then the inherited PATH minus any real emcc.
    inherited = [p for p in os.environ.get("PATH", "").split(os.pathsep)
                 if p and not (Path(p) / ("emcc.bat" if windows else "emcc")).exists()]
    env = dict(os.environ, LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler), LABELLE_NO_PREBUILD="1",
               FAKE_EMSDK_TEMPLATE=str(template), FAKE_GIT_LOG=str(git_log), FAKE_EMSDK_LOG=str(emsdk_log),
               PATH=os.pathsep.join([str(shims), *inherited]))
    for leftover in ("EMSDK", "EM_CONFIG", "LABELLE_OFFLINE", "LABELLE_EMSDK", "FAKE_EMSDK_SLOW"):
        env.pop(leftover, None)
    checks = 0

    def make_project(name, settings=None):
        project = base / name
        (project / "assets").mkdir(parents=True)
        (project / "assets" / "data.txt").write_text("one")
        config = ""
        if settings is not None:
            (project / "providers").mkdir()
            (project / "providers" / "web.json").write_text(json.dumps(settings))
            config = ', .provider_config = .{ .{ .package = "web", .file = "providers/web.json" } }'
        dep = f'.{{ .name = "web", .repo = "local:{repo.as_posix()}", .version = "0.3.0" }}'
        (project / "project.labelle").write_text(
            f'.{{ .name = "game", .zig_version = "{version}", .plugins = .{{ {dep} }}{config} }}')
        return project

    def target_of(project):
        found = list((project / ".labelle").glob("*_wasm"))
        assert len(found) == 1, found
        return found[0]

    def configure_lines(project):
        path = target_of(project) / "configure.log"
        return [line.split("|") for line in path.read_text().splitlines()] if path.exists() else []

    def run(project, *args, code=0, home, extra=None, drop=(), progress="off", timeout=900):
        global checks
        merged = dict(env, LABELLE_HOME=str(home), **(extra or {}))
        for name in drop:
            merged.pop(name, None)
        flags = [f"--progress={progress}"] if progress else []
        result = subprocess.run([cli, *args, *flags], cwd=project, env=merged, text=True, capture_output=True, timeout=timeout)
        assert code is None or result.returncode == code, (args, result.returncode, result.stdout[-4000:], result.stderr[-8000:])
        checks += 1
        return result

    def clones():
        return git_log.read_text().splitlines() if git_log.exists() else []

    def managed_dir(home):
        found = list((home / "providers").glob("local/*/emsdk/v1/*/4.0.9-3bcf1dcd01f0"))
        return found[0] if found else None

    emcc_name = "emcc.bat" if windows else "emcc"

    # ── Passthrough: an external EMSDK is used as is, nothing is cloned ──
    external = base / "external-emsdk"
    (external / "upstream" / "emscripten").mkdir(parents=True)
    (external / "upstream" / "emscripten" / emcc_name).write_text("")
    (external / ".emscripten").write_text("# external\n")
    home_a = base / "home-a"
    project = make_project("passthrough")
    result = run(project, "build", "--platform=wasm", home=home_a, extra={"EMSDK": str(external)})
    assert "emsdk from inherited EMSDK" in result.stderr, result.stderr
    lines = configure_lines(project)
    assert lines and all(l[1] == str(external) for l in lines), lines
    assert all(l[3] == str(external / "upstream" / "emscripten") for l in lines), lines
    assert clones() == [] and managed_dir(home_a) is None, "an external EMSDK must not download"
    assert (target_of(project) / "zig-out" / "web" / "game.wasm").read_bytes() == WASM

    # ── Managed, from zero: the fingerprint pass sees the contribution ──
    home = base / "home"
    project = make_project("managed")
    result = run(project, "generate", "--platform=wasm", home=home)
    assert len(clones()) == 1, clones()
    install = managed_dir(home)
    assert install and (install / ".labelle-web-install").is_file() and (install / "upstream" / "emscripten" / emcc_name).is_file()
    assert "emsdk from managed install" in result.stderr, result.stderr
    lines = configure_lines(project)
    # `generate` runs no compile: this line is the fingerprint pass.
    assert len(lines) == 1, lines
    assert lines[0][1] == str(install) and lines[0][2] == str(install / ".emscripten"), lines
    assert lines[0][3] == str(install / "upstream" / "emscripten"), lines
    # The build: pure NDJSON on stdout, ReleaseSafe from the target default,
    # the contribution in the compile, the loading shell stamped.
    result = run(project, "build", "--platform=wasm", home=home, progress="json")
    for line in result.stdout.splitlines():
        json.loads(line)  # anything else on stdout breaks the progress feed
    assert "fake emsdk" not in result.stdout and "Cloning" not in result.stdout
    lines = configure_lines(project)
    assert len(lines) >= 3, lines
    assert all(l[1] == str(install) for l in lines), lines
    assert lines[-1][0] == "ReleaseSafe", lines
    web = target_of(project) / "zig-out" / "web"
    assert (web / "game.wasm").read_bytes()[:4] == WASM[:4]
    assert 'data-wasm-bytes="8"' in (web / "index.html").read_text()
    assert len(clones()) == 1, "a cached install is reused"
    # An explicit --optimize wins over the target default.
    run(project, "build", "--platform=wasm", "--optimize=Debug", home=home)
    assert configure_lines(project)[-1][0] == "Debug", configure_lines(project)

    # ── The toolchain command and the doctor ──
    result = run(project, "web", "toolchain", "which", home=home, progress=None)
    assert str(install) in result.stdout and "installed: yes" in result.stdout, result.stdout
    result = run(project, "web", "doctor", "--json", home=home, progress=None)
    out = result.stdout.splitlines()
    assert len(out) == 1, result.stdout
    cap = json.loads(out[0])
    assert cap["id"] == "wasm" and cap["required"] is True and cap["ok"] is True, cap
    assert [i["id"] for i in cap["items"]] == ["python", "emsdk"], cap
    for item in cap["items"]:
        assert set(item) == {"id", "name", "ok", "fixable", "size_mb", "action", "detail", "hint"}, item
    assert cap["items"][0]["action"] == "labelle install python"
    assert str(install) in cap["items"][1]["detail"], cap
    # The core checks may fail on this host (SDL2 for desktop gamepads); the
    # provider's doctor runs after them regardless.
    result = run(project, "doctor", code=None, home=home, progress=None)
    assert "labelle web doctor (wasm)" in result.stderr, result.stderr

    # ── Offline: a cached emsdk needs no network; a missing one fails clearly ──
    run(project, "build", "--platform=wasm", home=home, extra={"LABELLE_OFFLINE": "1"})
    assert len(clones()) == 1
    other = make_project("offline")
    result = run(other, "build", "--platform=wasm", code=1, home=base / "home-offline", extra={"LABELLE_OFFLINE": "1"})
    assert "emsdk 4.0.9 is not installed" in result.stderr and "LABELLE_OFFLINE" in result.stderr, result.stderr
    assert "web/toolchain" in result.stderr, result.stderr
    assert len(clones()) == 1
    result = run(other, "web", "doctor", "--json", code=1, home=base / "home-offline", extra={"LABELLE_OFFLINE": "1"}, progress=None)
    assert json.loads(result.stdout)["items"][1]["ok"] is False

    # ── No Python: the toolchain hook names `labelle install python` ──
    nopy = base / "no-python-path"
    nopy.mkdir()
    result = run(make_project("no-python"), "build", "--platform=wasm", code=1, home=home, extra={"PATH": str(nopy)})
    assert "labelle install python" in result.stderr, result.stderr
    assert "web/toolchain" in result.stderr, result.stderr

    # ── Two builds installing one emsdk at once: one install, both succeed ──
    race_home = base / "home-race"
    racers = [make_project(f"race-{n}") for n in range(2)]
    # Warm the provider tool build so both builds reach the install together.
    # (Passthrough, so this installs nothing.)
    run(racers[0], "generate", "--platform=wasm", home=race_home, extra={"EMSDK": str(external)})
    before = len(clones())
    procs = [subprocess.Popen([cli, "build", "--platform=wasm", "--progress=off"], cwd=p, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=dict(env, LABELLE_HOME=str(race_home), FAKE_EMSDK_SLOW="3")) for p in racers]
    outputs = [p.communicate(timeout=900) for p in procs]
    for p, (out, err) in zip(procs, outputs):
        assert p.returncode == 0, (out, err)
    assert len(clones()) == before + 1, clones()
    raced = managed_dir(race_home)
    assert raced and (raced / ".labelle-web-install").is_file()
    assert not list(raced.parent.glob("*.tmp-*")), "a staging tree was left behind"
    assert any("installed by another build" in err for _, err in outputs), outputs
    checks += 1

    # ── Package mode: every zig-pkg emsdk activated after generation ──
    project = make_project("package", settings={"schema_version": 1, "emsdk": {"source": "package"}})
    (project / "package-mode.flag").write_text("")
    installs_before = emsdk_log.read_text().count("install") if emsdk_log.exists() else 0
    result = run(project, "build", "--platform=wasm", home=home)
    pkgs = sorted((target_of(project) / "zig-pkg").iterdir())
    assert [p.name for p in pkgs] == ["emsdk-hash-a", "emsdk-hash-b"]
    for pkg in pkgs:
        assert (pkg / "upstream" / "emscripten" / emcc_name).is_file() and (pkg / ".emscripten").is_file(), pkg
    lines = configure_lines(project)
    # The fingerprint pass ran before activation: no contribution there.
    assert lines[0][1] == "-", lines
    assert lines[-1][1] == str(pkgs[0]), lines
    assert "emsdk from package" in result.stderr, result.stderr
    assert len(clones()) == before + 1, "package mode never uses the managed install"
    assert emsdk_log.read_text().count("install") >= installs_before + 1

    # ── Browser watch: reload after a successful rebuild only ──
    project = make_project("watch", settings={"schema_version": 1, "open_browser": False})
    port = free_port()
    log = (base / "watch.log").open("w+")
    kwargs = {"start_new_session": True} if not windows else {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    session = subprocess.Popen([cli, "run", "--platform=wasm", "--watch", "--progress=off", "--", f"--port={port}", "--no-open"],
                               cwd=project, env=dict(env, LABELLE_HOME=str(home)), stdout=log, stderr=log, **kwargs)

    def generation():
        body = http(port, "/__labelle_livereload")
        return body.decode() if body is not None else None

    def dump():
        log.seek(0)
        return log.read()[-8000:]

    try:
        try:
            wait_for("the watch session to serve generation 0", lambda: generation() == "0")
            assert http(port, "/data.txt") == b"one"
            page = http(port, "/").decode()
            assert "__labelle_livereload" in page and 'data-wasm-bytes="8"' in page, page
            # A successful rebuild publishes, then the generation advances.
            (project / "assets" / "data.txt").write_text("two")
            wait_for("generation 1", lambda: generation() == "1")
            assert http(port, "/data.txt") == b"two"
            # A failed rebuild publishes nothing: same output, same generation.
            (project / "broken.flag").write_text("")
            (project / "assets" / "data.txt").write_text("three")
            wait_for("the failed rebuild", lambda: "fixture: broken build" in dump())
            time.sleep(1.5)
            assert generation() == "1" and http(port, "/data.txt") == b"two", dump()
            (project / "broken.flag").unlink()
            (project / "assets" / "data.txt").write_text("four")
            wait_for("generation 2", lambda: generation() == "2")
            assert http(port, "/data.txt") == b"four"
            assert "generation 2 published; reloading browsers" in dump()
        except AssertionError:
            print(dump(), file=sys.stderr)
            raise
        checks += 1
    finally:
        if windows:
            subprocess.run(["taskkill", "/PID", str(session.pid), "/T", "/F"], capture_output=True)
            session.wait(timeout=60)
        else:
            os.killpg(session.pid, signal.SIGTERM)
            code = session.wait(timeout=60)
            assert code == 0, (code, dump())
        log.close()
    print(f"PASS: {checks} toolchain, doctor and browser-watch checks through the real CLI")
