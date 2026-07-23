import { CandidateEntry } from './types';

/**
 * The already-committed (on-screen) context a candidate is scored against, most-recent word
 * last. Sourced from CompositionState.committedHistory() — the words and literals the user has
 * confirmed this composition session. Delimiters (a committed space or punctuation) can appear
 * here too; StaticWeightScorer ignores context entirely, and NeuralScorer's tokenizer simply
 * encodes whatever characters are there (see pinyin/NeuralScorer.ets), so no delimiter
 * filtering is needed at this layer.
 */
export interface ScoringContext {
  precedingWords: string[];
}

/**
 * Pluggable candidate scoring: given the committed context and one candidate, return a score —
 * higher sorts earlier. This is the seam between candidate *generation* (CandidateGenerator,
 * pinyin -> candidate set) and candidate *ranking*, rebuilt on `main` for issue #20 (the
 * `feat/6-context-aware-ranking` branch/PR #14 that first introduced this shape was closed
 * unmerged — see that PR's `pinyin/CandidateScorer.ets` for the interface-shape precedent this
 * follows, not for reusable code). Deliberately synchronous: NeuralScorer's actual model
 * inference is async, but it runs ahead of time in a separate `prepare()` step and caches
 * results, so `score()` itself never has to await anything (see pinyin/NeuralScorer.ets).
 */
export interface CandidateScorer {
  score(context: ScoringContext, candidate: CandidateEntry): number;
}

/**
 * Ranks purely by the dictionary's static frequency weight, ignoring context — the #5/#15
 * behavior, kept as the explicit baseline and as CandidateGenerator's default scorer. Returns
 * `ln(weight + 1)` rather than the raw weight: `ln` is a monotonic transform, so ranking with
 * just this scorer is identical to comparing `weight` directly (see CandidateGenerator's
 * regression test), but it puts the static term on the same additive log-scale NeuralScorer's
 * log-linear blend needs (`ln(weight+1) + coefficient * meanLogProb`).
 */
export class StaticWeightScorer implements CandidateScorer {
  score(context: ScoringContext, candidate: CandidateEntry): number {
    return Math.log(candidate.weight + 1);
  }
}
