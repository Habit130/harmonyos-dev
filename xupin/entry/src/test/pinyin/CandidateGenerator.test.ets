import { describe, it, expect } from '@ohos/hypium';
import { Dictionary } from '../../main/ets/pinyin/Dictionary';
import { generateCandidates } from '../../main/ets/pinyin/CandidateGenerator';
import { CandidateScorer, ScoringContext } from '../../main/ets/pinyin/CandidateScorer';
import { CandidateEntry } from '../../main/ets/pinyin/types';

// Key-sorted ascending (see Dictionary's class doc) — generateCandidates() now always
// consults prefixLookup() too, which relies on that order, so an unsorted fixture would
// silently corrupt every test below it, not just the ones that exercise prefixLookup
// directly.
const FIXTURE = [
  'bei\t北\t900',
  'bei\t杯\t800',
  'beijing\t北京\t1000',
  'beijing\t背景\t500',
  'jing\t京\t700',
  'shi\t是\t400',
  'xian\t先\t600',
  'xian\t西安\t550',
  'xian\t现\t500',
].join('\n');

// For the mid-composition prefix-completion repro (issue #15): buffer "xi" is itself a
// legal, dictionary-known syllable, but "xihan"/"xihao"/"xihuan" all extend past it, and
// "xih"/"xihu"/"xihua" aren't legal syllable sequences on their own.
const REPRO_FIXTURE = [
  'xi\t西\t500',
  'xihan\t西汉\t300',
  'xihao\t喜好\t400',
  'xihuan\t喜欢\t900',
].join('\n');

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

    it('surfaces prefix-completion candidates for an incomplete syllable (issue #15)', 0, () => {
      // "b" isn't a legal syllable on its own (segment() returns []), but "bei"/"beijing"
      // both extend it, so the bar must not go blank while the user is still mid-syllable.
      const dict = Dictionary.parse(FIXTURE);
      const results = generateCandidates('b', dict);
      expect(results.length).assertEqual(4);
      expect(results[0].word).assertEqual('北京'); // weight 1000, highest overall
      expect(results[0].matchedLength).assertEqual(1); // consumes just the typed "b"
      expect(results[1].word).assertEqual('北');
      expect(results[2].word).assertEqual('杯');
      expect(results[3].word).assertEqual('背景');
    });

    it('returns empty for an empty buffer', 0, () => {
      const dict = Dictionary.parse(FIXTURE);
      expect(generateCandidates('', dict).length).assertEqual(0);
    });

    it('keeps every intermediate typing state non-empty and narrows toward the exact match (issue #15 repro: x -> xi -> xih -> xihu -> xihua -> xihuan)', 0, () => {
      const dict = Dictionary.parse(REPRO_FIXTURE);

      const x = generateCandidates('x', dict);
      expect(x.length).assertEqual(4); // 西/西汉/喜好/喜欢 all start with "x"

      const xi = generateCandidates('xi', dict);
      expect(xi.length).assertEqual(4); // "xi" itself is also a dictionary key (西)
      expect(xi[0].word).assertEqual('喜欢'); // highest weight (900) wins the rank

      const xih = generateCandidates('xih', dict);
      expect(xih.length).assertEqual(3); // "xi" (西) drops out: not a prefix of "xih"
      expect(xih[0].word).assertEqual('喜欢');

      const xihu = generateCandidates('xihu', dict);
      expect(xihu.length).assertEqual(2); // 西汉/喜好 drop out: not prefixes of "xihu"
      expect(xihu[0].word).assertEqual('喜欢');
      expect(xihu[0].matchedLength).assertEqual(4); // prefix completion: key "xihuan" is
      // longer than the 4-char buffer, but matchedLength is still just buffer.length.
      expect(xihu[1].word).assertEqual('西'); // longest-legal-prefix fallback ("xi"+"hu")

      const xihua = generateCandidates('xihua', dict);
      expect(xihua.length).assertEqual(2);
      expect(xihua[0].word).assertEqual('喜欢');

      const xihuan = generateCandidates('xihuan', dict);
      expect(xihuan.length).assertEqual(1); // exact whole-buffer match only
      expect(xihuan[0].word).assertEqual('喜欢');
      expect(xihuan[0].matchedLength).assertEqual(6);
    });

    it('ranks the full merged candidate set by weight before truncating to the display limit — no early recall cutoff (issue #15)', 0, () => {
      // 80 candidates share the "zz" prefix; the highest-weight one sorts LAST in key
      // order. A "truncate the first N keys, then score" bug would drop it before it's
      // ever scored — the correct "score everything, then truncate" pipeline keeps it.
      // Display limit is 5 (issue #24 phase 3, shrunk from #22 D3's 9 == the neural model's
      // batch size), not #15's original 50 — this test only cares that truncation happens
      // after scoring, not the exact cap value, so it still uses a candidate pool much larger
      // than the cap.
      const lines: string[] = [];
      for (let i = 0; i < 79; i++) {
        const suffix = i < 10 ? '0' + i.toString() : i.toString();
        lines.push('zz' + suffix + '\tfiller' + suffix + '\t' + i.toString());
      }
      lines.push('zz79\twinner\t100000');
      const dict = Dictionary.parse(lines.join('\n'));

      const results = generateCandidates('zz', dict);
      expect(results.length).assertEqual(5);
      expect(results[0].word).assertEqual('winner');
      expect(results[0].weight).assertEqual(100000);
    });

    it('an injected scorer changes ranking (issue #20); omitting it keeps this repo\'s original weight order', 0, () => {
      const dict = Dictionary.parse(FIXTURE);

      // No scorer passed: identical to the pre-#20 order (same assertions as "surfaces every
      // dictionary reading of an ambiguous buffer" above) — the regression case.
      const defaultOrder = generateCandidates('xian', dict);
      expect(defaultOrder[0].word).assertEqual('先');
      expect(defaultOrder[1].word).assertEqual('西安');
      expect(defaultOrder[2].word).assertEqual('现');

      class AlwaysPreferXianScorer implements CandidateScorer {
        score(context: ScoringContext, candidate: CandidateEntry): number {
          return candidate.word === '现' ? 1000 : candidate.weight;
        }
      }
      const reordered = generateCandidates('xian', dict, new AlwaysPreferXianScorer());
      expect(reordered.length).assertEqual(3);
      expect(reordered[0].word).assertEqual('现'); // only the injected scorer prefers this
    });
  });
}
