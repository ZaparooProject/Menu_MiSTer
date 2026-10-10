#!/usr/bin/env python3
"""Package an exact kernel/module pair; this does not establish device qualification."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_id(path):
    notes = subprocess.check_output(['readelf', '-n', str(path)], text=True)
    ids = re.findall(r'Build ID: ([0-9a-f]+)', notes)
    if len(ids) != 1 or not re.fullmatch(r'(?:[0-9a-f]{2}){16,64}', ids[0]):
        raise ValueError(f'{path}: expected one GNU build ID')
    return ids[0]


def package(kernel_build, module, output):
    root = Path(__file__).resolve().parents[1]
    source = root / 'kernel/scanout-slots'
    header = (source / 'zaparoo_scanout_platform.h').read_text()
    revision = re.search(r'ZAPAROO_SCANOUT_KERNEL_REVISION "([0-9a-f]{40})"', header)[1]
    release = re.search(r'ZAPAROO_SCANOUT_KERNEL_RELEASE "([A-Za-z0-9._-]+)"', header)[1]
    if (kernel_build / 'include/config/kernel.release').read_text().strip() != release:
        raise ValueError('kernel release differs from the platform contract')
    def info(field):
        return subprocess.check_output(['modinfo', '-F', field, str(module)], text=True).strip()
    if info('kernel_revision') != revision or info('name') != 'zaparoo_scanout':
        raise ValueError('module identity differs from the platform contract')
    if info('vermagic') != release + ' SMP mod_unload ARMv7 p2v8':
        raise ValueError('unexpected vermagic')
    kernel_id, module_id = build_id(kernel_build / 'vmlinux'), build_id(module)
    profile = '\n'.join(['ZAPAROO-SCANOUT-PROFILE-1', release, kernel_id,
                         module_id, digest(module), revision, 'zaparoo-scanout-v2-native', ''])
    provenance = {
        'schema': 1, 'kernel_revision': revision,
        'kernel_build_id': kernel_id, 'module_build_id': module_id,
        'kernel_config_sha256': digest(kernel_build / '.config'),
        'kernel_symvers_sha256': digest(kernel_build / 'Module.symvers'),
        'module_sha256': digest(module),
        'source_sha256': {p.name: digest(p) for p in sorted(source.iterdir())
                          if p.name in ('zaparoo_scanout.c', 'zaparoo_scanout_platform.h',
                                        'zaparoo_scanout_uapi.h', 'Makefile')},
        'qualification': 'Build provenance only; device qualification is required before distribution.',
    }
    prefix = f'modules/{release}/{kernel_id}/'
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(prefix + 'profile', profile)
        archive.write(module, prefix + 'zaparoo_scanout.ko')
        archive.writestr(prefix + 'provenance.json', json.dumps(provenance, indent=2) + '\n')
        # Ship the matching source and existing attribution alongside the object.
        for name in provenance['source_sha256']:
            archive.write(source / name, prefix + 'source/' + name)
        archive.write(source / 'README.md', prefix + 'source/README.md')
    print(f'{output}: kernel {kernel_id}, module {module_id}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel-build', required=True, type=Path)
    parser.add_argument('--module', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    package(args.kernel_build, args.module, args.output)
