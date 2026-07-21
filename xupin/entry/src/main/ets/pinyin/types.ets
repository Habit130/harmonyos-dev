/** A dictionary entry as stored/looked up, before it's tied to any particular buffer match. */
export interface DictionaryEntry {
  word: string;
  weight: number;
}

/**
 * A dictionary entry ranked as a candidate for the current composition buffer.
 * `matchedLength` is how many leading buffer characters this candidate actually covers —
 * the full buffer on a whole-buffer hit, or a shorter prefix on a fallback match (see
 * CandidateGenerator). CompositionState.confirm() uses it to trim only the matched
 * portion off the buffer, leaving any unmatched trailing letters in place.
 */
export interface CandidateEntry {
  word: string;
  weight: number;
  matchedLength: number;
}
