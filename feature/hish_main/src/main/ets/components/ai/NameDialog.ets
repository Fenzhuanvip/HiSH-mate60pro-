@CustomDialog
export struct ArkPilotNameDialog {
  controller?: CustomDialogController;
  @Link textValue: string;
  title: string = '';
  subtitle: string = '';
  placeholder: string = '';
  confirmText: string = '确认';
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

      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .copyOption(CopyOptions.None)
          .fontSize(14)
          .fontColor('#475569')
          .lineHeight(20)
          .width('100%')
          .margin({ top: 8 })
      }

      TextInput({ placeholder: this.placeholder, text: this.textValue })
        .width('100%')
        .height(48)
        .fontSize(15)
        .fontColor('#182431')
        .placeholderColor('#64748B')
        .backgroundColor('#F7F8FA')
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .margin({ top: 22 })
        .enterKeyType(EnterKeyType.Done)
        .onChange((value: string) => {
          this.textValue = value;
        })

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

        Button(this.confirmText)
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#18181B')
          .borderRadius(20)
          .margin({ left: 12 })
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: 24 })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 20 })
    .backgroundColor('#FFFFFF')
    .borderRadius(24)
  }
}
