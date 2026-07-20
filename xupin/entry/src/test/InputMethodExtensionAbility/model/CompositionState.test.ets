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

    it('clears the buffer and records history on confirm', 0, () => {
      const state = new CompositionState();
      state.typeLetter('b');
      state.typeLetter('e');
      state.typeLetter('i');
      const inserted = state.confirm('北');
      expect(inserted).assertEqual('北');
      expect(state.compositionText).assertEqual('');
      expect(state.isComposing()).assertFalse();
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
      state.confirm('北京'); // a 2-character candidate word

      const result = state.backspace();
      expect(result.handledInBuffer).assertFalse();
      expect(result.deleteLength).assertEqual(2);
    });

    it('backspace with an empty buffer and no history is a no-op', 0, () => {
      const state = new CompositionState();
      const result = state.backspace();
      expect(result.handledInBuffer).assertFalse();
      expect(result.deleteLength).assertEqual(0);
    });

    it('literal confirms (space/punctuation) are tracked for backspace too', 0, () => {
      const state = new CompositionState();
      state.confirm('，');
      const result = state.backspace();
      expect(result.handledInBuffer).assertFalse();
      expect(result.deleteLength).assertEqual(1);
    });
  });
}
