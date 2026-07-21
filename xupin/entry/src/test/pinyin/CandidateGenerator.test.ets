import { describe, it, expect } from '@ohos/hypium';
import { Dictionary } from '../../main/ets/pinyin/Dictionary';
import { generateCandidates } from '../../main/ets/pinyin/CandidateGenerator';
import { BigramModel } from '../../main/ets/pinyin/BigramModel';
import { BigramScorer, ScoringContext } from '../../main/ets/pinyin/CandidateScorer';

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
  // Two readings of "gongji", statically 攻击(700) > 供给(600) — used by the context-aware
  // ranking tests below to show committed context reorder the same buffer.
  'gongji\t攻击\t700',
  'gongji\t供给\t600',
].join('\n');

// Corpus evidence for the context tests: 攻击 follows 发起, 供给 follows 物资.
const CONTEXT_MODEL = BigramModel.parse([
  '发起\t攻击\t150',
  '物资\t供给\t200',
].join('\n'));

function ctx(...words: string[]): ScoringContext {
  return { precedingWords: words };
}

export default function candidateGeneratorTest() {
  describe('CandidateGeneratorTest', () => {
    it('prefers the whole-buffer multi-char word over a char-by-char reading', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      const results = generateCandidates('beijing', dict);
      expect(results.length).assertEqual(2);
      expect(results[0].word).assertEqual('北京');
      expect(results[0].matchedLength).assertEqual(7); // whole buffer, "beijing".length
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
      // Matched only the "beijing" prefix (7 chars), not the full 10-char buffer — the
      // trailing "shi" must stay in the composition buffer on confirm (issue #13, #6).
      expect(results[0].matchedLength).assertEqual(7);
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

    // The #6 headline: the same pinyin buffer, ranked against two different committed contexts,
    // produces two different candidate orders — the demonstrable proof that context drives ranking.
    it('reorders the same pinyin buffer under different committed context', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      const scorer = new BigramScorer(CONTEXT_MODEL);

      const afterLaunch = generateCandidates('gongji', dict, scorer, ctx('发起'));
      const afterSupplies = generateCandidates('gongji', dict, scorer, ctx('物资'));

      // Both draw from the identical candidate set, only the order differs.
      expect(afterLaunch.length).assertEqual(2);
      expect(afterSupplies.length).assertEqual(2);
      expect(afterLaunch[0].word).assertEqual('攻击');   // "发起攻击"
      expect(afterSupplies[0].word).assertEqual('供给'); // "物资供给", flipped above statically-heavier 攻击
      expect(afterLaunch[0].word === afterSupplies[0].word).assertFalse();
    });

    it('with no scorer/context, ranking stays the #5 static-frequency order', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      const results = generateCandidates('gongji', dict);
      expect(results[0].word).assertEqual('攻击'); // static weight 700 > 600
      expect(results[1].word).assertEqual('供给');
    });

    it('an empty context ranks by static frequency, matching the no-scorer path', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      const scorer = new BigramScorer(CONTEXT_MODEL);
      const results = generateCandidates('gongji', dict, scorer, ctx());
      expect(results[0].word).assertEqual('攻击');
      expect(results[1].word).assertEqual('供给');
    });
  });
}
