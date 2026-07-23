import { hilog } from '@kit.PerformanceAnalysisKit';
import { inputClientHolder } from '../model/InputClientHolder';
import { dictionaryHolder } from '../model/DictionaryHolder';
import { tokenizerHolder } from '../model/TokenizerHolder';
import { neuralModelHolder } from '../model/NeuralModelHolder';
import { CompositionState } from '../model/CompositionState';
import { generateCandidates } from '../../pinyin/CandidateGenerator';
import { CandidateEntry } from '../../pinyin/types';
import { NeuralScorer, RankedCandidates, rankCandidates } from '../../pinyin/NeuralScorer';
import { ScoringContext } from '../../pinyin/CandidateScorer';

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
  // Issue #22 D7/D8: whether the neural model actually participated in producing the CURRENT
  // this.candidates order — the only user-visible signal for "did context-aware ranking run
  // this round", via the first candidate's style (see candidateBar()/firstCandidateStyle()).
  @State neuralRanked: boolean = false;

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
    this.neuralRanked = false;
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

  // Async since issue #20; issue #22 D6 changed this to exactly one UI assignment per keystroke
  // (was two: an immediate static-only assignment, then an overwrite once the neural rerank
  // resolved). **Compile-only verified** — see xupin/docs/issue-22-shape-fix.md and
  // xupin/docs/spike-20-neural-ranking.md for why the neural path itself can't be exercised
  // off-device; the static-only path (dictionary present, neural assets absent) is the same
  // code that was already real-device-verified pre-#20.
  private async refreshCandidates(): Promise<void> {
    const buffer = this.composition.compositionText;
    this.compositionText = buffer;
    const dictionary = dictionaryHolder.getDictionary();
    if (!dictionary || buffer.length === 0) {
      this.candidates = [];
      this.neuralRanked = false;
      return;
    }

    // Issue #22 D8: turn the "neural participated" style off the instant this keystroke starts
    // being processed. `this.candidates` is deliberately left untouched here (still the
    // previous keystroke's list) until the single assignment below, so the bar never flashes
    // empty or shows an intermediate static-only reorder while a batched forward pass is in
    // flight — the same flag doubles as "still computing" and "this round has no neural score"
    // (D8: "同一个样式通道同时表达「正在算」和「没生效」"); both render identically, see
    // candidateBar()/firstCandidateStyle().
    this.neuralRanked = false;

    const model = neuralModelHolder.getModel();
    const tokenizer = tokenizerHolder.getTokenizer();
    const scorer = model && tokenizer ? new NeuralScorer(model, tokenizer) : undefined;
    if (!scorer) {
      // Issue #22 D7: no longer a silent degrade — pre-#22 this branch returned with zero log
      // trace ("the sanctioned degrade path"). Every keystroke while assets are missing now
      // logs at error level, distinguishable from an inference failure below by message text.
      hilog.error(DOMAIN, TAG,
        'refreshCandidates: neural assets missing (model loaded=%{public}s, tokenizer loaded=%{public}s), staying on static ranking',
        String(model !== undefined), String(tokenizer !== undefined));
    }
    const context: ScoringContext = { precedingWords: this.composition.committedHistory() };

    let result: RankedCandidates;
    try {
      result = await rankCandidates(buffer, dictionary, context, scorer);
    } catch (err) {
      // Sole catch in the whole neural-ranking call chain (MindSporeNeuralModel.predict ->
      // NeuralScorer.prepare -> rankCandidates all propagate, none catch). Distinguishes a real
      // inference failure from the assets-missing branch above by message text;
      // MindSporeNeuralModel embeds the failing tensor's name/shape/dataSize in its thrown
      // messages where relevant (issue #22 acceptance criteria: both categories must be
      // separately diagnosable from the log alone).
      const message = err instanceof Error ? err.message : String(err);
      hilog.error(DOMAIN, TAG, 'refreshCandidates: neural inference failed, staying on static ranking: %{public}s',
        message);
      if (this.composition.compositionText !== buffer) {
        return;
      }
      this.candidates = generateCandidates(buffer, dictionary);
      return; // this.neuralRanked is already false, set at the top of this call
    }

    // The user may have kept typing while the batched forward pass above was in flight — if the
    // composition buffer has since moved on, this result is for a buffer that's no longer
    // current, so drop it rather than clobber whatever refreshCandidates() call came after.
    if (this.composition.compositionText !== buffer) {
      return;
    }
    this.candidates = result.candidates;
    this.neuralRanked = result.neuralRanked;
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

  // Issue #22 D7: the single seam for "does the first candidate look neurally-ranked" — a
  // minimal placeholder (bold + an accent color) standing in for the animated colorful-font
  // module that's out of this issue's scope. That later module only needs to replace this
  // method's body; candidateBar() below doesn't need to change again.
  private firstCandidateFontColor(): ResourceColor {
    return this.neuralRanked ? Color.Blue : Color.Black;
  }

  private firstCandidateFontWeight(): FontWeight {
    return this.neuralRanked ? FontWeight.Bold : FontWeight.Normal;
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
          // Key must include matchedLength, not just word: #15's prefix completion makes
          // the same word reappear at growing matchedLength as the buffer lengthens (e.g.
          // "哈哈" as buffer goes "ha" -> "hah" -> "haha"). With a word-only key, ForEach
          // sees an unchanged key and skips rebinding the existing component — its onClick
          // closure keeps the stale, shorter matchedLength from when the word first
          // appeared, so confirm() clears too little of the buffer (issue #18).
          ForEach(this.candidates, (candidate: CandidateEntry, index: number) => {
            Text(candidate.word)
              .fontSize(18)
              .fontColor(index === 0 ? this.firstCandidateFontColor() : Color.Black)
              .fontWeight(index === 0 ? this.firstCandidateFontWeight() : FontWeight.Normal)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .onClick(() => this.onCandidateClick(candidate))
          }, (candidate: CandidateEntry) => candidate.word + ' ' + String(candidate.matchedLength))
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
