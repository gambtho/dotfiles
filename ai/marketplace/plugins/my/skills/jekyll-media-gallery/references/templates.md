# Gallery front-end templates

Copy these into the target site and adapt class names / tokens to match its
existing styles. They assume the manifest shape emitted by
`scripts/build_gallery.py`:

```yaml
days:
  - date: "2026-07-18"
    day_number: 1        # only present if --start-date was passed
    items:
      - { file: "2026-07-18_182634", type: photo }
      - { file: "2026-07-19_065602", type: video }
```

Derivative URL convention (must match the script exactly):
- thumbnail: `/assets/gallery/thumb/<file>.jpg` (always .jpg, even for video)
- full: `/assets/gallery/full/<file>.jpg` for photos, `<file>.mp4` for videos

---

## 1. Gallery page — `gallery.md`

Front matter uses the site's default layout. If the site has a `_days`
collection (trip/event sites), the section heading cross-references it by
`day_number` so titles stay single-sourced; otherwise it just shows the date.
Adapt or drop that `where` lookup for sites without a day collection.

```liquid
---
layout: default
title: Gallery
permalink: /gallery/
---

# Gallery

<p class="gallery-intro">Photos and videos, in order.</p>

{% comment %} Only needed if the site has a _days collection to pull titles from. {% endcomment %}
{% assign day_pages = site.days | sort: "day_number" %}

<nav class="gallery-jump" aria-label="Jump to day">
  {% for day in site.data.gallery.days %}
  <a href="#day-{{ forloop.index }}" class="gallery-jump-chip">
    {% if day.day_number %}Day {{ day.day_number }}{% else %}{{ day.date | date: "%b %-d" }}{% endif %}
  </a>
  {% endfor %}
</nav>

{% for day in site.data.gallery.days %}
  {% assign match = day_pages | where: "day_number", day.day_number | first %}
  <section class="gallery-day" id="day-{{ forloop.index }}">
    <h2 class="gallery-day-heading">
      {% if day.day_number %}Day {{ day.day_number }}{% endif %}
      <span class="gallery-day-date">{{ day.date | date: "%b %-d" }}</span>
      {% if match %}<span class="gallery-day-title">{{ match.title }}</span>{% endif %}
    </h2>
    <div class="gallery-grid">
      {% for item in day.items %}
      <button type="button" class="gallery-thumb{% if item.type == 'video' %} is-video{% endif %}"
        {% if item.type == 'video' %}data-full="{{ '/assets/gallery/full/' | append: item.file | append: '.mp4' | relative_url }}"{% else %}data-full="{{ '/assets/gallery/full/' | append: item.file | append: '.jpg' | relative_url }}"{% endif %}
        data-type="{{ item.type }}"
        data-day="{{ forloop.parentloop.index }}"
        data-index="{{ forloop.index0 }}">
        <img src="{{ '/assets/gallery/thumb/' | append: item.file | append: '.jpg' | relative_url }}"
             loading="lazy" alt="{% if day.day_number %}Day {{ day.day_number }} {% endif %}{{ item.type }}">
        {% if item.type == 'video' %}<span class="gallery-play" aria-hidden="true">▶</span>{% endif %}
      </button>
      {% endfor %}
    </div>
  </section>
{% endfor %}

<div class="lightbox" id="lightbox" role="dialog" aria-modal="true" aria-label="Photo and video viewer" hidden>
  <button class="lightbox-close" aria-label="Close">&times;</button>
  <button class="lightbox-prev" aria-label="Previous">&larr;</button>
  <div class="lightbox-stage" id="lightbox-stage"></div>
  <button class="lightbox-next" aria-label="Next">&rarr;</button>
</div>
```

**Liquid gotcha:** there is no `ternary` filter. Build the `.mp4`/`.jpg`
`data-full` value with an explicit `{% if %}…{% else %}…{% endif %}` as above.
Always run every asset/href through `relative_url` so the site works under a
non-empty `baseurl`.

---

## 2. Lightbox JS

Drop this into the site's main JS. If that file wraps everything in an IIFE,
put this module INSIDE it (before the final `})();`) so nothing leaks to the
global scope. It is a no-op on pages without a gallery (guards on the elements).

```javascript
(function initGallery() {
  const lightbox = document.getElementById('lightbox');
  if (!lightbox) return;
  const stage = document.getElementById('lightbox-stage');
  const thumbs = Array.from(document.querySelectorAll('.gallery-thumb'));
  if (!thumbs.length) return;

  // Group thumbs by day so prev/next stays within a day.
  const byDay = {};
  thumbs.forEach(function(t) {
    const d = t.dataset.day;
    (byDay[d] = byDay[d] || []).push(t);
  });

  let currentDay = null;
  let currentIndex = 0;
  let lastFocused = null;

  function render(thumb) {
    stage.innerHTML = '';
    if (thumb.dataset.type === 'video') {
      const v = document.createElement('video');
      v.src = thumb.dataset.full; v.controls = true; v.autoplay = true; v.playsInline = true;
      stage.appendChild(v);
    } else {
      const img = document.createElement('img');
      img.src = thumb.dataset.full;
      const inner = thumb.querySelector('img');
      img.alt = inner ? inner.alt : '';
      stage.appendChild(img);
    }
  }

  function open(thumb) {
    currentDay = thumb.dataset.day;
    currentIndex = byDay[currentDay].indexOf(thumb);
    render(thumb);
    lightbox.hidden = false;
    document.body.classList.add('lightbox-open');
    lastFocused = thumb;
    lightbox.querySelector('.lightbox-close').focus(); // move focus into the dialog
  }

  function close() {
    lightbox.hidden = true;
    stage.innerHTML = '';                       // removing the <video> stops playback
    document.body.classList.remove('lightbox-open');
    if (lastFocused) { lastFocused.focus(); lastFocused = null; } // restore focus
  }

  function step(delta) {
    const group = byDay[currentDay];
    currentIndex = (currentIndex + delta + group.length) % group.length;
    render(group[currentIndex]);
  }

  thumbs.forEach(function(t) { t.addEventListener('click', function() { open(t); }); });
  lightbox.querySelector('.lightbox-close').addEventListener('click', close);
  lightbox.querySelector('.lightbox-prev').addEventListener('click', function() { step(-1); });
  lightbox.querySelector('.lightbox-next').addEventListener('click', function() { step(1); });
  lightbox.addEventListener('click', function(e) { if (e.target === lightbox) close(); });

  document.addEventListener('keydown', function(e) {
    if (lightbox.hidden) return;
    if (e.key === 'Escape') { close(); return; }
    if (e.key === 'ArrowLeft') { step(-1); return; }
    if (e.key === 'ArrowRight') { step(1); return; }
    if (e.key === 'Tab') {                       // trap focus within the dialog
      const focusable = Array.from(lightbox.querySelectorAll('button:not([disabled])'))
        .filter(function(el) { return el.offsetParent !== null; });
      if (!focusable.length) return;
      const first = focusable[0], last = focusable[focusable.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });

  // Touch swipe: horizontal drag beyond threshold navigates within the day.
  const SWIPE_THRESHOLD = 50;
  let startX = 0, startY = 0;
  lightbox.addEventListener('touchstart', function(e) {
    const t = e.changedTouches[0]; startX = t.clientX; startY = t.clientY;
  }, { passive: true });
  lightbox.addEventListener('touchend', function(e) {
    const t = e.changedTouches[0];
    const dx = t.clientX - startX, dy = t.clientY - startY;
    if (Math.abs(dx) < SWIPE_THRESHOLD || Math.abs(dx) <= Math.abs(dy)) return; // ignore vertical/small
    step(dx < 0 ? 1 : -1);
  }, { passive: true });
})();
```

---

## 3. CSS

Append to the site's stylesheet. Replace the `var(--…)` tokens with the site's
own (or literal values) — these names mirror a common palette but every site
differs. The grid, sticky jump bar, video badge, and full-screen lightbox are
the parts that matter; colors should follow the host site.

```css
/* Gallery */
.gallery-intro { color: var(--color-text-light, #6b7280); }

.gallery-jump {
  position: sticky; top: var(--header-height, 0); z-index: 50;
  display: flex; gap: .5rem; overflow-x: auto; padding: .5rem 0; margin-bottom: 1.5rem;
  background: var(--color-bg, #fff); -webkit-overflow-scrolling: touch;
}
.gallery-jump-chip {
  flex: 0 0 auto; padding: .25rem 1rem; border: 1px solid var(--color-border, #e5e7eb);
  border-radius: 999px; font-size: .85rem; text-decoration: none;
  color: var(--color-secondary, #1e3a5f); white-space: nowrap; background: #fff;
}
.gallery-jump-chip:hover { background: var(--color-primary, #dc2626); color: #fff; border-color: var(--color-primary, #dc2626); }

.gallery-day { margin-bottom: 3rem; scroll-margin-top: calc(var(--header-height, 0) + 3rem); }
.gallery-day-heading {
  display: flex; align-items: baseline; gap: .5rem; flex-wrap: wrap;
  border-bottom: 2px solid var(--color-primary, #dc2626); padding-bottom: .25rem;
}
.gallery-day-date { color: var(--color-primary, #dc2626); font-size: .9rem; font-weight: 600; }
.gallery-day-title { color: var(--color-text-light, #6b7280); font-size: .95rem; }

.gallery-grid {
  display: grid; gap: .25rem; margin-top: 1rem;
  grid-template-columns: repeat(auto-fill, minmax(100px, 1fr));
}
@media (min-width: 600px) {
  .gallery-grid { grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: .5rem; }
}
.gallery-thumb {
  position: relative; padding: 0; border: none; cursor: pointer;
  aspect-ratio: 1 / 1; border-radius: 8px; overflow: hidden;
  background: var(--color-border, #e5e7eb); box-shadow: 0 1px 3px rgba(0,0,0,.12);
}
.gallery-thumb img { width: 100%; height: 100%; object-fit: cover; display: block; transition: transform .2s ease; }
.gallery-thumb:hover img { transform: scale(1.05); }
.gallery-play {
  position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
  color: #fff; font-size: 1.6rem; text-shadow: 0 1px 4px rgba(0,0,0,.6);
  background: rgba(0,0,0,.15); pointer-events: none;
}

/* Lightbox */
.lightbox {
  position: fixed; inset: 0; z-index: 1000;
  display: flex; align-items: center; justify-content: center;
  background: rgba(0,0,0,.92); padding: 1rem;
}
.lightbox[hidden] { display: none; }
.lightbox-stage { max-width: 100%; max-height: 100%; display: flex; }
.lightbox-stage img, .lightbox-stage video { max-width: 100%; max-height: 90vh; border-radius: 6px; }
.lightbox-close, .lightbox-prev, .lightbox-next {
  position: absolute; background: rgba(255,255,255,.12); color: #fff; border: none; cursor: pointer;
  font-size: 1.5rem; line-height: 1; width: 44px; height: 44px; border-radius: 50%;
}
.lightbox-close { top: 1rem; right: 1rem; }
.lightbox-prev { left: .5rem; top: 50%; transform: translateY(-50%); }
.lightbox-next { right: .5rem; top: 50%; transform: translateY(-50%); }
.lightbox-close:hover, .lightbox-prev:hover, .lightbox-next:hover { background: var(--color-primary, #dc2626); }
body.lightbox-open { overflow: hidden; }
```

---

## 4. Service worker (only if the site has one)

If the site registers a service worker with a precache list, add the gallery
PAGE route (`/gallery/`) to that list and bump the cache version so the new list
takes effect. Do NOT add the individual `/assets/gallery/` image URLs — there
can be hundreds and force-caching them all bloats and slows the SW install. A
typical network-first fetch handler already caches them opportunistically as
they're viewed.
