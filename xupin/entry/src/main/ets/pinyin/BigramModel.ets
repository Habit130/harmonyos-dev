/**
 * Word-level bigram counts: how often each word was seen immediately following a given
 * preceding word in a training corpus (see tools/build-bigram.py). Pure and IO-free like
 * Dictionary — construct it from already-read text via `BigramModel.parse`, never from a file
 * path or resourceManager, so the scoring layer built on top stays unit-testable off-device.
 *
 * Where the static Dictionary answers "which words can this pinyin be", this answers "given the
 * last committed word, which of those candidates more likely comes next" — the statistical basis
 * for context-aware ranking (issue #6; see CONTEXT.md's 训练语料 vs 词典数据 distinction).
 *
 * A first-order (bigram) model only: it looks back exactly one word. Ranking a candidate set is
 * always done under a single fixed preceding word, so raw counts rank identically to normalized
 * conditional probabilities — the model deliberately stores counts and leaves any normalization
 * to the scorer, keeping the asset compact.
 */
export class BigramModel {
  // prevWord -> (word -> observed count)
  private readonly successors: Map<string, Map<string, number>>;

  private constructor(successors: Map<string, Map<string, number>>) {
    this.successors = successors;
  }

  /**
   * Parses the `prevWord\tword\tcount` TSV produced by tools/build-bigram.py. `parse('')`
   * yields an empty model, which every scorer treats as "no contextual evidence".
   */
  static parse(text: string): BigramModel {
    const successors = new Map<string, Map<string, number>>();
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
      const prev = parts[0];
      const word = parts[1];
      const count = Number(parts[2]);
      let bucket = successors.get(prev);
      if (bucket === undefined) {
        bucket = new Map<string, number>();
        successors.set(prev, bucket);
      }
      bucket.set(word, count);
    }
    return new BigramModel(successors);
  }

  /**
   * How many times `word` was observed immediately after `prevWord`; 0 when that pair was never
   * seen or either word is unknown to the model (so the scorer's bigram term vanishes gracefully).
   */
  count(prevWord: string, word: string): number {
    const bucket = this.successors.get(prevWord);
    if (bucket === undefined) {
      return 0;
    }
    return bucket.get(word) ?? 0;
  }
}
