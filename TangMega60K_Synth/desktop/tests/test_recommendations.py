"""推荐业务和强制刷新测试：网络用替身，缓存用独立临时目录。"""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from score_library.recommendations import recommend, select_items
from score_library.mutopia import MutopiaCatalog
from score_library.service import ScoreLibrary


def item(index, instrument='for Piano', midi=True):
    return {'title':f'曲目{index}', 'composer':'测试作者', 'instruments':instrument,
            'midiUrl':f'https://www.mutopiaproject.org/test{index}.mid' if midi else None,
            'license':'Public Domain','licenseUrl':'https://www.mutopiaproject.org/legal.html',
            'detailUrl':f'https://www.mutopiaproject.org/info{index}'}


def html(title):
    return ('<table class="result-table"><tr>' + ''.join(f'<td>{text}</td>' for text in
            [title,'Composer','','','for Piano','','','','',
             '<a href="../legal.html">Public Domain</a>',
             '<a href="https://www.mutopiaproject.org/test.mid">.mid</a>']) + '</tr></table>').encode()


class RecommendationTests(unittest.TestCase):
    def test_solo_first_only_downloadable_keyboard_and_deduplicated(self):
        source=[item(0,'Voice and Piano'), item(1,'Violin'), item(2,midi=False),
                item(3), item(3), item(4,'for Harpsichord'), item(5,'for Piano and Orchestra')]
        result=select_items(source)
        self.assertEqual([value['title'] for value in result],['曲目3','曲目4','曲目0','曲目5'])
        self.assertEqual(result[0]['license'],'Public Domain')
        self.assertIn('独奏',result[0]['recommendationReason'])
        self.assertEqual(len(select_items([item(i) for i in range(20)])),6)

    def test_batch_changes_page_and_refresh_reaches_provider(self):
        catalog=Mock()
        catalog.search.return_value={'items':[item(i) for i in range(10)],'cached':False,'offline':False}
        result=recommend(catalog,3,True)
        catalog.search.assert_called_once_with('piano',30,refresh=True)
        self.assertFalse(result['capacityChecked'])
        self.assertEqual(result['batch'],3)
        self.assertEqual(len(result['items']),6)
        recommend(catalog,20)
        self.assertEqual(catalog.search.call_args.args,('piano',0))

    def test_empty_page_falls_back_once(self):
        catalog=Mock()
        catalog.search.side_effect=[{'items':[item(0,'Violin')]},{'items':[item(1)]}]
        result=recommend(catalog,9)
        self.assertEqual(result['sourceOffset'],0)
        self.assertEqual(len(result['items']),1)
        self.assertEqual(catalog.search.call_count,2)

    def test_invalid_parameters_do_not_fetch(self):
        catalog=Mock()
        for batch,refresh in [(-1,False),(True,False),(100001,False),(0,'true')]:
            with self.assertRaises(ValueError):recommend(catalog,batch,refresh)
        catalog.search.assert_not_called()

    def test_forced_refresh_bypasses_cache_and_failed_refresh_keeps_old(self):
        with tempfile.TemporaryDirectory() as folder:
            catalog=MutopiaCatalog(folder)
            with patch('score_library.mutopia.download',side_effect=[html('First'),html('Updated'),OSError('offline')]) as fetch:
                self.assertEqual(catalog.search('piano')['items'][0]['title'],'First')
                self.assertTrue(catalog.search('piano')['cached'])
                self.assertEqual(fetch.call_count,1)
                self.assertEqual(catalog.search('piano',refresh=True)['items'][0]['title'],'Updated')
                fallback=catalog.search('piano',refresh=True)
                self.assertTrue(fallback['offline'])
                self.assertEqual(fallback['items'][0]['title'],'Updated')
                self.assertEqual(fetch.call_count,3)

    def test_recommendations_receive_safe_fetch_tokens(self):
        with tempfile.TemporaryDirectory() as folder:
            service=ScoreLibrary(folder)
            with patch.object(service.catalog,'search',return_value={'items':[item(1)]}):
                result=service.recommend()
                token=result['items'][0]['token']
                self.assertEqual(service._items[token]['midiUrl'],item(1)['midiUrl'])
                self.assertEqual(len(token),32)
                with self.assertRaises(ValueError):service.fetch('arbitrary-url')


if __name__=='__main__':
    unittest.main(verbosity=2)
