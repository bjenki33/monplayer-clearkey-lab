"""Rebuild only LGPL FFmpeg core; replace the package's GPL/nonfree binaries."""
import hashlib
import os
import re
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

SHA256 = '488c76e57dd9b3bee901f71d5c95eaf1db4a5a31fe46a28654e837144207c270'
LIBS = ['avcodec', 'avfilter', 'avformat', 'avutil', 'swresample', 'swscale']


def run(*args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True)


def main():
    root = Path('build/ffmpeg-lgpl').resolve()
    source = root / 'ffmpeg-6.1'
    root.mkdir(parents=True, exist_ok=True)
    archive = root / 'ffmpeg-6.1.tar.xz'
    if not archive.exists():
        urllib.request.urlretrieve('https://ffmpeg.org/releases/ffmpeg-6.1.tar.xz', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('Official source checksum mismatch')
    if not source.exists():
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                target = (root / member.name).resolve()
                if root not in target.parents or member.issym() or member.islnk():
                    raise RuntimeError('Unsafe source archive')
            tar.extractall(root)
    package = Path('build/packages/checkouts/FFmpegKit').resolve()
    if not (package / 'Sources').is_dir():
        raise RuntimeError('Resolve pinned Swift package first')
    triples = [('device', 'iphoneos', 'arm64', 'arm64-apple-ios15.5'),
               ('sim-arm64', 'iphonesimulator', 'arm64', 'arm64-apple-ios15.5-simulator'),
               ('sim-x64', 'iphonesimulator', 'x86_64', 'x86_64-apple-ios15.5-simulator')]
    for label, sdk_name, arch, triple in triples:
        prefix = root / 'output' / label
        if not all((prefix / 'lib' / f'lib{x}.a').is_file() for x in LIBS):
            build = root / label; build.mkdir(parents=True, exist_ok=True)
            sdk = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'], text=True).strip()
            clang = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--find', 'clang'], text=True).strip()
            pc = build / 'pkgconfig'; pc.mkdir(exist_ok=True)
            (pc / 'libxml-2.0.pc').write_text(
                f'prefix={sdk}/usr\nlibdir=${{prefix}}/lib\nincludedir=${{prefix}}/include/libxml2\n'
                'Name: libxml2\nDescription: Apple SDK XML library\nVersion: 2.9.4\nLibs: -lxml2\nCflags: -I${includedir}\n')
            env = os.environ.copy(); env['PKG_CONFIG_LIBDIR'] = str(pc); env['PKG_CONFIG_PATH'] = str(pc)
            args = [str(source / 'configure'), '--prefix=' + str(prefix), '--arch=' + arch,
                    '--target-os=darwin', '--enable-cross-compile', '--sysroot=' + sdk,
                    '--cc=' + clang, '--cxx=' + clang.replace('/clang', '/clang++'),
                    '--extra-cflags=-target ' + triple, '--extra-ldflags=-target ' + triple,
                    '--disable-gpl', '--disable-nonfree', '--disable-version3',
                    '--disable-autodetect', '--disable-programs', '--disable-doc', '--disable-debug',
                    '--disable-shared', '--enable-static', '--enable-pic', '--enable-securetransport',
                    '--enable-videotoolbox', '--enable-audiotoolbox', '--enable-libxml2',
                    '--disable-avdevice', '--disable-indevs', '--disable-outdevs',
                    '--disable-decoders', '--enable-decoder=h264,hevc,aac,aac_latm,ac3,eac3,mp3,mp3float,opus,vorbis,flac,alac,pcm_s16le,pcm_s16be',
                    '--disable-encoders', '--enable-encoder=aac,pcm_s16le',
                    '--disable-demuxers', '--enable-demuxer=dash,hls,mov,mpegts,matroska,aac,ac3,eac3,mp3,ogg,flac,wav',
                    '--disable-muxers', '--enable-muxer=mov,mp4,mpegts,matroska']
            run(*args, cwd=build, env=env)
            config = (build / 'ffbuild/config.mak').read_text()
            if re.search(r'(?m)^CONFIG_(GPL|NONFREE|VERSION3)=yes$', config):
                raise RuntimeError('Unapproved FFmpeg license configuration')
            run('make', '-j', str(max(2, os.cpu_count() or 2)), cwd=build, env=env)
            run('make', 'install', cwd=build, env=env)
        for lib in LIBS:
            framework = f'Lib{lib}.framework'
            slice_name = 'ios-arm64_arm64e' if label == 'device' else 'ios-arm64_x86_64-simulator'
            target = package / 'Sources' / f'Lib{lib}.xcframework' / slice_name / framework / f'Lib{lib}'
            if label == 'device':
                shutil.copy2(prefix / 'lib' / f'lib{lib}.a', target)
    for lib in LIBS:
        target = package / 'Sources' / f'Lib{lib}.xcframework/ios-arm64_x86_64-simulator/Lib{lib}.framework/Lib{lib}'
        run('lipo', '-create', str(root / 'output/sim-arm64/lib' / f'lib{lib}.a'),
            str(root / 'output/sim-x64/lib' / f'lib{lib}.a'), '-output', str(target))
    for label, *_ in triples:
        notice = root / 'output' / label / 'LICENSE.LGPLv2.1'
        shutil.copy2(source / 'COPYING.LGPLv2.1', notice)
    print('PASS: device and simulator package cores replaced by rebuilt LGPL FFmpeg6.1')


if __name__ == '__main__':
    main()
