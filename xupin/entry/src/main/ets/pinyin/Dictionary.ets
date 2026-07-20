import { CandidateEntry } from './types';

/**
 * Pinyin-key -> candidate word lookup. Pure and IO-free: construct it from already-read
 * text via `Dictionary.parse`, never from a file path or resourceManager directly, so it
 * stays unit-testable off-device (see RawFileDictionaryLoader for the on-device loader).
 */
export class Dictionary {
  private readonly entries: Map<string, CandidateEntry[]>;

  private constructor(entries: Map<string, CandidateEntry[]>) {
    this.entries = entries;
  }

  /**
   * Parses the `pinyinKey\tword\tweight` TSV format produced by tools/build-dict.py.
   * Entries are expected pre-sorted weight-descending within each key (the build script
   * guarantees this), so lookup() does no runtime sorting.
   */
  static parse(text: string): Dictionary {
    const entries = new Map<string, CandidateEntry[]>();
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
      }
      bucket.push({ word, weight });
    }
    return new Dictionary(entries);
  }

  lookup(pinyinKey: string): CandidateEntry[] {
    return this.entries.get(pinyinKey) ?? [];
  }
}
