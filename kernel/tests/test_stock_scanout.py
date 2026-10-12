"""Reject stock identity substitutions unless the entire loaded image reproduces."""
import gzip
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location('stock_scanout', Path(__file__).resolve().parents[1] / 'stock-scanout.py')
stock = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stock)


def literal_block(data):
    if len(data) < 15:
        return bytes([len(data) << 4]) + data
    extra = len(data) - 15
    return b'\xf0' + b'\xff' * (extra // 255) + bytes([extra % 255]) + data


class StockTests(unittest.TestCase):
    def setUp(self):
        self.config = b'CONFIG_SMP=y\n'
        self.image = (b'kernel-prefix' + stock.NOTE + bytes.fromhex('ab' * 20)
                      + b'IKCFG_ST' + gzip.compress(self.config) + b'IKCFG_ED' + b'kernel-tail')
        offset = self.image.index(stock.NOTE) + len(stock.NOTE)
        block = literal_block(self.image)
        self.official = b'prefix' + b'\x02\x21\x4c\x18' + struct.pack('<I', len(block)) + block
        self.manifest = {
            'name': 'stock-test', 'official_image_sha256': stock.sha(self.official),
            'stock_Image_sha256': stock.sha(self.image),
            'kernel_config_sha256': stock.sha(self.config),
            'stock_kernel_build_id': 'ab' * 20, 'build_id_offset': offset,
            'image_bytes': len(self.image), 'lz4_offset': 6,
            'normalized_Image_sha256': stock.sha(self.image[:offset] + bytes(20) + self.image[offset + 20:]),
        }

    def test_legacy_lz4_and_embedded_config(self):
        image = stock.stock_image(self.official, self.manifest)
        self.assertEqual(image, self.image)
        self.assertEqual(stock.stock_config(image, self.manifest), self.config)

    def test_overlapping_lz4_match(self):
        self.assertEqual(stock.lz4_block(b'\x12a\x01\x00'), b'a' * 7)

    def test_malformed_lz4(self):
        for data in (b'\xf0', b'\x20a', b'\x10a\x00\x00', b'\x10a\x02\x00', b'\x10a\x01'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                stock.lz4_block(data)
        with self.assertRaises(ValueError):
            stock.lz4_block(b'\x12a\x01\x00', limit=6)

    def test_official_hash_must_match_before_decompression(self):
        with self.assertRaisesRegex(ValueError, 'official image checksum'):
            stock.stock_image(self.official + b'changed', self.manifest)

    def test_declared_image_size_and_hash_checked(self):
        for key, value in [('image_bytes', 1), ('stock_Image_sha256', '0' * 64)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                stock.stock_image(self.official, {**self.manifest, key: value})

    def test_config_hash_must_match(self):
        with self.assertRaisesRegex(ValueError, 'stock config checksum'):
            stock.stock_config(self.image, {**self.manifest, 'kernel_config_sha256': '0' * 64})

    def test_only_build_id_descriptor_may_differ(self):
        offset = self.manifest['build_id_offset']
        rebuilt = self.image[:offset] + b'\xcd' * 20 + self.image[offset + 20:]
        proof = stock.reproduction(self.image, rebuilt, self.manifest)
        self.assertEqual(proof['stock_kernel_build_id'], 'ab' * 20)
        self.assertEqual(proof['reproduced_kernel_build_id'], 'cd' * 20)
        self.assertNotEqual(proof['stock_Image_sha256'], proof['reproduced_Image_sha256'])
        for where in (0, offset - 1, offset + 20, len(rebuilt) - 1):
            bad = bytearray(rebuilt)
            bad[where] ^= 1
            with self.subTest(where=where), self.assertRaises(ValueError):
                stock.reproduction(self.image, bytes(bad), self.manifest)

    def test_identical_images_allowed(self):
        stock.reproduction(self.image, self.image, self.manifest)

    def test_wrong_stock_identity_rejected(self):
        with self.assertRaisesRegex(ValueError, 'stock kernel ID'):
            stock.reproduction(self.image, self.image, {**self.manifest, 'stock_kernel_build_id': 'cd' * 20})

    def test_wrong_normalized_hash_rejected(self):
        with self.assertRaisesRegex(ValueError, 'normalized Image'):
            stock.reproduction(self.image, self.image, {**self.manifest, 'normalized_Image_sha256': '0' * 64})

    def test_changed_image_size_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Image size'):
            stock.reproduction(self.image, self.image + b'\0', self.manifest)

    def test_prepare_extracts_only_verified_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            official = root / 'official'
            official.write_bytes(self.official)
            stock.prepare({**self.manifest, 'temporary_uts_version': '# SMP '}, official, root / 'inputs')
            self.assertEqual((root / 'inputs/stock.config').read_bytes(), self.config)
            self.assertEqual((root / 'inputs/utsversion-tmp.h').read_text(), '#define UTS_VERSION "# SMP "\n')

    def test_package_records_both_ids_and_rejects_wrong_symbols_or_module(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / 'build'
            source = root / 'module'
            (build / 'arch/arm/boot').mkdir(parents=True)
            (build / 'include/config').mkdir(parents=True)
            source.mkdir()
            offset = self.manifest['build_id_offset']
            (build / 'arch/arm/boot/Image').write_bytes(self.image[:offset] + b'\xcd' * 20 + self.image[offset + 20:])
            (build / 'include/config/kernel.release').write_text('6.18.38-MiSTer\n')
            (build / '.config').write_bytes(self.config)
            (build / 'Module.symvers').write_bytes(b'symbols')
            for name in (*stock.SOURCES, 'README.md', 'zaparoo_scanout.ko'):
                (source / name).write_bytes(name.encode())
            official = root / 'official'
            official.write_bytes(self.official)
            manifest = {**self.manifest, 'kernel_release': '6.18.38-MiSTer',
                        'kernel_revision': 'a' * 40, 'kernel_symvers_sha256': stock.sha(b'symbols'),
                        'official_image_url': 'https://example.invalid/stock'}
            path = root / 'manifest.json'
            path.write_text(json.dumps(manifest))
            module_info = {'name': 'zaparoo_scanout', 'kernel_revision': 'a' * 40,
                           'vermagic': '6.18.38-MiSTer SMP mod_unload ARMv7 p2v8'}
            with patch.object(stock, 'elf_build_id', side_effect=lambda p: 'cd' * 20 if p.name == 'vmlinux' else 'ef' * 20), \
                    patch.object(stock.subprocess, 'check_output', side_effect=lambda args, **kw: module_info[args[2]]):
                output = root / 'bundle.zip'
                stock.package(path, official, build, source, output)
                with zipfile.ZipFile(output) as archive:
                    prefix = 'modules/6.18.38-MiSTer/' + 'ab' * 20 + '/'
                    provenance = json.loads(archive.read(prefix + 'provenance.json'))
                    self.assertEqual(provenance['kernel_build_id'], 'ab' * 20)
                    self.assertEqual(provenance['stock_reproduction']['reproduced_kernel_build_id'], 'cd' * 20)
                    for name, digest in provenance['source_sha256'].items():
                        self.assertEqual(stock.sha(archive.read(prefix + 'source/' + name)), digest)
                module_info['kernel_revision'] = 'b' * 40
                with self.assertRaisesRegex(ValueError, 'module kernel_revision'):
                    stock.package(path, official, build, source, root / 'bad-module.zip')
                (build / 'Module.symvers').write_bytes(b'wrong')
                with self.assertRaisesRegex(ValueError, 'Module.symvers checksum'):
                    stock.package(path, official, build, source, root / 'bad-symbols.zip')
                self.assertFalse((root / 'bad-module.zip').exists())
                self.assertFalse((root / 'bad-symbols.zip').exists())


if __name__ == '__main__':
    unittest.main()
