"""Generate only owned colors/sine waves with published synthetic test keys."""
import copy
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET


KID1 = '000102030405060708090a0b0c0d0e0f'
KEY1 = '101112131415161718191a1b1c1d1e1f'
KID2 = '202122232425262728292a2b2c2d2e2f'
KEY2 = '303132333435363738393a3b3c3d3e3f'
NS = 'urn:mpeg:dash:schema:mpd:2011'
CENC = 'urn:mpeg:cenc:2013'
ET.register_namespace('', NS)
ET.register_namespace('cenc', CENC)


def ffmpeg(*args):
    values = [arg.as_posix() if isinstance(arg, Path) else str(arg) for arg in args]
    subprocess.run(['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', *values], check=True)


def dash(path, media_args, kid=None, key=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    options = ['-f', 'dash', '-seg_duration', '1', '-use_template', '1', '-use_timeline', '1']
    if kid:
        options += ['-format_options', f'encryption_scheme=cenc-aes-ctr:encryption_key={key}:encryption_kid={kid}']
    ffmpeg(*media_args, *options, path)


def adaptation(path, prefix, new_id, kid):
    item = copy.deepcopy(ET.parse(path).getroot().find(f'{{{NS}}}Period/{{{NS}}}AdaptationSet'))
    item.set('id', str(new_id))
    for rep in item.findall(f'{{{NS}}}Representation'):
        old_id = rep.attrib['id']
        for template in rep.findall(f'{{{NS}}}SegmentTemplate'):
            for field in ['initialization', 'media']:
                template.set(field, prefix + template.attrib[field].replace('$RepresentationID$', old_id))
        rep.set('id', str(new_id))
    uuid = '-'.join([kid[:8], kid[8:12], kid[12:16], kid[16:20], kid[20:]])
    ET.SubElement(item, f'{{{NS}}}ContentProtection', {
        'schemeIdUri': 'urn:mpeg:dash:mp4protection:2011', 'value': 'cenc', f'{{{CENC}}}default_KID': uuid,
    })
    return item


def main(root):
    root = Path(root)
    video = ['-f', 'lavfi', '-i', 'color=red:size=128x72:rate=10', '-t', '3',
             '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-g', '10', '-an']
    dash(root / 'manifest.mpd', video, KID1, KEY1)
    multi = root / 'multikey'
    dash(multi / 'video/manifest.mpd', video, KID1, KEY1)
    audio = ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '3',
             '-c:a', 'aac', '-ac', '1', '-b:a', '96k', '-vn']
    dash(multi / 'audio/manifest.mpd', audio, KID2, KEY2)
    dash(multi / 'reference/manifest.mpd', audio)
    reference = multi / 'reference'
    # Homebrew's host FFmpeg may omit the DASH reader; MOV still reads these
    # exact owned fragmented-MP4 packets without changing the audio reference.
    reference_movie = reference / 'reference.mp4'
    fragments = [reference / 'init-stream0.m4s', *sorted(reference.glob('chunk-stream0-*.m4s'))]
    reference_movie.write_bytes(b''.join(part.read_bytes() for part in fragments))
    ffmpeg('-i', reference_movie, '-map', '0:a:0', '-c:a', 'pcm_f32le',
           '-f', 'f32le', multi / 'audio-reference.f32')
    manifest = ET.parse(multi / 'video/manifest.mpd')
    period = manifest.getroot().find(f'{{{NS}}}Period')
    for child in list(period):
        period.remove(child)
    period.append(adaptation(multi / 'video/manifest.mpd', 'video/', 0, KID1))
    period.append(adaptation(multi / 'audio/manifest.mpd', 'audio/', 1, KID2))
    manifest.write(multi / 'manifest.mpd', encoding='utf-8', xml_declaration=True)
    variants = copy.deepcopy(manifest)
    video_group = variants.getroot().find(f'{{{NS}}}Period/{{{NS}}}AdaptationSet')
    selected = video_group.find(f'{{{NS}}}Representation')
    selected.set('id', 'selected')
    selected.set('height', '720')
    selected.set('bandwidth', '2000000')
    for name, height in [('unused-low', '240'), ('unused-mid', '480')]:
        unused = copy.deepcopy(selected)
        unused.set('id', name); unused.set('height', height)
        unused.set('bandwidth', '500000')
        for template in unused.findall(f'{{{NS}}}SegmentTemplate'):
            template.set('initialization', name + '/missing-init.m4s')
            template.set('media', name + '/missing-$Number$.m4s')
        video_group.insert(0, unused)
    variants.write(multi / 'variants.mpd', encoding='utf-8', xml_declaration=True)
    for directory in [root, multi / 'video', multi / 'audio']:
        assert any(b'tenc' in x.read_bytes() or b'senc' in x.read_bytes() for x in directory.glob('*.m4s')), 'fixture is not encrypted'
    assert (multi / 'audio-reference.f32').stat().st_size > 48000 * 4, 'missing owned audio reference'
    print('PASS: generated owned single-key and two-distinct-key audio/video CENC fixtures')


if __name__ == '__main__':
    main(sys.argv[1])
