import { LEGAL_SYLLABLES } from './syllables';

const SYLLABLE_SET: Set<string> = new Set(LEGAL_SYLLABLES);
const MAX_SYLLABLE_LENGTH: number = LEGAL_SYLLABLES.reduce(
  (max: number, syllable: string): number => Math.max(max, syllable.length), 0);

// Defensive cap on enumerated paths: guards against pathological long buffers with many
// ambiguous boundaries. Real typing buffers stay short in v1 because confirming any
// candidate clears the whole composition buffer (see CompositionState).
const MAX_PATHS = 256;

/**
 * Finds every legal way to split `buffer` into a sequence of pinyin syllables that
 * together consume the whole string. Returns [] if `buffer` cannot be fully segmented
 * (e.g. it's an incomplete syllable the user hasn't finished typing yet).
 *
 * Ambiguous input like "xian" legitimately segments two ways and both are returned:
 * segment("xian") -> [["xian"], ["xi", "an"]]
 */
export function segment(buffer: string): string[][] {
  if (buffer.length === 0) {
    return [];
  }
  const paths: string[][] = [];
  const current: string[] = [];
  search(buffer, 0, current, paths);
  return paths;
}

// Backtracking search over syllable-boundary positions, accumulating full segmentations
// (paths where every syllable is legal and together they consume the whole buffer) into
// `paths`. Not nested inside `segment` because ArkTS disallows nested function
// declarations (arkts-no-nested-funcs).
function search(buffer: string, pos: number, current: string[], paths: string[][]): void {
  if (paths.length >= MAX_PATHS) {
    return;
  }
  if (pos === buffer.length) {
    paths.push(current.slice());
    return;
  }
  const maxLen = Math.min(MAX_SYLLABLE_LENGTH, buffer.length - pos);
  for (let len = 1; len <= maxLen; len++) {
    const syllable = buffer.substring(pos, pos + len);
    if (SYLLABLE_SET.has(syllable)) {
      current.push(syllable);
      search(buffer, pos + len, current, paths);
      current.pop();
      if (paths.length >= MAX_PATHS) {
        return;
      }
    }
  }
}
