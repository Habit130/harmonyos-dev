import { CandidateScorer, ScoringContext } from './CandidateScorer';
import { CandidateEntry } from './types';
import { Tokenizer } from './Tokenizer';

// Preceding characters fed to the model as context, capped so a long document doesn't grow the
// forward pass unboundedly. Named/tunable rather than a magic number (issue #20's own
// instruction, mirroring BigramScorer.DEFAULT_BIGRAM_COEFFICIENT's style from the closed #14).
// 12 is the midpoint of the issue's suggested 8-16 range — a provisional starting point, not a
// device-measured value: the phase-1 spike (xupin/docs/spike-20-neural-ranking.md) confirmed
// conversion/execution feasibility but real-device latency (which should inform this number,
// longer context = more accurate but slower) is still pending, deferred by the user until after
// this implementation lands. Retune once that number is in.
export const DEFAULT_CONTEXT_WINDOW_CHARS: number = 12;

// How many of the (already static-weight-ranked) candidates get the expensive neural re-score,
// per issue #20's confirmed retreat design — see rerankWithNeuralScorer()'s doc for why this
// exists at all. 20 is the top of the issue's suggested 15-20 starting range.
export const DEFAULT_NEURAL_RERANK_LIMIT: number = 20;

/**
 * Abstraction over "run one forward pass, get next-token logits back" — decouples
 * NeuralScorer's scoring math (teacher-forced log-prob extraction, length normalization,
 * log-linear blend — all pure and unit-tested against a fake model below) from the concrete
 * inference backend. The real implementation
 * (InputMethodExtensionAbility/model/MindSporeNeuralModel.ets) wraps MindSpore Lite Kit's
 * async, tensor-based ArkTS API and is compile-only-verified, not unit-tested — see that file's
 * doc for why (issue #20 phase 3: real on-device inference can't be exercised off-device).
 * Async to match that real predict() API's `Promise<MSTensor[]>` shape.
 */
export interface NeuralModel {
  /** `tokenIds` is one full sequence (context + candidate). Returns `logits[position][vocabId]`. */
  predict(tokenIds: number[]): Promise<number[][]>;
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
 * degrades that the same as any other missing-signal case (pure static term).
 */
export function meanTeacherForcedLogProb(
  logits: number[][],
  contextLen: number,
  candidateIds: number[]
): number | undefined {
  let total = 0;
  let scored = 0;
  for (let j = 0; j < candidateIds.length; j++) {
    const position = contextLen + j - 1;
    if (position < 0 || position >= logits.length) {
      continue;
    }
    total += logProbOf(logits[position], candidateIds[j]);
    scored++;
  }
  return scored === 0 ? undefined : total / scored;
}

// log-softmax(logits)[tokenId], via the standard max-subtraction form for numerical stability
// (logits can be large; naive exp() would overflow before normalizing).
function logProbOf(positionLogits: number[], tokenId: number): number {
  let max = -Infinity;
  for (let i = 0; i < positionLogits.length; i++) {
    if (positionLogits[i] > max) {
      max = positionLogits[i];
    }
  }
  let sumExp = 0;
  for (let i = 0; i < positionLogits.length; i++) {
    sumExp += Math.exp(positionLogits[i] - max);
  }
  const logSumExp = max + Math.log(sumExp);
  return positionLogits[tokenId] - logSumExp;
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
  private readonly neuralCoefficient: number;
  private readonly meanLogProbByWord: Map<string, number> = new Map();

  constructor(model: NeuralModel, tokenizer: Tokenizer, contextWindowChars?: number, neuralCoefficient?: number) {
    this.model = model;
    this.tokenizer = tokenizer;
    this.contextWindowChars = contextWindowChars ?? DEFAULT_CONTEXT_WINDOW_CHARS;
    this.neuralCoefficient = neuralCoefficient ?? NeuralScorer.DEFAULT_NEURAL_COEFFICIENT;
  }

  /**
   * Runs one forward pass per candidate (teacher-forced against context+candidate tokens) and
   * caches each candidate's `meanLogProb`, keyed by word. Must be awaited before score() is
   * called for these candidates — score() itself stays synchronous (CandidateScorer's
   * interface is deliberately sync, see that file's doc) by only ever reading this
   * pre-populated cache.
   */
  async prepare(context: ScoringContext, candidates: CandidateEntry[]): Promise<void> {
    const contextText = context.precedingWords.join('');
    const windowed = contextText.length > this.contextWindowChars
      ? contextText.slice(contextText.length - this.contextWindowChars)
      : contextText;
    const contextIds = this.tokenizer.encode(windowed);

    for (let i = 0; i < candidates.length; i++) {
      const word = candidates[i].word;
      const meanLogProb = await this.forwardOne(contextIds, word);
      if (meanLogProb !== undefined) {
        this.meanLogProbByWord.set(word, meanLogProb);
      }
    }
  }

  private async forwardOne(contextIds: number[], word: string): Promise<number | undefined> {
    const candidateIds = this.tokenizer.encode(word);
    const sequence = contextIds.concat(candidateIds);
    if (sequence.length === 0) {
      return undefined;
    }
    const logits = await this.model.predict(sequence);
    return meanTeacherForcedLogProb(logits, contextIds.length, candidateIds);
  }

  /**
   * Synchronous by contract (CandidateScorer). Degrades to the pure static term — the only
   * sanctioned degrade path (issue #20) — whenever there's no cached neural signal: prepare()
   * was never called, the model failed to load upstream (see MindSporeNeuralModel's doc), or
   * this candidate simply wasn't part of the prepare() batch (outside the reranked top-N, see
   * rerankWithNeuralScorer() below).
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

interface RerankCandidate {
  entry: CandidateEntry;
  index: number;
}

/**
 * Issue #20's confirmed retreat design: the phase-1 spike found cross-keystroke KV-cache reuse
 * isn't reachable on this platform (xupin/docs/spike-20-neural-ranking.md §4/§5a — ArkTS's
 * MindSpore Lite binding is static-shape-only, and the KV-cache graph itself only runs when its
 * shape is fixed at conversion time, not resized per call), so scoring the *entire* candidate
 * set with the neural model on every keystroke is not attempted. `rankedByStatic` is assumed
 * already fully scored and truncated by CandidateGenerator's default (StaticWeightScorer)
 * pipeline — this function re-sorts only its front `limit` candidates using `scorer`, splicing
 * the result back in front of the untouched static-ranked remainder.
 *
 * This is a deliberate, issue-sanctioned exception to #15's "score the whole set before
 * truncating" rule — but note the whole set already *was* scored (by StaticWeightScorer, one
 * pass) before any truncation happened; only the expensive *neural* re-score is limited to a
 * head subset, not candidate recall itself.
 *
 * Skips reranking entirely when `context.precedingWords` is empty. With empty context,
 * `meanTeacherForcedLogProb` has no preceding position for a single-token candidate's own
 * first token and returns `undefined` (see that function's doc), so `score()` degrades a
 * 1-char candidate to the pure static term while a 2+-char candidate in the same batch still
 * gets a partial neural signal from its own later tokens — mixing "static only" and
 * "static+neural" scores within one sorted batch, which would artificially favor whichever
 * candidates happened to dodge the (typically strongly negative) neural term regardless of
 * actual quality. This only occurs at empty context: once `contextLen >= 1`, every candidate
 * including single-char ones has a valid position, so no mix is possible. A causal LM
 * conditioned on nothing has no real opinion about a first token anyway, so falling back to
 * static order here is also the semantically correct behavior, not just a bugfix.
 */
export async function rerankWithNeuralScorer(
  rankedByStatic: CandidateEntry[],
  context: ScoringContext,
  scorer: NeuralScorer,
  limit?: number
): Promise<CandidateEntry[]> {
  if (context.precedingWords.length === 0) {
    return rankedByStatic;
  }
  const rerankLimit = limit ?? DEFAULT_NEURAL_RERANK_LIMIT;
  const head = rankedByStatic.slice(0, rerankLimit);
  const tail = rankedByStatic.slice(rerankLimit);
  await scorer.prepare(context, head);

  const weighted = head.map((entry: CandidateEntry, index: number): RerankCandidate => {
    return { entry, index };
  });
  weighted.sort((a: RerankCandidate, b: RerankCandidate): number => {
    const scoreDiff = scorer.score(context, b.entry) - scorer.score(context, a.entry);
    if (scoreDiff !== 0) {
      return scoreDiff;
    }
    return a.index - b.index;
  });
  return weighted.map((w: RerankCandidate): CandidateEntry => w.entry).concat(tail);
}
