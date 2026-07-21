import { describe, it, expect } from '@ohos/hypium';
import { CompositionState } from '../../../main/ets/InputMethodExtensionAbility/model/CompositionState';

export default function compositionStateTest() {
  describe('CompositionStateTest', () => {
    it('accumulates typed letters into the composition text', 0, () => {
      const state = new CompositionState();
      state.typeLetter('b');
      state.typeLetter('e');
      state.typeLetter('i');
      expect(state.compositionText).assertEqual('bei');
      expect(state.isComposing()).assertTrue();
    });

    it('clears the buffer and records history on a full-buffer confirm', 0, () => {
      const state = new CompositionState();
      state.typeLetter('b');
      state.typeLetter('e');
      state.typeLetter('i');
      const inserted = state.confirm('北', 3);
      expect(inserted).assertEqual('北');
      expect(state.compositionText).assertEqual('');
      expect(state.isComposing()).assertFalse();
    });

    it('confirm only trims the matched prefix, leaving unmatched letters composing', 0, () => {
      // Mirrors the "xianzaiba" repro from issue #13: a candidate only covers a prefix of
      // the typed buffer, so the trailing unmatched letters must stay in the buffer
      // instead of being silently dropped.
      const state = new CompositionState();
      'xianzaiba'.split('').forEach((letter: string) => state.typeLetter(letter));
      const inserted = state.confirm('现在', 7); // covers "xianzai", not the trailing "ba"
      expect(inserted).assertEqual('现在');
      expect(state.compositionText).assertEqual('ba');
      expect(state.isComposing()).assertTrue();
    });

    it('backspace while composing removes only the last pinyin letter', 0, () => {
      const state = new CompositionState();
      state.typeLetter('b');
      state.typeLetter('e');
      state.typeLetter('i');
      const result = state.backspace();
      expect(result.handledInBuffer).assertTrue();
      expect(result.deleteLength).assertEqual(0);
      expect(state.compositionText).assertEqual('be');
    });

    it('backspace on an empty buffer deletes the last committed segment by its length', 0, () => {
      const state = new CompositionState();
      state.typeLetter('b');
      state.typeLetter('e');
      state.typeLetter('i');
      state.confirm('北京', 3); // a 2-character candidate word, full-buffer match

      const result = state.backspace();
      expect(result.handledInBuffer).assertFalse();
      expect(result.deleteLength).assertEqual(2);
    });

    it('backspace with an empty buffer and no history falls back to deleting 1 character', 0, () => {
      const state = new CompositionState();
      const result = state.backspace();
      expect(result.handledInBuffer).assertFalse();
      expect(result.deleteLength).assertEqual(1);
    });

    it('literal confirms (space/punctuation) are tracked for backspace too', 0, () => {
      const state = new CompositionState();
      state.confirm('，', 0);
      const result = state.backspace();
      expect(result.handledInBuffer).assertFalse();
      expect(result.deleteLength).assertEqual(1);
    });
  });
}
