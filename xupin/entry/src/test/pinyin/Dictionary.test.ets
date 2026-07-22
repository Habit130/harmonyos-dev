import { describe, it, expect } from '@ohos/hypium';
import { Dictionary } from '../../main/ets/pinyin/Dictionary';

const FIXTURE = [
  'beijing\t北京\t1000',
  'beijing\t背景\t500',
  'bei\t北\t900',
  'bei\t杯\t800',
].join('\n');

// prefixLookup()'s binary search relies on keys being pre-sorted ascending (see Dictionary's
// class doc) — unlike FIXTURE above, this one must actually be in that order.
const PREFIX_FIXTURE = [
  'bei\t北\t900',
  'beijing\t北京\t1000',
  'jing\t京\t700',
  'shi\t是\t400',
  'xian\t先\t600',
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

    it('prefixLookup returns [] when no key starts with the prefix', 0, () => {
      const dict = Dictionary.parse(PREFIX_FIXTURE);
      expect(dict.prefixLookup('q').length).assertEqual(0);
    });

    it('prefixLookup matches exactly one key when no other key extends it', 0, () => {
      const dict = Dictionary.parse(PREFIX_FIXTURE);
      const results = dict.prefixLookup('jing');
      expect(results.length).assertEqual(1);
      expect(results[0].word).assertEqual('京');
    });

    it('prefixLookup includes the dictionary\'s first sorted key', 0, () => {
      const dict = Dictionary.parse(PREFIX_FIXTURE);
      // "b" reaches both "bei" (index 0 of the sorted key array) and "beijing".
      const results = dict.prefixLookup('b');
      expect(results.length).assertEqual(2);
      expect(results[0].word).assertEqual('北');
      expect(results[1].word).assertEqual('北京');
    });

    it('prefixLookup includes the dictionary\'s last sorted key', 0, () => {
      const dict = Dictionary.parse(PREFIX_FIXTURE);
      // "xia" reaches only "xian" (index 4, the last key in the sorted array).
      const results = dict.prefixLookup('xia');
      expect(results.length).assertEqual(1);
      expect(results[0].word).assertEqual('先');
    });

    it('prefixLookup returns [] for an empty prefix', 0, () => {
      const dict = Dictionary.parse(PREFIX_FIXTURE);
      expect(dict.prefixLookup('').length).assertEqual(0);
    });
  });
}
