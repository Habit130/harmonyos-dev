import { Tokenizer } from '../../pinyin/Tokenizer';

class TokenizerHolder {
  private tokenizer: Tokenizer | undefined = undefined;

  setTokenizer(tokenizer: Tokenizer): void {
    this.tokenizer = tokenizer;
  }

  getTokenizer(): Tokenizer | undefined {
    return this.tokenizer;
  }
}

export const tokenizerHolder: TokenizerHolder = new TokenizerHolder();
