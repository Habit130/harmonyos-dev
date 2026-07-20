import { describe, it, expect } from '@ohos/hypium';
import { Dictionary } from '../../main/ets/pinyin/Dictionary';

const FIXTURE = [
  'beijing\t北京\t1000',
  'beijing\t背景\t500',
  'bei\t北\t900',
  'bei\t杯\t800',
].join('\n');

export default function dictionaryTest() {
  describe('DictionaryTest', () => {
    it('returns candidates for a known key, preserving pre-sorted order', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      const results = dict.lookup('beijing');
      expect(results.length).assertEqual(2);
      expect(results[0].word).assertEqual('北京');
      expect(results[0].weight).assertEqual(1000);
      expect(results[1].word).assertEqual('背景');
    });

    it('returns an empty array for an unknown key', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      expect(dict.lookup('nihao').length).assertEqual(0);
    });

    it('ignores malformed lines (wrong column count)', 0, () => {
      const dict = Dictionary.parse('beijing\t北京\t1000\nmalformed line\nbei\t北\t900');
      expect(dict.lookup('beijing').length).assertEqual(1);
      expect(dict.lookup('bei').length).assertEqual(1);
    });

    it('handles an empty dictionary', 0, () => {
      const dict = Dictionary.parse('');
      expect(dict.lookup('beijing').length).assertEqual(0);
    });
  });
}
