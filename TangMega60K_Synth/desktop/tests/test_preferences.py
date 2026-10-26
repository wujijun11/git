"""本机偏好实际文件读写测试，路径仅为测试临时目录，不访问用户配置。"""
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from preferences import Preferences, validate_bindings


class PreferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='TangKeys_')
        self.store = Preferences(self.temporary.name)
        self.codes = [f'Key{chr(65 + i)}' for i in range(25)]

    def tearDown(self):
        self.temporary.cleanup()

    def test_restart_loads_exact_saved_layout(self):
        self.assertIsNone(self.store.load_bindings()['codes'])
        self.codes[2] = None
        self.store.save_bindings(self.codes)
        reopened = Preferences(self.temporary.name)
        self.assertEqual(reopened.load_bindings()['codes'], self.codes)
        self.assertEqual(list(Path(self.temporary.name).glob('*.tmp')), [])

    def test_bad_input_never_overwrites_valid_file(self):
        self.store.save_bindings(self.codes)
        original = self.store.path.read_bytes()
        for bad in [[], self.codes[:-1], self.codes[:1] * 25, ['Escape'] + [None] * 24,
                    [False] + [None] * 24, [{}] + [None] * 24]:
            with self.assertRaises(ValueError):
                self.store.save_bindings(bad)
            self.assertEqual(self.store.path.read_bytes(), original)

    def test_corrupt_settings_warn_and_preserve_original(self):
        for data in [b'broken', b'[]', b'{"version":2}', b'x' * 16385]:
            self.store.path.write_bytes(data)
            result = self.store.load_bindings()
            self.assertTrue(result['ok'])
            self.assertIsNone(result['codes'])
            self.assertIn('warning', result)
            self.assertEqual(self.store.path.read_bytes(), data)

    def test_symbol_and_numeric_keys_supported(self):
        self.assertEqual(validate_bindings(['Slash', 'Digit0', 'Numpad0'] + [None] * 22)[:3],
                         ['Slash', 'Digit0', 'Numpad0'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
