"""Real CLI command dispatch plus provider wire hooks, exports and HTTP serving."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
import urllib.parse
import zipfile

p = argparse.ArgumentParser()
p.add_argument('--cli', required=True)
p.add_argument('--zig', required=True)
a = p.parse_args()
cli, zig = str(Path(a.cli).resolve()), str(Path(a.zig).resolve())
repo = Path(__file__).resolve().parents[2]
exe = repo / 'zig-out/bin' / ('labelle-web.exe' if os.name == 'nt' else 'labelle-web')
version = subprocess.check_output([zig, 'version'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='labelle-web-provider-') as temp:
    temp = Path(temp).resolve()
    project = temp / 'game'
    web = project / '.labelle/test_wasm/zig-out/web'
    web.mkdir(parents=True)
    wasm = b'\0asm\1\0\0\0'
    (web / 'game.wasm').write_bytes(wasm)
    (web / 'game.js').write_text('// fixture glue')
    dep = f'.{{ .name = "web", .repo = "local:{repo.as_posix()}", .version = "0.1.0" }}'
    (project / 'project.labelle').write_text(f'.{{ .name = "test", .zig_version = "{version}", .plugins = .{{ {dep} }} }}')
    (project / 'labelle.lock').write_text(f'.{{ .plugins = .{{ {dep} }} }}')
    env = dict(os.environ, LABELLE_HOME=str(temp / 'home'), LABELLE_ZIG=zig)
    def run(*args, fail=None):
        result = subprocess.run([cli, *args], cwd=project, env=env, text=True, capture_output=True, timeout=180)
        if fail:
            assert result.returncode and fail in result.stderr, (result.returncode, result.stdout, result.stderr)
        else:
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        return result
    assert 'web export' in run('help').stderr
    # Old export shares the CLI run phase: it must refuse a server replacement.
    for verb in ('serve', 'export'):
        run('wasm', verb, '--no-build', fail='legacy `wasm serve/export`')
    run('web', 'export', '--output=dist', '--zip', '--platform=github-pages')
    dist = project / 'dist'
    assert 'data-wasm-bytes="8"' in (dist / 'index.html').read_text()
    assert (dist / '.nojekyll').exists()
    assert (dist / 'labelle-loader.js').is_file()
    with zipfile.ZipFile(project / 'dist.zip') as archive:
        assert archive.read('index.html') == (dist / 'index.html').read_bytes()
    # Source paths are protected before they exist, not only after realpath succeeds.
    run('web', 'export', '--output=web', fail='DestructiveOutputPath')
    run('web', 'export', '--output=web/new', fail='DestructiveOutputPath')
    assert not (project / 'web').exists()
    for bad in ('marker-directory', 'marker-invalid'):
        folder = project / bad
        folder.mkdir()
        (folder / 'keep').write_text('keep')
        if bad == 'marker-directory':
            (folder / '.labelle-export').mkdir()
        else:
            (folder / '.labelle-export').write_text('{}')
        run('web', 'export', f'--output={bad}', fail='DestructiveOutputPath')
        assert (folder / 'keep').read_text() == 'keep'
    if os.name != 'nt':
        folder = project / 'marker-link'
        folder.mkdir()
        (folder / 'keep').write_text('keep')
        (folder / '.labelle-export').symlink_to(dist / '.labelle-export')
        run('web', 'export', '--output=marker-link', fail='DestructiveOutputPath')
        assert (folder / 'keep').read_text() == 'keep'
        # Neither required nor auxiliary symlinks may silently vanish from export.
        original_js = (web / 'game.js').read_bytes()
        (project / 'real-game.js').write_bytes(original_js)
        (web / 'game.js').unlink()
        (web / 'game.js').symlink_to(project / 'real-game.js')
        run('web', 'export', '--output=dist', fail='InvalidBuildArtifact')
        (web / 'game.js').unlink()
        (web / 'game.js').write_bytes(original_js)
        original_export = (dist / 'index.html').read_bytes()
        (web / 'linked-extra.js').symlink_to(project / 'real-game.js')
        run('web', 'export', '--output=dist', fail='UnsupportedBuildArtifact')
        assert (dist / 'index.html').read_bytes() == original_export
        run('web', 'serve', '--no-open', fail='UnsupportedBuildArtifact')
        (web / 'linked-extra.js').unlink()
    # Runtime names must deploy to case-sensitive hosts without changing spelling.
    (web / 'game.js').rename(web / 'GAME.JS')
    run('web', 'export', '--output=dist', fail='InvalidBuildArtifact')
    (web / 'GAME.JS').rename(web / 'game.js')
    (web / '.labelle-export').write_text('input must not replace ownership')
    run('web', 'export', '--output=dist', fail='ReservedWebAsset')
    (web / '.labelle-export').unlink()
    # Custom source stays untouched; relative page resources ship with it.
    custom = project / 'web'
    custom.mkdir()
    source = '<!doctype html><title>Custom</title><div data-wasm-bytes="__WASM_BYTES__"></div><script src="extra.js"></script>'
    (custom / 'index.html').write_text(source)
    (custom / 'extra.js').write_text('window.extra = true;')
    (custom / '.labelle-export').write_text('not metadata')
    run('web', 'export', '--output=reserved-marker', fail='ReservedWebAsset')
    (custom / '.labelle-export').unlink()
    run('web', 'export', '--output=dist')
    assert (dist / 'index.html').read_text() == source.replace('__WASM_BYTES__', '8')
    assert (custom / 'index.html').read_text() == source
    assert (dist / 'extra.js').read_text() == 'window.extra = true;'
    # Custom files invalidate every compressed sibling, regardless of copy order.
    (web / 'extra.js.gz').write_bytes(b'old build compression')
    (custom / 'extra.js.br').write_bytes(b'old source compression')
    (custom / 'café image.txt').write_text('unicode resource')
    run('web', 'export', '--output=dist', '--zip')
    assert not (dist / 'extra.js.gz').exists() and not (dist / 'extra.js.br').exists()
    with zipfile.ZipFile(project / 'dist.zip') as archive:
        assert archive.read('café image.txt') == b'unicode resource'
    # Existing exports may replace their own archive; unrelated/replaced files survive.
    (project / 'unrelated.zip').write_bytes(b'keep unrelated archive')
    run('web', 'export', '--output=unrelated', '--zip', fail='DestructiveArchivePath')
    assert not (project / 'unrelated').exists()
    assert (project / 'unrelated.zip').read_bytes() == b'keep unrelated archive'
    previous_zip = (project / 'dist.zip').read_bytes()
    previous_html = (dist / 'index.html').read_bytes()
    (project / 'dist.zip').write_bytes(b'replaced archive')
    run('web', 'export', '--output=dist', '--zip', fail='DestructiveArchivePath')
    assert (project / 'dist.zip').read_bytes() == b'replaced archive'
    assert (dist / 'index.html').read_bytes() == previous_html
    (project / 'dist.zip').write_bytes(previous_zip)
    # Reserved variants cannot truncate a runtime artifact on case-insensitive hosts.
    (custom / 'Game.WASM').write_bytes(b'bad overwrite')
    run('web', 'export', '--output=reserved', fail='ReservedWebAsset')
    assert (project / 'reserved/game.wasm').read_bytes() == wasm
    (custom / 'Game.WASM').unlink()
    run('web', 'export', '--output=.', fail='DestructiveOutputPath')
    run('web', 'export', '--output=web', fail='DestructiveOutputPath')
    (project / 'user-data').mkdir()
    (project / 'user-data/keep').write_text('keep')
    run('web', 'export', '--output=user-data', fail='DestructiveOutputPath')
    assert (project / 'user-data/keep').read_text() == 'keep'
    # Exercise actual post-build and bundle wire contexts; generic CLI hooks
    # are independently covered in labelle-cli/test/provider_hooks_e2e.py.
    context = dict(contract_version='1.1.0', invocation=dict(kind='hook', id='shell', step='build', phase='after'), package_dir=str(repo), project_dir=str(project), target='wasm', lock_file=str(project / 'labelle.lock'), config_file=None, output_dir=str(web.parent), zig_executable=zig, optimize='Debug', progress='json')
    ctxfile = temp / 'context.json'
    def hook():
        ctxfile.write_text(json.dumps(context))
        result = subprocess.run([exe], env=dict(env, LABELLE_CONTEXT=str(ctxfile)), cwd=project, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        assert result.stdout == '', 'JSON progress mode must not emit non-protocol stdout'
    hook()
    assert (web / 'index.html').read_text() == source.replace('__WASM_BYTES__', '8')
    # Deleted custom files disappear from staging and export, while newly emitted
    # backend content replacing an old overlay is preserved.
    (custom / 'nested').mkdir()
    (custom / 'nested/removed.txt').write_text('remove me')
    (custom / 'overridden.txt').write_text('old custom')
    hook()
    (custom / 'nested/removed.txt').unlink()
    (custom / 'overridden.txt').unlink()
    (web / 'overridden.txt').write_text('new backend')
    run('web', 'export', '--output=dist')
    assert not (dist / 'nested/removed.txt').exists()
    assert (dist / 'overridden.txt').read_text() == 'new backend'
    hook()
    assert not (web / 'nested/removed.txt').exists()
    assert (web / 'overridden.txt').read_text() == 'new backend'
    (custom / 'CaseAsset.txt').write_text('case rename')
    hook()
    (custom / 'CaseAsset.txt').rename(custom / 'caseasset.txt')
    hook()
    assert (web / 'caseasset.txt').read_text() == 'case rename'
    # Rebuilding/restaging after a custom page is removed restores the default.
    (custom / 'index.html').unlink()
    hook()
    assert '<title>LaBelle</title>' in (web / 'index.html').read_text()
    (custom / 'index.html').write_text(source)
    hook()
    context.update(invocation=dict(kind='hook', id='export', step='bundle', phase='replace'), output_dir=str(project / 'bundle'))
    hook()
    assert 'data-wasm-bytes="8"' in (project / 'bundle/index.html').read_text()
    assert not (project / 'bundle/.labelle-shell-state.json').exists()
    # JSON escaping may make provenance larger than the supported source HTML.
    context.update(invocation=dict(kind='hook', id='shell', step='build', phase='after'), output_dir=str(web.parent))
    large_page = '"' * (9 * 1024 * 1024)
    (web / 'index.html').write_text(large_page)
    hook()
    assert (web / '.labelle-shell-state.json').stat().st_size > 16 * 1024 * 1024
    hook()
    (custom / 'index.html').unlink()
    hook()
    assert (web / 'index.html').read_text() == large_page
    (web / 'index.html').unlink()
    (web / '.labelle-shell-state.json').unlink()
    (custom / 'index.html').write_text(source)
    # A controlled optimizer changes the shipped length: size stamping must
    # follow that transform, and stale compressed siblings must be removed.
    if os.name != 'nt':
        tools = temp / 'tools'
        tools.mkdir()
        optimizer = tools / 'wasm-opt'
        optimizer.write_text('#!/usr/bin/env python3\nimport pathlib,sys\npathlib.Path(sys.argv[sys.argv.index("-o")+1]).write_bytes(b"\\x00asm\\x01\\x00\\x00\\x00")\n')
        optimizer.chmod(0o755)
        env['PATH'] = str(tools) + os.pathsep + os.environ['PATH']
        (web / 'game.wasm').write_bytes(wasm + b'\0\1\0')
        (web / 'game.wasm.opt').write_bytes(b'legitimate asset')
        (web / 'game.wasm.gz').write_bytes(b'stale')
        (web / 'index.html.gz').write_bytes(b'stale')
        run('web', 'export', '--output=optimized')
        final = project / 'optimized'
        assert len((final / 'game.wasm').read_bytes()) == 8
        assert 'data-wasm-bytes="8"' in (final / 'index.html').read_text()
        assert not (final / 'game.wasm.gz').exists()
        assert not (final / 'index.html.gz').exists()
        assert (final / 'game.wasm.opt').read_bytes() == b'legitimate asset'
        optimizer.write_text(optimizer.read_text() + '\nraise SystemExit(1)\n')
        run('web', 'export', '--output=optimizer-failed')
        assert (project / 'optimizer-failed/game.wasm.opt').read_bytes() == b'legitimate asset'
        assert not list(project.glob('*.wasm-opt-*')), 'optimizer scratch directories leaked'
        (web / 'game.wasm').write_bytes(wasm)
        env['PATH'] = os.environ['PATH']
    # Serve through the actual CLI, including final stamped page and custom JS.
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    log = (temp / 'serve.log').open('w+')
    kwargs = {'start_new_session': True} if os.name != 'nt' else {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP}
    proc = subprocess.Popen([cli, 'web', 'serve', f'--port={port}', '--no-open'], cwd=project, env=env, stdout=log, stderr=log, **kwargs)
    try:
        deadline = time.monotonic() + 60
        while True:
            try:
                response = urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=1).read().decode()
                break
            except OSError:
                if proc.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise AssertionError(log.read())
                time.sleep(.1)
        assert response == source.replace('__WASM_BYTES__', '8')
        if os.name != 'nt':
            # A new symlink introduced after startup cannot escape the served root.
            (web / 'escape.txt').symlink_to(project / 'project.labelle')
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/escape.txt', timeout=3)
                raise AssertionError('server followed an escaping symlink')
            except urllib.error.HTTPError as error:
                assert error.code == 403, error.code
            finally:
                (web / 'escape.txt').unlink()
        assert urllib.request.urlopen(f'http://127.0.0.1:{port}/' + urllib.parse.quote('café image.txt'), timeout=3).read() == b'unicode resource'
        for hidden in ('.labelle-shell-state.json', './.labelle-shell-state.json', '.LABELLE-SHELL-STATE.JSON', '%2elabelle-shell-state.json', '%2e%2e/project.labelle', '%5c..%5cproject.labelle'):
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/{hidden}', timeout=3)
                raise AssertionError('private staging metadata was served')
            except urllib.error.HTTPError as error:
                assert error.code in (400, 404), error.code
        assert urllib.request.urlopen(f'http://127.0.0.1:{port}/extra.js').read() == b'window.extra = true;'
    finally:
        if os.name == 'nt':
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], capture_output=True)
        else:
            os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=15)
        log.close()
    # Several generated backends cannot silently choose the wrong wasm.
    other = project / '.labelle/other_wasm/zig-out/web'
    other.mkdir(parents=True)
    (other / 'game.wasm').write_bytes(wasm)
    run('web', 'export', '--output=dist', fail='AmbiguousBuildOutput')
    run('web', 'export', f'--input={web}', '--output=dist')
    print('PASS: CLI discovery/export/serve, custom assets, hook staging/bundle, and destructive-path guards')
