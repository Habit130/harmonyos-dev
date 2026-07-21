/**
 * Result of a backspace press, telling the caller whether it was absorbed by shrinking
 * the (not-yet-committed) composition buffer, or needs to delete already-committed text
 * from the target field.
 */
export interface BackspaceResult {
  handledInBuffer: boolean;
  /** UTF-16 code units to delete via the target field's deleteForwardSync. Only
   * meaningful when handledInBuffer is false; zero when there's nothing to delete. */
  deleteLength: number;
}

/**
 * Tracks the pinyin composition buffer and a history of committed segments, purely in
 * memory — it never touches the target text field itself (that's the UI layer's job).
 * The composition buffer is rendered in the IME's own panel, not as inline preview text
 * in the target field (see PR notes for why: no acceptance criterion requires touching
 * the target field mid-composition, and IMEKit's setPreviewText isn't supported by every
 * target editor).
 *
 * Backspace semantics (PRD acceptance criteria):
 * - composing (buffer non-empty): removes the last typed pinyin letter.
 * - not composing (buffer empty), with history: removes the last *committed* segment (a
 *   candidate word, or a literal space/punctuation) from the target field — tracked via
 *   `history` since we have no way to read the target field's existing content back.
 * - not composing, with no history (e.g. content in the field predates this composition
 *   session): falls back to deleting 1 character ahead of the cursor, the standard IME
 *   backspace default, rather than doing nothing.
 */
export class CompositionState {
  private buffer: string[] = [];
  private history: string[] = [];

  get compositionText(): string {
    return this.buffer.join('');
  }

  isComposing(): boolean {
    return this.buffer.length > 0;
  }

  typeLetter(letter: string): void {
    this.buffer.push(letter);
  }

  /**
   * Confirms `text` (a candidate word, or a literal space/punctuation), trims the leading
   * `matchedLength` characters it covers off the composition buffer, and records it for
   * future backspace. Any buffer characters beyond `matchedLength` (a candidate that only
   * covered a prefix of the buffer) stay put, still composing. Returns `text` so the
   * caller can insert it into the target field.
   */
  confirm(text: string, matchedLength: number): string {
    this.buffer = this.buffer.slice(matchedLength);
    this.history.push(text);
    return text;
  }

  backspace(): BackspaceResult {
    if (this.isComposing()) {
      this.buffer.pop();
      return { handledInBuffer: true, deleteLength: 0 };
    }
    const last = this.history.pop();
    if (last === undefined) {
      return { handledInBuffer: false, deleteLength: 1 };
    }
    return { handledInBuffer: false, deleteLength: last.length };
  }
}
