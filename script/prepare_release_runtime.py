#!/usr/bin/env python3
"""Fetch the pinned public IINA runtime and its complete source materials.

No upstream build script is executed. Downloads are verified, existing files are
preserved, and no files are deleted. Large output belongs in .local/ or dist/.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "ThirdParty/iina-1.5.0/runtime-lock.json"


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def download(url: str, path: Path, expected: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if digest(path) != expected:
            raise RuntimeError(f"Cached file checksum mismatch; preserve/move it before retrying: {path}")
        return path
    partial = path.with_suffix(path.suffix + ".partial")
    subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location",
                    "--retry", "2", "--connect-timeout", "30", "--max-time", "300",
                    "--output", str(partial), url], check=True)
    if digest(partial) != expected:
        raise RuntimeError(f"Downloaded file checksum mismatch: {path.name}")
    partial.replace(path)
    return path


def notice_name(name: str) -> bool:
    return bool(re.match(r"^(licen[cs]e|copying|copyright|notice|authors|patents)([._-]|$)",
                         PurePosixPath(name).name, re.I))


def archive_notices(path: Path) -> list[tuple[str, bytes]]:
    with tarfile.open(path) as archive:
        return [(item.name, archive.extractfile(item).read()) for item in archive.getmembers()
                if item.isfile() and notice_name(item.name)]


def unpack_recipe(archive_path: Path, destination: Path) -> set[Path]:
    # Recipes contain only regular files/directories. Never follow archive links.
    files = set()
    with tarfile.open(archive_path) as archive:
        for item in archive.getmembers():
            relative = PurePosixPath(item.name)
            if relative.is_absolute() or ".." in relative.parts or len(relative.parts) < 2:
                continue
            target = destination.joinpath(*relative.parts[1:])
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif item.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                data = archive.extractfile(item).read()
                if target.exists() and target.read_bytes() != data:
                    raise RuntimeError(f"Modified recipe is preserved: {target}")
                target.write_bytes(data)
                target.chmod(item.mode & 0o777)
                files.add(target.relative_to(destination))
            else:
                raise RuntimeError(f"Unexpected recipe archive entry: {item.name}")
    return files


def git_source(component: dict, cache: Path) -> tuple[Path, list[dict]]:
    directory = cache / f"{component['name']}-{component['version']}"
    if not directory.exists():
        subprocess.run(["git", "-c", "advice.detachedHead=false", "clone", "--depth", "1",
                        "--branch", component["tag"], component["repository"], str(directory)], check=True)
    revision = subprocess.check_output(["git", "-C", str(directory), "rev-parse", "HEAD"], text=True).strip()
    if revision != component["commit"]:
        raise RuntimeError(f"Unexpected {component['name']} revision: {revision}")
    subprocess.run(["git", "-C", str(directory), "submodule", "update", "--init", "--recursive", "--depth", "1"], check=True)
    state = subprocess.check_output(["git", "-C", str(directory), "submodule", "status", "--recursive"], text=True)
    submodules = []
    for line in state.splitlines():
        if not line.startswith(" "):
            raise RuntimeError(f"Submodule does not match the pinned parent: {line}")
        sha, name = line.strip().split()[:2]
        submodules.append({"path": name, "commit": sha})
    dirty = subprocess.check_output(["git", "-C", str(directory), "status", "--porcelain", "--untracked-files=no"], text=True)
    if dirty.strip():
        raise RuntimeError(f"Source checkout has local changes: {component['name']}")
    return directory, submodules


def copy_git_sources(checkout: Path, destination: Path) -> list[Path]:
    # Copy only tracked source files, including the pinned submodules. Never
    # sweep a checkout for arbitrary ignored/untracked files or local secrets.
    names = subprocess.check_output(["git", "-C", str(checkout), "ls-files", "--recurse-submodules", "-z"])
    relative_files = [Path(name.decode()) for name in names.split(b"\0") if name]
    expected = set(relative_files)
    if destination.exists():
        unexpected = [path for path in destination.rglob("*") if path.is_file() and path.name != ".DS_Store"
                      and path.relative_to(destination) not in expected]
        if unexpected:
            raise RuntimeError(f"Unexpected files in source material; preserve/move the directory: {destination}")
    result = []
    for relative in relative_files:
        source = checkout / relative
        if not source.resolve().is_relative_to(checkout.resolve()):
            raise RuntimeError(f"Source symlink escapes checkout: {relative}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        # Internal source symlinks are materialized as the exact target bytes.
        shutil.copy2(source, target)
        result.append(source)
    return result


def validate_files(directory: Path, expected: set[Path], allow_missing: bool = False,
                   ignore_finder_metadata: bool = False) -> None:
    """Reject unknown files before packaging; Finder metadata is never included."""
    for relative in expected:
        target = directory / relative
        if allow_missing and not target.exists() and not target.is_symlink():
            continue
        if (relative.is_absolute() or ".." in relative.parts or target.is_symlink()
                or not target.is_file() or not target.resolve().is_relative_to(directory.resolve())):
            raise RuntimeError(f"Missing or unsafe material file: {relative}")
    for target in directory.rglob("*"):
        if ignore_finder_metadata and target.name == ".DS_Store":
            continue
        if target.is_symlink() or (not target.is_dir() and target.relative_to(directory) not in expected):
            raise RuntimeError(f"Unexpected material file is preserved: {target.relative_to(directory)}")


def source_notice_hashes(source_archive: Path) -> dict[Path, str]:
    """Read the notice whitelist from an already SHA-256-verified source archive."""
    result = {}
    prefix = PurePosixPath("iina-dependencies/notices")
    with tarfile.open(source_archive) as archive:
        for item in archive.getmembers():
            name = PurePosixPath(item.name)
            if not name.is_relative_to(prefix) or item.isdir():
                continue
            relative = name.relative_to(prefix)
            if not item.isfile() or ".." in relative.parts or Path(relative) in result:
                raise RuntimeError(f"Unsafe or duplicate source notice: {item.name}")
            result[Path(relative)] = hashlib.sha256(archive.extractfile(item).read()).hexdigest()
    if not result or Path("GPL-3.0.txt") not in result:
        raise RuntimeError("Corresponding source archive lacks the release notice set")
    return result


def validate_notices(directory: Path, expected: dict[Path, str], ignore_finder_metadata: bool = False) -> None:
    validate_files(directory, set(expected), ignore_finder_metadata=ignore_finder_metadata)
    for relative, expected_hash in expected.items():
        if digest(directory / relative) != expected_hash:
            raise RuntimeError(f"Notice differs from corresponding source: {relative}")


def write_archive(directory: Path, output: Path, files: set[Path]) -> None:
    # Validate before opening output so an injected file cannot replace an
    # existing verified archive. Only explicit entries are added, nonrecursively.
    validate_files(directory, files, ignore_finder_metadata=True)
    entries = set(files)
    for relative in files:
        entries.update(relative.parents)
    # Fixed metadata yields the same archive on the developer machine and CI.
    def metadata(item: tarfile.TarInfo) -> tarfile.TarInfo | None:
        if ".DS_Store" in PurePosixPath(item.name).parts or ".git" in PurePosixPath(item.name).parts:
            return None
        item.uid = item.gid = 0
        item.uname = item.gname = ""
        item.mtime = 0
        return item
    with output.open("wb") as stream, gzip.GzipFile(filename="", mode="wb", fileobj=stream, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for relative in sorted(entries):
                name = str(PurePosixPath("iina-dependencies") / relative)
                archive.add(directory / relative, arcname=name, recursive=False, filter=metadata)


def self_test(output: Path) -> None:
    """Exercise extra-file rejection without deleting the fixtures or old output."""
    checks = output / "script-checks"
    checks.mkdir(parents=True, exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix="whitelist-", dir=checks))
    for index, extra in enumerate(("private.txt", "recipes/sources/private.env", "notices/private.txt")):
        material = base / str(index) / "material"
        material.mkdir(parents=True)
        (material / "known.txt").write_text("verified public source\n")
        archive = material.parent / "existing-source.tar.gz"
        write_archive(material, archive, {Path("known.txt")})
        before = digest(archive)
        injected = material / extra
        injected.parent.mkdir(parents=True, exist_ok=True)
        injected.write_text("retain but reject\n")
        try:
            write_archive(material, archive, {Path("known.txt")})
        except RuntimeError as error:
            assert "Unexpected material file" in str(error)
        else:
            raise AssertionError(f"Accepted injected source file: {extra}")
        assert digest(archive) == before
        assert injected.read_text() == "retain but reject\n"
        with tarfile.open(archive) as saved:
            assert saved.getnames() == ["iina-dependencies", "iina-dependencies/known.txt"]
    for index, extra in enumerate(("private.txt", ".DS_Store")):
        notices = base / f"components-{index}"
        notices.mkdir()
        known = notices / "GPL-3.0.txt"
        known.write_text("license fixture\n")
        expected = {Path("GPL-3.0.txt"): digest(known)}
        validate_notices(notices, expected)
        (notices / extra).write_text("retain but reject\n")
        for check in (lambda: validate_files(notices, set(expected), allow_missing=True),
                      lambda: validate_notices(notices, expected)):
            try:
                check()
            except RuntimeError as error:
                assert "Unexpected material file" in str(error)
            else:
                raise AssertionError(f"Accepted injected app notice: {extra}")
        assert (notices / extra).read_text() == "retain but reject\n"
    print("PASS: source/app notice whitelists reject extra files and preserve existing archives/files.")
    print(f"Self-test fixtures retained at {base}")


def prepare(output: Path) -> None:
    lock = json.loads(LOCK.read_text())
    downloads = output / "downloads"
    recipe_archive = download(lock["recipeURL"], downloads / "recipes.tar.gz", lock["recipeSHA256"])
    runtime_archive = download(lock["runtimeURL"], downloads / "iina-deps-fat.zip", lock["runtimeSHA256"])
    runtime = output / "runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(runtime_archive) as archive:
        for item in archive.infolist():
            if PurePosixPath(item.filename).name != item.filename or not item.filename.endswith(".dylib"):
                raise RuntimeError(f"Unexpected runtime ZIP member: {item.filename}")
            target = runtime / item.filename
            data = archive.read(item)
            if target.exists() and target.read_bytes() != data:
                raise RuntimeError(f"Modified runtime file is preserved: {target}")
            target.write_bytes(data)
            target.chmod(0o755)
    if len(list(runtime.glob("*.dylib"))) != 44:
        raise RuntimeError("Expected exactly 44 libraries in the pinned runtime")

    material = output / "source-materials"
    recipes = material / "recipes"
    material_files = {Path("recipes") / relative for relative in unpack_recipe(recipe_archive, recipes)}
    sources = recipes / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    notices = output / "notices"
    notices.mkdir(parents=True, exist_ok=True)
    archives = [item for item in lock["components"] if "url" in item]
    material_files.update(Path("recipes/sources") / item["filename"] for item in archives)
    notice_files = set()
    failures = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        jobs = {pool.submit(download, item["url"], sources / item["filename"], item["sha256"]): item
                for item in archives}
        for job in as_completed(jobs):
            item = jobs[job]
            try:
                job.result()
                print(f"Verified {item['name']} {item['version']}", flush=True)
            except Exception as error:
                failures.append(f"{item['name']}: {error}")
    if failures:
        raise RuntimeError("Source acquisition incomplete:\n" + "\n".join(failures))

    inventory = []
    for component in lock["components"]:
        item = dict(component)
        if "url" in item:
            texts = archive_notices(sources / item["filename"])
        else:
            checkout, submodules = git_source(item, output / "git-sources")
            item["submodules"] = submodules
            destination = sources / checkout.name
            tracked_files = copy_git_sources(checkout, destination)
            material_files.update((destination / path.relative_to(checkout)).relative_to(material)
                                  for path in tracked_files)
            texts = [(str(path.relative_to(checkout)), path.read_bytes())
                     for path in sorted(tracked_files) if notice_name(path.name)]
        if not texts:
            raise RuntimeError(f"No license/copyright material found: {item['name']}")
        for name, data in texts:
            relative = PurePosixPath(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(f"Unsafe notice path: {name}")
            original = notices / "originals" / item["name"] / relative
            original.parent.mkdir(parents=True, exist_ok=True)
            original.write_bytes(data)
            notice_files.add(original.relative_to(notices))
        header = f"{item['name']} {item['version']}\nSource: {item.get('url', item.get('repository'))}\n"
        combined = header + "\n".join(f"\n--- {name} ---\n" + data.decode("utf-8", errors="replace") for name, data in texts)
        (notices / f"{item['name']}.txt").write_text(combined)
        notice_files.add(Path(f"{item['name']}.txt"))
        item["noticeFiles"] = [name for name, _ in texts]
        inventory.append(item)
    (material / "source-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    shutil.copy2(LOCK, material / "runtime-lock.json")
    shutil.copy2(LOCK, notices / "runtime-lock.json")
    readme = ROOT / "ThirdParty/iina-1.5.0/README.md"
    shutil.copy2(readme, material / "README.md")
    shutil.copy2(readme, notices / "README.md")
    shutil.copy2(ROOT / "Sources/CMPV/LICENSE.GPL", notices / "GPL-2.0.txt")
    with tarfile.open(sources / "ffmpeg-9.0.1.tar.xz") as archive:
        (notices / "GPL-3.0.txt").write_bytes(archive.extractfile("ffmpeg-9.0.1/COPYING.GPLv3").read())
    notice_files.update(map(Path, ("runtime-lock.json", "README.md", "GPL-2.0.txt", "GPL-3.0.txt")))
    validate_files(notices, notice_files, ignore_finder_metadata=True)
    for relative in notice_files:
        target = material / "notices" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(notices / relative, target)
    material_files.update(Path("notices") / relative for relative in notice_files)
    material_files.update(map(Path, ("source-inventory.json", "runtime-lock.json", "README.md")))
    source_archive = output / "iina-dependencies-source.tar.gz"
    write_archive(material, source_archive, material_files)
    provenance = {"source": "IINA official dependencies release", "recipeCommit": lock["recipeCommit"],
                  "upstreamRelease": lock["upstreamRelease"], "runtimeArchiveSHA256": lock["runtimeSHA256"],
                  "sourceArchiveSHA256": digest(source_archive),
                  "libraries": {path.name: digest(path) for path in sorted(runtime.glob("*.dylib"))}}
    (runtime / "muxi-runtime-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Runtime: {runtime}\nCorresponding source: {source_archive}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".local/release-materials")
    parser.add_argument("--self-test", action="store_true", help="Check whitelist rejection without network or builds")
    args = parser.parse_args()
    if args.self_test:
        self_test(args.output.resolve())
    else:
        prepare(args.output.resolve())
