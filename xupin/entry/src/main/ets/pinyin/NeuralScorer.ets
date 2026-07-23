import { CandidateScorer, ScoringContext } from './CandidateScorer';
import { CandidateEntry } from './types';
import { Tokenizer } from './Tokenizer';
import { Dictionary } from './Dictionary';
import { generateCandidates, DEFAULT_DISPLAY_LIMIT } from './CandidateGenerator';

// Preceding characters fed to the model as context, capped so a long document doesn't grow the
// forward pass unboundedly. Named/tunable rather than a magic number (issue #20's own
// instruction, mirroring BigramScorer.DEFAULT_BIGRAM_COEFFICIENT's style from the closed #14).
//
// Issue #22 D4: this is no longer just a "cap", it's one half of the model's fixed sequence
// length (the other half is DEFAULT_MAX_CANDIDATE_TOKENS below) — SEQUENCE_LENGTH is baked into
// the converted .ms file's tensor shape (xupin/docs/issue-22-shape-fix.md §5), so changing this
// number requires re-running the conversion scripts and re-bundling the model, not just
// recompiling ArkTS.
export const DEFAULT_CONTEXT_WINDOW_CHARS: number = 12;

// Max candidate token count scored per row (issue #22 D4): the dictionary's own word-length
// distribution puts 99.94% of entries at <=8 characters (the remaining 0.06%, 125 entries, get
// scored on only their first 8 tokens — meanTeacherForcedLogProb is already length-normalized,
// so this is a truncated estimate, not a degraded one). Paired with
// DEFAULT_CONTEXT_WINDOW_CHARS to make the model's fixed 20-token sequence length; see that
// constant's doc for why both are model-resource parameters now.
export const DEFAULT_MAX_CANDIDATE_TOKENS: number = 8;

// Batch size == the candidate bar's display cap (issue #22 D3): ArkTS's MindSpore Lite binding
// only runs a shape baked in at conversion time (no runtime resize —
// xupin/docs/spike-20-neural-ranking.md §4), so "how many candidates get a neural score per
// keystroke" is fixed by the converted .ms file, not chosen at runtime. Re-exporting
// CandidateGenerator's DEFAULT_DISPLAY_LIMIT (rather than declaring a second constant with the
// same value) makes it structurally impossible for the two to drift apart.
export const DEFAULT_BATCH_SIZE: number = DEFAULT_DISPLAY_LIMIT;

/**
 * One read-only view over a single batch row's `[sequenceLength, vocabSize]` logits — the
 * abstraction that lets MindSporeNeuralModel.ets hand back a thin accessor over its raw
 * `Float32Array` instead of materializing a `number[][]` per row (issue #22 D9: at
 * `[9, 20, 21128]` output size, that materialization was ~15.2MB of nested-array allocation and
 * copying per keystroke). Test fakes can implement this over a plain nested array instead — see
 * NeuralScorer.test.ets's `arrayRowLogits()`.
 */
export interface RowLogits {
  readonly vocabSize: number;
  at(position: number, tokenId: number): number;
}

/**
 * One row of a batched forward pass: exactly `sequenceLength` token ids (context + candidate
 * tokens, right-padded with the tokenizer's `[PAD]` id — see buildBatchRow()) and a matching
 * attention mask (1 = real token, 0 = padding). `position_ids` isn't part of this shape because
 * it's always `0..sequenceLength-1` for every row regardless of content (real tokens are always
 * front-loaded by right-padding) — MindSporeNeuralModel.ets derives it directly from
 * `tokenIds.length` rather than being told.
 */
export interface BatchRow {
  readonly tokenIds: number[];
  readonly attentionMask: number[];
}

/**
 * Row-major view over a flat `[batchSize, sequenceLength, vocabSize]` buffer — the layout
 * MindSpore Lite Kit's `MSTensor.getData()` returns for the model's `logits` output
 * (`row * sequenceLength * vocabSize + position * vocabSize + tokenId`). Factored out of
 * MindSporeNeuralModel.ets (which can't be unit-tested at all — real on-device inference can't
 * be exercised off-device, see that file's doc) specifically so this stride arithmetic — the one
 * part of issue #22 D9's Float32Array-reading redesign most prone to a silent off-by-one or
 * wrong-stride bug, which would read a neighboring row's logits instead of throwing — gets real
 * test coverage against a hand-laid buffer (see NeuralScorer.test.ets).
 */
export class FlatBatchLogits {
  private readonly flat: Float32Array;
  private readonly sequenceLength: number;
  private readonly vocabSize: number;

  constructor(flat: Float32Array, sequenceLength: number, vocabSize: number) {
    this.flat = flat;
    this.sequenceLength = sequenceLength;
    this.vocabSize = vocabSize;
  }

  rowAt(row: number): RowLogits {
    return new FlatRowLogits(this.flat, row * this.sequenceLength * this.vocabSize, this.vocabSize);
  }
}

class FlatRowLogits implements RowLogits {
  readonly vocabSize: number;
  private readonly flat: Float32Array;
  private readonly rowBase: number;

  constructor(flat: Float32Array, rowBase: number, vocabSize: number) {
    this.flat = flat;
    this.rowBase = rowBase;
    this.vocabSize = vocabSize;
  }

  at(position: number, tokenId: number): number {
    return this.flat[this.rowBase + position * this.vocabSize + tokenId];
  }
}

/**
 * Abstraction over "run one batched forward pass, get per-row logits back" — decouples
 * NeuralScorer's scoring math (teacher-forced log-prob extraction, length normalization,
 * log-linear blend — all pure and unit-tested against a fake model below) from the concrete
 * inference backend. The real implementation
 * (InputMethodExtensionAbility/model/MindSporeNeuralModel.ets) wraps MindSpore Lite Kit's
 * async, tensor-based ArkTS API and is compile-only-verified, not unit-tested — see that file's
 * doc for why (issue #20 phase 3: real on-device inference can't be exercised off-device).
 *
 * Issue #22 D2: exactly one `predict()` call per keystroke, `rows.length` rows at a time —
 * replaces the pre-#22 one-call-per-candidate design (issue #22's G4: that design's serial
 * `await`s meant a fast typist's earlier keystrokes were still being scored, and discarded via
 * the buffer-staleness guard, when later ones arrived).
 */
export interface NeuralModel {
  predict(rows: BatchRow[]): Promise<RowLogits[]>;
}

/**
 * `logits[p]` is a causal LM's distribution for the token *after* position `p` (i.e. having
 * seen `sequence[0..p]`) — so `sequence[contextLen + j]`, the `j`-th candidate token, is
 * predicted by `logits[contextLen + j - 1]`. Averages (not sums — see NeuralScorer's doc for
 * why) each scorable candidate token's teacher-forced log-probability.
 *
 * The first candidate token (`j = 0`) needs `contextLen >= 1` to have a preceding position to
 * read logits from. With empty context AND a single-token candidate there is no preceding
 * position anywhere in the sequence, so this returns `undefined` — NeuralScorer.score()
 * degrades that the same as any other missing-signal case (pure static term). In production
 * this branch is now rare rather than routine: issue #22 D5 makes NeuralScorer.prepare() prefix
 * a `[CLS]` anchor whenever the committed context is empty, so `contextLen` is normally >= 1
 * even for a session's very first word. This function still accepts (and tests) `contextLen`
 * values below that floor directly — it's a pure function with no opinion about where its
 * caller's `contextLen` came from.
 *
 * No upper-bound position check: issue #22's batch-row construction (buildBatchRow(),
 * NeuralScorer.prepare()) guarantees `contextLen + candidateIds.length <= sequenceLength` by
 * truncating both context and candidate token counts before this is ever called in production,
 * so `position` never reaches `logits`'s padding region. Callers that violate that invariant
 * would read past intended content rather than fail loudly — this is deliberately trusted
 * construction-time state, not a runtime-validated contract (matches this codebase's general
 * "trust internal invariants" convention).
 */
export function meanTeacherForcedLogProb(
  logits: RowLogits,
  contextLen: number,
  candidateIds: number[]
): number | undefined {
  let total = 0;
  let scored = 0;
  for (let j = 0; j < candidateIds.length; j++) {
    const position = contextLen + j - 1;
    if (position < 0) {
      continue;
    }
    total += logProbOf(logits, position, candidateIds[j]);
    scored++;
  }
  return scored === 0 ? undefined : total / scored;
}

// log-softmax(logits)[tokenId], via the standard max-subtraction form for numerical stability
// (logits can be large; naive exp() would overflow before normalizing).
function logProbOf(logits: RowLogits, position: number, tokenId: number): number {
  let max = -Infinity;
  for (let v = 0; v < logits.vocabSize; v++) {
    const value = logits.at(position, v);
    if (value > max) {
      max = value;
    }
  }
  let sumExp = 0;
  for (let v = 0; v < logits.vocabSize; v++) {
    sumExp += Math.exp(logits.at(position, v) - max);
  }
  const logSumExp = max + Math.log(sumExp);
  return logits.at(position, tokenId) - logSumExp;
}

/**
 * Right-pads `contextIds + candidateIds` out to `sequenceLength` with `padId`, and builds the
 * matching attention mask (1 for the real content, 0 for padding). Pure and exported for direct
 * unit testing (issue #22's own acceptance bar for this kind of never-exercised-off-device
 * plumbing: give the bug-prone array-building its own tested seam rather than folding it into
 * MindSporeNeuralModel.ets, which can't be unit-tested at all).
 */
export function buildBatchRow(
  contextIds: number[],
  candidateIds: number[],
  sequenceLength: number,
  padId: number
): BatchRow {
  const tokenIds = contextIds.concat(candidateIds);
  const realLength = tokenIds.length;
  while (tokenIds.length < sequenceLength) {
    tokenIds.push(padId);
  }
  const attentionMask: number[] = [];
  for (let i = 0; i < sequenceLength; i++) {
    attentionMask.push(i < realLength ? 1 : 0);
  }
  return { tokenIds, attentionMask };
}

/**
 * Filler for an unused batch slot, when fewer than `batchSize` real candidates exist this
 * keystroke (issue #22 phase B: "候选不足9个时补哑行，其输出丢弃") — the model's shape is fixed
 * at exactly `batchSize` rows, so short candidate lists still need every slot filled. Content
 * doesn't matter since this row's output is never read, but the attention mask is all-1s rather
 * than all-0s: an all-zero mask leaves nothing for that row's attention softmax to normalize
 * over, an edge case worth avoiding even though the result is discarded either way.
 */
export function buildDummyRow(sequenceLength: number, padId: number): BatchRow {
  return {
    tokenIds: new Array<number>(sequenceLength).fill(padId),
    attentionMask: new Array<number>(sequenceLength).fill(1)
  };
}

/**
 * Log-linear blend of a candidate's static frequency and the neural model's teacher-forced
 * confidence in it given the committed context:
 *
 *   score = ln(weight + 1) + coefficient * meanLogProb
 *
 * `meanLogProb` is length-normalized (mean, not sum, of each candidate token's log-prob) —
 * summing would structurally penalize longer candidates (more multiplied probabilities), the
 * opposite of what a scorer meant to let longer-but-context-appropriate words win should do;
 * this system routinely ranks candidates of different token lengths against each other
 * (prefix-completion vs whole-buffer matches at different `matchedLength`, see issue #18).
 *
 * Additive, not a fallback-only term: unlike a bigram count (PR #14's BigramScorer, since
 * abandoned), a language model always emits *some* log-prob for any token — there's no "the
 * model has no opinion" case, so the static term is always present in the sum too, never
 * dropped outright the way a missing bigram count would be. That said, at the current
 * provisional `coefficient` this is NOT a magnitude-bounded blend: `meanLogProb` routinely
 * spans a wider range (≈0 to -10ish) than the static term's typical head-to-head gaps
 * (≈0.7 ln-units per the PRD's 攻击 vs 供给 example), so a confident neural read can and will
 * outweigh the static signal. That's an open calibration question, not a claimed property of
 * `coefficient`'s current value — see below.
 *
 * `coefficient`'s default is a reasoned provisional estimate, not a device-measured value
 * (deferred per the user's instruction — see DEFAULT_CONTEXT_WINDOW_CHARS's doc for the same
 * deferral); expect it to move once real device numbers are available. Retune then, same as
 * the context window.
 */
export class NeuralScorer implements CandidateScorer {
  static readonly DEFAULT_NEURAL_COEFFICIENT: number = 2;

  private readonly model: NeuralModel;
  private readonly tokenizer: Tokenizer;
  private readonly contextWindowChars: number;
  private readonly maxCandidateTokens: number;
  private readonly batchSize: number;
  private readonly sequenceLength: number;
  private readonly neuralCoefficient: number;
  private readonly meanLogProbByWord: Map<string, number> = new Map();

  constructor(
    model: NeuralModel,
    tokenizer: Tokenizer,
    contextWindowChars?: number,
    neuralCoefficient?: number,
    maxCandidateTokens?: number,
    batchSize?: number
  ) {
    this.model = model;
    this.tokenizer = tokenizer;
    this.contextWindowChars = contextWindowChars ?? DEFAULT_CONTEXT_WINDOW_CHARS;
    this.neuralCoefficient = neuralCoefficient ?? NeuralScorer.DEFAULT_NEURAL_COEFFICIENT;
    this.maxCandidateTokens = maxCandidateTokens ?? DEFAULT_MAX_CANDIDATE_TOKENS;
    this.batchSize = batchSize ?? DEFAULT_BATCH_SIZE;
    // Derived, not independently settable: issue #22 D4 fixes sequenceLength as exactly
    // contextWindowChars + maxCandidateTokens, so there's no way to construct a NeuralScorer
    // whose row layout doesn't match that invariant.
    this.sequenceLength = this.contextWindowChars + this.maxCandidateTokens;
  }

  /**
   * Runs exactly one batched forward pass (issue #22 D2) — `candidates.length` real rows plus
   * enough `buildDummyRow()` filler to reach `batchSize` — and caches each real candidate's
   * `meanLogProb`, keyed by word. Must be awaited before score() is called for these candidates;
   * score() itself stays synchronous (CandidateScorer's interface is deliberately sync, see
   * that file's doc) by only ever reading this pre-populated cache.
   *
   * `context.precedingWords` being empty no longer skips neural scoring the way the pre-#22
   * `rerankWithNeuralScorer()` did (issue #20's G1 bug: a session's very first word could never
   * get a neural score) — buildContextIds() below prefixes a `[CLS]` anchor instead (D5), so
   * every row in the batch has a valid preceding position uniformly.
   */
  async prepare(context: ScoringContext, candidates: CandidateEntry[]): Promise<void> {
    const contextIds = this.buildContextIds(context);
    const padId = this.tokenizer.padId();
    const rows: BatchRow[] = [];
    const candidateIdsByIndex: number[][] = [];
    for (let i = 0; i < candidates.length; i++) {
      const candidateIds = this.tokenizer.encode(candidates[i].word).slice(0, this.maxCandidateTokens);
      candidateIdsByIndex.push(candidateIds);
      rows.push(buildBatchRow(contextIds, candidateIds, this.sequenceLength, padId));
    }
    while (rows.length < this.batchSize) {
      rows.push(buildDummyRow(this.sequenceLength, padId));
    }

    const batchLogits = await this.model.predict(rows);

    for (let i = 0; i < candidates.length; i++) {
      const meanLogProb = meanTeacherForcedLogProb(batchLogits[i], contextIds.length, candidateIdsByIndex[i]);
      if (meanLogProb !== undefined) {
        this.meanLogProbByWord.set(candidates[i].word, meanLogProb);
      }
    }
  }

  /**
   * Empty context (no committed history this composition session) gets a single `[CLS]` token
   * instead of an empty array (issue #22 D5) — confirmed a genuine trained start-of-sequence
   * anchor for this checkpoint, not assumed (xupin/docs/issue-22-shape-fix.md §1). A real,
   * non-empty context is windowed to the trailing `contextWindowChars` characters same as
   * pre-#22.
   */
  private buildContextIds(context: ScoringContext): number[] {
    const contextText = context.precedingWords.join('');
    if (contextText.length === 0) {
      return [this.tokenizer.clsId()];
    }
    const windowed = contextText.length > this.contextWindowChars
      ? contextText.slice(contextText.length - this.contextWindowChars)
      : contextText;
    return this.tokenizer.encode(windowed);
  }

  /**
   * Synchronous by contract (CandidateScorer). Degrades to the pure static term — the only
   * sanctioned degrade path (issue #20) — whenever there's no cached neural signal: prepare()
   * was never called, or the model failed to load upstream (see MindSporeNeuralModel's doc).
   * Since issue #22's rankCandidates() always prepare()s every candidate it's about to score
   * (no separate reranked-head-vs-untouched-tail split anymore, see this file's rankCandidates
   * doc), a cache miss here now means real failure upstream, not "this candidate was outside
   * the rerank window" — Index.ets's caller is responsible for treating a whole-batch failure
   * as a whole-batch degrade rather than relying on this per-candidate fallback to paper over
   * a partial failure.
   */
  score(context: ScoringContext, candidate: CandidateEntry): number {
    const staticTerm = Math.log(candidate.weight + 1);
    const meanLogProb = this.meanLogProbByWord.get(candidate.word);
    if (meanLogProb === undefined) {
      return staticTerm;
    }
    return staticTerm + this.neuralCoefficient * meanLogProb;
  }
}

/** `rankCandidates()`'s result: the ranked candidates to display, plus whether the neural model
  * actually participated in producing that order this round — issue #22 D7's "first candidate's
  * style is the user-visible signal for whether neural ranking ran" needs this as an explicit
  * flag rather than inferring it from candidate content. */
export interface RankedCandidates {
  candidates: CandidateEntry[];
  neuralRanked: boolean;
}

interface ScoredCandidate {
  entry: CandidateEntry;
  index: number;
}

function sortByScore(entries: CandidateEntry[], context: ScoringContext, scorer: CandidateScorer): CandidateEntry[] {
  const weighted = entries.map((entry: CandidateEntry, index: number): ScoredCandidate => {
    return { entry, index };
  });
  weighted.sort((a: ScoredCandidate, b: ScoredCandidate): number => {
    const scoreDiff = scorer.score(context, b.entry) - scorer.score(context, a.entry);
    if (scoreDiff !== 0) {
      return scoreDiff;
    }
    return a.index - b.index;
  });
  return weighted.map((w: ScoredCandidate): CandidateEntry => w.entry);
}

/**
 * The single async ranking facade issue #22 D6 asks for: one call from Index.ets, one resulting
 * UI assignment. Replaces the pre-#22 `rerankWithNeuralScorer()` two-stage design (static
 * ranking assigned to the UI immediately, then overwritten later by a reranked result) and the
 * `DEFAULT_NEURAL_RERANK_LIMIT` constant that went with it — both are gone, not just renamed.
 *
 * What D6 removes is the *second UI assignment*, not the *static ranking pass itself*: this
 * still calls `generateCandidates()` (StaticWeightScorer, full recall-then-truncate per issue
 * #15) to build the shortlist before any neural work happens — issue #22's explicit "对#15的真实
 * 偏离" note 3 is that only this already-truncated shortlist (now `DEFAULT_DISPLAY_LIMIT` == the
 * neural batch size) ever gets a neural score; a candidate that didn't make the static top-9
 * cannot be recovered by a stronger neural opinion. That limitation already existed pre-#22 (the
 * old `rerankWithNeuralScorer`'s `DEFAULT_NEURAL_RERANK_LIMIT` window), #22 just makes the window
 * and the display limit the same number instead of two independently-tunable ones.
 *
 * `scorer` is `undefined` exactly when the neural assets (model/tokenizer) aren't loaded —
 * Index.ets constructs one only when both holders have something to hand back. That case (and a
 * `scorer.prepare()` failure, left to propagate rather than caught here — same "one catch site,
 * in Index.ets" discipline the pre-#22 code already used) both mean `neuralRanked: false` on the
 * *caller's* side; this function itself only reports `false` for the "no scorer at all" case,
 * since a thrown prepare() means this function never returns at all.
 */
export async function rankCandidates(
  buffer: string,
  dictionary: Dictionary,
  context: ScoringContext,
  scorer?: NeuralScorer
): Promise<RankedCandidates> {
  const shortlist = generateCandidates(buffer, dictionary);
  if (!scorer) {
    return { candidates: shortlist, neuralRanked: false };
  }
  await scorer.prepare(context, shortlist);
  return { candidates: sortByScore(shortlist, context, scorer), neuralRanked: true };
}
