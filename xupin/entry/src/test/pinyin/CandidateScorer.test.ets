import { describe, it, expect } from '@ohos/hypium';
import { BigramModel } from '../../main/ets/pinyin/BigramModel';
import { BigramScorer, ScoringContext, StaticWeightScorer } from '../../main/ets/pinyin/CandidateScorer';
import { CandidateEntry } from '../../main/ets/pinyin/types';

// Two candidates of the same pinyin "gongji". By static frequency 攻击(700) outranks 供给(600).
const GONGJI: CandidateEntry = { word: '攻击', weight: 700, matchedLength: 5 };
const GONGGEI: CandidateEntry = { word: '供给', weight: 600, matchedLength: 5 };

// Corpus evidence: 攻击 tends to follow 发起 ("发起攻击"); 供给 tends to follow 物资 ("物资供给").
const MODEL = BigramModel.parse([
  '发起\t攻击\t150',
  '物资\t供给\t200',
].join('\n'));

function ctx(...words: string[]): ScoringContext {
  return { precedingWords: words };
}

export default function candidateScorerTest() {
  describe('CandidateScorerTest', () => {
    it('StaticWeightScorer returns the raw weight and ignores context', 0, () => {
      const scorer = new StaticWeightScorer();
      expect(scorer.score(ctx(), GONGJI)).assertEqual(700);
      expect(scorer.score(ctx('物资'), GONGGEI)).assertEqual(600); // context makes no difference
    });

    it('BigramScorer lets contextual evidence outrank a more-frequent-but-context-wrong candidate', 0, () => {
      const scorer = new BigramScorer(MODEL);
      // After 物资, the corpus strongly favors 供给, flipping it above the statically-heavier 攻击.
      expect(scorer.score(ctx('物资'), GONGGEI) > scorer.score(ctx('物资'), GONGJI)).assertTrue();
      // After 发起, the corpus favors 攻击, reinforcing the static order.
      expect(scorer.score(ctx('发起'), GONGJI) > scorer.score(ctx('发起'), GONGGEI)).assertTrue();
    });

    it('BigramScorer falls back to static order with empty context', 0, () => {
      const scorer = new BigramScorer(MODEL);
      expect(scorer.score(ctx(), GONGJI) > scorer.score(ctx(), GONGGEI)).assertTrue();
    });

    it('BigramScorer ignores a preceding delimiter/unknown word (no bigram entry) and stays static', 0, () => {
      const scorer = new BigramScorer(MODEL);
      // Last committed thing is a comma: the model has no key for it, so no contextual signal.
      expect(scorer.score(ctx('物资', '，'), GONGJI) > scorer.score(ctx('物资', '，'), GONGGEI)).assertTrue();
    });

    it('a zero bigramCoefficient reduces BigramScorer to pure static ranking', 0, () => {
      // Proves the coefficient is the only lever turning contextual evidence into rank changes:
      // with it zeroed, even strong 物资->供给 evidence cannot lift 供给 above 攻击.
      const scorer = new BigramScorer(MODEL, 0);
      expect(scorer.score(ctx('物资'), GONGJI) > scorer.score(ctx('物资'), GONGGEI)).assertTrue();
    });
  });
}
