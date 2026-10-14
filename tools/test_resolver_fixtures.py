"""Owned resolution fixture protocol tests;not Swift or physical player proof."""
import base64
import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import fixture_http as fixture


class ResolverFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), fixture.Handler)
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()
        cls.origin = 'http://127.0.0.1:' + str(cls.server.server_address[1])

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join(timeout=3)

    def read(self, mode, resource, body=None):
        headers = {'X-License': 'owned-license'} if resource == 'keys' else {'X-Stream': 'owned-stream'}
        request = Request(self.origin + '/resolve/' + self._testMethodName.replace('_', '') + '/' + mode + '/' + resource,
                          data=body, headers=headers)
        with urlopen(request, timeout=4) as response:
            return response.read()

    def stats(self, mode):
        value = json.loads(self.read(mode, 'stats'))
        for field in ['wrong_headers', 'wrong_challenges', 'cookies']:
            self.assertEqual(value[field], 0)
        return value

    def test_get_changes_key_map_only_on_second_attempt(self):
        first = json.loads(self.read('get', 'keys'))
        manifest = self.read('get', 'manifest.mpd')
        second = json.loads(self.read('get', 'keys'))
        self.assertEqual(first['keys'][0]['kid'], fixture.KIDS[0])
        self.assertEqual(second['keys'][0]['kid'], fixture.ROTATED_KID)
        self.assertIn(b'404142434445464748494a4b4c4d4e4f', manifest)
        self.assertEqual(self.stats('get')['keys'], 2)

    def test_post_requires_fresh_challenge_after_manifest_changes(self):
        for attempt in [1, 2]:
            manifest = self.read('post', 'manifest.mpd')
            first = fixture.KIDS[0] if attempt == 1 else fixture.ROTATED_KID
            self.assertIn(base64.urlsafe_b64decode(first + '==').hex().encode(), manifest)
            body = json.dumps({'type': 'temporary', 'kids': [first, fixture.KIDS[1]]}).encode()
            keys = json.loads(self.read('post', 'keys', body))
            self.assertEqual(keys['keys'][0]['kid'], fixture.ROTATED_KID)
        self.assertEqual(self.stats('post')['manifests'], 2)

    def test_permanent_never_refreshes_and_stats_count_all_requests(self):
        for _ in range(3):
            keys = json.loads(self.read('permanent', 'keys'))
            self.assertEqual(keys['keys'][0]['kid'], fixture.KIDS[0])
            self.read('permanent', 'manifest.mpd')
        stats = self.stats('permanent')
        self.assertEqual((stats['keys'], stats['manifests']), (3, 3))

    def test_single_compatibility_and_matching_fixture_are_distinct(self):
        self.assertEqual(len(json.loads(self.read('single', 'keys'))['keys']), 1)
        self.assertIn(b'404142434445464748494a4b4c4d4e4f', self.read('single', 'manifest.mpd'))
        self.assertIn(b'000102030405060708090a0b0c0d0e0f', self.read('matching', 'manifest.mpd'))
        self.stats('single')

    def test_auth_and_parse_failures_are_explicit(self):
        with self.assertRaises(HTTPError) as failure:
            self.read('deny', 'keys')
        self.assertEqual(failure.exception.code, 403)
        with self.assertRaises(json.JSONDecodeError):
            json.loads(self.read('invalid', 'keys'))
        self.stats('invalid')

    def test_wrong_post_challenge_is_rejected_and_counted(self):
        with self.assertRaises(HTTPError) as failure:
            self.read('post', 'keys', b'{"kids":[],"type":"temporary"}')
        self.assertEqual(failure.exception.code, 400)
        stats = json.loads(self.read('post', 'stats'))
        self.assertEqual(stats['wrong_challenges'], 1)


if __name__ == '__main__':
    unittest.main()
