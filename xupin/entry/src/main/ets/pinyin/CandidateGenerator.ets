import { Dictionary } from './Dictionary';
import { segment } from './Segmenter';
import { CandidateEntry, DictionaryEntry } from './types';
import { CandidateScorer, ScoringContext, StaticWeightScorer } from './CandidateScorer';

// A shared no-context / static-frequency default so callers that don't pass a scorer (and #5's
// tests) get the exact pre-#6 static ordering without allocating on every call.
const STATIC_SCORER: CandidateScorer = new StaticWeightScorer();
const EMPTY_CONTEXT: ScoringContext = { precedingWords: [] };

// A candidate paired with its scorer output, plus its original position so ties resolve to the
// dictionary's static weight-descending order regardless of the engine's sort stability.
interface ScoredCandidate {
  entry: CandidateEntry;
  score: number;
  index: number;
}

/**
 * Ranked candidates for the current pinyin composition buffer.
 *
 * Candidate *set* selection is unchanged from #5: whole-buffer dictionary matches always win
 * first (looking up the buffer's concatenated pinyin key is invariant to how it's segmented into
 * syllables — e.g. "xian" and "xi"+"an" concatenate to the same key "xian" — so a single lookup
 * already surfaces every reading ambiguity, including multi-character whole-word matches like
 * "beijing" -> 北京). When nothing matches the whole buffer, falls back to the longest
 * legal-segmentation prefix that does have a match (deliberately not full multi-word chaining;
 * v1 clears the whole buffer on any confirm, see CompositionState).
 *
 * What #6 changes is candidate *ranking*: the selected set is re-ordered by a pluggable
 * `scorer` given the committed `context`, replacing #5's static-frequency-only order. With no
 * scorer/context supplied it falls back to a StaticWeightScorer over empty context, which
 * reproduces the exact #5 ordering — so this is a superset, not a behavior change, for callers
 * that don't opt into context.
 */
export function generateCandidates(
  buffer: string,
  dictionary: Dictionary,
  scorer?: CandidateScorer,
  context?: ScoringContext
): CandidateEntry[] {
  if (buffer.length === 0) {
    return [];
  }
  const paths = segment(buffer);
  if (paths.length === 0) {
    return [];
  }

  const entries = lookupCandidates(buffer, dictionary, paths);
  return rank(entries, scorer, context);
}

// The #5 candidate-set lookup, untouched: whole-buffer hit first, else longest legal prefix hit.
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

// Re-orders the selected candidates by the scorer's output, highest first. Ties (e.g. a scorer
// with no contextual signal returning equal scores) keep the dictionary's original weight-desc
// order via the `index` tiebreak, so the static-frequency ranking is preserved exactly whenever
// context adds nothing.
function rank(entries: CandidateEntry[], scorer?: CandidateScorer, context?: ScoringContext): CandidateEntry[] {
  if (entries.length <= 1) {
    return entries;
  }
  const activeScorer = scorer ?? STATIC_SCORER;
  const activeContext = context ?? EMPTY_CONTEXT;
  const scored = entries.map((entry: CandidateEntry, index: number): ScoredCandidate => {
    return { entry: entry, score: activeScorer.score(activeContext, entry), index: index };
  });
  scored.sort((a: ScoredCandidate, b: ScoredCandidate): number => {
    if (b.score !== a.score) {
      return b.score - a.score;
    }
    return a.index - b.index;
  });
  return scored.map((s: ScoredCandidate): CandidateEntry => s.entry);
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
