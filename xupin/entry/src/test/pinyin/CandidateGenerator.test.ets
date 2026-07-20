import { describe, it, expect } from '@ohos/hypium';
import { Dictionary } from '../../main/ets/pinyin/Dictionary';
import { generateCandidates } from '../../main/ets/pinyin/CandidateGenerator';

const FIXTURE = [
  'bei\t北\t900',
  'bei\t杯\t800',
  'jing\t京\t700',
  'beijing\t北京\t1000',
  'beijing\t背景\t500',
  'xian\t先\t600',
  'xian\t西安\t550',
  'xian\t现\t500',
  'shi\t是\t400',
].join('\n');

export default function candidateGeneratorTest() {
  describe('CandidateGeneratorTest', () => {
    it('prefers the whole-buffer multi-char word over a char-by-char reading', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      const results = generateCandidates('beijing', dict);
      expect(results.length).assertEqual(2);
      expect(results[0].word).assertEqual('北京');
      expect(results[1].word).assertEqual('背景');
    });

    it('surfaces every dictionary reading of an ambiguous buffer from one lookup', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      const results = generateCandidates('xian', dict);
      expect(results.length).assertEqual(3);
      expect(results[0].word).assertEqual('先');
      expect(results[1].word).assertEqual('西安');
      expect(results[2].word).assertEqual('现');
    });

    it('falls back to the longest legal prefix when the whole buffer has no match', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      // "beijingshi" itself isn't a dictionary entry, but its "beijing" prefix is.
      const results = generateCandidates('beijingshi', dict);
      expect(results.length).assertEqual(2);
      expect(results[0].word).assertEqual('北京');
      expect(results[1].word).assertEqual('背景');
    });

    it('returns empty when the buffer is legal pinyin but wholly unknown to the dictionary', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      expect(generateCandidates('gan', dict).length).assertEqual(0);
    });

    it('returns empty for an incomplete syllable', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      expect(generateCandidates('b', dict).length).assertEqual(0);
    });

    it('returns empty for an empty buffer', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      expect(generateCandidates('', dict).length).assertEqual(0);
    });
  });
}
