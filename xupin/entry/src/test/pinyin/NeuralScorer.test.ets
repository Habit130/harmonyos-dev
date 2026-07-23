import { describe, it, expect } from '@ohos/hypium';
import {
  BatchRow,
  FlatBatchLogits,
  NeuralModel,
  NeuralScorer,
  RowLogits,
  buildBatchRow,
  buildDummyRow,
  meanTeacherForcedLogProb,
  rankCandidates
} from '../../main/ets/pinyin/NeuralScorer';
import { Tokenizer } from '../../main/ets/pinyin/Tokenizer';
import { Dictionary } from '../../main/ets/pinyin/Dictionary';
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

// Wraps a plain [position][tokenId] array as the RowLogits accessor the production code reads
// (MindSporeNeuralModel.ets's real implementation wraps a flat Float32Array instead — see that
// file — but tests only need something implementing the same minimal interface). A class, not
// an object literal: ArkTS requires interfaces with method members to be satisfied by a
// declared class (arkts-no-untyped-obj-literals), same reason MindSporeNeuralModel.ets's real
// FlatRowLogits is a class rather than a literal.
class ArrayRowLogits implements RowLogits {
  readonly vocabSize: number;
  private readonly rows: number[][];

  constructor(rows: number[][]) {
    this.vocabSize = rows.length > 0 ? rows[0].length : 0;
    this.rows = rows;
  }

  at(position: number, tokenId: number): number {
    return this.rows[position][tokenId];
  }
}

function arrayRowLogits(rows: number[][]): RowLogits {
  return new ArrayRowLogits(rows);
}

// A vocab small enough to hand-verify: [PAD]=0, [UNK]=1, [CLS]=2, then one id per character
// used below.
const FIXTURE_VOCAB = [
  '[PAD]', '[UNK]', '[CLS]', '发', '起', '物', '资', '攻', '击', '供', '给'
].join('\n');
// ids: [PAD]=0 [UNK]=1 [CLS]=2 发=3 起=4 物=5 资=6 攻=7 击=8 供=9 给=10

class FakeNeuralModel implements NeuralModel {
  private readonly logitsByRowKey: Map<string, number[][]>;
  calls: BatchRow[][] = [];

  constructor(logitsByRowKey: Map<string, number[][]>) {
    this.logitsByRowKey = logitsByRowKey;
  }

  async predict(rows: BatchRow[]): Promise<RowLogits[]> {
    this.calls.push(rows);
    return rows.map((row: BatchRow): RowLogits => {
      const key = row.tokenIds.join(',');
      const canned = this.logitsByRowKey.get(key);
      if (canned === undefined) {
        throw new Error('FakeNeuralModel: no canned logits for row ' + key);
      }
      return arrayRowLogits(canned);
    });
  }
}

function candidate(word: string, weight: number): CandidateEntry {
  return { word, weight, matchedLength: word.length };
}

export default function neuralScorerTest() {
  describe('NeuralScorerTest', () => {
    it('meanTeacherForcedLogProb averages (not sums) each candidate token\'s log-prob, reading logits[contextLen+j-1]', 0, () => {
      const rawLogits = [
        [0, 0, 0, 0], // position 0: uniform over a 4-token vocab
        [10, 0, 0, 0] // position 1: near-certain token 0
      ];
      const logits = arrayRowLogits(rawLogits);
      const single = meanTeacherForcedLogProb(logits, 1, [0]);
      expect(single as number).assertClose(Math.log(0.25), 1e-9);

      const twoToken = meanTeacherForcedLogProb(logits, 1, [0, 0]);
      const expectedMean = (Math.log(0.25) + expectedLogSoftmax(rawLogits[1], 0)) / 2;
      expect(twoToken as number).assertClose(expectedMean, 1e-6);
    });

    it('meanTeacherForcedLogProb returns undefined with empty context and a single-token candidate (no preceding position exists)', 0, () => {
      expect(meanTeacherForcedLogProb(arrayRowLogits([[0, 0]]), 0, [0])).assertUndefined();
    });

    it('meanTeacherForcedLogProb self-conditions a multi-token candidate\'s later tokens on its own earlier tokens, even with empty context', 0, () => {
      const rawLogits = [[5, 0]];
      // Two-token candidate [0, 1] with contextLen=0: token 0 (j=0) has no preceding
      // position and is skipped; token 1 (j=1) reads logits[0] — the candidate's own first
      // token conditions its second.
      const result = meanTeacherForcedLogProb(arrayRowLogits(rawLogits), 0, [0, 1]);
      expect(result as number).assertClose(expectedLogSoftmax(rawLogits[0], 1), 1e-9);
    });

    it('buildBatchRow right-pads context+candidate tokens and marks real vs. padding positions in attentionMask', 0, () => {
      const row = buildBatchRow([3, 4], [7, 8], 6, 0); // context 发起, candidate 攻击, seq=6, pad=0
      expect(row.tokenIds).assertDeepEquals([3, 4, 7, 8, 0, 0]);
      expect(row.attentionMask).assertDeepEquals([1, 1, 1, 1, 0, 0]);
    });

    it('buildBatchRow needs no padding when context+candidate exactly fill sequenceLength', 0, () => {
      const row = buildBatchRow([3, 4], [7, 8], 4, 0);
      expect(row.tokenIds).assertDeepEquals([3, 4, 7, 8]);
      expect(row.attentionMask).assertDeepEquals([1, 1, 1, 1]);
    });

    it('buildDummyRow fills every position with the pad id and an all-1 attentionMask (avoids a fully-masked row)', 0, () => {
      const row = buildDummyRow(4, 0);
      expect(row.tokenIds).assertDeepEquals([0, 0, 0, 0]);
      expect(row.attentionMask).assertDeepEquals([1, 1, 1, 1]);
    });

    it('FlatBatchLogits reads a flat [batch, sequence, vocab] buffer with the correct row-major stride (issue #22 D9)', 0, () => {
      // Hand-laid batch=2, sequenceLength=3, vocabSize=4 tensor: value at flat index i is just
      // i itself, so every read's expected value is computable by inspection —
      // row*12 + position*4 + tokenId.
      const flat = new Float32Array([
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, // row 0
        12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 // row 1
      ]);
      const batch = new FlatBatchLogits(flat, 3, 4);
      const row0 = batch.rowAt(0);
      const row1 = batch.rowAt(1);
      expect(row0.vocabSize).assertEqual(4);
      expect(row0.at(0, 0)).assertEqual(0);
      expect(row0.at(0, 3)).assertEqual(3);
      expect(row0.at(1, 0)).assertEqual(4);
      expect(row0.at(2, 3)).assertEqual(11); // last element of row 0
      expect(row1.at(0, 0)).assertEqual(12); // row 1 starts right after row 0, not overlapping it
      expect(row1.at(2, 3)).assertEqual(23); // last element of the whole buffer
    });

    it('score() degrades to the pure static term when prepare() was never called', 0, () => {
      const model = new FakeNeuralModel(new Map());
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      const scorer = new NeuralScorer(model, tokenizer);
      const context: ScoringContext = { precedingWords: ['发起'] };
      expect(scorer.score(context, candidate('攻击', 500441))).assertEqual(Math.log(500442));
    });

    it('score() degrades to the static term for a candidate outside the prepare()d batch (cache miss)', 0, async () => {
      // batchSize=1 so the single prepare()d candidate is the only row — no dummy-row padding
      // to account for. contextWindowChars=2/maxCandidateTokens=2 (seq=4) makes context (发起)
      // and candidate (攻击) exactly fill the row with zero padding, so the canned key below
      // needs no trailing pad ids.
      const model = new FakeNeuralModel(new Map<string, number[][]>([
        ['3,4,7,8', [
          [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        ]]
      ]));
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      const scorer = new NeuralScorer(model, tokenizer, 2, undefined, 2, 1);
      const context: ScoringContext = { precedingWords: ['发起'] };
      await scorer.prepare(context, [candidate('攻击', 500441)]);
      // 供给 was never in the prepare() batch — must degrade, not throw or use stale data.
      expect(scorer.score(context, candidate('供给', 238495))).assertEqual(Math.log(238496));
    });

    it('reproduces the PRD\'s own motivating example: 发起+gongji should prefer 供给 over 攻击 despite its lower static weight, via exactly one batched predict() call', 0, async () => {
      // Real weights from issue #20's Context section (xupin's shipped dictionary):
      // 攻击=500,441 vs 供给=238,495 — a real, but modest (~0.74 ln-unit), static gap. A
      // neural model confident in "发起...供给" and unsure about "发起...攻击" should be able
      // to flip this, which is the entire point of #20/#22 (see the closed #6's bigram
      // version, which failed this exact example — 阶段1 Context section).
      const uniform11 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      const confidentIn = (tokenId: number): number[] => {
        const row = uniform11.slice();
        row[tokenId] = 10;
        return row;
      };
      // batchSize=2 matches the 2 real candidates exactly — no dummy-row padding to account
      // for. contextWindowChars=4/maxCandidateTokens=2 keeps rows at a hand-verifiable length 6.
      const model = new FakeNeuralModel(new Map<string, number[][]>([
        // 发起攻击 (+2 pad): model has no preference at any real position (uniform).
        ['3,4,7,8,0,0', [uniform11, uniform11, uniform11, uniform11, uniform11, uniform11]],
        // 发起供给 (+2 pad): model is confident in 供 at position 1, then 给 at position 2.
        ['3,4,9,10,0,0', [uniform11, confidentIn(9), confidentIn(10), uniform11, uniform11, uniform11]]
      ]));
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      const scorer = new NeuralScorer(model, tokenizer, 4, undefined, 2, 2); // default coefficient
      const context: ScoringContext = { precedingWords: ['发起'] };
      const candidates = [candidate('攻击', 500441), candidate('供给', 238495)];

      await scorer.prepare(context, candidates);
      expect(model.calls.length).assertEqual(1); // exactly one predict() call for both candidates
      expect(model.calls[0].length).assertEqual(2); // one row per candidate, no padding needed
      const gongjiScore = scorer.score(context, candidates[0]);
      const gongeiScore = scorer.score(context, candidates[1]);
      expect(gongeiScore > gongjiScore).assertTrue();
    });

    it('prepare() pads the batch out to batchSize with dummy rows when there are fewer real candidates, and still scores every real one', 0, async () => {
      // batchSize=3 with only 1 real candidate: predict() must still be called with exactly 3
      // rows (the real one + 2 dummy rows), matching what the model's fixed shape requires.
      const dummyKey = '0,0,0,0'; // buildDummyRow(4, padId=0)
      const uniform11 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      const model = new FakeNeuralModel(new Map<string, number[][]>([
        ['2,7,8,0', [uniform11, uniform11]], // [CLS]攻击+pad — positions 0,1 are the ones read
        [dummyKey, [uniform11, uniform11]]   // never read, just needs to resolve without throwing
      ]));
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      const scorer = new NeuralScorer(model, tokenizer, 2, undefined, 2, 3); // seq = 2+2 = 4
      const context: ScoringContext = { precedingWords: [] }; // empty -> [CLS] anchor (D5)

      await scorer.prepare(context, [candidate('攻击', 500441)]);
      expect(model.calls.length).assertEqual(1);
      expect(model.calls[0].length).assertEqual(3); // 1 real + 2 dummy rows, matching batchSize
      expect(model.calls[0][1].tokenIds).assertDeepEquals([0, 0, 0, 0]); // dummy row content
      expect(model.calls[0][1].attentionMask).assertDeepEquals([1, 1, 1, 1]); // never all-0
      // The real candidate still got a genuine neural score despite the padding around it.
      const staticOnly = Math.log(500442);
      expect(scorer.score(context, candidate('攻击', 500441)) === staticOnly).assertFalse();
    });

    it('empty context gets a single [CLS] anchor (issue #22 D5) so even a 1-char candidate gets a real neural score — replaces the pre-#22 behavior of skipping neural scoring entirely at empty context', 0, async () => {
      // [CLS]=2, candidate '起' (id 4) alone: sequence [2, 4], contextLen=1 (just [CLS]) so
      // the single candidate token has a valid preceding position — meanTeacherForcedLogProb
      // reads logits[contextLen + 0 - 1] = logits[0], i.e. only the FIRST row below is read.
      const model = new FakeNeuralModel(new Map<string, number[][]>([
        ['2,4', [[0, 0, 0, 0, 10], [0, 0, 0, 0, 0]]] // position0 (the one read): confident in token 4
      ]));
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      const scorer = new NeuralScorer(model, tokenizer, 1, undefined, 1, 1); // seq = 1+1 = 2
      const context: ScoringContext = { precedingWords: [] };

      await scorer.prepare(context, [candidate('起', 100)]);
      expect(model.calls.length).assertEqual(1);
      expect(model.calls[0][0].tokenIds[0]).assertEqual(2); // [CLS] is the context, not skipped
      const staticOnly = Math.log(101);
      expect(scorer.score(context, candidate('起', 100)) === staticOnly).assertFalse(); // got a real neural term
    });

    it('rankCandidates() returns the static shortlist unchanged, with neuralRanked=false, when no scorer is passed (neural assets not loaded)', 0, async () => {
      const dict = Dictionary.parse(['jia\t甲\t100', 'jia\t乙\t90'].join('\n'));
      const context: ScoringContext = { precedingWords: [] };
      const result = await rankCandidates('jia', dict, context, undefined);
      expect(result.neuralRanked).assertFalse();
      expect(result.candidates.length).assertEqual(2);
      expect(result.candidates[0].word).assertEqual('甲'); // static weight order, unchanged
      expect(result.candidates[1].word).assertEqual('乙');
    });

    it('rankCandidates() reranks the static shortlist via the injected scorer in exactly one predict() call, and reports neuralRanked=true', 0, async () => {
      const dict = Dictionary.parse(['jia\t甲\t100', 'jia\t乙\t90'].join('\n'));
      const vocab = ['[PAD]', '[UNK]', '[CLS]', '甲', '乙'].join('\n'); // 甲=3 乙=4
      const uniform = [0, 0, 0, 0, 0];
      const confidentIn = (tokenId: number): number[] => {
        const row = uniform.slice();
        row[tokenId] = 10;
        return row;
      };
      // Empty context -> [CLS] anchor (id 2). seq = contextWindowChars(1) + maxCandidateTokens(1)
      // = 2; a 1-char candidate's only read position is logits[0] (contextLen=1, j=0), i.e. only
      // the FIRST row of each canned pair below is actually consulted.
      const model = new FakeNeuralModel(new Map<string, number[][]>([
        ['2,3', [uniform, uniform]],        // 甲: neutral at position0 — no reason to reorder
        ['2,4', [confidentIn(4), uniform]]  // 乙: confident at position0 — should flip the static order
      ]));
      const tokenizer = Tokenizer.parse(vocab);
      const scorer = new NeuralScorer(model, tokenizer, 1, undefined, 1, 2);
      const context: ScoringContext = { precedingWords: [] };

      const result = await rankCandidates('jia', dict, context, scorer);
      expect(model.calls.length).assertEqual(1); // one predict() call for the whole keystroke
      expect(result.neuralRanked).assertTrue();
      expect(result.candidates.length).assertEqual(2);
      expect(result.candidates[0].word).assertEqual('乙'); // neural signal reversed the static order
      expect(result.candidates[1].word).assertEqual('甲');
    });
  });
}
