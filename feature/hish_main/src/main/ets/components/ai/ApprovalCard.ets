import { CodexApprovalRequest } from '../../backend/CodexBackend';

/**
 * 审批卡片 — 当 AI 要执行命令时弹出，用户选允许、拒绝或送到终端。
 * 从 AiWorkbench.ets 提取，通过回调与父组件通信。
 */
@Component
export struct ApprovalCard {
  @Prop approval: CodexApprovalRequest
  @Prop fontSize: number = 12
  @Prop lineHeight: number = 19
  // 深色/浅色主题
  @Prop isDark: boolean = false
  // 回调
  onApprove: () => void = (): void => {}
  onDecline: () => void = (): void => {}
  onSendToTerminal: () => void = (): void => {}

  private textStrong(): string {
    return this.isDark ? '#F1F5F9' : '#0F172A'
  }

  private panelBg(): string {
    return this.isDark ? '#1E293B' : '#FFFFFF'
  }

  private themeBorderColor(): string {
    return this.isDark ? '#334155' : '#E2E8F0'
  }

  private cardBg(): string {
    return this.isDark ? '#1E293B' : '#F8FAFC'
  }

  build() {
    Column() {
      Row() {
        Text(this.approval.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textStrong())

        Blank()
          .layoutWeight(1)

        // "需要确认" 标签
        Text('需要确认')
          .fontSize(10)
          .fontColor('#92400E')
          .backgroundColor('#FEF3C7')
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
      .width('100%')

      Text(this.approval.detail)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.fontSize)
        .fontColor(this.textStrong())
        .lineHeight(this.lineHeight)
        .margin({ top: 10 })

      Row() {
        Button('拒绝')
          .height(34)
          .fontSize(12)
          .backgroundColor(this.panelBg())
          .fontColor(this.textStrong())
          .borderRadius(8)
          .border({ width: 0.5, color: this.themeBorderColor() })
          .onClick(() => {
            this.onDecline()
          })

        Button('允许')
          .height(34)
          .margin({ left: 8 })
          .fontSize(12)
          .backgroundColor('#27272A')
          .fontColor('#FFFFFF')
          .borderRadius(8)
          .onClick(() => {
            this.onApprove()
          })

        // "在终端执行" — 仅命令类型审批显示
        if (this.approval.kind === 'command') {
          Button('在终端执行')
            .height(34)
            .margin({ left: 8 })
            .fontSize(12)
            .backgroundColor('#1E40AF')
            .fontColor('#FFFFFF')
            .borderRadius(8)
            .onClick(() => {
              this.onSendToTerminal()
            })
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 12 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardBg())
    .border({ width: 0.5, color: this.themeBorderColor() })
    .borderRadius(10)
    .margin({ top: 10 })
  }
}
