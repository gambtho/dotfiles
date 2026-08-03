import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = (
    REPO_ROOT
    / "ai/marketplace/plugins/my/skills/jekyll-media-gallery/scripts/build_gallery.py"
)


def load_gallery_module():
    pil = types.ModuleType("PIL")
    pil.Image = types.SimpleNamespace(LANCZOS=1, open=lambda _path: None)
    pil.ImageFile = types.SimpleNamespace(LOAD_TRUNCATED_IMAGES=False)
    pil.ImageOps = types.SimpleNamespace(exif_transpose=lambda image: image)
    spec = importlib.util.spec_from_file_location("gallery_under_test", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, {"PIL": pil, "pillow_heif": None}):
        spec.loader.exec_module(module)
    return module


gallery = load_gallery_module()


class FakeImage:
    def __init__(self, save):
        self._save = save

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def convert(self, _mode):
        return self

    def thumbnail(self, _size, _resample):
        return None

    def save(self, path, *_args, **_kwargs):
        self._save(Path(path))


class AtomicOutputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def assert_no_stages(self):
        self.assertEqual([p.name for p in self.path.iterdir() if ".stage." in p.name], [])

    def test_atomic_output_preserves_destination_when_writer_fails(self):
        destination = self.path / "video.mp4"
        destination.write_bytes(b"valid-old")

        def fail(stage):
            stage.write_bytes(b"partial")
            raise RuntimeError("transcode failed")

        with self.assertRaisesRegex(RuntimeError, "transcode failed"):
            gallery.publish_atomically(destination, fail)

        self.assertEqual(destination.read_bytes(), b"valid-old")
        self.assert_no_stages()

    def test_atomic_output_replaces_destination_and_cleans_stage(self):
        destination = self.path / "photo.jpg"
        destination.write_bytes(b"old")

        gallery.publish_atomically(destination, lambda stage: stage.write_bytes(b"new"))

        self.assertEqual(destination.read_bytes(), b"new")
        self.assert_no_stages()

    def test_atomic_output_rejects_empty_required_output(self):
        destination = self.path / "video.mp4"
        destination.write_bytes(b"valid-old")

        with self.assertRaisesRegex(RuntimeError, "empty output"):
            gallery.publish_atomically(destination, lambda _stage: None)

        self.assertEqual(destination.read_bytes(), b"valid-old")
        self.assert_no_stages()

    def test_video_empty_output_is_preserved_then_retry_publishes_both_files(self):
        source = self.path / "source.mov"
        full_dir = self.path / "full"
        thumb_dir = self.path / "thumb"
        full_dir.mkdir()
        thumb_dir.mkdir()
        source.write_bytes(b"source")
        full = full_dir / "clip.mp4"
        thumb = thumb_dir / "clip.jpg"
        full.write_bytes(b"valid-old")

        with mock.patch.object(gallery.subprocess, "run", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "empty output"):
                gallery.build_video(
                    source, "clip", thumb_dir, full_dir, 400, 720, True
                )

        self.assertEqual(full.read_bytes(), b"valid-old")

        destinations = []

        def succeed(command, **_kwargs):
            stage = Path(command[-1])
            destinations.append(stage)
            stage.write_bytes(b"complete")
            return subprocess.CompletedProcess(command, 0)

        with mock.patch.object(gallery.subprocess, "run", side_effect=succeed):
            gallery.build_video(source, "clip", thumb_dir, full_dir, 400, 720, True)

        self.assertEqual(full.read_bytes(), b"complete")
        self.assertEqual(thumb.read_bytes(), b"complete")
        self.assertTrue(all(stage not in (full, thumb) for stage in destinations))
        self.assertEqual(list(full_dir.glob("*.stage.*")), [])
        self.assertEqual(list(thumb_dir.glob("*.stage.*")), [])

    def test_image_writer_failure_preserves_existing_destination(self):
        source = self.path / "source.jpg"
        full_dir = self.path / "full"
        thumb_dir = self.path / "thumb"
        full_dir.mkdir()
        thumb_dir.mkdir()
        source.write_bytes(b"source")
        full = full_dir / "photo.jpg"
        full.write_bytes(b"valid-old")

        def save(stage):
            stage.write_bytes(b"partial")
            if stage.parent == full_dir:
                raise RuntimeError("image failed")

        fake_image = FakeImage(save)
        with mock.patch.object(gallery.Image, "open", return_value=fake_image):
            with self.assertRaisesRegex(RuntimeError, "image failed"):
                gallery.build_photo(
                    source, "photo", thumb_dir, full_dir, 400, 1600, True
                )

        self.assertEqual(full.read_bytes(), b"valid-old")
        self.assertEqual(list(full_dir.glob("*.stage.*")), [])

    def test_manifest_replace_failure_preserves_existing_manifest(self):
        manifest = self.path / "gallery.yml"
        manifest.write_text("valid-old\n")
        real_replace = os.replace

        def fail_replace(source, destination):
            if Path(destination) == manifest:
                raise OSError("replace failed")
            return real_replace(source, destination)

        with mock.patch.object(gallery.os, "replace", side_effect=fail_replace):
            with self.assertRaisesRegex(OSError, "replace failed"):
                gallery.write_manifest(
                    manifest, {"2026-08-01": [("photo", "photo")]}, None
                )

        self.assertEqual(manifest.read_text(), "valid-old\n")
        self.assert_no_stages()

    def test_atomic_output_publishes_world_readable_permissions(self):
        destination = self.path / "photo.jpg"

        # Pin the umask: with no existing destination the published mode is
        # derived from it, so a restrictive umask on the runner would fail this
        # test for a reason that has nothing to do with the code under test.
        previous_umask = os.umask(0o022)
        try:
            gallery.publish_atomically(
                destination, lambda stage: stage.write_bytes(b"new")
            )
        finally:
            os.umask(previous_umask)

        mode = stat.S_IMODE(destination.stat().st_mode)
        # Gallery derivatives are committed to a static site and served by a web
        # server, so a private mkstemp stage (0600) must not become the
        # published mode.
        self.assertTrue(mode & stat.S_IRGRP, f"group-unreadable mode {oct(mode)}")
        self.assertTrue(mode & stat.S_IROTH, f"world-unreadable mode {oct(mode)}")

    def test_atomic_output_preserves_existing_destination_permissions(self):
        destination = self.path / "photo.jpg"
        destination.write_bytes(b"old")
        os.chmod(destination, 0o640)

        gallery.publish_atomically(destination, lambda stage: stage.write_bytes(b"new"))

        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o640)


if __name__ == "__main__":
    unittest.main()
