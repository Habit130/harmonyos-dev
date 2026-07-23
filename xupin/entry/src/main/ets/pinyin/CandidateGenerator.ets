import { Dictionary } from './Dictionary';
import { segment } from './Segmenter';
import { CandidateEntry, DictionaryEntry } from './types';
import { CandidateScorer, ScoringContext, StaticWeightScorer } from './CandidateScorer';

// rankAndTruncate() scores every candidate against this context regardless of which scorer is
// injected. StaticWeightScorer (the default) ignores context entirely, so an empty one is a
// harmless placeholder for it. A context-aware rerank (NeuralScorer) doesn't go through this
// function at all — see pinyin/NeuralScorer.ets's rankCandidates(), which re-scores this
// function's own (StaticWeightScorer-ranked) result with the real committed context (issue #20,
// reworked into a single async facade by issue #22 D6).
const NO_CONTEXT: ScoringContext = { precedingWords: [] };

// Display-count cap applied only after the full candidate set is merged and ranked (see
// generateCandidates) — never as an earlier recall cutoff. Named/injectable rather than a
// magic number, mirroring BigramScorer.DEFAULT_BIGRAM_COEFFICIENT's style (issue #15).
//
// 9, not the pre-#22 value of 50: issue #22 D3 ties this to the neural model's batch size —
// ArkTS's MindSpore Lite binding only supports a fixed shape baked in at conversion time (no
// runtime resize, see xupin/docs/spike-20-neural-ranking.md §4), so the number of candidates
// that get a neural score in one forward pass is fixed by the converted .ms file, not by a
// runtime parameter. Making the display limit and the batch size the same number means every
// candidate the user can actually see was scored by the same pass — no mixing a neurally-scored
// head with a static-only tail. NeuralScorer.ets's DEFAULT_BATCH_SIZE re-exports this constant
// rather than redeclaring it, so the two can't drift apart. Changing this value requires
// re-running the model conversion (xupin/docs/issue-22-shape-fix.md §5) — it is not a
// recompile-only change.
export const DEFAULT_DISPLAY_LIMIT: number = 9;

// A candidate paired with its original merge-order position, so ties (equal weight) keep a
// deterministic order via the index tiebreak instead of depending on Array.sort's stability
// guarantees across engines.
interface WeightedCandidate {
  entry: CandidateEntry;
  index: number;
}

/**
 * Ranked candidates for the current pinyin composition buffer, merged from two sources
 * (issue #15) and then scored/truncated as one pipeline — never a subset scored first:
 *
 * 1. `lookupCandidates()` (unchanged from #5): whole-buffer dictionary matches always win
 *    first — looking up the buffer's concatenated pinyin key is invariant to how it's
 *    segmented into syllables (e.g. "xian" and "xi"+"an" concatenate to the same key
 *    "xian"), so a single lookup already surfaces every reading ambiguity the dictionary
 *    knows about, including multi-character whole-word matches like "beijing" -> 北京
 *    outranking a char-by-char reading. When nothing matches the whole buffer, falls back
 *    to the longest legal-segmentation prefix that does have a match. This is deliberately
 *    not full multi-word chaining: any confirm only clears the matched portion of the
 *    composition buffer (see CompositionState.confirm), so a candidate only ever needs to
 *    represent one pick, not a full-sentence conversion.
 * 2. `prefixCandidates()`: dictionary keys that have the buffer as a *leading* substring
 *    (e.g. buffer "xih" matches key "xihuan"), independent of whether the buffer itself
 *    segments into legal syllables. This is what makes intermediate typing states like "x"
 *    or "xih" show candidates instead of a blank bar.
 *
 * The two sets are merged and deduped by (word, matchedLength), then the whole merged set
 * is ranked and only then truncated to DEFAULT_DISPLAY_LIMIT — scoring never runs on a
 * pre-truncated subset, so a low-static-weight candidate that a context-aware scorer would
 * rank highly is never discarded before it gets scored.
 *
 * `scorer` defaults to a fresh StaticWeightScorer, so omitting it reproduces this repo's
 * pre-#20 behavior exactly (regression-tested in CandidateGenerator.test.ets) — ranking by
 * `ln(weight+1)` sorts identically to ranking by raw `weight`, since `ln` is monotonic.
 */
export function generateCandidates(
  buffer: string,
  dictionary: Dictionary,
  scorer?: CandidateScorer,
  displayLimit?: number
): CandidateEntry[] {
  if (buffer.length === 0) {
    return [];
  }
  const paths = segment(buffer);
  const looked = lookupCandidates(buffer, dictionary, paths);
  const prefixed = prefixCandidates(buffer, dictionary);
  const merged = mergeCandidates(looked, prefixed);
  return rankAndTruncate(merged, displayLimit ?? DEFAULT_DISPLAY_LIMIT, scorer ?? new StaticWeightScorer());
}

// The #5 candidate-set lookup, untouched: whole-buffer hit first, else longest legal prefix
// hit. Naturally returns [] when `paths` is empty (collectPrefixLengths([]) is [], and an
// empty `paths` only ever occurs alongside no whole-buffer dictionary key either) — so this
// needs no explicit paths.length guard of its own.
function lookupCandidates(buffer: string, dictionary: Dictionary, paths: string[][]): CandidateEntry[] {
  const direct = dictionary.lookup(buffer);
  if (direct.length > 0) {
    return withMatchedLength(direct, buffer.length);
  }

  const prefixLengths = collectPrefixLengths(paths);
  for (let i = 0; i < prefixLengths.length; i++) {
    const prefixLength = prefixLengths[i];
    const hits = dictionary.lookup(buffer.substring(0, prefixLength));
    if (hits.length > 0) {
      return withMatchedLength(hits, prefixLength);
    }
  }
  return [];
}

// New candidate source (issue #15): dictionary keys extending the buffer as a prefix.
// Picking one of these consumes the whole buffer (matchedLength = buffer.length) even
// though the matched key may be longer — the unfinished trailing letters the user hasn't
// typed yet aren't required. CompositionState.confirm() already trims by matchedLength, so
// this needs no change on the consuming side.
function prefixCandidates(buffer: string, dictionary: Dictionary): CandidateEntry[] {
  return withMatchedLength(dictionary.prefixLookup(buffer), buffer.length);
}

// Unions lookupCandidates()'s and prefixCandidates()'s results, deduping by (word,
// matchedLength) with no source priority (issue #15). The only real overlap case is a
// whole-buffer dictionary hit: the buffer is trivially a prefix of its own key, so that
// key's entries surface from both sources with an identical matchedLength.
function mergeCandidates(a: CandidateEntry[], b: CandidateEntry[]): CandidateEntry[] {
  const seen = new Set<string>();
  const merged: CandidateEntry[] = [];
  const combined = a.concat(b);
  for (let i = 0; i < combined.length; i++) {
    const entry = combined[i];
    const dedupeKey = entry.word + ' ' + String(entry.matchedLength);
    if (!seen.has(dedupeKey)) {
      seen.add(dedupeKey);
      merged.push(entry);
    }
  }
  return merged;
}

// Scores the merged set via the injected scorer and only then truncates to displayLimit, so
// truncation can never discard a candidate the scoring step hasn't seen yet.
function rankAndTruncate(entries: CandidateEntry[], displayLimit: number, scorer: CandidateScorer): CandidateEntry[] {
  const weighted = entries.map((entry: CandidateEntry, index: number): WeightedCandidate => {
    return { entry, index };
  });
  weighted.sort((a: WeightedCandidate, b: WeightedCandidate): number => {
    const scoreDiff = scorer.score(NO_CONTEXT, b.entry) - scorer.score(NO_CONTEXT, a.entry);
    if (scoreDiff !== 0) {
      return scoreDiff;
    }
    return a.index - b.index;
  });
  const ranked = weighted.map((w: WeightedCandidate): CandidateEntry => w.entry);
  return ranked.length > displayLimit ? ranked.slice(0, displayLimit) : ranked;
}

// Tags each dictionary hit with how many leading buffer characters it actually covers, so
// CompositionState.confirm() can trim only that portion instead of the whole buffer.
function withMatchedLength(entries: DictionaryEntry[], matchedLength: number): CandidateEntry[] {
  return entries.map((entry: DictionaryEntry): CandidateEntry => {
    return { word: entry.word, weight: entry.weight, matchedLength };
  });
}

// Distinct syllable-boundary lengths shorter than the full buffer, reachable by any legal
// segmentation, sorted longest-first for longest-prefix-match fallback. Ambiguity is
// handled by taking the union across every path: a boundary only reachable via one of
// several legal segmentations (like "xi"+"ang" but not "xiang") is still tried.
function collectPrefixLengths(paths: string[][]): number[] {
  const lengths = new Set<number>();
  for (let p = 0; p < paths.length; p++) {
    const path = paths[p];
    let cursor = 0;
    for (let i = 0; i < path.length - 1; i++) {
      cursor += path[i].length;
      lengths.add(cursor);
    }
  }
  const result = Array.from(lengths);
  result.sort((a: number, b: number): number => b - a);
  return result;
}
