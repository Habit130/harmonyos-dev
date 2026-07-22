import { DictionaryEntry } from './types';

/**
 * Pinyin-key -> candidate word lookup. Pure and IO-free: construct it from already-read
 * text via `Dictionary.parse`, never from a file path or resourceManager directly, so it
 * stays unit-testable off-device (see RawFileDictionaryLoader for the on-device loader).
 */
export class Dictionary {
  private readonly entries: Map<string, DictionaryEntry[]>;
  // Unique keys in the order they first appear in the parsed TSV. tools/build-dict.py
  // writes keys in ascending sorted order, so this array is already sorted — parse() must
  // not let that order get lost inside the Map (whose iteration order isn't something
  // prefixLookup()'s binary search should depend on). No re-sort here: relying on the
  // build script's guarantee avoids an O(n log n) pass over ~163k keys on every load.
  private readonly sortedKeys: string[];

  private constructor(entries: Map<string, DictionaryEntry[]>, sortedKeys: string[]) {
    this.entries = entries;
    this.sortedKeys = sortedKeys;
  }

  /**
   * Parses the `pinyinKey\tword\tweight` TSV format produced by tools/build-dict.py.
   * Entries are expected pre-sorted weight-descending within each key (the build script
   * guarantees this), so lookup() does no runtime sorting. Keys are likewise expected
   * pre-sorted ascending across the whole file (see `sortedKeys`), for prefixLookup().
   */
  static parse(text: string): Dictionary {
    const entries = new Map<string, DictionaryEntry[]>();
    const sortedKeys: string[] = [];
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.length === 0) {
        continue;
      }
      const parts = line.split('\t');
      if (parts.length !== 3) {
        continue;
      }
      const key = parts[0];
      const word = parts[1];
      const weight = Number(parts[2]);
      let bucket = entries.get(key);
      if (bucket === undefined) {
        bucket = [];
        entries.set(key, bucket);
        sortedKeys.push(key);
      }
      bucket.push({ word, weight });
    }
    return new Dictionary(entries, sortedKeys);
  }

  lookup(pinyinKey: string): DictionaryEntry[] {
    return this.entries.get(pinyinKey) ?? [];
  }

  /**
   * Every dictionary entry whose key has `prefix` as a leading substring (e.g. prefix
   * "xih" matches key "xihuan"), found via binary search over `sortedKeys` rather than a
   * linear scan. Unlike lookup(), `prefix` itself doesn't need to be a legal pinyin
   * syllable or a dictionary key on its own — this backs mid-composition completion
   * candidates (issue #15) for buffers segment() can't fully split yet.
   */
  prefixLookup(prefix: string): DictionaryEntry[] {
    if (prefix.length === 0) {
      return [];
    }
    const lo = this.lowerBound(prefix);
    const hi = this.lowerBound(exclusiveUpperBound(prefix));
    const result: DictionaryEntry[] = [];
    for (let i = lo; i < hi; i++) {
      const bucket = this.entries.get(this.sortedKeys[i]) ?? [];
      for (let j = 0; j < bucket.length; j++) {
        result.push(bucket[j]);
      }
    }
    return result;
  }

  // First index in sortedKeys whose key is >= target; sortedKeys.length if none is.
  private lowerBound(target: string): number {
    let lo = 0;
    let hi = this.sortedKeys.length;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      if (this.sortedKeys[mid] < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

// Smallest string that sorts after every string having `prefix` as a leading substring:
// bump the last character's code point by one (e.g. "xih" -> "xii"). Pinyin keys are
// lowercase ASCII letters only, so there's no surrogate-pair/multi-byte case to handle.
function exclusiveUpperBound(prefix: string): string {
  const lastCharCode = prefix.charCodeAt(prefix.length - 1);
  return prefix.substring(0, prefix.length - 1) + String.fromCharCode(lastCharCode + 1);
}
