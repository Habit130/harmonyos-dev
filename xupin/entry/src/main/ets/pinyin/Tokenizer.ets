/**
 * Char-level tokenizer aligned with the neural checkpoint's vocab format (issue #20 spike:
 * confirmed `uer/gpt2-chinese-cluecorpussmall` tokenizes Chinese text one character at a time,
 * via a BERT/WordPiece-style `vocab.txt` where line index is the token id and each line is a
 * plain token or one of two "does this continue a word" variants of the same character
 * (`发` vs `##发`) — see `xupin/docs/spike-20-neural-ranking.md` §1 for the full analysis,
 * including a live `encode()` transcript on this project's own PRD example words. WordPiece's
 * `##`-continuation form never actually fires for isolated CJK characters (BERT's
 * `_tokenize_chinese_chars` pre-splits every Chinese character into its own single-character
 * "word" before WordPiece runs), so this tokenizer only needs the plain single-character
 * entries — no multi-character merge/greedy-longest-match logic.
 *
 * Pure and IO-free like Dictionary: construct from already-read vocab text, never from a file
 * path or resourceManager directly, so it stays unit-testable off-device (the on-device loader
 * lives in InputMethodExtensionAbility/model/TokenizerHolder.ets).
 */
export class Tokenizer {
  private readonly charToId: Map<string, number>;
  private readonly unknownId: number;
  private readonly startId: number;
  private readonly paddingId: number;

  private constructor(charToId: Map<string, number>, unknownId: number, startId: number, paddingId: number) {
    this.charToId = charToId;
    this.unknownId = unknownId;
    this.startId = startId;
    this.paddingId = paddingId;
  }

  /**
   * Parses a `vocab.txt`-style file: one token per line, line index is the token id. Keeps
   * only single non-ASCII characters (the plain, non-`##`-prefixed CJK entries — `##`-prefixed
   * duplicates of the same characters are skipped, per the file doc above) plus `[UNK]`/`[CLS]`/
   * `[PAD]`'s ids. `[UNK]` is encode()'s out-of-vocabulary fallback; `[CLS]`/`[PAD]` are for
   * NeuralScorer's batch row construction (issue #22 D5's empty-context start anchor, and
   * padding rows/positions out to the model's fixed sequence length — see that file). Other
   * multi-character/ASCII/digit entries (WordPiece subword fragments for non-Chinese text) are
   * dropped — this project only ever tokenizes Chinese candidate words and context (see
   * CONTEXT.md's 候选词 definition).
   */
  static parse(vocabText: string): Tokenizer {
    const lines = vocabText.split('\n');
    const charToId = new Map<string, number>();
    let unknownId = -1;
    let startId = -1;
    let paddingId = -1;
    for (let i = 0; i < lines.length; i++) {
      const token = stripTrailingCr(lines[i]);
      if (token === '[UNK]') {
        unknownId = i;
        continue;
      }
      if (token === '[CLS]') {
        startId = i;
        continue;
      }
      if (token === '[PAD]') {
        paddingId = i;
        continue;
      }
      if (token.length === 1 && token.charCodeAt(0) > 127) {
        charToId.set(token, i);
      }
    }
    return new Tokenizer(charToId, unknownId, startId, paddingId);
  }

  /** Maps each character to its vocab id, in order; unmapped characters become [UNK]. */
  encode(text: string): number[] {
    const ids: number[] = [];
    const chars = Array.from(text);
    for (let i = 0; i < chars.length; i++) {
      ids.push(this.charToId.get(chars[i]) ?? this.unknownId);
    }
    return ids;
  }

  /**
   * `[CLS]`'s vocab id — used as the single-token start-of-sequence anchor when there's no
   * committed context yet (issue #22 D5). Confirmed a genuine trained start anchor for
   * `uer/gpt2-chinese-cluecorpussmall`, not assumed — see
   * `xupin/docs/issue-22-shape-fix.md` §1 for the empirical check.
   */
  clsId(): number {
    return this.startId;
  }

  /** `[PAD]`'s vocab id — used to right-pad batch rows out to the model's fixed sequence length. */
  padId(): number {
    return this.paddingId;
  }
}

function stripTrailingCr(line: string): string {
  return line.length > 0 && line.charAt(line.length - 1) === '\r' ? line.slice(0, -1) : line;
}
