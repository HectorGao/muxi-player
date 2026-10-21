#!/usr/bin/env python3
"""Package a verified app and matching sources; never publish or overwrite a release."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, cwd=ROOT).strip()


def package(app: Path, materials: Path, output: Path, version: str) -> None:
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise RuntimeError("Invalid release version")
    if output.exists() and any(output.iterdir()):
        raise RuntimeError("Release output is not empty; existing release files are preserved")
    commit = run("git", "rev-parse", "HEAD")
    if run("git", "status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError("Commit the reviewed release sources before packaging")
    relevant = ("Sources/", "Tests/", "script/", "docs/", "ThirdParty/", ".github/",
                "Package.swift", "README.md", "LICENSE")
    if any(path.startswith(relevant) for path in run("git", "ls-files", "--others", "--exclude-standard").splitlines()):
        raise RuntimeError("Untracked release source files must be reviewed and committed first")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("MuxiReleaseVersion") != version:
        raise RuntimeError("App version differs from requested release version")
    if info.get("MuxiBuildCommit") != commit:
        raise RuntimeError("Rebuild the app from the final release commit before packaging")
    executable = app / "Contents/MacOS/MuxiPlayer"
    architectures = run("lipo", "-archs", str(executable)).split()
    if architectures != ["arm64"]:
        raise RuntimeError("This release pipeline currently validates Apple Silicon (arm64) only")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    runtime_root = app / "Contents/Resources/ThirdParty/mpv"
    manifest = json.loads((runtime_root / "runtime-manifest.json").read_text())
    provenance = json.loads((runtime_root / "runtime-provenance.json").read_text())
    lock = json.loads((ROOT / "ThirdParty/iina-1.5.0/runtime-lock.json").read_text())
    if (provenance["runtimeArchiveSHA256"] != lock["runtimeSHA256"]
            or provenance["recipeCommit"] != lock["recipeCommit"]):
        raise RuntimeError("App runtime does not match the pinned release recipe")
    if {item["name"]: item["sourceSHA256"] for item in manifest["libraries"]} != provenance["libraries"]:
        raise RuntimeError("App source-library hashes differ from the official runtime")
    for item in manifest["libraries"]:
        if sha256(app / "Contents/Frameworks" / item["name"]) != item["bundledSHA256"]:
            raise RuntimeError(f"Bundled library changed: {item['name']}")
    dependency_source = materials / "iina-dependencies-source.tar.gz"
    if sha256(dependency_source) != provenance["sourceArchiveSHA256"]:
        raise RuntimeError("Dependency source archive does not match the tested app")
    if not (runtime_root / "components/GPL-3.0.txt").is_file():
        raise RuntimeError("Combined binary license and component notices are missing")
    output.mkdir(parents=True, exist_ok=True)
    prefix = f"MuxiPlayer-{version}"
    app_zip = output / f"{prefix}-macOS-arm64.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(app_zip))
    source_tar = output / f"{prefix}-source.tar.gz"
    # Export only committed repository contents. No .local/, .git/, credentials,
    # source download caches or runtime binaries are copied from the workspace.
    with source_tar.open("wb") as target, gzip.GzipFile(filename="", fileobj=target, mode="wb", mtime=0) as compressed:
        process = subprocess.Popen(["git", "archive", "--format=tar", f"--prefix={prefix}/", commit],
                                   cwd=ROOT, stdout=subprocess.PIPE)
        shutil.copyfileobj(process.stdout, compressed)
        if process.wait() != 0:
            raise RuntimeError("git archive failed")
    dependency_tar = output / f"{prefix}-dependencies-source.tar.gz"
    shutil.copy2(dependency_source, dependency_tar)
    release_info = {"version": version, "buildNumber": info["CFBundleVersion"], "sourceCommit": commit,
                    "architectures": architectures, "minimumMacOS": info["LSMinimumSystemVersion"],
                    "signature": "ad-hoc", "notarized": False, "binaryLicense": "GPL-3.0-or-later",
                    "runtime": provenance, "assets": [app_zip.name, source_tar.name, dependency_tar.name]}
    (output / "release-manifest.json").write_text(json.dumps(release_info, indent=2) + "\n")
    files = sorted(path for path in output.iterdir() if path.is_file())
    (output / "SHA256SUMS").write_text("".join(f"{sha256(path)}  {path.name}\n" for path in files))
    print(f"Prepared {output}. Upload all five files together; app signing is ad-hoc, not notarized.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--app-bundle", type=Path, required=True)
    parser.add_argument("--materials", type=Path, default=ROOT / ".local/release-materials")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.app_bundle.resolve(), args.materials.resolve(), args.output.resolve(), args.version)
