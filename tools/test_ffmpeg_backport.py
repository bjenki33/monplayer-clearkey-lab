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

    def testDashSelectionRunsInsideManifestParserBeforeComponentOpen(self):
        dash = transform('dashdec.c', self.originals['dashdec.c'].decode())
        start = dash.index('static int parse_manifest(AVFormatContext')
        end = dash.index('static int64_t calc_cur_seg_no(', start)
        self.assertIn('ret = ck_select_video_representation(s);', dash[start:end])
        self.assertIn('"ck_video_representation"', dash)
        self.assertIn('matches != 1', dash)
        self.assertIn('free_representation(c->videos[i])', dash)
        self.assertLess(dash.index('ck_select_video_representation(s);', start), dash.index('static int dash_read_header('))

    def testNearLiveDelayIsOptInAndOldDefaultIsRetained(self):
        dash = transform('dashdec.c', self.originals['dashdec.c'].decode())
        self.assertIn('c->ck_live_delay ? c->ck_live_delay : 60', dash)
        self.assertIn('"ck_live_delay"', dash)
        self.assertIn('AV_OPT_TYPE_INT, {.i64 = 0}, 0, 60', dash)

    def testURLScratchAlignmentIncludesTerminatorAtEveryBoundary(self):
        dash = transform('dashdec.c', self.originals['dashdec.c'].decode())
        self.assertIn('tmp_max_url_size = aligned(tmp_max_url_size + 1);', dash)
        self.assertNotIn('tmp_max_url_size = aligned(tmp_max_url_size);', dash)
        for length in [0, 1, 63, 64, 65, 127, 128, 129, 4096]:
            capacity = ((length + 1 + 63) >> 6) << 6
            self.assertGreater(capacity, length)
            self.assertEqual(capacity % 64, 0)

    def testFragmentRecoveryIsOptInBoundedGETTransportOnlyAndInterruptible(self):
        dash = transform('dashdec.c', self.originals['dashdec.c'].decode())
        start = dash.index('static int ck_open_fragment(')
        end = dash.index('static int ck_response_string(', start)
        recovery = dash[start:end]
        self.assertIn('AV_OPT_TYPE_BOOL, {.i64 = 0}, 0, 1', dash)
        self.assertIn('retries >= 2', recovery)
        self.assertIn('av_gettime_relative() + 5 * AV_TIME_BASE', recovery)
        self.assertIn('"rw_timeout", remaining', recovery)
        self.assertIn('"timeout", remaining', recovery)
        self.assertIn('"post_data"', recovery)
        self.assertIn('!strcmp(method->value, "GET")', recovery)
        self.assertNotIn('AVERROR_HTTP', recovery)
        self.assertNotIn('AVERROR(EIO)', recovery)
        self.assertIn('ff_check_interrupt(c->interrupt_callback)', recovery)
        self.assertIn('deadline ? &interrupt : c->interrupt_callback', recovery)
        self.assertIn('pls->ck_open_deadline = 0;', recovery)
        self.assertIn('av_gettime_relative() >= pls->ck_open_deadline', dash)
        self.assertIn('ret = ck_open_fragment(c, pls, url, &opts);', dash)
        self.assertIn('goto end; /* Bounded route fails rather than skipping forever. */', dash)
        self.assertIn('return v->ck_fragment_error;', dash)
        self.assertIn('pls->ck_fragment_error = ret;', dash)

    def testBodyResumeValidatesEntityBeforeDeliveringAndSharesOneBudget(self):
        dash = transform('dashdec.c', self.originals['dashdec.c'].decode())
        self.assertIn('status != 206', dash)
        self.assertIn('start != pls->cur_seg_offset', dash)
        self.assertIn('total != pls->ck_body_total', dash)
        self.assertIn('strcmp(tag, pls->ck_body_etag)', dash)
        self.assertIn('If-Range: %s', dash)
        self.assertIn('pls->ck_body_retries >= 2', dash)
        self.assertIn('!pls->ck_body_deadline', dash)
        self.assertIn('seg != pls->init_section', dash)
        self.assertIn('!av_stristr(headers->value, "range:")', dash)
        self.assertIn('av_freep(&pls->ck_body_url);', dash)
        self.assertIn('pls->ck_open_deadline = pls->ck_body_deadline;', dash)

    def testHTTPMetadataExportIsDefaultOffBoundedUniqueAndResetPerResponse(self):
        http = transform('http.c', self.originals['http.c'].decode())
        self.assertIn('if (!s->ck_export_headers)', http)
        self.assertIn('if (*target || strlen(value) > 512)', http)
        for field in ['ck_etag', 'ck_content_range', 'ck_content_length', 'ck_content_encoding', 'ck_transfer_encoding']:
            self.assertEqual(http.count(f'av_freep(&s->{field});'), 2)
            self.assertIn(f'OFFSET({field}), AV_OPT_TYPE_STRING', http)

    def testLiveRefreshConvertsGlobalSequenceToRelativeAndBackForBothTracks(self):
        dash = transform('dashdec.c', self.originals['dashdec.c'].decode())
        for kind in ['video', 'audio']:
            self.assertIn(f'cur_{kind}->cur_seq_no - cur_{kind}->first_seq_no', dash)
            self.assertIn(f'ccur_{kind}->first_seq_no + index', dash)
        self.assertIn('av_gettime_relative() + 20 * AV_TIME_BASE', dash)
        self.assertIn('av_usleep(250000)', dash)
        self.assertIn('refresh_manifest(pls->parent) < 0', dash)


if __name__ == '__main__':
    unittest.main()
