"""A fresh `labelle init` project built for wasm from zero (RFC labelle-cli#466 §8, PR W).

python tests/provider/wasm_from_zero.py --cli /path/to/labelle --work /scratch/dir --mode managed
python tests/provider/wasm_from_zero.py --cli /path/to/labelle --work /scratch/dir --mode passthrough

`managed`: a clean HOME and LABELLE_HOME under `--work`, EMSDK unset and every
emcc scrubbed from PATH. `labelle init` (the CLI under test, v2.1.0), add
this checkout as a `local:` provider, `labelle build --platform=wasm`: the
web provider must fetch, verify and activate emsdk into its cache_dir, and the
build must produce a real `zig-out/web/game.wasm` and a stamped `index.html`.

`passthrough` (after `managed`, same `--work`): the managed install is moved
out of the cache and set as an external EMSDK; the rebuild must use it as is,
with no install. Real network and a real emscripten; no fakes.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True)
parser.add_argument("--work", required=True)
parser.add_argument("--mode", choices=("managed", "passthrough"), required=True)
options = parser.parse_args()
windows = os.name == "nt"
cli = Path(options.cli)
if windows and cli.suffix != ".exe":
    cli = cli.with_suffix(".exe")
cli = str(cli.resolve())
repo = Path(__file__).resolve().parents[2]
work = Path(options.work).resolve()
home = work / "h"
labelle_home = home / ".labelle"
project = work / "game"
emcc = "emcc.bat" if windows else "emcc"

# A controlled environment: nothing inherited can provide the toolchain.
path = [p for p in os.environ.get("PATH", "").split(os.pathsep) if p and not (Path(p) / emcc).exists()]
env = dict(os.environ, HOME=str(home), USERPROFILE=str(home), LABELLE_HOME=str(labelle_home), PATH=os.pathsep.join(path))
for name in ("EMSDK", "EM_CONFIG", "EMSDK_NODE", "EMSDK_PYTHON", "LABELLE_EMSDK", "LABELLE_ZIG", "LABELLE_ASSEMBLER", "LABELLE_OFFLINE"):
    env.pop(name, None)
assert shutil.which(emcc, path=env["PATH"]) is None, "an emcc is still on PATH"


def labelle(*args, cwd, extra=None):
    """Run the CLI, echoing its output, and return (status, stdout, stderr)."""
    print("$ labelle " + " ".join(args), flush=True)
    result = subprocess.run([cli, *args], cwd=cwd, env=dict(env, **(extra or {})), text=True, capture_output=True, timeout=5400)
    sys.stdout.write(result.stdout[-20000:])
    sys.stdout.write(result.stderr[-60000:])
    sys.stdout.flush()
    return result


def managed_installs():
    return sorted(labelle_home.glob("providers/*/*/emsdk/v1/*/4.0.9-3bcf1dcd01f0"))


def check_output():
    targets = list((project / ".labelle").glob("*_wasm"))
    assert len(targets) == 1, targets
    web = targets[0] / "zig-out" / "web"
    wasm = (web / "game.wasm").read_bytes()
    assert wasm[:4] == b"\0asm", "zig-out/web/game.wasm is not a wasm module"
    page = (web / "index.html").read_text(encoding="utf-8")
    assert f'data-wasm-bytes="{len(wasm)}"' in page, "index.html is not stamped with the wasm size"
    print(f"ok: {web / 'game.wasm'} ({len(wasm)} bytes), index.html stamped", flush=True)


if options.mode == "managed":
    shutil.rmtree(work, ignore_errors=True)
    home.mkdir(parents=True)
    result = labelle("init", "game", cwd=work)
    assert result.returncode == 0, "labelle init failed"
    config = project / "project.labelle"
    text = config.read_text(encoding="utf-8")
    dep = '.{ .name = "web", .repo = "local:%s", .version = "0.3.2" }' % repo.as_posix()
    text, count = re.subn(r"\.plugins\s*=\s*\.\{", ".plugins = .{ " + dep + ",", text, count=1)
    assert count == 1, "project.labelle has no .plugins list"
    config.write_text(text, encoding="utf-8")

    result = labelle("build", "--platform=wasm", cwd=project)
    assert result.returncode == 0, f"labelle build --platform=wasm failed ({result.returncode})"
    log = result.stdout + result.stderr
    assert "emsdk from managed install" in log, "the provider did not use its managed install"
    assert "installing emsdk 4.0.9" in log, "the provider did not provision emsdk"
    installs = managed_installs()
    assert len(installs) == 1, installs
    assert (installs[0] / ".labelle-web-install").is_file()
    assert (installs[0] / "upstream" / "emscripten" / emcc).is_file()
    check_output()

    result = labelle("web", "doctor", "--json", cwd=project)
    assert result.returncode == 0, "labelle web doctor failed"
    cap = json.loads(result.stdout)
    assert cap["id"] == "wasm" and cap["ok"], cap
    assert str(installs[0]) in cap["items"][1]["detail"], cap
else:
    installs = managed_installs()
    assert len(installs) == 1, "run --mode managed first"
    external = work / "external-emsdk"
    shutil.rmtree(external, ignore_errors=True)
    shutil.move(str(installs[0]), str(external))
    assert not managed_installs()
    result = labelle("build", "--platform=wasm", cwd=project, extra={"EMSDK": str(external)})
    assert result.returncode == 0, f"labelle build --platform=wasm failed ({result.returncode})"
    log = result.stdout + result.stderr
    assert f"emsdk from inherited EMSDK: {external}" in log, "the external EMSDK was not passed through"
    assert "installing emsdk" not in log, "the provider downloaded despite an external EMSDK"
    assert not managed_installs(), "a managed install appeared despite an external EMSDK"
    check_output()
print(f"PASS: wasm from zero ({options.mode})")
