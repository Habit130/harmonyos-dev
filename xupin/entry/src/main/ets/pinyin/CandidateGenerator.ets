import { Dictionary } from './Dictionary';
import { segment } from './Segmenter';
import { CandidateEntry, DictionaryEntry } from './types';

/**
 * Ranked candidates for the current pinyin composition buffer.
 *
 * Whole-buffer dictionary matches always win first: looking up the buffer's concatenated
 * pinyin key is invariant to how it's segmented into syllables (e.g. "xian" and "xi"+"an"
 * concatenate to the same key "xian"), so a single lookup already surfaces every reading
 * ambiguity the dictionary knows about, including multi-character whole-word matches like
 * "beijing" -> 北京 outranking a char-by-char reading.
 *
 * When nothing matches the whole buffer (e.g. it's longer than any dictionary entry),
 * falls back to the longest legal-segmentation prefix that does have a match. This is
 * deliberately not full multi-word chaining: v1 clears the whole composition buffer on
 * any confirm (see CompositionState), so a candidate only ever needs to represent one
 * pick, not a full-sentence conversion.
 */
export function generateCandidates(buffer: string, dictionary: Dictionary): CandidateEntry[] {
  if (buffer.length === 0) {
    return [];
  }
  const paths = segment(buffer);
  if (paths.length === 0) {
    return [];
  }

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
