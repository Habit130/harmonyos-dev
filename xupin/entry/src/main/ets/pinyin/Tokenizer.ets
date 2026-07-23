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

  private constructor(charToId: Map<string, number>, unknownId: number) {
    this.charToId = charToId;
    this.unknownId = unknownId;
  }

  /**
   * Parses a `vocab.txt`-style file: one token per line, line index is the token id. Keeps
   * only single non-ASCII characters (the plain, non-`##`-prefixed CJK entries — `##`-prefixed
   * duplicates of the same characters are skipped, per the file doc above) plus `[UNK]`'s id
   * for encode()'s out-of-vocabulary fallback. Multi-character/ASCII/digit entries (WordPiece
   * subword fragments for non-Chinese text) are dropped — this project only ever tokenizes
   * Chinese candidate words and context (see CONTEXT.md's 候选词 definition).
   */
  static parse(vocabText: string): Tokenizer {
    const lines = vocabText.split('\n');
    const charToId = new Map<string, number>();
    let unknownId = -1;
    for (let i = 0; i < lines.length; i++) {
      const token = stripTrailingCr(lines[i]);
      if (token === '[UNK]') {
        unknownId = i;
        continue;
      }
      if (token.length === 1 && token.charCodeAt(0) > 127) {
        charToId.set(token, i);
      }
    }
    return new Tokenizer(charToId, unknownId);
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
}

function stripTrailingCr(line: string): string {
  return line.length > 0 && line.charAt(line.length - 1) === '\r' ? line.slice(0, -1) : line;
}
