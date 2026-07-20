import { router } from '@kit.ArkUI';

@Entry
@Component
struct About {
  build() {
    Column({ space: 16 }) {
      Text('关于序拼')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)

      Text('序拼是一款在本地运行、基于上下文对候选词排序的拼音输入法。所有数据只保存在设备本地,不会联网。')
        .fontSize(16)
        .textAlign(TextAlign.Start)
        .width('100%')

      Button('返回')
        .onClick(() => {
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }
}
