@CustomDialog
export struct ArkPilotProjectCreateDialog {
  controller?: CustomDialogController;
  @Link projectName: string;
  @Link sourceUri: string;
  canSelectExternalFolder: () => boolean = () => false;
  chooseFolder: () => void = () => {};
  cancel: () => void = () => {};
  confirm: () => void = () => {};
  @State private sourceInfoHovering: boolean = false;
  @State private sourceInfoPinned: boolean = false;

  private sourceFolderText(): string {
    if (this.sourceUri.length > 0) {
      return `同步文件夹：${this.sourceUri}`;
    }
    return this.canSelectExternalFolder() ? '未选择同步文件夹' : '未启用下载目录同步';
  }

  private sourceFolderColor(): ResourceColor {
    return this.sourceUri.length > 0 ? '#182431' : '#475569';
  }

  private shouldShowSourceInfo(): boolean {
    return this.sourceInfoHovering || this.sourceInfoPinned;
  }

  @Builder
  private sourceInfoPopup() {
    Column() {
      Text('同步文件夹')
        .copyOption(CopyOptions.None)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#18181B')
        .width('100%')

      Text('同步文件夹是项目和本地目录之间的交换入口。项目在应用内运行，需要时再手动与该文件夹导入或导出项目文件。')
        .copyOption(CopyOptions.None)
        .fontSize(12)
        .fontColor('#4E5969')
        .lineHeight(18)
        .width('100%')
        .margin({ top: 8 })

      Column() {
        Text('• 导出项目内容：创建项目后，可以在项目菜单中，把应用内该项目文件夹内容导出到同步文件夹。')
          .copyOption(CopyOptions.None)
          .fontSize(12)
          .fontColor('#4E5969')
          .lineHeight(18)
          .width('100%')

        Text('• 导入文件夹内容：可以在项目菜单中，把同步文件夹中的内容导入到项目文件夹内。')
          .copyOption(CopyOptions.None)
          .fontSize(12)
          .fontColor('#4E5969')
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6 })

        Text('• 未选择时：仅使用应用内项目目录，可以在项目菜单中重新关联同步文件夹。')
          .copyOption(CopyOptions.None)
          .fontSize(12)
          .fontColor('#4E5969')
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6 })
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width(292)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }

  build() {
    Column() {
      Row() {
        Text('新建项目')
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

      Text('运行目录将自动创建在应用内项目目录。')
        .copyOption(CopyOptions.None)
        .fontSize(14)
        .fontColor('#475569')
        .lineHeight(20)
        .width('100%')
        .margin({ top: 8 })

      TextInput({ placeholder: '输入项目名称', text: this.projectName })
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
          this.projectName = value;
        })

      Column() {
        Row() {
          Text('同步文件夹')
            .copyOption(CopyOptions.None)
            .fontSize(12)
            .fontColor('#475569')

          Blank()
            .layoutWeight(1)

          Text('i')
            .copyOption(CopyOptions.None)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.shouldShowSourceInfo() ? '#18181B' : '#4E5969')
            .textAlign(TextAlign.Center)
            .width(22)
            .height(22)
            .backgroundColor(this.shouldShowSourceInfo() ? '#E5E7EB' : '#FFFFFF')
            .border({ width: 1, color: '#D1D5DB' })
            .borderRadius(11)
            .onHover((isHover: boolean) => {
              this.sourceInfoHovering = isHover;
            })
            .onClick(() => {
              if (this.sourceInfoPinned) {
                this.sourceInfoPinned = false;
                this.sourceInfoHovering = false;
              } else {
                this.sourceInfoPinned = true;
              }
            })
            .bindPopup(this.shouldShowSourceInfo(), {
              builder: this.sourceInfoPopup,
              placement: Placement.Right,
              targetSpace: 8,
              width: 320,
              radius: 16,
              mask: false,
              autoCancel: true,
              enableArrow: true,
              popupColor: '#FFFFFF',
              shadow: { radius: 16, color: '#26000000', offsetX: 0, offsetY: 6 },
              onStateChange: (event) => {
                if (!event.isVisible) {
                  this.sourceInfoHovering = false;
                  this.sourceInfoPinned = false;
                }
              }
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.sourceFolderText())
          .copyOption(CopyOptions.None)
          .fontSize(13)
          .fontColor(this.sourceFolderColor())
          .lineHeight(18)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })

      }
      .width('100%')
      .padding(14)
      .margin({ top: 12 })
      .backgroundColor('#F7F8FA')
      .borderRadius(12)

      Button(this.canSelectExternalFolder() ? '选择同步文件夹' : '启用下载目录同步')
        .type(ButtonType.Normal)
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor('#18181B')
        .backgroundColor('#F2F3F5')
        .borderRadius(12)
        .margin({ top: 12 })
        .onClick(() => {
          this.chooseFolder();
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

        Button('创建')
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
