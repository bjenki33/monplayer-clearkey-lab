"""Loopback-only CI fixture; no external media, credentials or content keys."""
import gzip
import copy
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import threading
import time
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

ROOT = Path(sys.argv[1]).resolve()
NS = 'urn:mpeg:dash:schema:mpd:2011'
ET.register_namespace('', NS)
ET.register_namespace('cenc', 'urn:mpeg:cenc:2013')
SESSIONS = {}
SESSION_LOCK = threading.Lock()


def live_manifest(session):
    with SESSION_LOCK:
        clock, wall = SESSIONS.setdefault(session, (time.monotonic() - 12, time.time() - 12))
    elapsed = time.monotonic() - clock
    tree = ET.parse(ROOT / 'live-source/manifest.mpd')
    root = tree.getroot()
    root.set('type', 'dynamic')
    root.attrib.pop('mediaPresentationDuration', None)
    root.set('availabilityStartTime', datetime.fromtimestamp(wall, timezone.utc).isoformat().replace('+00:00', 'Z'))
    root.set('minimumUpdatePeriod', 'PT1S')
    root.set('suggestedPresentationDelay', 'PT4S')
    root.set('timeShiftBufferDepth', 'PT30S')
    root.set('minBufferTime', 'PT10S')
    for period in root.findall(f'{{{NS}}}Period'):
        period.attrib.pop('duration', None)
        for template in period.iter(f'{{{NS}}}SegmentTemplate'):
            scale = int(template.get('timescale'))
            timeline = template.find(f'{{{NS}}}SegmentTimeline')
            entries, timestamp = [], 0
            number = int(template.get('startNumber', '1'))
            for entry in timeline:
                timestamp = int(entry.get('t', timestamp))
                duration = int(entry.get('d'))
                for _ in range(int(entry.get('r', '0')) + 1):
                    if timestamp + duration <= elapsed * scale and timestamp >= max(0, elapsed - 30) * scale:
                        entries.append((number, timestamp, duration))
                    timestamp += duration; number += 1
            for entry in list(timeline):
                timeline.remove(entry)
            if not entries:
                raise RuntimeError('Owned live fixture exhausted or not available')
            template.set('startNumber', str(entries[0][0]))
            for _, timestamp, duration in entries:
                ET.SubElement(timeline, f'{{{NS}}}S', {'t': str(timestamp), 'd': str(duration)})
            for field in ['initialization', 'media']:
                template.set(field, '/gzip/live-source/' + template.get(field))
        video = next(group for group in period if group.get('contentType') == 'video')
        unused = copy.deepcopy(video.find(f'{{{NS}}}Representation'))
        unused.set('id', 'unused-live'); unused.set('height', '45'); unused.set('bandwidth', '100000')
        for template in unused.iter(f'{{{NS}}}SegmentTemplate'):
            template.set('initialization', '/gzip/live-source/unused/missing-init.m4s')
            template.set('media', '/gzip/live-source/unused/missing-$Number$.m4s')
        video.insert(0, unused)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/health':
            body, code, kind, encoding = b'fixture ready', 200, 'text/plain', None
        elif path == '/redirect.php':
            self.send_response(302)
            self.send_header('Location', '/gzip/manifest.mpd')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        elif path.startswith('/live/') and path.endswith('/manifest.mpd'):
            session = path.split('/')[2]
            if not session.isalnum() or len(session) > 64:
                self.send_error(400); return
            body, code, kind, encoding = live_manifest(session), 200, 'application/dash+xml', None
        else:
            # Incorrect redirect-base resolution must fail, not hit a root alias.
            relative = path.removeprefix('/gzip/') if path.startswith('/gzip/') else '_missing_'
            target = (ROOT / relative).resolve()
            if ROOT not in target.parents or not target.is_file():
                body, code, kind, encoding = b'missing fixture', 404, 'text/plain', None
            else:
                body, code = target.read_bytes(), 200
                kind = 'application/dash+xml' if target.suffix == '.mpd' else 'video/iso.segment'
                encoding = 'gzip' if path.startswith('/gzip/') and target.suffix == '.mpd' else None
                if encoding:
                    body = gzip.compress(body)
        self.send_response(code)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        if encoding:
            self.send_header('Content-Encoding', encoding)
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(('127.0.0.1', 18761), Handler).serve_forever()
