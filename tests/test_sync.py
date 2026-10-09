"""Run with python3 tests/test_sync.py; executes the workflow's actual shell blocks."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap


workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/sync.yml").read_text()


def step(name):
    block = workflow.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]
    return textwrap.dedent(block.split("        run: |\n", 1)[1])


for name in ("Resolve release", "Download official assets", "Prepare artifacts", "Store distribution branch"):
    subprocess.run(["bash", "-n", "-c", step(name)], check=True)

with tempfile.TemporaryDirectory(prefix="pi sync test ") as temporary:
    root = Path(temporary)
    filename = "pi-windows-x64.zip"
    prepare = step("Prepare artifacts")
    for size in (37, 50_000_000, 50_000_001, 75_000_000):
        case = root / str(size)
        download = case / "download"
        download.mkdir(parents=True)
        source = download / filename
        with source.open("wb") as stream:
            stream.write(b"start")
            stream.seek(size - 3)
            stream.write(b"end")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        checksum = f"{digest.upper()} *{filename}\n"
        (download / "SHA256SUMS").write_text(checksum)
        release = {
            "tag_name": "v1.1.0",
            "html_url": "https://github.com/earendil-works/pi/releases/tag/v1.1.0",
            "assets": [{
                "name": filename, "size": size,
                "browser_download_url": "https://github.com/earendil-works/pi/releases/download/v1.1.0/" + filename,
            }],
        }
        (case / "release.json").write_text(json.dumps(release))
        env = {**os.environ, "SYNC_DIR": str(case)}
        subprocess.run(["bash", "-e", "-c", prepare], env=env, check=True)
        distribution = case / "distribution"
        manifest = json.loads((distribution / "manifest.json").read_text())
        count = 1 if size <= 50_000_000 else size // 25_000_000 + 1
        names = [filename] if count == 1 else [f"{filename}.{i:03d}" for i in range(1, count + 1)]
        assert manifest == {
            "format_version": 1, "version": "1.1.0", "upstream_tag": "v1.1.0",
            "platform": "windows-x64", "release_url": release["html_url"],
            "asset_url": release["assets"][0]["browser_download_url"],
            "zip": {"filename": filename, "size_bytes": size, "sha256": digest},
            "artifacts": names,
        }
        assert sorted(p.name for p in distribution.iterdir()) == sorted(["manifest.json", *names])
        parts = [(distribution / name).read_bytes() for name in names]
        assert b"".join(parts) == source.read_bytes()
        if count > 1:
            assert max(map(len, parts)) <= 25_000_000
            assert max(map(len, parts)) - min(map(len, parts)) <= 1

        shutil.rmtree(distribution)
        for bad_checksum in ("", checksum * 2, "x" * 64 + "  " + filename, "0" * 64 + "  " + filename):
            (download / "SHA256SUMS").write_text(bad_checksum)
            result = subprocess.run(["bash", "-e", "-c", prepare], env=env, capture_output=True)
            assert result.returncode != 0
            assert not distribution.exists()
        (download / "SHA256SUMS").write_text(checksum)
        release["assets"][0]["size"] += 1
        (case / "release.json").write_text(json.dumps(release))
        assert subprocess.run(["bash", "-e", "-c", prepare], env=env, capture_output=True).returncode != 0
        assert not distribution.exists()
        source.unlink()
        assert subprocess.run(["bash", "-e", "-c", prepare], env=env, capture_output=True).returncode != 0
        assert not distribution.exists()

    # Verify the real storage step creates only a root commit and refuses replacement.
    remote = root / "remote.git"
    subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
    branch = "dist/windows-x64/v1.1.0"
    for attempt in (1, 2):
        case = root / f"store {attempt}"
        distribution = case / "distribution"
        distribution.mkdir(parents=True)
        (distribution / "manifest.json").write_text(json.dumps({"attempt": attempt}))
        (distribution / filename).write_bytes(b"artifact")
        env = {**os.environ, "SYNC_DIR": str(case), "BRANCH": branch,
               "REPOSITORY_URL": str(remote), "GITHUB_STEP_SUMMARY": str(root / "summary")}
        result = subprocess.run(["bash", "-e", "-c", step("Store distribution branch")], env=env, capture_output=True)
        assert (result.returncode == 0) == (attempt == 1), result.stderr.decode()
    git = ["git", "--git-dir", str(remote)]
    assert subprocess.check_output([*git, "rev-list", "--count", branch]).strip() == b"1"
    assert subprocess.check_output([*git, "ls-tree", "--name-only", branch]).decode().splitlines() == ["manifest.json", filename]
    assert json.loads(subprocess.check_output([*git, "show", f"{branch}:manifest.json"])) == {"attempt": 1}

print("Sync checks passed: size boundaries, ordered byte-preserving splits, invalid assets, immutable orphan branch.")
