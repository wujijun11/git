"""只验证曲库诊断与错误传播，不联网、不连接硬件。"""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from score_library.diagnostics import check_catalog, error_summary
from score_library.mutopia import MutopiaCatalog


class CatalogDiagnosticTests(unittest.TestCase):
    def test_cached_cards_never_count_as_live_network_success(self):
        with patch('score_library.diagnostics.ScoreLibrary') as factory:
            library = factory.return_value
            library.catalog.search.return_value = {
                'items': [{'title': 'old'}], 'cached': True, 'offline': True,
                'offlineReason': 'TimeoutError: timed out',
            }
            library.recommend.return_value = library.catalog.search.return_value
            report = check_catalog(Path('unused-test-cache'))
        self.assertFalse(report['ok'])
        self.assertFalse(report['hardwareAccessed'])
        self.assertTrue(all(not item['ok'] for item in report['checks']))
        self.assertIn('timed out', report['checks'][0]['error'])

    def test_success_requires_nonempty_uncached_network_results(self):
        with patch('score_library.diagnostics.ScoreLibrary') as factory:
            library = factory.return_value
            library.catalog.search.return_value = {'items': [{'title': 'live'}]}
            library.recommend.return_value = {'items': [{'title': 'live'}]}
            report = check_catalog(Path('unused-test-cache'))
            library.catalog.search.assert_called_once_with('piano', 0, refresh=True)
            library.recommend.assert_called_once_with(0, True)
        self.assertTrue(report['ok'])

    def test_fallback_preserves_underlying_network_error(self):
        with tempfile.TemporaryDirectory() as folder:
            catalog = MutopiaCatalog(folder)
            markup = b'<table class="result-table"><td>Old</td><td>Author</td><td></td><td></td><td>for Piano</td></table>'
            with patch('score_library.mutopia.download', return_value=markup):
                catalog.search('piano')
            with patch('score_library.mutopia.download', side_effect=URLError(TimeoutError('timed out'))):
                result = catalog.search('piano', refresh=True)
        self.assertTrue(result['offline'])
        self.assertEqual(result['offlineReason'], 'TimeoutError: timed out')
        self.assertEqual(result['items'][0]['title'], 'Old')

    def test_creation_errors_are_reported_and_details_are_bounded(self):
        with patch('score_library.diagnostics.ScoreLibrary', side_effect=PermissionError('denied')):
            result = check_catalog(Path('unused-test-cache'))
        self.assertFalse(result['ok'])
        self.assertIn('PermissionError', result['error'])
        self.assertLessEqual(len(error_summary(OSError('x' * 900))), 500)


if __name__ == '__main__':
    unittest.main(verbosity=2)
