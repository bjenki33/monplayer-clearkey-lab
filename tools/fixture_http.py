"""Loopback-only CI fixture; no external media, credentials or content keys."""
import gzip
import copy
import json
import base64
import re
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import threading
import time
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit
from urllib.parse import parse_qs

KIDS = ['AAECAwQFBgcICQoLDA0ODw', 'ICEiIyQlJicoKSorLC0uLw']
LICENSE = {'keys': [{'kty': 'oct', 'kid': KIDS[0], 'k': 'EBESExQVFhcYGRobHB0eHw'},
                    {'kty': 'oct', 'kid': KIDS[1], 'k': 'MDEyMzQ1Njc4OTo7PD0-Pw'}], 'type': 'temporary'}

ROOT = Path(sys.argv[1]).resolve()
NS = 'urn:mpeg:dash:schema:mpd:2011'
ET.register_namespace('', NS)
ET.register_namespace('cenc', 'urn:mpeg:cenc:2013')
SESSIONS = {}
SESSION_LOCK = threading.Lock()
SEQUENCE_BASE = 895000000


def live_manifest(session):
    with SESSION_LOCK:
        state = SESSIONS.setdefault(session, {'clock': time.monotonic() - 120, 'wall': time.time() - 120, 'ages': {}})
        clock, wall = state['clock'], state['wall']
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
            template.set('startNumber', str(entries[0][0] + SEQUENCE_BASE))
            for _, timestamp, duration in entries:
                ET.SubElement(timeline, f'{{{NS}}}S', {'t': str(timestamp), 'd': str(duration)})
            for field in ['initialization', 'media']:
                template.set(field, '/live/' + session + '/' + template.get(field))
        video = next(group for group in period if group.get('contentType') == 'video')
        unused = copy.deepcopy(video.find(f'{{{NS}}}Representation'))
        unused.set('id', 'unused-live'); unused.set('height', '45'); unused.set('bandwidth', '100000')
        for template in unused.iter(f'{{{NS}}}SegmentTemplate'):
            template.set('initialization', '/gzip/live-source/unused/missing-init.m4s')
            template.set('media', '/gzip/live-source/unused/missing-$Number$.m4s')
        video.insert(0, unused)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def live_segment(session, media):
    match = re.fullmatch(r'(video|audio)/chunk-stream0-(\d+)\.m4s', media)
    if not match:
        return True
    group, number = match.group(1), int(match.group(2)) - SEQUENCE_BASE
    tree = ET.parse(ROOT / f'live-source/{group}/manifest.mpd')
    template = next(tree.getroot().iter(f'{{{NS}}}SegmentTemplate'))
    scale, current = int(template.get('timescale')), int(template.get('startNumber', '1'))
    timestamp = 0
    for entry in template.find(f'{{{NS}}}SegmentTimeline'):
        timestamp = int(entry.get('t', timestamp))
        duration = int(entry.get('d'))
        for _ in range(int(entry.get('r', '0')) + 1):
            if current == number:
                with SESSION_LOCK:
                    state = SESSIONS[session]
                    age = time.monotonic() - state['clock'] - timestamp / scale
                    state['ages'].setdefault(group, age)
                allowed = age >= duration / scale and age <= 32
                if not allowed:
                    with SESSION_LOCK:
                        key = 'future_requests' if age < duration / scale else 'expired_requests'
                        state['ages'][key] = state['ages'].get(key, 0) + 1
                return allowed
            current += 1; timestamp += duration
    return False


class Handler(BaseHTTPRequestHandler):
    def license(self, mode, post):
        raw = self.rfile.read(min(128 * 1024 + 1, int(self.headers.get('Content-Length', '0')))) if post else b''
        if mode == 'slow':
            time.sleep(6)
        code, extra = 200, {}
        result = copy.deepcopy(LICENSE)
        if post and self.headers.get('X-License') != 'owned-license':
            code = 403
        if post and self.headers.get('X-Stream') is not None:
            code = 403
        if post:
            try:
                if mode == 'form':
                    raw = base64.b64decode(parse_qs(raw.decode())['challenge'][0])
                elif mode == 'template':
                    raw = base64.b64decode(json.loads(raw)['challenge'])
                request = json.loads(raw)
                if request != {'fixture': 'owned'}:
                    assert request['type'] == 'temporary' and set(request['kids']) == set(KIDS)
            except Exception:
                code = 400
        if mode.startswith('redirect'):
            code = 307 if mode != 'redirect302' else 302
            extra['Location'] = '/license/standard' if mode != 'redirectcross' else 'http://localhost:18761/license/standard'
        if mode == 'loop':
            code, extra['Location'] = 307, '/license/loop'
        if mode == 'missing':
            result['keys'] = result['keys'][:1]
        if mode == 'conflict':
            result['keys'].append({**result['keys'][0], 'k': result['keys'][1]['k']})
        if mode == 'persistent':
            result['type'] = 'persistent-license'
        if mode == 'deny':
            code = 403
        body = json.dumps(result, separators=(',', ':')).encode()
        if mode == 'base64':
            body = base64.b64encode(body)
        elif mode == 'json':
            body = json.dumps({'payload': result}).encode()
        elif mode == 'jsonbase64':
            body = json.dumps({'payload': base64.b64encode(body).decode()}).encode()
        elif mode == 'invalid':
            body = b'<html>not a license</html>'
        elif mode in ['oversize', 'oversizestream']:
            body = b'x' * (1024 * 1024 + 1)
        elif mode == 'cookiecheck':
            body = json.dumps({'cookie_present': self.headers.get('Cookie') is not None}).encode()
        elif mode == 'gzip':
            body = gzip.compress(body)
            extra['Content-Encoding'] = 'gzip'
        if code in [302,307]:
            body = b''
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        if mode != 'oversizestream':
            self.send_header('Content-Length', str(len(body)))
        else:
            self.send_header('Connection', 'close')
            self.close_connection = True
        self.send_header('Set-Cookie', 'owned-fixture=never-retain; Path=/')
        for name, value in extra.items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        path = urlsplit(self.path).path
        if path.startswith('/license/'):
            self.license(path.split('/')[-1], True)
        else:
            self.send_error(404)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path.startswith('/license/'):
            self.license(path.split('/')[-1], False)
            return
        if path.startswith('/licensed/') and path.endswith('/manifest.mpd'):
            if self.headers.get('X-Stream') != 'owned-stream' or self.headers.get('X-License') is not None:
                self.send_error(403); return
            source = ET.parse(ROOT / 'multikey/manifest.mpd')
            for template in source.getroot().iter(f'{{{NS}}}SegmentTemplate'):
                for field in ['initialization', 'media']:
                    template.set(field, '/gzip/multikey/' + template.get(field))
            body, code, kind, encoding = ET.tostring(source.getroot()), 200, 'application/dash+xml', None
        elif path == '/health':
            body, code, kind, encoding = b'fixture ready', 200, 'text/plain', None
        elif path == '/redirect.php':
            self.send_response(302)
            self.send_header('Location', '/gzip/manifest.mpd')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        elif path.startswith('/live/') and path.endswith('/manifest.mpd'):
            session = path.split('/')[2]
            if session.startswith('licensed') and (self.headers.get('X-Stream') != 'owned-stream' or self.headers.get('X-License') is not None):
                self.send_error(403); return
            if not session.isalnum() or len(session) > 64:
                self.send_error(400); return
            body, code, kind, encoding = live_manifest(session), 200, 'application/dash+xml', None
        elif path.startswith('/live/') and path.endswith('/stats'):
            session = path.split('/')[2]
            with SESSION_LOCK:
                stats = dict(SESSIONS.get(session, {}).get('ages', {}))
            body, code, kind, encoding = json.dumps(stats).encode(), 200, 'application/json', None
        else:
            # Incorrect redirect-base resolution must fail, not hit a root alias.
            allowed = True
            if path.startswith('/live/'):
                _, _, session, media = path.split('/', 3)
                if session.startswith('licensed') and (self.headers.get('X-Stream') != 'owned-stream' or self.headers.get('X-License') is not None):
                    self.send_error(403); return
                allowed = live_segment(session, media)
                match = re.fullmatch(r'(video|audio)/chunk-stream0-(\d+)\.m4s', media)
                if match:
                    media = f'{match.group(1)}/chunk-stream0-{int(match.group(2))-SEQUENCE_BASE:05d}.m4s'
                relative = 'live-source/' + media
            else:
                relative = path.removeprefix('/gzip/') if path.startswith('/gzip/') else '_missing_'
            target = (ROOT / relative).resolve()
            if not allowed or ROOT not in target.parents or not target.is_file():
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
