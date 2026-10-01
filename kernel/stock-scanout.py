#!/usr/bin/env python3
"""Reproduce a pinned stock image before assigning its identity to a fresh module."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import zipfile

NOTE = struct.pack('<III', 4, 20, 3) + b'GNU\0'
SOURCES = ('zaparoo_scanout.c', 'zaparoo_scanout_platform.h',
           'zaparoo_scanout_uapi.h', 'Makefile')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def lz4_block(data, limit=8 * 1024 * 1024):
    """Decode a bounded raw LZ4 block; stock ARM zImages use legacy framing."""
    output = bytearray()
    pos = 0

    def length(initial):
        nonlocal pos
        size = initial
        if initial == 15:
            while True:
                require(pos < len(data), 'truncated LZ4 length')
                extra = data[pos]
                pos += 1
                size += extra
                require(size <= limit, 'oversized LZ4 sequence')
                if extra != 255:
                    break
        return size

    while pos < len(data):
        token = data[pos]
        pos += 1
        literals = length(token >> 4)
        require(pos + literals <= len(data), 'truncated LZ4 literals')
        require(len(output) + literals <= limit, 'oversized LZ4 block')
        output.extend(data[pos:pos + literals])
        pos += literals
        if pos == len(data):
            break
        require(pos + 2 <= len(data), 'truncated LZ4 offset')
        offset = struct.unpack_from('<H', data, pos)[0]
        pos += 2
        require(0 < offset <= len(output), 'invalid LZ4 offset')
        count = length(token & 15) + 4
        require(len(output) + count <= limit, 'oversized LZ4 match')
        # LZ4 permits overlap: the existing suffix repeats into the new bytes.
        seed = output[-offset:]
        output.extend((seed * ((count + offset - 1) // offset))[:count])
    return bytes(output)


def stock_image(data, manifest):
    require(sha(data) == manifest['official_image_sha256'], 'official image checksum mismatch')
    pos = manifest['lz4_offset']
    require(data[pos:pos + 4] == b'\x02\x21\x4c\x18', 'missing legacy LZ4 header')
    pos += 4
    image = bytearray()
    while len(image) < manifest['image_bytes']:
        require(pos + 4 <= len(data), 'missing LZ4 block size')
        size = struct.unpack_from('<I', data, pos)[0]
        pos += 4
        require(0 < size <= 9 * 1024 * 1024 and pos + size <= len(data), 'invalid LZ4 block size')
        image.extend(lz4_block(data[pos:pos + size]))
        pos += size
    require(len(image) == manifest['image_bytes'], 'stock Image size mismatch')
    require(sha(image) == manifest['stock_Image_sha256'], 'stock Image checksum mismatch')
    return bytes(image)


def stock_config(image, manifest):
    start = image.find(b'IKCFG_ST')
    end = image.find(b'IKCFG_ED', start + 8)
    require(start >= 0 and end > start, 'missing embedded stock config')
    config = gzip.decompress(image[start + 8:end])
    require(sha(config) == manifest['kernel_config_sha256'], 'stock config checksum mismatch')
    return config


def reproduction(stock, rebuilt, manifest):
    offset = manifest['build_id_offset']
    end = offset + 20
    require(len(stock) == len(rebuilt) == manifest['image_bytes'], 'reproduced Image size mismatch')
    require(stock[offset - len(NOTE):offset] == NOTE, 'stock GNU build-ID note missing')
    require(rebuilt[offset - len(NOTE):offset] == NOTE, 'reproduced GNU build-ID note missing')
    require(stock[offset:end].hex() == manifest['stock_kernel_build_id'], 'stock kernel ID mismatch')
    require(stock[:offset] == rebuilt[:offset] and stock[end:] == rebuilt[end:],
            'reproduced Image differs outside GNU build-ID descriptor')
    normalized = stock[:offset] + bytes(20) + stock[end:]
    require(sha(normalized) == manifest['normalized_Image_sha256'], 'normalized Image checksum mismatch')
    return {
        'stock_kernel_build_id': stock[offset:end].hex(),
        'reproduced_kernel_build_id': rebuilt[offset:end].hex(),
        'stock_Image_sha256': sha(stock),
        'reproduced_Image_sha256': sha(rebuilt),
        'normalized_Image_sha256': sha(normalized),
        'only_difference': {'offset': offset, 'length': 20, 'meaning': 'GNU build-ID descriptor'},
    }


def elf_build_id(path):
    text = subprocess.check_output(['readelf', '-n', str(path)], text=True)
    ids = re.findall(r'Build ID: ([0-9a-f]+)', text)
    require(len(ids) == 1 and re.fullmatch(r'(?:[0-9a-f]{2}){16,64}', ids[0]),
            f'{path}: expected one GNU build ID')
    return ids[0]


def prepare(manifest, official, output):
    image = stock_image(official.read_bytes(), manifest)
    config = stock_config(image, manifest)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'Image.stock').write_bytes(image)
    (output / 'stock.config').write_bytes(config)
    (output / 'utsversion-tmp.h').write_text(
        '#define UTS_VERSION ' + json.dumps(manifest['temporary_uts_version']) + '\n')


def package(manifest_path, official, kernel_build, module_source, output):
    manifest = json.loads(manifest_path.read_text())
    stock = stock_image(official.read_bytes(), manifest)
    rebuilt = (kernel_build / 'arch/arm/boot/Image').read_bytes()
    proof = reproduction(stock, rebuilt, manifest)
    require(elf_build_id(kernel_build / 'vmlinux') == proof['reproduced_kernel_build_id'],
            'vmlinux build ID differs from reproduced Image')
    for file, key in (('.config', 'kernel_config_sha256'), ('Module.symvers', 'kernel_symvers_sha256')):
        require(sha((kernel_build / file).read_bytes()) == manifest[key], f'{file} checksum mismatch')
    release = manifest['kernel_release']
    require((kernel_build / 'include/config/kernel.release').read_text().strip() == release,
            'kernel release mismatch')
    module_path = module_source / 'zaparoo_scanout.ko'
    module = module_path.read_bytes()
    for field, expected in [('name', 'zaparoo_scanout'), ('kernel_revision', manifest['kernel_revision']),
                            ('vermagic', release + ' SMP mod_unload ARMv7 p2v8')]:
        actual = subprocess.check_output(['modinfo', '-F', field, str(module_path)], text=True).strip()
        require(actual == expected, f'module {field} mismatch')
    module_id = elf_build_id(module_path)
    sources = {name: (module_source / name).read_bytes() for name in SOURCES}
    tools = Path(__file__).resolve().parent
    sources.update({
        'stock-manifest.json': manifest_path.read_bytes(),
        'stock-reproduction.json': (json.dumps(proof, indent=2) + '\n').encode(),
        'stock.config': (kernel_build / '.config').read_bytes(),
        'stock-scanout.py': Path(__file__).read_bytes(),
        'build-stock-scanout.sh': (tools / 'build-stock-scanout.sh').read_bytes(),
    })
    provenance = {
        'schema': 1, 'kernel_revision': manifest['kernel_revision'],
        'kernel_build_id': manifest['stock_kernel_build_id'],
        'module_build_id': module_id, 'module_sha256': sha(module),
        'kernel_config_sha256': manifest['kernel_config_sha256'],
        'kernel_symvers_sha256': manifest['kernel_symvers_sha256'],
        'source_sha256': {name: sha(data) for name, data in sources.items()},
        'official_image_url': manifest['official_image_url'],
        'official_image_sha256': manifest['official_image_sha256'],
        'stock_reproduction': proof,
        'qualification': 'Stock Image reproduced except GNU build-ID descriptor. '
                         'New module and matched stack still require device qualification before distribution.',
    }
    prefix = f'modules/{release}/{manifest["stock_kernel_build_id"]}/'
    profile = '\n'.join(['ZAPAROO-SCANOUT-PROFILE-1', release, manifest['stock_kernel_build_id'],
                         module_id, sha(module), manifest['kernel_revision'],
                         'zaparoo-scanout-v1-1080p', ''])
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(prefix + 'profile', profile)
        archive.writestr(prefix + 'zaparoo_scanout.ko', module)
        archive.writestr(prefix + 'provenance.json', json.dumps(provenance, indent=2) + '\n')
        archive.write(module_source / 'README.md', prefix + 'source/README.md')
        for name, data in sorted(sources.items()):
            archive.writestr(prefix + 'source/' + name, data)
    print(f'{output}: verified stock kernel {manifest["stock_kernel_build_id"]}, module {module_id}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    pre = sub.add_parser('prepare')
    pack = sub.add_parser('package')
    for command in (pre, pack):
        command.add_argument('--manifest', required=True, type=Path)
        command.add_argument('--official', required=True, type=Path)
        command.add_argument('--output', required=True, type=Path)
    pack.add_argument('--kernel-build', required=True, type=Path)
    pack.add_argument('--module-source', required=True, type=Path)
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(json.loads(args.manifest.read_text()), args.official, args.output)
    else:
        package(args.manifest, args.official, args.kernel_build, args.module_source, args.output)


if __name__ == '__main__':
    main()
