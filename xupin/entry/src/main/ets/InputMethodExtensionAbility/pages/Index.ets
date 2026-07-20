import { hilog } from '@kit.PerformanceAnalysisKit';
import { inputClientHolder } from '../model/InputClientHolder';
import { dictionaryHolder } from '../model/DictionaryHolder';
import { CompositionState } from '../model/CompositionState';
import { generateCandidates } from '../../pinyin/CandidateGenerator';
import { CandidateEntry } from '../../pinyin/types';

const DOMAIN = 0x0000;
const TAG = 'XupinIME';

const LETTER_ROWS: string[][] = [
  ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
  ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
  ['z', 'x', 'c', 'v', 'b', 'n', 'm']
];

const NUMBER_SYMBOL_ROWS: string[][] = [
  ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
  ['-', '/', ':', ';', '(', ')', '¥', '&', '@', '"'],
  ['.', ',', '?', '!', "'"]
];

enum PanelMode {
  LETTERS,
  NUMBER_SYMBOL
}

@Entry
@Component
struct Index {
  @State mode: PanelMode = PanelMode.LETTERS;
  @State compositionText: string = '';
  @State candidates: CandidateEntry[] = [];

  private composition: CompositionState = new CompositionState();

  // Candidates are shown in a panel-only composition bar, not as inline preview text in
  // the target field (IMEKit's setPreviewText isn't supported by every target editor, and
  // no acceptance criterion needs the target field touched mid-composition). So a letter
  // key never calls insertTextSync — only a confirmed candidate or literal does.
  private onLetterKey(letter: string): void {
    this.composition.typeLetter(letter);
    this.refreshCandidates();
  }

  private onCandidateClick(word: string): void {
    this.confirm(word);
  }

  private onSpace(): void {
    if (this.composition.isComposing()) {
      this.confirm(this.bestCandidateOrRawBuffer());
    }
    this.confirm(' ');
  }

  // Any key on the number/symbol panel (digits and punctuation alike) implicitly confirms
  // pending composition first, then inserts itself — the PRD only calls out punctuation
  // explicitly, but treating digits the same avoids an arbitrary special case.
  private onNumberSymbolKey(char: string): void {
    if (this.composition.isComposing()) {
      this.confirm(this.bestCandidateOrRawBuffer());
    }
    this.confirm(char);
  }

  private onBackspace(): void {
    const result = this.composition.backspace();
    if (!result.handledInBuffer && result.deleteLength > 0) {
      const client = inputClientHolder.getClient();
      if (!client) {
        hilog.warn(DOMAIN, TAG, 'backspace: no bound InputClient');
      } else {
        client.deleteForwardSync(result.deleteLength);
      }
    }
    this.refreshCandidates();
  }

  private confirm(text: string): void {
    const inserted = this.composition.confirm(text);
    const client = inputClientHolder.getClient();
    if (!client) {
      hilog.warn(DOMAIN, TAG, 'confirm: no bound InputClient');
    } else {
      client.insertTextSync(inserted);
    }
    this.refreshCandidates();
  }

  private bestCandidateOrRawBuffer(): string {
    if (this.candidates.length > 0) {
      return this.candidates[0].word;
    }
    // No dictionary match (unrecognized or still-ambiguous pinyin): fall back to
    // committing the raw letters rather than silently dropping what the user typed.
    return this.composition.compositionText;
  }

  private refreshCandidates(): void {
    this.compositionText = this.composition.compositionText;
    const dictionary = dictionaryHolder.getDictionary();
    if (!dictionary || this.compositionText.length === 0) {
      this.candidates = [];
      return;
    }
    this.candidates = generateCandidates(this.compositionText, dictionary);
  }

  @Builder
  keyButton(label: string) {
    Text(label)
      .fontSize(18)
      .fontColor(Color.Black)
      .backgroundColor(Color.White)
      .borderRadius(6)
      .textAlign(TextAlign.Center)
      .height(44)
      .layoutWeight(1)
      .margin(2)
      .onClick(() => {
        if (this.mode === PanelMode.LETTERS) {
          this.onLetterKey(label);
        } else {
          this.onNumberSymbolKey(label);
        }
      })
  }

  @Builder
  keyRow(keys: string[]) {
    Row({ space: 4 }) {
      ForEach(keys, (key: string) => {
        this.keyButton(key)
      }, (key: string) => key)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  candidateBar() {
    Row({ space: 4 }) {
      if (this.compositionText.length > 0) {
        Text(this.compositionText)
          .fontSize(16)
          .fontColor(Color.Gray)
          .margin({ right: 8 })
      }
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.candidates, (candidate: CandidateEntry) => {
            Text(candidate.word)
              .fontSize(18)
              .fontColor(Color.Black)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .onClick(() => this.onCandidateClick(candidate.word))
          }, (candidate: CandidateEntry) => candidate.word)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height(36)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column({ space: 6 }) {
      if (this.compositionText.length > 0) {
        this.candidateBar()
      }

      if (this.mode === PanelMode.LETTERS) {
        this.keyRow(LETTER_ROWS[0])
        this.keyRow(LETTER_ROWS[1])
        this.keyRow(LETTER_ROWS[2])
      } else {
        this.keyRow(NUMBER_SYMBOL_ROWS[0])
        this.keyRow(NUMBER_SYMBOL_ROWS[1])
        this.keyRow(NUMBER_SYMBOL_ROWS[2])
      }

      Row({ space: 4 }) {
        Button(this.mode === PanelMode.LETTERS ? '?123' : 'ABC')
          .fontSize(16)
          .onClick(() => {
            this.mode = this.mode === PanelMode.LETTERS ? PanelMode.NUMBER_SYMBOL : PanelMode.LETTERS;
          })
        Button('空格')
          .fontSize(16)
          .layoutWeight(1)
          .onClick(() => this.onSpace())
        Button('删除')
          .fontSize(16)
          .onClick(() => this.onBackspace())
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#D5D8DD')
    .justifyContent(FlexAlign.Center)
    .padding(8)
  }
}
