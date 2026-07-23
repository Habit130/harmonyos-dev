import { describe, it, expect } from '@ohos/hypium';
import { Tokenizer } from '../../main/ets/pinyin/Tokenizer';

// A small synthetic vocab, NOT the real checkpoint's vocab.txt (issue #20 spike: the real
// checkpoint's license isn't confirmed yet — see xupin/docs/spike-20-neural-ranking.md's
// "License status" section — so no checkpoint-derived data is committed here; this fixture
// only needs to exercise the parsing rules Tokenizer.parse() implements). Line index is the
// token id, matching vocab.txt's convention.
const FIXTURE_VOCAB = [
  '[PAD]',   // 0
  '[UNK]',   // 1
  '[CLS]',   // 2
  '[SEP]',   // 3
  '你',      // 4
  '好',      // 5
  '##你',    // 6 - WordPiece continuation duplicate of line 4, must never be matched directly
  'ing',     // 7 - ASCII multi-char, excluded
  '网络',    // 8 - CJK multi-char, excluded (not a per-character entry)
  '吗',      // 9
].join('\n');

export default function tokenizerTest() {
  describe('TokenizerTest', () => {
    it('maps known characters to their vocab line index', 0, () => {
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      expect(tokenizer.encode('你好')).assertDeepEquals([4, 5]);
      expect(tokenizer.encode('你好吗')).assertDeepEquals([4, 5, 9]);
    });

    it('falls back to [UNK]\'s id for characters missing from the vocab', 0, () => {
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      // 什 and 么 aren't in the fixture vocab at all.
      expect(tokenizer.encode('你什么')).assertDeepEquals([4, 1, 1]);
    });

    it('never matches a multi-character vocab entry per-character', 0, () => {
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      // "网络" (line 8) and "ing" (line 7) are vocab entries, but as whole multi-character
      // tokens — encoding their individual characters must miss and fall back to [UNK],
      // proving Tokenizer.parse() didn't index them per-character.
      expect(tokenizer.encode('网')).assertDeepEquals([1]);
      expect(tokenizer.encode('i')).assertDeepEquals([1]);
    });

    it('never resolves a character to its WordPiece "##"-continuation duplicate', 0, () => {
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      // line 6 is "##你" — encode('你') must resolve to the plain entry (line 4), proving
      // the "##" variant was excluded from the char map rather than silently shadowing it.
      expect(tokenizer.encode('你')).assertDeepEquals([4]);
    });

    it('returns an empty array for empty input', 0, () => {
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      expect(tokenizer.encode('').length).assertEqual(0);
    });

    it('exposes [CLS] and [PAD]\'s vocab ids (issue #22 D5/D9 batch-row construction)', 0, () => {
      const tokenizer = Tokenizer.parse(FIXTURE_VOCAB);
      expect(tokenizer.clsId()).assertEqual(2);
      expect(tokenizer.padId()).assertEqual(0);
    });
  });
}
