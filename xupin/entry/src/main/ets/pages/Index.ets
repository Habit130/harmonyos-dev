import { router } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  build() {
    Column({ space: 16 }) {
      Text('序拼')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)

      Text('序拼是一款在本地运行的拼音输入法。首次使用前,请先在系统设置里启用它:')
        .fontSize(16)
        .textAlign(TextAlign.Start)
        .width('100%')

      Column({ space: 8 }) {
        Text('1. 打开「设置」')
        Text('2. 进入「输入法」')
        Text('3. 在「所有输入法」里启用「序拼」')
        Text('4. 切换输入法时选择「序拼」')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Button('关于')
        .onClick(() => {
          router.pushUrl({ url: 'pages/About' });
        })
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }
}
