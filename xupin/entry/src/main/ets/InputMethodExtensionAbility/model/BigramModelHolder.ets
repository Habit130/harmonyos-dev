import { BigramModel } from '../../pinyin/BigramModel';

// Mirrors DictionaryHolder: a process-wide slot the extension fills once the bigram model asset
// is read at startup, so the panel UI can reach it without threading it through construction.
// Stays undefined until loaded (and if loading fails), which the UI treats as "no contextual
// evidence" and falls back to static-frequency ranking.
class BigramModelHolder {
  private model: BigramModel | undefined = undefined;

  setModel(model: BigramModel): void {
    this.model = model;
  }

  getModel(): BigramModel | undefined {
    return this.model;
  }
}

export const bigramModelHolder: BigramModelHolder = new BigramModelHolder();
