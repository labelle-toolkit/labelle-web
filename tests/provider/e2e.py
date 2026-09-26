"""Real CLI command dispatch plus provider wire hooks, exports and HTTP serving."""
import argparse
import hashlib
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
            assert 'leaked' not in result.stderr, result.stderr
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
    # Owned archive bytes do not grant permission to overwrite another hard link.
    archive_before = (project / 'dist.zip').read_bytes()
    page_before = (dist / 'index.html').read_bytes()
    os.link(project / 'dist.zip', project / 'backup.zip')
    run('web', 'export', '--output=dist', '--zip', fail='DestructiveArchivePath')
    assert (project / 'backup.zip').read_bytes() == archive_before
    assert (dist / 'index.html').read_bytes() == page_before
    (project / 'backup.zip').unlink()
    (web / '.nojekyll').mkdir()
    run('web', 'export', '--output=dist', '--platform=github-pages', fail='InvalidPagesMarker')
    assert (dist / 'index.html').read_bytes() == page_before
    (web / '.nojekyll').rmdir()
    # Source paths are protected before they exist, not only after realpath succeeds.
    run('web', 'export', '--output=web', fail='DestructiveOutputPath')
    run('web', 'export', '--output=web/new', fail='DestructiveOutputPath')
    if (project / 'PROJECT.LABELLE').exists():
        run('web', 'export', '--output=Web', fail='DestructiveOutputPath')
        run('web', 'export', '--output=Web/new', fail='DestructiveOutputPath')
        assert not (project / 'web').exists()

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
    for name in ('index.html', 'labelle-loader.js', 'labelle-logo.png', '.labelle-shell-state.json'):
        path = web / name
        saved = path.read_bytes() if path.exists() else None
        if path.exists():
            path.unlink()
        path.mkdir()
        old_export = (dist / 'index.html').read_bytes()
        run('web', 'export', '--output=dist', fail='InvalidWebAssetDestination')
        assert (dist / 'index.html').read_bytes() == old_export
        path.rmdir()
        if saved is not None:
            path.write_bytes(saved)
    if os.name != 'nt':
        external = project / 'external-source'
        external.mkdir()
        (external / 'private.txt').write_text('must not copy through a root symlink')
        (project / 'web').symlink_to(external, target_is_directory=True)
        run('web', 'export', '--output=dist', fail='labelle-web:')
        assert not (dist / 'private.txt').exists()
        (project / 'web').unlink()
    # Custom source stays untouched; relative page resources ship with it.
    custom = project / 'web'
    custom.mkdir()
    (custom / '.nojekyll').mkdir()
    run('web', 'export', '--output=dist', '--platform=github-pages', fail='InvalidPagesMarker')
    assert (dist / 'index.html').read_bytes() == page_before
    (custom / '.nojekyll').rmdir()
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
    assert not (project / 'reserved').exists()
    assert (web / 'game.wasm').read_bytes() == wasm
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
    def hook(fail=None):
        ctxfile.write_text(json.dumps(context))
        result = subprocess.run([exe], env=dict(env, LABELLE_CONTEXT=str(ctxfile)), cwd=project, capture_output=True, text=True, timeout=30)
        if fail:
            assert result.returncode != 0 and fail in result.stderr, result.stderr
            return
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
    # Clear the owned layer before copying replacements, including shape changes.
    (custom / 'changes-shape').write_text('file')
    (custom / 'compressed-replacement').write_text('original')
    (custom / 'É.txt').write_text('unicode case rename')
    hook()
    (custom / 'changes-shape').unlink()
    (custom / 'changes-shape').mkdir()
    (custom / 'changes-shape/config.json').write_text('{}')
    (custom / 'compressed-replacement').unlink()
    (custom / 'compressed-replacement.gz').write_bytes(b'standalone gzip')
    (custom / 'É.txt').rename(custom / 'é.txt')
    hook()
    assert (web / 'changes-shape/config.json').read_text() == '{}'
    assert (web / 'compressed-replacement.gz').read_bytes() == b'standalone gzip'
    assert (web / 'é.txt').read_text() == 'unicode case rename'
    (custom / 'changes-shape/config.json').unlink()
    (custom / 'changes-shape').rmdir()
    (custom / 'changes-shape').write_text('file again')
    hook()
    assert (web / 'changes-shape').read_text() == 'file again'
    (custom / '__labelle_livereload').write_text('ordinary project asset')
    if os.name != 'nt':
        (custom / 'encoded\\asset.txt').write_text('POSIX asset')
    # Directory ownership also covers empty directories and Unicode shape changes.
    (custom / 'empty-owned').mkdir()
    (custom / 'ÖShape').write_text('Unicode file')
    hook()
    (custom / 'empty-owned').rmdir()
    (custom / 'empty-owned').write_text('replaced empty directory')
    (custom / 'ÖShape').unlink()
    (custom / 'öShape').mkdir()
    (custom / 'öShape/child.txt').write_text('child')
    hook()
    assert (web / 'empty-owned').read_text() == 'replaced empty directory'
    assert (web / 'öShape/child.txt').read_text() == 'child'
    (custom / 'öShape/child.txt').unlink()
    (custom / 'öShape').rmdir()
    (custom / 'ÖShape').write_text('file again')
    hook()
    assert (web / 'ÖShape').read_text() == 'file again'
    (web / 'backend-empty').mkdir()
    (custom / 'backend-empty').write_text('must not replace backend directory')
    hook(fail='InvalidWebAssetDestination')
    assert (web / 'backend-empty').is_dir()
    (custom / 'backend-empty').unlink()
    # Copying an overlay must not truncate another file sharing its inode.
    outside = project / 'hardlink-source.txt'
    outside.write_text('must survive')
    (custom / 'linked.txt').write_text('new custom content')
    os.link(outside, web / 'linked.txt')
    hook(fail='InvalidWebAssetDestination')
    assert outside.read_text() == 'must survive'
    (web / 'linked.txt').unlink()
    (custom / 'linked.txt').unlink()
    (custom / 'config').mkdir()
    (custom / 'config/.labelle-shell-state.json').write_text('ordinary nested asset')
    hook()
    # Invalid semantic settings fail before restamping the existing output.
    page_before = (web / 'index.html').read_bytes()
    run('web', 'serve', '--port=0', fail='InvalidPort')
    assert (web / 'index.html').read_bytes() == page_before
    # Preflight is all-or-nothing for unsupported trees: no untracked partial overlay.
    (custom / 'ordinary-partial.txt').write_text('must not leak')
    (custom / 'GAME.JS').write_text('invalid reserved entry')
    previous_page = (web / 'index.html').read_bytes()
    hook(fail='ReservedWebAsset')
    assert not (web / 'ordinary-partial.txt').exists()
    assert (web / 'index.html').read_bytes() == previous_page
    (custom / 'ordinary-partial.txt').unlink()
    (custom / 'GAME.JS').unlink()
    # File-to-directory backend replacements survive removal of the custom source.
    (custom / 'becomes-directory').write_text('old custom file')
    hook()
    (custom / 'becomes-directory').unlink()
    (web / 'becomes-directory').unlink()
    (web / 'becomes-directory').mkdir()
    (web / 'becomes-directory/backend.txt').write_text('new backend directory')
    hook()
    assert (web / 'becomes-directory/backend.txt').read_text() == 'new backend directory'
    if os.name != 'nt':
        for name in ('icon:dark.png', 'icon\\dark.png'):
            (custom / name).write_text('legal POSIX path')
        hook()
        for name in ('icon:dark.png', 'icon\\dark.png'):
            (custom / name).unlink()
        hook()
        for name in ('icon:dark.png', 'icon\\dark.png'):
            assert not (web / name).exists()
    # Repeated large overlays use indexed lookups instead of pairwise path scans.
    many = custom / 'many'
    many.mkdir()
    for n in range(1000):
        (many / f'{n}.txt').write_text(str(n))
    hook()
    hook()
    assert (web / 'many/999.txt').read_text() == '999'
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
    # Matching digests cannot let a saved ownership record delete runtime files.
    state_path = web / '.labelle-shell-state.json'
    safe_state = state_path.read_bytes()
    for reserved in ('game.js', 'game.wasm'):
        artifact = (web / reserved).read_bytes()
        poisoned = json.loads(safe_state)
        poisoned['custom'].append(dict(path=reserved, digest=list(hashlib.sha256(artifact).hexdigest().encode())))
        state_path.write_text(json.dumps(poisoned))
        hook(fail='InvalidAssetProvenance')
        assert (web / reserved).read_bytes() == artifact
        assert (project / 'bundle/index.html').exists()
    state_path.write_bytes(safe_state)
    # Corrupt provenance must preserve an existing release even without web/.
    state_path = web / '.labelle-shell-state.json'
    saved_state = state_path.read_bytes()
    previous_release = (project / 'bundle/index.html').read_bytes()
    custom.rename(project / 'web-away')
    state_path.write_text('{')
    hook(fail='UnexpectedEndOfInput')
    assert (project / 'bundle/index.html').read_bytes() == previous_release
    state_path.write_bytes(saved_state)
    (project / 'web-away').rename(custom)
    # Oversized pages fail before clearing a previously published export.
    for page_path in (web / 'index.html', custom / 'index.html'):
        saved_page = page_path.read_bytes()
        page_path.write_bytes(b'x' * (16 * 1024 * 1024 + 1))
        hook(fail='StreamTooLong')
        assert (project / 'bundle/index.html').read_bytes() == previous_release
        page_path.write_bytes(saved_page)
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
        assert urllib.request.urlopen(f'http://127.0.0.1:{port}/__labelle_livereload', timeout=3).read() == b'ordinary project asset'
        if os.name != 'nt':
            assert urllib.request.urlopen(f'http://127.0.0.1:{port}/encoded%5Casset.txt', timeout=3).read() == b'POSIX asset'
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
        assert urllib.request.urlopen(f'http://127.0.0.1:{port}/config/.labelle-shell-state.json').read() == b'ordinary nested asset'
        assert urllib.request.urlopen(f'http://127.0.0.1:{port}/extra.js').read() == b'window.extra = true;'
    finally:
        if os.name == 'nt':
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], capture_output=True)
        else:
            os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=15)
        log.close()
    if os.name != 'nt':
        # Signal the provider itself: the CLI parent has its own signal policy.
        with socket.socket() as free_port:
            free_port.bind(('127.0.0.1', 0))
            port = free_port.getsockname()[1]
        serve_config = temp / 'serve-config.json'
        serve_config.write_text(json.dumps(dict(port=port, open_browser=False)))
        context.update(invocation=dict(kind='hook', id='serve', step='run', phase='replace'), output_dir=str(web.parent), config_file=str(serve_config))
        ctxfile.write_text(json.dumps(context))
        direct = subprocess.Popen([exe], cwd=project, env=dict(env, LABELLE_CONTEXT=str(ctxfile)), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    stalled = socket.create_connection(('127.0.0.1', port), timeout=1)
                    break
                except OSError:
                    assert direct.poll() is None and time.monotonic() < deadline
                    time.sleep(0.05)
            with stalled:
                stalled.sendall(b'GET / HTTP/1.1\r\nHost:')
                time.sleep(0.2)
                direct.terminate()
                stdout, stderr = direct.communicate(timeout=5)
                assert direct.returncode == 0, stderr
                assert stdout == b''
        finally:
            if direct.poll() is None:
                direct.kill()
                direct.wait()
    # Several generated backends cannot silently choose the wrong wasm.
    other = project / '.labelle/other_wasm/zig-out/web'
    other.mkdir(parents=True)
    (other / 'game.wasm').write_bytes(wasm)
    run('web', 'export', '--output=dist', fail='AmbiguousBuildOutput')
    run('web', 'export', f'--input={web}', '--output=dist')
    print('PASS: CLI discovery/export/serve, custom assets, hook staging/bundle, and destructive-path guards')
