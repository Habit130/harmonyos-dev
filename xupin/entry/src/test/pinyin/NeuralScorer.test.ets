import { describe, it, expect } from '@ohos/hypium';
import {
  NeuralModel,
  NeuralScorer,
  meanTeacherForcedLogProb,
  rerankWithNeuralScorer
} from '../../main/ets/pinyin/NeuralScorer';
import { Tokenizer } from '../../main/ets/pinyin/Tokenizer';
import { ScoringContext } from '../../main/ets/pinyin/CandidateScorer';
import { CandidateEntry } from '../../main/ets/pinyin/types';

// Independent reimplementation of log-softmax for expected-value computation in these tests
// (not a call into NeuralScorer.ets's internal helper, which isn't exported) — a second,
// separately-written version of the same well-known formula is a legitimate cross-check, not
// duplicated risk, since it's simple enough to verify by inspection.
function expectedLogSoftmax(logits: number[], tokenId: number): number {
  let max = -Infinity;
  for (let i = 0; i < logits.length; i++) {
    if (logits[i] > max) {
      max = logits[i];
    }
  }
  let sumExp = 0;
  for (let i = 0; i < logits.length; i++) {
    sumExp += Math.exp(logits[i] - max);
  }
  return logits[tokenId] - (max + Math.log(sumExp));
}

// A vocab small enough to hand-verify: [PAD]=0, [UNK]=1, then one id per character used below.
const FIXTURE_VOCAB = [
  '[PAD]', '[UNK]', '发', '起', '物', '资', '攻', '击', '供', '给'
].join('\n');
// ids: 发=2 起=3 物=4 资=5 攻=6 击=7 供=8 给=9

class FakeNeuralModel implements NeuralModel {
  private readonly logitsBySequence: Map<string, number[][]>;
  calls: number[][] = [];

  constructor(logitsBySequence: Map<string, number[][]>) {
    this.logitsBySequence = logitsBySequence;
  }

  async predict(tokenIds: number[]): Promise<number[][]> {
    this.calls.push(tokenIds);
    const logits = this.logitsBySequence.get(tokenIds.join(','));
    if (logits === undefined) {
      throw new Error('FakeNeuralModel: no canned logits for sequence ' + tokenIds.join(','));
    }
    return logits;
  }
}

function candidate(word: string, weight: number): CandidateEntry {
  return { word, weight, matchedLength: word.length };
}

export default function neuralScorerTest() {
  describe('NeuralScorerTest', () => {
    it('meanTeacherForcedLogProb averages (not sums) each candidate token\'s log-prob, reading logits[contextLen+j-1]', 0, () => {
      const logits = [
        [0, 0, 0, 0], // position 0: uniform over a 4-token vocab
        [10, 0, 0, 0] // position 1: near-certain token 0
      ];
      const single = meanTeacherForcedLogProb(logits, 1, [0]);
      expect(single as number).assertClose(Math.log(0.25), 1e-9);

      const twoToken = meanTeacherForcedLogProb(logits, 1, [0, 0]);
      const expectedMean = (Math.log(0.25) + expectedLogSoftmax(logits[1], 0)) / 2;
      expect(twoToken as number).assertClose(expectedMean, 1e-6);
    });

    it('meanTeacherForcedLogProb returns undefined with empty context and a single-token candidate (no preceding position exists)', 0, () => {
      expect(meanTeacherForcedLogProb([[0, 0]], 0, [0])).assertUndefined();
    });

    it('meanTeacherForcedLogProb self-conditions a multi-token candidate\'s later tokens on its own earlier tokens, even with empty context', 0, () => {
      const logits = [[5, 0]];
      // Two-token candidate [0, 1] with contextLen=0: token 0 (j=0) has no preceding
      // position and is skipped; token 1 (j=1) reads logits[0] — the candidate's own first
      // token conditions its second.
      const result = meanTeacherForcedLogProb(logits, 0, [0, 1]);
      expect(result as number).assertClose(expectedLogSoftmax(logits[0], 1), 1e-9);
    });

    it('score() degrades to the pure static term when prepare() was never called', 0, () => {
      const model = new FakeNeuralModel(new Map());
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      const scorer = new NeuralScorer(model, tokenizer);
      const context: ScoringContext = { precedingWords: ['发起'] };
      expect(scorer.score(context, candidate('攻击', 500441))).assertEqual(Math.log(500442));
    });

    it('score() degrades to the static term for a candidate outside the prepare()d batch (cache miss)', 0, async () => {
      const model = new FakeNeuralModel(new Map<string, number[][]>([
        ['2,3,6,7', [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 10, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 10, 0, 0]]]
      ]));
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      const scorer = new NeuralScorer(model, tokenizer);
      const context: ScoringContext = { precedingWords: ['发起'] };
      await scorer.prepare(context, [candidate('攻击', 500441)]);
      // 供给 was never in the prepare() batch — must degrade, not throw or use stale data.
      expect(scorer.score(context, candidate('供给', 238495))).assertEqual(Math.log(238496));
    });

    it('reproduces the PRD\'s own motivating example: 发起+gongji should prefer 供给 over 攻击 despite its lower static weight', 0, async () => {
      // Real weights from issue #20's Context section (xupin's shipped dictionary):
      // 攻击=500,441 vs 供给=238,495 — a real, but modest (~0.74 ln-unit), static gap. A
      // neural model confident in "发起...供给" and unsure about "发起...攻击" should be able
      // to flip this, which is the entire point of #20 (see the closed #6's bigram version,
      // which failed this exact example — 阶段1 Context section).
      const uniform10 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      const confidentIn = (tokenId: number): number[] => {
        const row = uniform10.slice();
        row[tokenId] = 10;
        return row;
      };
      const model = new FakeNeuralModel(new Map<string, number[][]>([
        // 发起攻击: model has no preference at either position (uniform).
        ['2,3,6,7', [uniform10, uniform10, uniform10, uniform10]],
        // 发起供给: model is confident in 供 at position 1, then 给 at position 2.
        ['2,3,8,9', [uniform10, confidentIn(8), confidentIn(9), uniform10]]
      ]));
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      const scorer = new NeuralScorer(model, tokenizer); // default coefficient
      const context: ScoringContext = { precedingWords: ['发起'] };
      const candidates = [candidate('攻击', 500441), candidate('供给', 238495)];

      await scorer.prepare(context, candidates);
      const gongjiScore = scorer.score(context, candidates[0]);
      const gongeiScore = scorer.score(context, candidates[1]);
      expect(gongeiScore > gongjiScore).assertTrue();
    });

    it('rerankWithNeuralScorer only re-scores the front `limit` candidates, and can reorder them while leaving the untouched tail intact', 0, async () => {
      const vocab = ['[PAD]', '[UNK]', '甲', '乙', '丙'].join('\n'); // 甲=2 乙=3 丙=4
      const uniform = [0, 0, 0, 0, 0];
      const confidentIn = (tokenId: number): number[] => {
        const row = uniform.slice();
        row[tokenId] = 10;
        return row;
      };
      const model = new FakeNeuralModel(new Map<string, number[][]>([
        ['2,3', [uniform]],          // 甲乙: no neural confidence in 乙
        ['2,4', [confidentIn(4)]]    // 甲丙: strongly confident in 丙
      ]));
      const tokenizer = Tokenizer.parse(vocab);
      const scorer = new NeuralScorer(model, tokenizer);
      const context: ScoringContext = { precedingWords: ['甲'] };

      // Static order ranks 乙 above 丙 (weight 100 vs 90 — a modest ~0.1 ln-unit gap, same
      // shape as the real dictionary's typical head-to-head gaps). The confident-vs-uniform
      // neural signal above should reverse that. filler-C/filler-D sit beyond the rerank
      // limit and must come back completely untouched, in their original relative order.
      const rankedByStatic: CandidateEntry[] = [
        { word: '乙', weight: 100, matchedLength: 1 },
        { word: '丙', weight: 90, matchedLength: 1 },
        { word: 'filler-C', weight: 50, matchedLength: 8 },
        { word: 'filler-D', weight: 10, matchedLength: 8 }
      ];

      const result = await rerankWithNeuralScorer(rankedByStatic, context, scorer, 2);
      expect(model.calls.length).assertEqual(2); // only the head 2 got a forward pass
      expect(result.length).assertEqual(4);
      expect(result[0].word).assertEqual('丙'); // neural signal reversed the static order
      expect(result[1].word).assertEqual('乙');
      expect(result[2].word).assertEqual('filler-C'); // tail untouched, original order
      expect(result[3].word).assertEqual('filler-D');
    });

    it('rerankWithNeuralScorer skips reranking entirely with empty context, even when the head mixes 1-char and 2-char candidates', 0, async () => {
      // Regression for the mixed-scale bug: at empty context, meanTeacherForcedLogProb
      // returns undefined for a 1-char candidate (no preceding position) but still yields a
      // partial signal for a 2-char candidate (self-conditioned second token) — scoring both
      // in the same batch would have compared "pure static" against "static+neural" and
      // artificially favored whichever candidate dodged the (usually negative) neural term.
      // The fix skips reranking outright at empty context, so no forward pass should even
      // happen and the static order must come back untouched.
      const vocab = ['[PAD]', '[UNK]', '甲', '乙', '丙'].join('\n');
      const model = new FakeNeuralModel(new Map()); // no canned logits — any call throws
      const tokenizer = Tokenizer.parse(vocab);
      const scorer = new NeuralScorer(model, tokenizer);
      const context: ScoringContext = { precedingWords: [] };

      const rankedByStatic: CandidateEntry[] = [
        { word: '乙', weight: 100, matchedLength: 1 },  // 1-char: would score undefined
        { word: '甲丙', weight: 90, matchedLength: 2 }   // 2-char: would still get a partial score
      ];

      const result = await rerankWithNeuralScorer(rankedByStatic, context, scorer, 2);
      expect(model.calls.length).assertEqual(0); // no forward pass attempted at all
      expect(result.length).assertEqual(2);
      expect(result[0].word).assertEqual('乙'); // static order preserved exactly
      expect(result[1].word).assertEqual('甲丙');
    });
  });
}
