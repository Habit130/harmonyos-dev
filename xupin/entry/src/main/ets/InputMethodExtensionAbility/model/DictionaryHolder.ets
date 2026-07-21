import { Dictionary } from '../../pinyin/Dictionary';

class DictionaryHolder {
  private dictionary: Dictionary | undefined = undefined;

  setDictionary(dictionary: Dictionary): void {
    this.dictionary = dictionary;
  }

  getDictionary(): Dictionary | undefined {
    return this.dictionary;
  }
}

export const dictionaryHolder: DictionaryHolder = new DictionaryHolder();
