---
name: jekyll-media-gallery
description: Use this to add a photo/video gallery page to a Jekyll, GitHub Pages, or similar static site — whenever someone wants to display, show off, or browse pictures and movies from a folder (e.g. `./media`) on their site. Trigger it for requests like "show the trip photos on the website", "make a gallery/photos/media page", "turn this folder of pictures and clips into a browsable gallery", "add our vacation/wedding/event photos and videos to the site", or "my media folder loads too slow on GitHub Pages" — even when the user doesn't say "gallery" or name the tooling, as long as it's a static/Jekyll site. It builds day-grouped sections, optimized thumbnails, transcoded web-friendly videos, a responsive lazy-loaded grid, and an accessible lightbox. It also handles the parts that silently break otherwise: GitHub Pages can't resize images or serve Git LFS, stripped photo metadata forces dates from filenames, and truncated files crash naive scripts. Do NOT use it for non-static-site galleries (React/Vue/WordPress/Shopify), single-image edits, plain `.mov`→mp4 conversion, a blog post with a few inline photos, or Jekyll build-error debugging — those are different tasks.
---

# Jekyll media gallery

Turn a folder of photos and videos into a day-grouped gallery page on a Jekyll
(or other static) site: web-optimized derivatives committed to the repo, an
editable manifest, a responsive lazy-loaded grid, and an accessible lightbox
that plays videos.

The bundled `scripts/build_gallery.py` does the optimization and manifest
generation; `references/templates.md` has the page/JS/CSS to adapt;
`references/lessons-learned.md` explains the non-obvious constraints. **Read
`lessons-learned.md` early** — it's why the defaults are what they are.

## Why not just point `<img>` at the originals

GitHub Pages (and most static hosts) can't resize images at build time and
**won't serve Git LFS files** (they come back as pointer stubs, so every image
breaks live while working locally). So the durable approach is: optimize
locally, commit ready-to-serve derivatives, keep originals off the site. A big
phone-photo set (hundreds of files, ~500 MB) becomes ~120–180 MB of
derivatives — fine for a Pages repo and fast on mobile.

## Workflow

Scale this to the request; a small gallery on a familiar site skips the
ceremony. For anything substantial, follow the site's own conventions over these
defaults.

### 1. Inspect the site and the media

- Find the Jekyll root (`_config.yml`), how assets and pages are laid out,
  the default layout, the nav include, and the design tokens/CSS conventions.
  The gallery must look native, so read the existing CSS before writing any.
- Look at the media folder: count, file types, total size, and the **filename
  pattern** (it's usually the only reliable date source — see below). Check
  whether `_data/` exists (manifest home) and whether there's a service worker.
- Check tools: `python3` + Pillow are required; `ffmpeg`/`ffprobe` are required
  only if there are videos; `exiftool` is optional but gives the best dates.
  If a needed tool is missing, tell the user the exact install command and stop.

### 2. Decide date grouping

Media metadata is frequently stripped, so `build_gallery.py` resolves each
item's date as **exif → filename timestamp → mtime** (first that works). Group
by calendar date. For trip/event sites, pass `--start-date YYYY-MM-DD` to also
emit a 1-based `day_number` per day, which lets the page show "Day 3" and
cross-reference a `_days` collection for titles.

Warn the user that, without metadata, near-midnight photos can land in an
adjacent day; the manifest is hand-editable to fix any.

### 3. Run the build

The originals are read-only inputs and are **never committed**. Only the
derivatives and manifest go in the repo.

```
python3 <skill>/scripts/build_gallery.py \
  --source /abs/path/to/media \
  --assets <site>/assets/gallery \
  [--start-date 2026-07-18] [--regen-manifest]
```

This writes `assets/gallery/thumb/<file>.jpg`, `assets/gallery/full/<file>.jpg`
(photos) / `<file>.mp4` (videos), and a `gallery.yml` manifest (into `_data/`
when that layout is detected). It's idempotent — re-running resumes and only
rebuilds what changed. Transcoding many videos takes **several minutes**; run it
in a shell you control and watch the output-file count rather than trusting a
single completion signal (see lessons-learned).

### 4. Add the page, styles, and script

Adapt the three templates in `references/templates.md` to the site:

- `gallery.md` at `/gallery/` — day sections from the manifest, a sticky
  day-jump bar, a responsive `loading="lazy"` grid, a `▶` badge on videos, and
  the lightbox container (a labeled `role="dialog"`).
- Lightbox JS — add to the site's main JS (inside its IIFE if it has one).
  Click a thumb to open the full photo / playable video, prev/next within a day
  (arrows, keyboard, and touch-swipe), Esc/backdrop to close, with focus moved
  into the dialog, Tab trapped, and focus restored on close.
- CSS — append to the site's stylesheet, swapping in the site's own tokens.
- Add a **Gallery** link to the nav include (and any home quick-links).
- If the site has a service worker with a precache list, add the `/gallery/`
  **page route** and bump the cache version — but not the hundreds of image
  URLs (see lessons-learned).

Mind the front-end gotchas from lessons-learned: no Liquid `ternary` filter;
always use `relative_url`; keep the lightbox accessible.

### 5. Verify

- Every manifest item resolves to an on-disk thumb + full (0 missing).
- `bundle exec jekyll build` succeeds; the built `/gallery/` HTML has the
  expected thumbnail and video counts.
- Serve locally and confirm `/gallery/` returns 200 and a sample thumbnail and
  a sample video both serve 200; then eyeball the grid on a narrow viewport and
  click/swipe through the lightbox (photo display + video playback). The visual
  pass is the one step automation can't fully cover — flag it for the user.
- Confirm no originals from the source folder are staged in git.

## Scope for a first version

A clean day-grouped grid with a working lightbox is the coherent v1. Captions,
favorites, albums, and filtering are reasonable later additions — add them only
when asked, so the first version stays focused.
