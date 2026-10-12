"""Source-transform checks; NOT compiled decoding or device playback proof."""
import hashlib
from pathlib import Path
import tarfile
import tempfile
import unittest
import os

from ffmpeg_cenc_multikey import ORIGINAL, apply, transform


class BackportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'ffmpeg-6.1'
        (self.root / 'libavformat').mkdir(parents=True)
        archive = Path(os.environ['CK_FFMPEG_SOURCE_ARCHIVE'])
        with tarfile.open(archive) as tar:
            self.originals = {name: tar.extractfile(f'ffmpeg-6.1/libavformat/{name}').read() for name in ORIGINAL}
        for name, content in self.originals.items():
            (self.root / 'libavformat' / name).write_bytes(content)

    def tearDown(self):
        self.temp.cleanup()

    def testExactSourceAndIdempotence(self):
        for name, content in self.originals.items():
            self.assertEqual(hashlib.sha256(content).hexdigest(), ORIGINAL[name])
        apply(self.root)
        before = {name: (self.root / 'libavformat' / name).read_bytes() for name in ORIGINAL}
        apply(self.root)
        self.assertEqual(before, {name: (self.root / 'libavformat' / name).read_bytes() for name in ORIGINAL})

    def testTamperedInputFailsBeforeWriting(self):
        path = self.root / 'libavformat/mov.c'
        path.write_bytes(path.read_bytes() + b'\n')
        with self.assertRaises(RuntimeError):
            apply(self.root)
        self.assertFalse((self.root / 'libavformat/isom.h.ck-original').exists())

    def testTamperedPatchedSourceRejected(self):
        apply(self.root)
        path = self.root / 'libavformat/dashdec.c'
        path.write_bytes(path.read_bytes() + b'\n')
        with self.assertRaises(RuntimeError):
            apply(self.root)

    def testKeySelectionAndCacheResetReachAllSchemes(self):
        mov = transform('mov.c', self.originals['mov.c'].decode())
        self.assertIn('ck_select_sample_key(c, sc, sample)', mov)
        self.assertNotIn('av_aes_ctr_init(sc->cenc.aes_ctr, c->decryption_key)', mov)
        self.assertEqual(mov.count('sc->cenc.active_key, 16 * 8, 1'), 2)
        self.assertEqual(mov.count('av_aes_ctr_init(sc->cenc.aes_ctr, sc->cenc.active_key)'), 2)
        self.assertIn('sc->cenc.aes_ctr = NULL;', mov)
        self.assertIn('"No valid supplied key for encrypted sample', mov)


if __name__ == '__main__':
    unittest.main()
