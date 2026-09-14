@CustomDialog
export struct ArkPilotLogoutDialog {
  controller?: CustomDialogController;
  cancel: () => void = () => {};
  confirm: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text('退出登录')
          .copyOption(CopyOptions.None)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
          .layoutWeight(1)
        Button('×')
          .type(ButtonType.Circle)
          .accessibilityText('关闭')
          .width(32)
          .height(32)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#64748B')
          .backgroundColor('#F1F5F9')
          .border({ width: 1, color: '#E2E8F0' })
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')

      Text('确定要退出华为账号登录吗？')
        .copyOption(CopyOptions.None)
        .fontSize(15)
        .fontColor('#182431')
        .lineHeight(22)
        .width('100%')
        .margin({ top: 16 })

      Text('退出后需要重新使用华为账号登录。')
        .copyOption(CopyOptions.None)
        .fontSize(13)
        .fontColor('#475569')
        .lineHeight(19)
        .width('100%')
        .margin({ top: 8 })

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

        Button('退出')
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
