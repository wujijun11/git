"""Download a pinned, workspace-local Android build toolchain; no global install."""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
from pathlib import Path, PurePosixPath
import urllib.request
import time
import zipfile


PACKAGES = (
    ("gradle-8.9-bin.zip", "https://downloads.gradle.org/distributions/gradle-8.9-bin.zip",
     "sha256", "d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab",
     "gradle-8.9", ".", "gradle-8.9/bin/gradle.bat"),
    ("platform-35_r02.zip", "https://dl.google.com/android/repository/platform-35_r02.zip",
     "sha1", "0bb560a90a7a2cbd0dd8348224d518b638fe7949",
     "android-35", "sdk/platforms/android-35", "sdk/platforms/android-35/android.jar"),
    ("build-tools_r35_windows.zip", "https://dl.google.com/android/repository/build-tools_r35_windows.zip",
     "sha1", "af059bb67cf7786f45ee0db85e2d24985df1b4b6",
     "android-15", "sdk/build-tools/35.0.0", "sdk/build-tools/35.0.0/aapt2.exe"),
)


def digest(path: Path, algorithm: str) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


def install(root: Path, spec: tuple[str, ...]) -> None:
    name, url, algorithm, checksum, prefix, destination, marker = spec
    if (root / marker).exists():
        print("Available: " + marker, flush=True)
        return
    archive = root / name
    if not archive.exists() or digest(archive, algorithm) != checksum:
        partial = archive.with_suffix(".part")
        print("Downloading " + name, flush=True)
        for attempt in range(3):
            try:
                download_url = url.replace("//dl.google.com/", "//dl-ssl.google.com/") if attempt == 1 else url
                with urllib.request.urlopen(download_url, timeout=25) as response, partial.open("wb") as output:
                    while block := response.read(1024 * 1024):
                        output.write(block)
                break
            except OSError:
                if attempt == 2:
                    raise
                time.sleep(attempt + 1)
        if digest(partial, algorithm) != checksum:
            raise RuntimeError("Official archive checksum mismatch: " + name)
        partial.replace(archive)
    destination_path = (root / destination).resolve()
    with zipfile.ZipFile(archive) as source:
        for entry in source.infolist():
            parts = PurePosixPath(entry.filename).parts
            if not parts or parts[0] != prefix or ".." in parts or entry.is_dir():
                continue
            # Gradle retains its versioned directory; SDK packages lose the ZIP prefix.
            relative = Path(*parts) if destination == "." else Path(*parts[1:])
            target = (destination_path / relative).resolve()
            if not target.is_relative_to(root):
                raise RuntimeError("Archive path escapes tool directory")
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(entry) as inp, target.open("wb") as out:
                while block := inp.read(1024 * 1024):
                    out.write(block)
    if not (root / marker).exists():
        raise RuntimeError("Archive layout changed: " + name)
    print("Verified and extracted " + name, flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool-root", required=True, type=Path)
    args = parser.parse_args()
    root = args.tool_root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        list(executor.map(lambda package: install(root, package), PACKAGES))


if __name__ == "__main__":
    main()
