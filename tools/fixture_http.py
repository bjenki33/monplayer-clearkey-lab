"""Loopback-only CI fixture; no external media, credentials or content keys."""
import gzip
import copy
import json
import base64
import re
import socket
import hashlib
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
ROTATED_KID = 'QEFCQ0RFRkdISUpLTE1OTw'
ROTATED_KEY = {'kty': 'oct', 'kid': ROTATED_KID, 'k': 'UFFSU1RVVldYWVpbXF1eXw'}

ROOT = Path(sys.argv[1]).resolve()
NS = 'urn:mpeg:dash:schema:mpd:2011'
ET.register_namespace('', NS)
ET.register_namespace('cenc', 'urn:mpeg:cenc:2013')
SESSIONS = {}
SESSION_LOCK = threading.Lock()
TRANSPORT = {}
SEQUENCE_BASE = 895000000


def live_source(session):
    return 'live-longgop' if session.startswith('nativelonggop') else 'live-source'


def live_manifest(session):
    with SESSION_LOCK:
        state = SESSIONS.setdefault(session, {'clock': time.monotonic() - 120, 'wall': time.time() - 120, 'ages': {}})
        clock, wall = state['clock'], state['wall']
    elapsed = time.monotonic() - clock
    tree = ET.parse(ROOT / live_source(session) / 'manifest.mpd')
    root = tree.getroot()
    with SESSION_LOCK:
        rotated = state.get('rotated', False)
    if rotated:
        for item in root.iter(f'{{{NS}}}AdaptationSet'):
            if item.get('contentType') == 'video':
                for protection in item.findall(f'{{{NS}}}ContentProtection'):
                    protection.set('{urn:mpeg:cenc:2013}default_KID', '40414243-4445-4647-4849-4a4b4c4d4e4f')
                for template in item.iter(f'{{{NS}}}SegmentTemplate'):
                    for field in ['initialization', 'media']:
                        template.set(field, template.get(field).replace('video/', 'rotatedvideo/'))
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
    match = re.fullmatch(r'(video|audio|rotatedvideo)/chunk-stream0-(\d+)\.m4s', media)
    if not match:
        return True
    group, number = match.group(1), int(match.group(2)) - SEQUENCE_BASE
    tree = ET.parse(ROOT / live_source(session) / group / 'manifest.mpd')
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
                    if group == 'rotatedvideo':
                        state['ages']['rotated_requests'] = state['ages'].get('rotated_requests', 0) + 1
                allowed = age >= duration / scale and age <= 32
                if not allowed:
                    with SESSION_LOCK:
                        key = 'future_requests' if age < duration / scale else 'expired_requests'
                        state['ages'][key] = state['ages'].get(key, 0) + 1
                return allowed
            current += 1; timestamp += duration
    return False


class Handler(BaseHTTPRequestHandler):
    def body_fault(self, session, media, body):
        if not session.startswith('body') or not re.fullmatch(r'video/chunk-stream0-\d+\.m4s', media):
            return False
        etag = '"' + hashlib.sha256(body).hexdigest() + '"'
        with SESSION_LOCK:
            state = SESSIONS[session]
            fault = state.setdefault('fault', {'armed': session.startswith('bodyinitial'),
                                               'target': None, 'attempts': 0})
            if not fault['armed']:
                return False
            if fault['target'] is None:
                fault['target'] = media
                fault['delivered'] = 0
            if media != fault['target']:
                return False
            fault['attempts'] += 1
            attempt = fault['attempts']
            stats = state['ages']
            stats['body_attempts'] = attempt
            stats['body_wrong_headers'] = stats.get('body_wrong_headers', 0) + int(
                self.headers.get('X-Stream') != 'owned-stream' or self.headers.get('X-License') is not None)
            match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
            offset = int(match.group(1)) if match else 0
            if attempt > 1:
                wrong = not match or offset != fault['delivered'] or int(match.group(2) or len(body)-1) != len(body)-1
                stats['body_wrong_offset'] = stats.get('body_wrong_offset', 0) + int(wrong)
                stats['body_wrong_validator'] = stats.get('body_wrong_validator', 0) + int(self.headers.get('If-Range') != etag)
                stats['body_positive_offsets'] = stats.get('body_positive_offsets', 0) + int(offset > 0)
            else:
                stats['body_initial_range'] = int(match is not None or self.headers.get('If-Range') is not None)
            cut = attempt <= 2 or session.endswith(('always', 'slow', 'trickle'))
            stats['body_cuts'] = stats.get('body_cuts', 0) + int(cut)
            stats['body_successes'] = stats.get('body_successes', 0) + int(not cut)
        if attempt > 1 and session.endswith('slow'):
            time.sleep(6)
        if attempt > 1 and session.endswith('deny'):
            self.send_error(403); return True
        code = 206 if match else 200
        if attempt > 1 and session.endswith('ignored'):
            code, offset = 200, 0
        headers = {'ETag': etag, 'Content-Length': str(len(body)-offset)}
        if match and code == 206:
            start = offset + int(session.endswith('wrongstart'))
            total = len(body) + int(session.endswith('wrongtotal'))
            end = len(body)-1-int(session.endswith('wrongend'))
            headers['Content-Range'] = f'bytes {start}-{end}/{total}'
            if session.endswith('overflow'):
                headers['Content-Range'] = f'bytes {start}-{end}/999999999999999999999999999999999999'
        if session.endswith('weak'):
            headers['ETag'] = 'W/' + etag
        if session.endswith('missing'):
            headers.pop('ETag')
        if session.endswith('unknown'):
            headers.pop('Content-Length')
        if session.endswith('encoded'):
            headers['Content-Encoding'] = 'owned-unsupported'
        if attempt > 1 and session.endswith('changed'):
            headers['ETag'] = '"owned-changed"'
        if attempt > 1 and session.endswith('wronglength'):
            headers['Content-Length'] = str(len(body)-offset+1)
        remaining = body[offset:]
        payload = remaining[:max(1, len(remaining)//2)] if cut else remaining
        with SESSION_LOCK:
            fault['delivered'] = offset + len(payload)
            stats['body_total'] = len(body)
            stats['body_delivered'] = fault['delivered']
        try:
            self.send_response(code)
            self.send_header('Content-Type', 'video/iso.segment')
            self.send_header('Connection', 'close')
            for key, value in headers.items():
                self.send_header(key, value)
            if attempt > 1 and session.endswith('duplicate'):
                self.send_header('ETag', etag)
            self.end_headers()
            if attempt > 1 and session.endswith('trickle'):
                for byte in payload:
                    self.wfile.write(bytes([byte])); self.wfile.flush(); time.sleep(0.3)
            else:
                self.wfile.write(payload); self.wfile.flush()
            if cut:
                self.connection.shutdown(socket.SHUT_RDWR)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True
        return True

    def fragment_fault(self, session, media):
        if not session.startswith('segment'):
            return False
        with SESSION_LOCK:
            state = SESSIONS[session]
            fault = state.setdefault('fault', {'armed': session.startswith('segmentinit'),
                                               'target': None, 'attempts': 0})
            if not fault['armed'] or not media.startswith('video/'):
                return False
            if fault['target'] is None:
                fault['target'] = media
                fault['range'] = self.headers.get('Range')
            if media != fault['target']:
                return False
            fault['attempts'] += 1
            attempt = fault['attempts']
            stats = state['ages']
            stats['fault_attempts'] = attempt
            stats['fault_offset_changed'] = stats.get('fault_offset_changed', 0) + int(self.headers.get('Range') != fault['range'])
            stats['fault_wrong_headers'] = stats.get('fault_wrong_headers', 0) + int(
                self.headers.get('X-Stream') != 'owned-stream' or self.headers.get('X-License') is not None)
            failed = attempt <= 2 or session.endswith(('always', 'deny', 'server', 'slow', 'trickle'))
            if failed:
                stats['fault_failures'] = stats.get('fault_failures', 0) + 1
            else:
                stats['fault_successes'] = stats.get('fault_successes', 0) + 1
        if not failed:
            return False
        if session.endswith(('deny', 'server')):
            self.send_error(403 if session.endswith('deny') else 503)
        else:
            if session.endswith('trickle') and attempt > 1:
                try:
                    for byte in b'HTTP/1.1 200 OK\r\nX-Owned-Trickle: ' + b'x' * 80:
                        self.wfile.write(bytes([byte])); self.wfile.flush()
                        time.sleep(0.3)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                self.close_connection = True
                return True
            if session.endswith('slow') and attempt > 1:
                time.sleep(6)
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR); self.connection.close()
            except OSError:
                pass
        return True

    def transport(self, session, mode, post=False):
        if mode == 'stats':
            with SESSION_LOCK:
                result = copy.deepcopy(TRANSPORT.get(session, {}))
            body, code, extra = json.dumps(result).encode(), 200, {}
        else:
            if post:
                self.rfile.read(min(128 * 1024, int(self.headers.get('Content-Length', '0'))))
            with SESSION_LOCK:
                state = TRANSPORT.setdefault(session, {'attempts': 0, 'times': [], 'cookies': 0,
                                                       'wrong_headers': 0, 'methods': []})
                state['attempts'] += 1
                attempt = state['attempts']
                state['times'].append(time.monotonic())
                state['methods'].append('POST' if post else 'GET')
                state['cookies'] += int(self.headers.get('Cookie') is not None)
                state['wrong_headers'] += int(self.headers.get('X-Stream') != 'owned-stream' or
                                              self.headers.get('X-License') is not None)
                if session in ['alpha', 'beta']:
                    state['wrong_headers'] += int(self.headers.get('X-Owned') != session)
            body, code, extra = b'<MPD/>', 200, {}
            if mode in ['recover', 'always', 'rate', 'longwait', 'invalidwait', 'deadline', 'cancelwait']:
                if mode == 'always' or attempt <= (2 if mode == 'recover' else 1):
                    body, code = b'temporary owned outage', 503
                    wait = {'rate': '1', 'longwait': '120', 'invalidwait': 'not-a-time',
                            'deadline': '1', 'cancelwait': '2'}.get(mode)
                    if wait:
                        extra['Retry-After'] = wait
            elif mode in ['401', '403', '404', '500']:
                body, code = b'owned denied', int(mode)
            elif mode == 'drop' and attempt == 1:
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR); self.connection.close()
                return
            elif mode == 'partial' and attempt == 1:
                body, extra['partial'] = b'bad-prefix', '1'
            elif mode == 'slow':
                time.sleep(6)
            elif mode == 'oversize':
                body = b'x' * 2049
            elif mode == 'invalidmanifest':
                body = b'<html>not media</html>'
        self.send_response(code)
        self.send_header('Content-Type', 'application/dash+xml')
        self.send_header('Set-Cookie', 'owned-transport=never-retain; Path=/')
        self.send_header('Content-Length', str(len(body) + (5 if extra.pop('partial', None) else 0)))
        self.send_header('Connection', 'close'); self.close_connection = True
        for name, value in extra.items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def renewal(self, session):
        raw = self.rfile.read(min(128 * 1024 + 1, int(self.headers.get('Content-Length', '0'))))
        with SESSION_LOCK:
            state = SESSIONS.get(session)
            if state is None:
                self.send_error(404); return
            rotated = state.get('rotated', False)
        try:
            request = json.loads(raw)
            wanted = {ROTATED_KID if rotated else KIDS[0], KIDS[1]}
            assert self.headers.get('X-License') == 'owned-license' and self.headers.get('X-Stream') is None
            assert request['type'] == 'temporary' and set(request['kids']) == wanted
        except Exception:
            self.send_error(400); return
        with SESSION_LOCK:
            state['ages']['license_requests'] = state['ages'].get('license_requests', 0) + 1
            if rotated:
                state['ages']['new_key_requests'] = state['ages'].get('new_key_requests', 0) + 1
        if rotated and session.endswith('slow'):
            time.sleep(6)
        if rotated and session.endswith('denied'):
            self.send_error(403); return
        keys = [ROTATED_KEY if rotated else LICENSE['keys'][0], LICENSE['keys'][1]]
        if rotated and session.endswith('missing'):
            keys = keys[1:]
        if rotated and session.endswith('conflict'):
            keys.append({**LICENSE['keys'][1], 'k': ROTATED_KEY['k']})
        body = json.dumps({'keys': keys, 'type': 'temporary'}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

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
        if path.startswith('/transport/'):
            self.transport(*path.split('/')[2:4], post=True)
        elif path.startswith('/fault/') and path.endswith('/arm'):
            session = path.split('/')[2]
            with SESSION_LOCK:
                state = SESSIONS.get(session)
                if state is not None:
                    state['fault'] = {'armed': True, 'target': None, 'attempts': 0}
            self.send_response(204 if state is not None else 404)
            self.send_header('Content-Length', '0'); self.end_headers()
        elif path.startswith('/renew/'):
            self.renewal(path.split('/')[-1])
        elif path.startswith('/rotate/') and path.endswith('/advance'):
            session = path.split('/')[2]
            with SESSION_LOCK:
                state = SESSIONS.get(session)
                if state is not None:
                    state['rotated'] = True
            self.send_response(204 if state is not None else 404)
            self.send_header('Content-Length', '0'); self.end_headers()
        elif path.startswith('/license/'):
            self.license(path.split('/')[-1], True)
        else:
            self.send_error(404)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path.startswith('/native/'):
            parts = path.split('/')
            if len(parts) != 4 or not parts[2].isalnum() or len(parts[2]) > 64:
                self.send_error(400); return
            session, mode = parts[2:]
            if mode == 'redirect':
                self.send_response(307); self.send_header('Location', f'/native/{session}/list.m3u')
                self.send_header('Content-Length', '0'); self.end_headers(); return
            tags = ('#KODIPROP:inputstream.adaptive.license_type=clearkey\n'
                    '#KODIPROP:inputstream.adaptive.license_key=000102030405060708090a0b0c0d0e0f:101112131415161718191a1b1c1d1e1f,'
                    '202122232425262728292a2b2c2d2e2f:303132333435363738393a3b3c3d3e3f\n')
            if mode == 'plain':
                tags = ''
            body = (f'#EXTM3U\n#EXTINF:-1,Owned native import\n{tags}../../live/{session}/manifest.mpd\n').encode()
            self.send_response(403 if mode == 'denied' else 200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            self.send_header('X-Owned-Header', self.headers.get('X-Owned', 'none'))
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        if path.startswith('/transport/'):
            self.transport(*path.split('/')[2:4]); return
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
            if session == 'transportengine':
                with SESSION_LOCK:
                    state = TRANSPORT.setdefault(session, {'attempts': 0, 'failures': 0})
                    state['attempts'] += 1
                    failed = state['attempts'] <= 2
                    if failed:
                        state['failures'] += 1
                if failed:
                    self.send_error(503); return
            if session.startswith(('licensed', 'rotation', 'segment', 'body')) and (self.headers.get('X-Stream') != 'owned-stream' or self.headers.get('X-License') is not None):
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
                if session.startswith(('licensed', 'rotation', 'segment', 'body')) and (self.headers.get('X-Stream') != 'owned-stream' or self.headers.get('X-License') is not None):
                    self.send_error(403); return
                allowed = live_segment(session, media)
                if allowed and self.fragment_fault(session, media):
                    return
                requested_media = media
                match = re.fullmatch(r'(video|audio|rotatedvideo)/chunk-stream0-(\d+)\.m4s', media)
                if match:
                    media = f'{match.group(1)}/chunk-stream0-{int(match.group(2))-SEQUENCE_BASE:05d}.m4s'
                relative = live_source(session) + '/' + media
            else:
                relative = path.removeprefix('/gzip/') if path.startswith('/gzip/') else '_missing_'
            target = (ROOT / relative).resolve()
            if not allowed or ROOT not in target.parents or not target.is_file():
                body, code, kind, encoding = b'missing fixture', 404, 'text/plain', None
            else:
                body, code = target.read_bytes(), 200
                if path.startswith('/live/') and self.body_fault(session, requested_media, body):
                    return
                kind = {'.mpd': 'application/dash+xml', '.m3u8': 'application/vnd.apple.mpegurl',
                        '.mp4': 'video/mp4'}.get(target.suffix, 'video/iso.segment')
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
