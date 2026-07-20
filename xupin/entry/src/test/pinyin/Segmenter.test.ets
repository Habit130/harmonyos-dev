import { describe, it, expect } from '@ohos/hypium';
import { segment } from '../../main/ets/pinyin/Segmenter';

function sortedJoined(paths: string[][]): string[] {
  const joined = paths.map((path: string[]): string => path.join('+'));
  joined.sort();
  return joined;
}

export default function segmenterTest() {
  describe('SegmenterTest', () => {
    it('segments an unambiguous single syllable', 0, () => {
      expect(segment('bei')).assertDeepEquals([['bei']]);
    });

    it('segments an unambiguous multi-syllable buffer', 0, () => {
      expect(segment('beijing')).assertDeepEquals([['bei', 'jing']]);
    });

    it('returns both legal readings of an ambiguous buffer', 0, () => {
      expect(sortedJoined(segment('xian'))).assertDeepEquals(['xi+an', 'xian']);
    });

    it('returns both legal readings for fangan (方案 vs 反感)', 0, () => {
      expect(sortedJoined(segment('fangan'))).assertDeepEquals(['fan+gan', 'fang+an']);
    });

    it('returns empty for an incomplete syllable prefix', 0, () => {
      expect(segment('b')).assertDeepEquals([]);
      expect(segment('zh')).assertDeepEquals([]);
    });

    it('returns empty for a string that is not legal pinyin at all', 0, () => {
      expect(segment('qwx')).assertDeepEquals([]);
    });

    it('returns empty for an empty buffer', 0, () => {
      expect(segment('')).assertDeepEquals([]);
    });
  });
}
