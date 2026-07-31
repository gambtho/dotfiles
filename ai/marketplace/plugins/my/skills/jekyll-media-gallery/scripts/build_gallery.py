#!/usr/bin/env python3
"""Build web-optimized gallery derivatives + a manifest from a folder of media.

Site-agnostic: point it at any folder of photos/videos and a Jekyll (or other
static-site) assets directory. It writes small thumbnails and a bounded
full-size derivative for each item, transcodes videos to web-friendly mp4 with a
poster frame, and emits a date-grouped YAML manifest the gallery page renders
from.

Why this exists: GitHub Pages (and most static hosts) cannot process images at
build time and will not serve Git LFS content — it serves LFS pointer stubs
instead. So all optimization must happen locally and the ready-to-serve
derivatives get committed. Originals are read-only inputs and are never modified
or copied.

Date handling (how items are grouped):
  Media metadata is often stripped by messaging apps and exports, so we try
  several sources in order and use the first that works:
    1. EXIF/QuickTime capture date via `exiftool`, if installed.
    2. A timestamp embedded in the filename (several common patterns).
    3. File modification time (last resort — often just the download date).
  Pass --date-source to force one. Grouping is by local calendar date
  (YYYY-MM-DD). Pass --start-date YYYY-MM-DD to also emit a `day_number`
  (1-based day index from that date) for trip/event sites.

Resilience: real-world media sets contain truncated/corrupt files. Truncated
images are recovered where possible (Pillow lenient load); anything genuinely
unprocessable is skipped with a warning and excluded from the manifest, so one
bad file never aborts the whole run.

Requires: Pillow. pillow-heif required only if the source contains HEIC/HEIF.
ffmpeg + ffprobe required only if the source contains videos.
exiftool is optional (enables the most accurate date source).

Usage:
  python3 build_gallery.py --source PATH --assets PATH [--data-file PATH]
                           [--start-date YYYY-MM-DD] [--date-source auto|exif|filename|mtime]
                           [--thumb-max 400] [--full-max 1600] [--video-max-h 720]
                           [--force] [--regen-manifest]
"""
import argparse
import datetime as _dt
import json
import os
import re
import shutil
import subprocess
import sys

from PIL import Image, ImageFile, ImageOps

# HEIC/HEIF (the iPhone default) needs the pillow-heif plugin; vanilla Pillow
# cannot decode it. Register when available and track it so we can fail loudly
# with an actionable message instead of silently skipping every HEIC input.
try:
    from pillow_heif import register_heif_opener
except ImportError:
    _HEIF_AVAILABLE = False
else:
    register_heif_opener()
    _HEIF_AVAILABLE = True

# Recover truncated/incomplete images instead of crashing on them.
ImageFile.LOAD_TRUNCATED_IMAGES = True

PHOTO_EXT = {"jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif"}
HEIF_EXT = {"heic", "heif"}
VIDEO_EXT = {"mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp"}

# Filename timestamp patterns → named groups y/m/d. Ordered most-specific first.
# Covers the common phone/export conventions.
_FILENAME_DATE_PATTERNS = [
    # 2026-07-18_182634, 2026-07-18 18.26.34, 2026-07-18T182634
    re.compile(r"(?P<y>\d{4})[-_.](?P<m>\d{2})[-_.](?P<d>\d{2})[ _T]"),
    # 20260718_182634  /  IMG_20260718_...  /  VID_20260718...
    re.compile(r"(?P<y>\d{4})(?P<m>\d{2})(?P<d>\d{2})[_-]\d"),
    # PXL_20260718..., Screenshot_20260718...
    re.compile(r"[_-](?P<y>\d{4})(?P<m>\d{2})(?P<d>\d{2})"),
    # bare 2026-07-18 anywhere
    re.compile(r"(?P<y>\d{4})-(?P<m>\d{2})-(?P<d>\d{2})"),
]


def log(msg):
    print(msg, flush=True)


def die(msg):
    sys.exit(f"ERROR: {msg}")


def require_video_tools():
    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            die(f"'{tool}' is required to process videos. Install ffmpeg "
                f"(e.g. `sudo apt-get install -y ffmpeg` or `brew install ffmpeg`), "
                f"or move videos out of the source folder.")


def newer(src, dst):
    """True if dst is missing or older than src (drives idempotent skipping)."""
    return not os.path.exists(dst) or os.path.getmtime(dst) < os.path.getmtime(src)


# ---------- date detection ----------

_EXIF_AVAILABLE = shutil.which("exiftool") is not None


def date_from_exif(path):
    if not _EXIF_AVAILABLE:
        return None
    try:
        out = subprocess.run(
            ["exiftool", "-j", "-DateTimeOriginal", "-CreateDate", "-MediaCreateDate", path],
            check=True, stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdout=subprocess.PIPE, text=True,
        ).stdout
        data = json.loads(out)[0]
    except Exception:
        return None
    for key in ("DateTimeOriginal", "CreateDate", "MediaCreateDate"):
        val = data.get(key)
        if not val or str(val).startswith("0000"):
            continue
        m = re.match(r"(\d{4})[:\-](\d{2})[:\-](\d{2})", str(val))
        if m:
            try:
                return _dt.date(int(m[1]), int(m[2]), int(m[3]))
            except ValueError:
                continue
    return None


def date_from_filename(name):
    for pat in _FILENAME_DATE_PATTERNS:
        m = pat.search(name)
        if m:
            try:
                return _dt.date(int(m["y"]), int(m["m"]), int(m["d"]))
            except ValueError:
                continue
    return None


def date_from_mtime(path):
    return _dt.date.fromtimestamp(os.path.getmtime(path))


def resolve_date(path, name, source):
    """Return a date object using the requested source strategy (or None)."""
    if source == "exif":
        return date_from_exif(path)
    if source == "filename":
        return date_from_filename(name)
    if source == "mtime":
        return date_from_mtime(path)
    # auto: best available, in order.
    return date_from_exif(path) or date_from_filename(name) or date_from_mtime(path)


# ---------- derivative building ----------

def build_photo(src, base, thumb_dir, full_dir, thumb_max, full_max, force):
    thumb = os.path.join(thumb_dir, base + ".jpg")
    full = os.path.join(full_dir, base + ".jpg")
    for dst, size, q in ((thumb, thumb_max, 78), (full, full_max, 82)):
        if not force and not newer(src, dst):
            continue
        with Image.open(src) as im:
            im = ImageOps.exif_transpose(im).convert("RGB")
            im.thumbnail((size, size), Image.LANCZOS)
            im.save(dst, "JPEG", quality=q, optimize=True, progressive=True)


def build_video(src, base, thumb_dir, full_dir, thumb_max, video_max_h, force):
    full = os.path.join(full_dir, base + ".mp4")
    thumb = os.path.join(thumb_dir, base + ".jpg")
    if force or newer(src, full):
        subprocess.run(
            ["ffmpeg", "-y", "-i", src, "-vf", f"scale=-2:'min({video_max_h},ih)'",
             "-c:v", "libx264", "-preset", "medium", "-crf", "23",
             "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", full],
            check=True, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    if force or newer(src, thumb):
        subprocess.run(
            ["ffmpeg", "-y", "-i", src, "-vf",
             f"thumbnail,scale={thumb_max}:{thumb_max}:force_original_aspect_ratio=decrease",
             "-frames:v", "1", thumb],
            check=True, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


# ---------- manifest ----------

def yaml_quote(s):
    """Quote a scalar for YAML, escaping backslash and double-quote."""
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_manifest(path, days, start_date):
    """days: dict[date_str] -> list[(base, type)] already sorted."""
    lines = [
        "# Auto-generated by build_gallery.py. Hand edits are preserved unless",
        "# the script is run with --regen-manifest. 'file' is the basename",
        "# without extension; thumb is always <file>.jpg, full is <file>.jpg",
        "# for photos and <file>.mp4 for videos.",
        "days:",
    ]
    for dstr in sorted(days):
        d = _dt.date.fromisoformat(dstr)
        lines.append(f"  - date: {yaml_quote(dstr)}")
        if start_date is not None:
            lines.append(f"    day_number: {(d - start_date).days + 1}")
        lines.append("    items:")
        for base, typ in days[dstr]:
            lines.append(f"      - {{ file: {yaml_quote(base)}, type: {typ} }}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


# ---------- main ----------

def main():
    ap = argparse.ArgumentParser(description="Build gallery derivatives + manifest.")
    ap.add_argument("--source", required=True,
                    help="Folder of original photos/videos (read-only).")
    ap.add_argument("--assets", required=True,
                    help="Site assets dir for derivatives; thumb/ and full/ are created under it "
                         "(e.g. site/assets/gallery).")
    ap.add_argument("--data-file",
                    help="Manifest output path (default: <assets>/../../_data/gallery.yml if that "
                         "layout exists, else <assets>/gallery.yml).")
    ap.add_argument("--start-date",
                    help="YYYY-MM-DD; when set, emit a 1-based day_number per day (trip/event sites).")
    ap.add_argument("--date-source", choices=["auto", "exif", "filename", "mtime"], default="auto",
                    help="Where to read each item's date from (default: auto — exif, then filename, then mtime).")
    ap.add_argument("--thumb-max", type=int, default=400, help="Thumbnail long-edge px (default 400).")
    ap.add_argument("--full-max", type=int, default=1600, help="Full image long-edge px (default 1600).")
    ap.add_argument("--video-max-h", type=int, default=720, help="Video max height px (default 720).")
    ap.add_argument("--force", action="store_true", help="Rebuild derivatives even if up-to-date.")
    ap.add_argument("--regen-manifest", action="store_true", help="Overwrite an existing manifest.")
    args = ap.parse_args()

    if not os.path.isdir(args.source):
        die(f"source dir not found: {args.source}")

    start_date = None
    if args.start_date:
        try:
            start_date = _dt.date.fromisoformat(args.start_date)
        except ValueError:
            die(f"--start-date must be YYYY-MM-DD, got {args.start_date!r}")

    thumb_dir = os.path.join(args.assets, "thumb")
    full_dir = os.path.join(args.assets, "full")
    os.makedirs(thumb_dir, exist_ok=True)
    os.makedirs(full_dir, exist_ok=True)

    # Default manifest location: prefer a Jekyll _data dir two levels up from a
    # conventional site/assets/gallery layout, else drop it beside the assets.
    if args.data_file:
        manifest = args.data_file
    else:
        guess = os.path.normpath(os.path.join(args.assets, "..", "..", "_data", "gallery.yml"))
        manifest = guess if os.path.isdir(os.path.dirname(guess)) else os.path.join(args.assets, "gallery.yml")

    names = sorted(os.listdir(args.source))
    has_video = any(n.rsplit(".", 1)[-1].lower() in VIDEO_EXT for n in names if "." in n)
    if has_video:
        require_video_tools()

    # Fail early rather than skipping every HEIC/HEIF through the per-file
    # exception handler, which would silently drop them from the manifest.
    if not _HEIF_AVAILABLE and any(
        n.rsplit(".", 1)[-1].lower() in HEIF_EXT for n in names if "." in n
    ):
        die("source contains HEIC/HEIF files but pillow-heif is not installed. "
            "Install it (pip install pillow-heif) or convert those files first.")

    days = {}
    processed = skipped = 0
    seen_bases = {}
    for name in names:
        if "." not in name:
            continue
        base, ext = name.rsplit(".", 1)
        ext = ext.lower()
        if ext not in PHOTO_EXT and ext not in VIDEO_EXT:
            continue
        # Disambiguate same-basename/different-extension sources (the iPhone
        # Live Photo IMG_1234.HEIC + IMG_1234.MOV pattern). Without this the
        # second one overwrites the first's derivatives and the manifest ends
        # up with two entries pointing at the same files.
        if base in seen_bases:
            base = f"{base}_{ext}"
        seen_bases[base] = name
        src = os.path.join(args.source, name)
        try:
            d = resolve_date(src, name, args.date_source)
            if d is None:
                raise ValueError("could not determine a date")
            dstr = d.isoformat()
            if ext in PHOTO_EXT:
                build_photo(src, base, thumb_dir, full_dir, args.thumb_max, args.full_max, args.force)
                days.setdefault(dstr, []).append((base, "photo"))
            else:
                build_video(src, base, thumb_dir, full_dir, args.thumb_max, args.video_max_h, args.force)
                days.setdefault(dstr, []).append((base, "video"))
            processed += 1
            log(f"[{processed}] {name} -> {dstr}")
        except Exception as e:  # never let one bad file abort the whole run
            skipped += 1
            log(f"WARNING: skipping {name}: {type(e).__name__}: {e}")
            continue

    for dstr in days:
        days[dstr].sort(key=lambda t: t[0])

    if args.regen_manifest or not os.path.exists(manifest):
        write_manifest(manifest, days, start_date)
        log(f"Wrote manifest: {manifest}")
    else:
        # Derivatives were built for every source file, but the manifest is
        # deliberately left alone to preserve hand edits. Warn when that means
        # newly added media is not actually reachable from the gallery.
        with open(manifest) as f:
            existing = f.read()
        missing = [base for items in days.values() for base, _ in items
                   if f'file: {yaml_quote(base)}' not in existing]
        if missing:
            shown = ", ".join(missing[:5])
            more = f" (+{len(missing) - 5} more)" if len(missing) > 5 else ""
            log(f"WARNING: {len(missing)} processed file(s) are missing from the "
                f"existing manifest and will not appear in the gallery: {shown}{more}. "
                f"Add them by hand, or back up your edits and re-run with --regen-manifest.")
        log(f"Manifest exists, kept as-is (use --regen-manifest to overwrite): {manifest}")

    log(f"Done. Processed {processed} files across {len(days)} day(s). Skipped {skipped}.")


if __name__ == "__main__":
    main()
