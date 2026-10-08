#!/usr/bin/env python3
"""Remux MP4/MOV episode files so the index (moov) sits at the start.

Jellyfin Direct Play over the web needs that index up front. Pass the show or
season folder; video files underneath are found recursively.

Requires ffmpeg on PATH.

Usage:
  python3 remux-faststart.py "/path/to/Love Island - Beyond the Villa"
  python3 remux-faststart.py --dry-run "/path/to/Season 1"
"""

from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
from pathlib import Path

VIDEO_SUFFIXES = {".mp4", ".m4v", ".mov"}
TMP_SUFFIX = ".faststart.tmp"
MIN_SIZE_RATIO = 0.90


def iter_top_level_boxes(path: Path):
    size = path.stat().st_size
    with path.open("rb") as fh:
        pos = 0
        while pos + 8 <= size:
            fh.seek(pos)
            header = fh.read(8)
            if len(header) < 8:
                break
            box_size, box_type = struct.unpack(">I4s", header)
            try:
                kind = box_type.decode("ascii")
            except UnicodeDecodeError:
                kind = box_type.decode("latin1")
            header_len = 8
            if box_size == 1:
                extra = fh.read(8)
                if len(extra) < 8:
                    break
                box_size = struct.unpack(">Q", extra)[0]
                header_len = 16
            elif box_size == 0:
                box_size = size - pos
            if box_size < header_len:
                break
            yield kind, pos, box_size
            pos += box_size


def is_faststart(path: Path) -> bool:
    moov_at = None
    mdat_at = None
    for kind, offset, _size in iter_top_level_boxes(path):
        if kind == "moov" and moov_at is None:
            moov_at = offset
        elif kind == "mdat" and mdat_at is None:
            mdat_at = offset
        if moov_at is not None and mdat_at is not None:
            break
    return moov_at is not None and (mdat_at is None or moov_at < mdat_at)


def find_videos(root: Path) -> list[Path]:
    files = [
        path
        for path in root.rglob("*")
        if path.is_file()
        and path.suffix.lower() in VIDEO_SUFFIXES
        and not path.name.endswith(TMP_SUFFIX)
    ]
    return sorted(files)


def remux(src: Path, ffmpeg: str) -> None:
    tmp = src.with_name(src.name + TMP_SUFFIX)
    if tmp.exists():
        tmp.unlink()
    cmd = [
        ffmpeg,
        "-nostdin",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(src),
        "-map",
        "0",
        "-c",
        "copy",
        "-movflags",
        "+faststart",
        str(tmp),
    ]
    try:
        subprocess.run(cmd, check=True)
        orig_size = src.stat().st_size
        new_size = tmp.stat().st_size
        if new_size < orig_size * MIN_SIZE_RATIO:
            raise RuntimeError(
                f"remux output too small ({new_size} bytes vs {orig_size} original)"
            )
        if not is_faststart(tmp):
            raise RuntimeError("remux output still has moov after mdat")
        tmp.replace(src)
    except Exception:
        if tmp.exists():
            tmp.unlink()
        raise


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Remux episode MP4/MOV files in a folder for Jellyfin Direct Play (faststart)."
    )
    parser.add_argument(
        "folder",
        type=Path,
        help="Root folder that contains the episodes (show or season directory)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List what would be remuxed without writing files",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Remux even when the file already has faststart",
    )
    args = parser.parse_args()

    root = args.folder.expanduser().resolve()
    if not root.is_dir():
        print(f"Not a directory: {root}", file=sys.stderr)
        return 2

    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg and not args.dry_run:
        print("ffmpeg not found on PATH", file=sys.stderr)
        return 2

    videos = find_videos(root)
    if not videos:
        print(f"No MP4/MOV files under {root}")
        return 1

    remuxed = skipped = failed = 0
    for path in videos:
        rel = path.relative_to(root)
        try:
            already = is_faststart(path)
        except OSError as exc:
            print(f"FAIL  {rel}: {exc}", file=sys.stderr)
            failed += 1
            continue

        if already and not args.force:
            print(f"SKIP  {rel} (already faststart)")
            skipped += 1
            continue

        if args.dry_run:
            print(f"WOULD {rel}")
            remuxed += 1
            continue

        print(f"REMUX {rel} ...", flush=True)
        try:
            remux(path, ffmpeg)
        except subprocess.CalledProcessError as exc:
            print(f"FAIL  {rel}: ffmpeg exited {exc.returncode}", file=sys.stderr)
            failed += 1
            continue
        except Exception as exc:
            print(f"FAIL  {rel}: {exc}", file=sys.stderr)
            failed += 1
            continue
        print(f"OK    {rel}")
        remuxed += 1

    print(f"\nDone. remuxed={remuxed} skipped={skipped} failed={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        sys.exit(130)
