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

// Widest row across both panels (qwertyuiop / the digit row), used so every row's keys
// share one consistent width: shorter rows get Blank() spacers on both ends instead of
// stretching their own keys wider (see keyRow).
const MAX_ROW_LENGTH = 10;

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

  // Bumped by InputMethodService on every inputStart (new InputClient bound). Business
  // logic outside this component can't touch @State directly, so it signals through
  // AppStorage instead — @StorageLink + @Watch is the documented bridge for exactly this
  // (see ArkUI state-management guide, AppStorage section; matches the official IME Kit
  // sample's `subtypeChange` pattern). The key literal here must match the one
  // InputMethodService.ets writes to.
  @StorageLink('xupinCompositionResetSeq') @Watch('onCompositionResetSeqChange') compositionResetSeq: number = 0;

  private composition: CompositionState = new CompositionState();

  private onCompositionResetSeqChange(): void {
    this.composition = new CompositionState();
    this.compositionText = '';
    this.candidates = [];
  }

  // Candidates are shown in a panel-only composition bar, not as inline preview text in
  // the target field (IMEKit's setPreviewText isn't supported by every target editor, and
  // no acceptance criterion needs the target field touched mid-composition). So a letter
  // key never calls insertTextSync — only a confirmed candidate or literal does.
  private onLetterKey(letter: string): void {
    this.composition.typeLetter(letter);
    this.refreshCandidates();
  }

  private onCandidateClick(candidate: CandidateEntry): void {
    this.confirm(candidate.word, candidate.matchedLength);
  }

  private onSpace(): void {
    if (this.composition.isComposing()) {
      const best = this.bestCandidateOrRawBuffer();
      this.confirm(best.word, best.matchedLength);
    } else {
      this.confirm(' ', 0);
    }
  }

  // Any key on the number/symbol panel (digits and punctuation alike) implicitly confirms
  // pending composition first, then inserts itself — the PRD only calls out punctuation
  // explicitly, but treating digits the same avoids an arbitrary special case. The literal
  // char itself never matches any buffer content (matchedLength 0), so any pinyin left
  // over after confirming the candidate stays put, still composing.
  private onNumberSymbolKey(char: string): void {
    if (this.composition.isComposing()) {
      const best = this.bestCandidateOrRawBuffer();
      this.confirm(best.word, best.matchedLength);
    }
    this.confirm(char, 0);
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

  private confirm(text: string, matchedLength: number): void {
    const inserted = this.composition.confirm(text, matchedLength);
    const client = inputClientHolder.getClient();
    if (!client) {
      hilog.warn(DOMAIN, TAG, 'confirm: no bound InputClient');
    } else {
      client.insertTextSync(inserted);
    }
    this.refreshCandidates();
  }

  private bestCandidateOrRawBuffer(): CandidateEntry {
    if (this.candidates.length > 0) {
      return this.candidates[0];
    }
    // No dictionary match (unrecognized or still-ambiguous pinyin): fall back to
    // committing the raw letters rather than silently dropping what the user typed.
    // weight is unused past this point — 0 is just a harmless placeholder.
    const raw = this.composition.compositionText;
    return { word: raw, weight: 0, matchedLength: raw.length };
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

  // Every key shares one width (relative to the widest row, MAX_ROW_LENGTH) instead of
  // each row stretching its own keys to fill 100% independently — otherwise a 7-key row
  // ends up with visibly wider keys than a 10-key row. Shorter rows get Blank() spacers
  // (which auto-fill leftover main-axis space, see ArkUI linear-layout guide) split evenly
  // across both ends, so they end up centered with real-keyboard-style indentation instead
  // of stretched.
  @Builder
  keyRow(keys: string[]) {
    Row({ space: 4 }) {
      if (keys.length < MAX_ROW_LENGTH) {
        Blank().layoutWeight((MAX_ROW_LENGTH - keys.length) / 2)
      }
      ForEach(keys, (key: string) => {
        this.keyButton(key)
      }, (key: string) => key)
      if (keys.length < MAX_ROW_LENGTH) {
        Blank().layoutWeight((MAX_ROW_LENGTH - keys.length) / 2)
      }
    }
    .width('100%')
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
              .onClick(() => this.onCandidateClick(candidate))
          }, (candidate: CandidateEntry) => candidate.word)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      // Scroll's own content-alignment default is Alignment.Center (see ArkUI's universal
      // `align` attribute): with few candidates the inner Row is narrower than this
      // layoutWeight(1) box, so it was centering in the middle of the bar instead of
      // hugging the left edge next to the pinyin buffer text (issue #15).
      .align(Alignment.Start)
    }
    .width('100%')
    .height(36)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column({ space: 6 }) {
      // Always mounted at a fixed height (see candidateBar) so it reserves its place in
      // the layout even with no composition — otherwise the keyboard below shifts up/down
      // as the bar mounts/unmounts under the Column's centered justifyContent.
      this.candidateBar()

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
