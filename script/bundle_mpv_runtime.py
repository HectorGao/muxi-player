#!/usr/bin/env python3
"""Bundle the selected libmpv's dependency closure into a local macOS app.

Only public Mach-O libraries are read from the source installation. This tool
does not copy IINA preferences, plug-ins, databases, credentials or Swift runtime.
It never removes files. See docs/mpv-runtime.md before redistributing a bundle.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def runtime_directory(explicit: str | None) -> Path:
    configured = explicit if explicit is not None else os.environ.get("MUXI_MPV_LIB_DIR")
    candidates = [configured] if configured is not None else [
        "/Applications/IINA.app/Contents/Frameworks", "/opt/homebrew/lib", "/usr/local/lib"
    ]
    for directory in candidates:
        candidate = Path(directory).expanduser().absolute()
        if any((candidate / name).is_file() for name in ("libmpv.2.dylib", "libmpv.dylib")):
            return candidate
    raise RuntimeError("libmpv not found. Set MUXI_MPV_LIB_DIR to its library directory; see docs/mpv-runtime.md.")


def dylib_references(path: Path) -> list[str]:
    # otool prints one section per architecture. Keep the dependency union.
    references = []
    for line in run("/usr/bin/otool", "-L", str(path)).splitlines():
        if line.startswith("\t"):
            reference = line.strip().split(" (", 1)[0]
            if reference not in references:
                references.append(reference)
    return references


def install_ids(path: Path) -> list[str]:
    return [line.strip() for line in run("/usr/bin/otool", "-D", str(path)).splitlines()
            if line.strip() and not line.endswith(":")]


def is_system(reference: str) -> bool:
    return (reference.startswith(("/System/Library/", "/usr/lib/"))
            or Path(reference).name.startswith("libswift"))


@dataclass
class Library:
    source: Path
    filename: str
    original_id: str
    dependencies: dict[str, str]


def collect_libraries(directory: Path) -> tuple[list[Library], str]:
    root_library = next(directory / name for name in ("libmpv.2.dylib", "libmpv.dylib")
                        if (directory / name).is_file())
    by_source: dict[Path, Library] = {}
    by_filename: dict[str, Path] = {}

    def visit(path: Path) -> Library:
        source = path.resolve(strict=True)
        if source in by_source:
            return by_source[source]
        identities = list(dict.fromkeys(install_ids(source)))
        if len(identities) != 1:
            raise RuntimeError(f"Expected one install name shared by all architectures: {source}")
        identity = identities[0]
        filename = Path(identity).name
        if not filename.endswith(".dylib") or filename.startswith("libswift"):
            raise RuntimeError(f"Unsupported non-system dependency: {source}")
        if filename in by_filename and by_filename[filename] != source:
            raise RuntimeError(f"Two different libraries share the install name {filename}")
        library = Library(source, filename, identity, {})
        by_source[source] = library
        by_filename[filename] = source
        for reference in dylib_references(source):
            if reference in identities or is_system(reference):
                continue
            if reference.startswith("@rpath/"):
                relative = reference[len("@rpath/"):]
                candidates = [source.parent / relative, directory / relative]
                dependency = next((item for item in candidates if item.is_file()), None)
                if dependency is None:
                    raise RuntimeError(f"Cannot resolve {reference} required by {source}")
            elif reference.startswith("@loader_path/"):
                dependency = source.parent / reference[len("@loader_path/"):]
            elif reference.startswith("/"):
                dependency = Path(reference)
            else:
                raise RuntimeError(f"Cannot resolve {reference} required by {source}")
            library.dependencies[reference] = visit(dependency).filename
        return library

    main_library = visit(root_library)
    return sorted(by_source.values(), key=lambda item: item.filename), main_library.filename


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_description(directory: Path) -> dict:
    provenance = directory / "muxi-runtime-provenance.json"
    if provenance.is_file():
        info = json.loads(provenance.read_text())
        return {"kind": info["source"], "recipeCommit": info["recipeCommit"],
                "url": info["upstreamRelease"], "runtimeArchiveSHA256": info["runtimeArchiveSHA256"],
                "sourceArchiveSHA256": info["sourceArchiveSHA256"]}
    iina_bundle = directory.parent.parent
    if iina_bundle.name == "IINA.app":
        info = iina_bundle / "Contents" / "Info.plist"
        with info.open("rb") as stream:
            version = plistlib.load(stream)
        return {"kind": "installed IINA", "version": version.get("CFBundleShortVersionString"),
                "build": version.get("CFBundleVersion"), "url": "https://github.com/iina/iina"}
    return {"kind": "local libmpv installation", "url": "https://github.com/mpv-player/mpv"}


def bundle(app_bundle: Path, directory: Path, libraries: list[Library], main_filename: str) -> None:
    executable = app_bundle / "Contents" / "MacOS" / "MuxiPlayer"
    if not executable.is_file():
        raise RuntimeError(f"Build the app executable first: {executable}")
    provenance = directory / "muxi-runtime-provenance.json"
    if provenance.is_file():
        proof = json.loads(provenance.read_text())
        expected = proof["libraries"]
        actual = {library.filename: sha256(library.source) for library in libraries}
        if actual != expected:
            raise RuntimeError("Release runtime differs from the verified corresponding-source inventory")
        source_archive = directory.parent / "iina-dependencies-source.tar.gz"
        if not source_archive.is_file() or sha256(source_archive) != proof["sourceArchiveSHA256"]:
            raise RuntimeError("Matching dependency source archive is missing or changed")
    frameworks = app_bundle / "Contents" / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    filenames = {library.filename for library in libraries}
    unexpected = [path.name for path in frameworks.iterdir()
                  if path.name.endswith(".dylib") and path.name not in filenames]
    if unexpected:
        raise RuntimeError("Existing Frameworks contains unrelated libraries; preserve/move the old app bundle before rebuilding: "
                           + ", ".join(sorted(unexpected)))
    for library in libraries:
        target = frameworks / library.filename
        shutil.copy2(library.source, target)
        # Source packages can be read-only (e.g. Homebrew); change only our copy.
        target.chmod(target.stat().st_mode | 0o200)
        changes = ["/usr/bin/install_name_tool", "-id", "@rpath/" + library.filename]
        for old, filename in library.dependencies.items():
            changes.extend(["-change", old, "@loader_path/" + filename])
        run(*changes, str(target))
        run("/usr/bin/codesign", "--force", "--sign", "-", str(target))
        run("/usr/bin/codesign", "--verify", "--strict", str(target))
    main_references = [reference for reference in dylib_references(executable)
                       if Path(reference).name.startswith("libmpv")]
    if not main_references:
        raise RuntimeError("MuxiPlayer is not linked to libmpv")
    for old in main_references:
        new = "@rpath/" + main_filename
        if old != new:
            run("/usr/bin/install_name_tool", "-change", old, new, str(executable))
    # Distribution must not silently depend on the development installation.
    commands = run("/usr/bin/otool", "-l", str(executable))
    # SwiftPM also injects absolute build-product and toolchain directories.
    # Every non-system library needed by this executable is bundled above.
    # Keep only relative app paths and the operating system's Swift directory.
    rpaths = []
    next_path_is_rpath = False
    for line in commands.splitlines():
        if line.strip() == "cmd LC_RPATH":
            next_path_is_rpath = True
        elif next_path_is_rpath and line.strip().startswith("path "):
            path = line.strip()[len("path "):].split(" (offset", 1)[0]
            if path not in rpaths:
                rpaths.append(path)
            next_path_is_rpath = False
    for path in rpaths:
        if path.startswith("/") and not path.startswith(("/usr/lib/", "/System/Library/")):
            run("/usr/bin/install_name_tool", "-delete_rpath", path, str(executable))
    if "path @executable_path/../Frameworks (" not in commands:
        run("/usr/bin/install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable))
    for library in libraries:
        target = frameworks / library.filename
        for reference in dylib_references(target):
            if is_system(reference) or reference == "@rpath/" + library.filename:
                continue
            if not reference.startswith("@loader_path/") or not (frameworks / Path(reference).name).is_file():
                raise RuntimeError(f"Bundled dependency is not self-contained: {reference}")
    notices = app_bundle / "Contents" / "Resources" / "ThirdParty" / "mpv"
    notices.mkdir(parents=True, exist_ok=True)
    project_root = Path(__file__).resolve().parent.parent
    for filename in ("LICENSE.GPL", "LICENSE.LGPL", "VENDORED.md"):
        shutil.copy2(project_root / "Sources" / "CMPV" / filename, notices / filename)
    shutil.copy2(project_root / "docs" / "mpv-runtime.md", notices / "mpv-runtime.md")
    if provenance.is_file():
        shutil.copytree(directory.parent / "notices", notices / "components", dirs_exist_ok=True)
        shutil.copy2(provenance, notices / "runtime-provenance.json")
    metadata = {
        "purpose": ("pinned release runtime; matching dependency source archive required alongside binary"
                    if provenance.is_file() else "local development bundle; distribution compliance review required"),
        "source": source_description(directory), "apiHeadersVersion": "0.41.0",
        "libraries": [{"name": library.filename, "sourceSHA256": sha256(library.source),
                       "bundledSHA256": sha256(frameworks / library.filename),
                       "dependencies": sorted(set(library.dependencies.values()))}
                      for library in libraries]
    }
    (notices / "runtime-manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Bundled and signed {len(libraries)} libmpv libraries into {frameworks}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lib-dir", help="Override MUXI_MPV_LIB_DIR")
    parser.add_argument("--print-lib-dir", action="store_true", help="Print the selected development runtime directory")
    parser.add_argument("--inspect-only", action="store_true", help="Print dependency names without copying or modifying anything")
    parser.add_argument("--app-bundle", type=Path)
    args = parser.parse_args()
    directory = runtime_directory(args.lib_dir)
    if args.print_lib_dir:
        print(directory)
        return
    libraries, main_filename = collect_libraries(directory)
    if args.inspect_only:
        print(json.dumps({"source": source_description(directory), "libraryCount": len(libraries),
                          "libraries": [library.filename for library in libraries]}, indent=2))
        return
    if args.app_bundle is None:
        parser.error("--app-bundle is required unless --print-lib-dir or --inspect-only is used")
    bundle(args.app_bundle.absolute(), directory, libraries, main_filename)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"mpv runtime: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.output, file=sys.stderr)
        sys.exit(1)
