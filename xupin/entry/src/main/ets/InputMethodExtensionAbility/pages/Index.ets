import { hilog } from '@kit.PerformanceAnalysisKit';
import { inputClientHolder } from '../model/InputClientHolder';

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

  private insert(char: string): void {
    const client = inputClientHolder.getClient();
    if (!client) {
      hilog.warn(DOMAIN, TAG, 'insert: no bound InputClient');
      return;
    }
    client.insertTextSync(char);
  }

  private backspace(): void {
    const client = inputClientHolder.getClient();
    if (!client) {
      hilog.warn(DOMAIN, TAG, 'backspace: no bound InputClient');
      return;
    }
    client.deleteForwardSync(1);
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
      .onClick(() => this.insert(label))
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

  build() {
    Column({ space: 6 }) {
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
          .onClick(() => this.insert(' '))
        Button('删除')
          .fontSize(16)
          .onClick(() => this.backspace())
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
