@CustomDialog
export struct ArkPilotDeleteDialog {
  controller?: CustomDialogController;
  @Link targetName: string;
  title: string = '';
  targetType: string = '';
  description: string = '';
  cancel: () => void = () => {};
  confirm: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text(this.title)
          .copyOption(CopyOptions.None)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
          .layoutWeight(1)
        Button('×')
          .type(ButtonType.Normal)
          .accessibilityText('关闭')
          .width(32)
          .height(32)
          .fontSize(20)
          .fontColor('#182431')
          .backgroundColor('#F2F3F5')
          .borderRadius(10)
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')

      Text(`确认删除${this.targetType}「${this.targetName}」？`)
        .copyOption(CopyOptions.None)
        .fontSize(15)
        .fontColor('#182431')
        .lineHeight(22)
        .width('100%')
        .margin({ top: 16 })

      if (this.description.length > 0) {
        Text(this.description)
          .copyOption(CopyOptions.None)
          .fontSize(13)
          .fontColor('#475569')
          .lineHeight(19)
          .width('100%')
          .margin({ top: 8 })
      }

      Row() {
        Button('取消')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#182431')
          .backgroundColor('#F2F3F5')
          .borderRadius(20)
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })

        Button('删除')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#F97373')
          .borderRadius(20)
          .margin({ left: 12 })
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: 26 })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 20 })
    .backgroundColor('#FFFFFF')
    .borderRadius(24)
  }
}
