# Lessons learned — why the gallery is built this way

These are the non-obvious constraints and failure modes that shaped this
approach. Read this before deviating from the default pipeline; each item cost
real debugging to discover.

## Hosting constraints (drive the whole architecture)

- **GitHub Pages cannot process images.** No custom plugins run at build time,
  so you cannot resize or transcode on the server. All optimization must happen
  locally and the ready-to-serve derivatives get committed.
- **GitHub Pages does not serve Git LFS content.** It serves the LFS *pointer
  stub* (a few lines of text) instead of the file, so every `<img>`/`<video>`
  breaks on the live site while working locally — a nasty surprise. Therefore
  LFS is not a viable way to keep the repo small on Pages. If a site must keep
  true originals online, either commit web-optimized derivatives (the default
  here) or host originals in an external bucket (R2/S3/etc.) and reference them.
- **Consequence:** the default is "commit web-sized derivatives only; keep
  originals local." A 500-file / ~560 MB phone-photo set compresses to roughly
  120–180 MB of derivatives — acceptable for a Pages repo, and fast on mobile.

## Media metadata is often gone

- Messaging apps and some exports **strip EXIF/QuickTime metadata**, so capture
  dates and orientation may be absent. In one real set, 0 of 421 JPEGs had an
  EXIF date and all 88 videos had zeroed QuickTime dates.
- That's why the build script tries **exif → filename timestamp → mtime** in
  order. When metadata is stripped, the filename is usually the only real date
  signal (phone exports like `2026-07-18_182634.jpg` or `IMG_20260718_...`).
  File mtime is the weakest fallback — it's often just the download date.
- **Timezone caveat:** filename timestamps are usually local time but there's no
  way to prove it once metadata is gone. Photos taken near midnight can land in
  an adjacent day. The manifest is hand-editable precisely so a human can nudge
  these. Mention this to the user rather than presenting the grouping as exact.

## Real media sets contain broken files

- Expect a few **truncated/corrupt images** (missing trailing bytes) in any
  large real-world set. `PIL.ImageOps.exif_transpose` forces a full decode, so a
  truncated file raises `OSError: image file is truncated` — and if nothing
  catches it, the *entire* run dies on the first bad file, looking exactly like
  a hang partway through.
- The script defends against this two ways: `ImageFile.LOAD_TRUNCATED_IMAGES =
  True` recovers near-complete images, and a per-file try/except skips anything
  genuinely unprocessable with a warning (and omits it from the manifest) so one
  bad file never aborts the run. Always report the skip count.

## Long runs and orchestration

- Transcoding scores of videos takes **several minutes**. If you delegate the
  run to a subagent, its background shell may not survive idle cycles — the run
  can appear to "stall." Prefer running the build in a shell you control and
  watch progress by counting output files (e.g. mp4 count), not by trusting a
  single "done" signal. The script is idempotent, so re-running safely resumes.
- Verify against **file counts and the built HTML**, not vibes: every manifest
  item should resolve to an on-disk thumb + full; `jekyll build` output should
  contain the expected thumbnail and video counts; and `/gallery/` plus a sample
  thumb and a sample mp4 should each serve HTTP 200 locally.

## Front-end details that are easy to miss

- **Liquid has no `ternary` filter** — build the `.mp4`/`.jpg` `data-full` value
  with an explicit `{% if %}…{% else %}…{% endif %}`.
- Run every asset URL through **`relative_url`** so the site survives a
  non-empty `baseurl`. A service worker with hardcoded `/` paths and a page
  using `relative_url` will diverge if a baseurl is later added — keep both in
  mind.
- **Accessibility:** make the lightbox a real dialog (`role="dialog"`,
  `aria-modal`, a label), move focus into it on open, trap Tab within it, and
  restore focus to the invoking thumbnail on close. Clearing the stage on close
  also stops video/audio playback.
- **Mobile:** `loading="lazy"` on thumbnails is essential with hundreds of
  images. Horizontal touch-swipe in the lightbox should ignore primarily
  vertical or below-threshold gestures so it doesn't fight scrolling.

## What to keep out of scope for a first version

Captions, favorites/tagging, albums, city/type filtering, and EXIF-based date
correction are all reasonable later additions but tend to balloon a first
version. A clean day-grouped grid with a working lightbox is the coherent v1;
add the rest only when asked.
