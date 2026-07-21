import { CandidateEntry } from './types';
import { BigramModel } from './BigramModel';

/**
 * The already-committed (on-screen) context a candidate is scored against, most-recent word
 * last. Sourced from CompositionState.committedHistory() — the words and literals the user has
 * confirmed this composition session. Delimiters (a committed space or punctuation) can appear
 * here too; a word-based scorer simply finds no model entry for them and falls back to static
 * ordering, so no delimiter filtering is needed here.
 */
export interface ScoringContext {
  precedingWords: string[];
}

/**
 * Pluggable candidate scoring: given the committed context and one candidate, return a score —
 * higher sorts earlier. This is the seam issue #6 introduces between candidate *generation*
 * (CandidateGenerator, pinyin -> candidate set) and candidate *ranking*. It is decoupled from
 * IME Kit, the dictionary, the UI and the device, so any strategy — static frequency, bigram, or
 * a future neural model — is a drop-in, off-device-unit-testable implementation.
 */
export interface CandidateScorer {
  score(context: ScoringContext, candidate: CandidateEntry): number;
}

/**
 * Ranks purely by the dictionary's static frequency weight, ignoring context — the #5 behavior,
 * kept as the explicit baseline and as the graceful fallback used when no bigram model is loaded.
 */
export class StaticWeightScorer implements CandidateScorer {
  score(context: ScoringContext, candidate: CandidateEntry): number {
    return candidate.weight;
  }
}

/**
 * Log-linear blend of a candidate's static frequency and how often it followed the immediately
 * preceding committed word in the training corpus:
 *
 *   score = ln(weight + 1) + bigramCoefficient * ln(1 + bigramCount(lastWord, candidate.word))
 *
 * With no preceding word — or a preceding word/delimiter the model never saw — the bigram term is
 * ln(1) = 0 and the score collapses to the static-frequency ordering. So context *refines* the
 * frequency prior rather than replacing it, and behavior degrades to StaticWeightScorer exactly
 * when there is no contextual evidence. Only the single immediately preceding word is consulted
 * (a first-order model); longer context is out of scope for this issue.
 */
export class BigramScorer implements CandidateScorer {
  // Default weight on the bigram term. Static weights span hundreds–thousands (ln ≈ 5–8) while
  // corpus bigram counts span single digits–hundreds (ln ≈ 1–5); a coefficient of 3 lets strong
  // contextual evidence outrank a moderately-more-frequent-but-context-wrong candidate without
  // letting a single stray co-occurrence dominate a far more frequent word.
  static readonly DEFAULT_BIGRAM_COEFFICIENT: number = 3;

  private readonly model: BigramModel;
  private readonly bigramCoefficient: number;

  // bigramCoefficient is injected (optional, defaulting to DEFAULT_BIGRAM_COEFFICIENT) so its
  // influence on ranking is tunable and directly assertable in unit tests.
  constructor(model: BigramModel, bigramCoefficient?: number) {
    this.model = model;
    this.bigramCoefficient = bigramCoefficient ?? BigramScorer.DEFAULT_BIGRAM_COEFFICIENT;
  }

  score(context: ScoringContext, candidate: CandidateEntry): number {
    const staticTerm = Math.log(candidate.weight + 1);
    const words = context.precedingWords;
    const lastWord = words.length > 0 ? words[words.length - 1] : undefined;
    const bigramCount = lastWord === undefined ? 0 : this.model.count(lastWord, candidate.word);
    return staticTerm + this.bigramCoefficient * Math.log(1 + bigramCount);
  }
}
