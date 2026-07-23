import { describe, it, expect } from '@ohos/hypium';
import { StaticWeightScorer, ScoringContext } from '../../main/ets/pinyin/CandidateScorer';
import { CandidateEntry } from '../../main/ets/pinyin/types';

const NO_CONTEXT: ScoringContext = { precedingWords: [] };

function candidate(weight: number): CandidateEntry {
  return { word: 'x', weight, matchedLength: 1 };
}

export default function candidateScorerTest() {
  describe('CandidateScorerTest', () => {
    it('StaticWeightScorer scores ln(weight + 1), ignoring context', 0, () => {
      const scorer = new StaticWeightScorer();
      expect(scorer.score(NO_CONTEXT, candidate(0))).assertEqual(Math.log(1));
      expect(scorer.score(NO_CONTEXT, candidate(999))).assertEqual(Math.log(1000));
      const withContext: ScoringContext = { precedingWords: ['发起'] };
      expect(scorer.score(withContext, candidate(999))).assertEqual(scorer.score(NO_CONTEXT, candidate(999)));
    });

    it('StaticWeightScorer preserves weight ordering (ln is monotonic)', 0, () => {
      const scorer = new StaticWeightScorer();
      const low = scorer.score(NO_CONTEXT, candidate(100));
      const high = scorer.score(NO_CONTEXT, candidate(100000));
      expect(high > low).assertTrue();
    });
  });
}
