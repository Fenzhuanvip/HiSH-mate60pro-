import router from '@ohos.router';
import { webview } from '@kit.ArkWeb';

const LEGAL_DOMAIN = 0x0ff5;
const LEGAL_TAG = 'LegalPage';
// 隐私政策（云托管 H5）
const PRIVACY_URL = 'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2004540394976632768';

interface LegalSection {
  title: string;
  body: string;
}

const AGREEMENT_SECTIONS: LegalSection[] = [
  {
    title: '1. 关于我们',
    body: '感谢您选择使用 ArkPilot。\n\nArkPilot 是由西安洞宇溯元软件科技有限公司（以下简称“我们”或“洞宇溯元”）提供与运营。\n\nArkPilot 用户服务协议是洞宇溯元与用户（以下简称“您”）关于使用 ArkPilot 服务所订立的有效协议。'
  },
  {
    title: '2. 协议范围、目的及确认方式',
    body: '本用户服务协议及附属协议，以及页面展示的单项协议或规则、操作提示（以下合称为“本协议”）是我们为您提供 ArkPilot 服务所依据的条款，不可分割，您需同时遵守。\n\n请您仔细阅读本协议的全部内容，特别是字体加粗部分。\n\n如您对本协议内容及页面提示信息有疑问，请勿进行下一步操作。如您使用 ArkPilot 服务即视为您已阅读并同意本协议的约束。\n\n如果您不同意本协议的任意内容，或无法准确理解条款内容，请停止使用，不要进行后续操作。'
  },
  {
    title: '3. 使用本服务的要求',
    body: '3.1 您具备完全民事行为能力，方可使用 ArkPilot 服务，若您为无民事行为能力或为限制民事行为能力，请告知您的监护人，在您监护人的指导下阅读本协议，并在取得您监护人同意的前提下使用 ArkPilot 服务；\n\n3.2 您明确声明和保证：您具备足够的法律权利或授权来签署和履行本协议；您对于本协议的签署和履行不会对您须履行的任何其他协议、安排造成冲突或导致违约；\n\n3.3 如您所属的国家或地区排除本协议的全部或部分内容，则您应立即停止使用 ArkPilot 服务，否则，您继续使用 ArkPilot 服务视为您同意承担相关的法律风险或法律责任。'
  },
  {
    title: '4. 服务内容',
    body: 'ArkPilot 是洞宇溯元通过互联网（含移动互联网）为您提供的 AI Agent 服务平台，您可通过该平台进行对话、代码协助、技能调用与配置管理等操作。\n\n我们可能根据业务需要对本服务的内容进行升级、调整或终止，并尽合理努力提前提示您。'
  },
  {
    title: '5. 用户使用规则',
    body: '5.1 您使用您身份要素来进行的操作、发出的指令视为您本来做出，您应对您使用身份要素进行的所有行为产生的结果（包括但不限于签署各类协议、发布信息、配置服务及披露信息等）负责，因您的原因造成的账户、密码等信息被冒用、盗用或非法使用，由此引起的风险和损失需要由您自行承担；\n\n5.2 您在使用 ArkPilot 服务时，请务必仔细填写并核对您的账号、API 配置等信息，确保其真实、准确、完整有效；\n\n5.3 请您结合自身实际需求，充分考虑所选择的模型服务商等信息，确认并选择使用 ArkPilot 服务；\n\n5.4 您知悉并同意，如因为您自身出现输入错误、操作不当、选择错误等情形，您需自行承担所受到的经济损失及后果。'
  },
  {
    title: '6. 免责声明',
    body: '洞宇溯元基于互联网及电信网络提供服务，在您使用 ArkPilot 服务之前，应对 AI 生成内容可能蕴含的风险有一定的了解。\n\n由于网络故障、系统检修、维护或不稳定，或黑客攻击，或电力部门技术调整或故障，或第三方模型服务商等原因，导致 ArkPilot 服务存在失败、中断或延迟的，不是洞宇溯元违约，但洞宇溯元将尽一切努力恢复正常服务。\n\n洞宇溯元为技术服务平台仅按现状提供服务，在法律允许的范围内，洞宇溯元对以下情形导致的服务中断、延迟受阻不承担责任：\n（1） 受到计算机病毒、木马或其他恶意程序、黑客攻击的破坏；\n（2） 您、第三方的电脑软件、系统、硬件、网络和通信线路出现故障；\n（3） 您操作不当，包括但不限于提交错误的配置信息，或所选服务商出错；\n（4） 其他洞宇溯元无法控制或合理预见的情形。'
  },
  {
    title: '7. 用户禁止性规定',
    body: '您在使用本软件时必须遵守法律法规，不得利用本软件提供的服务从事违法违规行为，包括但不限于：\n（1） 发布、传送、传播、存储危害国家安全统一、破坏社会稳定、违反公序良俗、侮辱、诽谤、淫秽、暴力以及任何违反国家法律法规的内容；\n（2） 发布、传送、传播、存储侵害他人知识产权、商业秘密等合法权利的内容；\n（3） 恶意虚构事实、隐瞒真相以误导、欺骗他人；\n（4） 发布、传送、传播广告信息及垃圾信息；\n（5） 其他法律法规禁止的行为。\n\n如因您违反本条约定，导致任何第三方损害的，您应独立承担责任；洞宇溯元因此遭受损失的，您也应当一并赔偿。'
  },
  {
    title: '8. 对本协议的修订',
    body: '洞宇溯元有权在必要时修改本协议条款，您可以在本软件的最新版本中查阅相关协议条款。\n\n更新后的协议条款一旦公布即代替原来的协议条款，我们会在服务页面上及时发布对本协议的变更。若对本协议的修订会严重影响您或严重限制您对本服务的访问或使用，我们会在变更之前的合理时间内通知您。对于为了满足安全、法律或监管要求而对本服务作出的修订，我们可能无法满足前述的预告时间要求，但我们会尽快通知您。\n\n本协议条款变更后，如果您不接受修改后的协议，请立即停止使用本服务；如果您继续访问或使用本服务，即被视为您已接受修改后的协议。'
  },
  {
    title: '9. 适用法律及管辖',
    body: '本协议的订立、执行、解释及争议的解决均适用中华人民共和国法律。\n\n您同意，本协议签订地为陕西省西安市未央区。\n\n在合同履行过程中双方如发生纠纷，应协商解决；协商不成的，双方应向协议签订地有管辖权的人民法院以诉讼的方式解决。'
  },
  {
    title: '10. 联系我们',
    body: '如您对本协议有任何疑问，请通过邮箱 OriginVerseTech@originversetech.cn 与我们联系。'
  }
];

const AGREEMENT_DATE = '2026年9月1日';

@Entry
@Component
struct LegalPage {
  @State kind: string = 'agreement';
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    this.kind = (params !== null && params !== undefined && params['kind'] === 'privacy') ? 'privacy' : 'agreement';
  }

  private title(): string {
    return this.kind === 'privacy' ? '隐私政策' : '用户协议';
  }

  private textPrimary(): string {
    return '#0F172A';
  }

  private textSecondary(): string {
    return '#475569';
  }

  private textMuted(): string {
    return '#64748B';
  }

  private surface(): string {
    return '#FFFFFF';
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Button() {
          Row() {
            Text('<')
              .fontSize(16)
              .fontColor(this.textPrimary())
              .fontWeight(FontWeight.Bold)
            Text('返回')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textPrimary())
              .margin({ left: 6 })
          }
        }
        .height(36)
        .padding({ left: 12, right: 14 })
        .backgroundColor(this.surface())
        .borderRadius(10)
        .border({ width: 1, color: '#E5E7EB' })
        .onClick(() => { router.back(); })

        Text(this.title())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textPrimary())
          .margin({ left: 16 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })
      .backgroundColor(this.surface())

      // 正文：隐私政策走 WebView 云链接，用户协议走本地渲染
      if (this.kind === 'privacy') {
        Web({ src: PRIVACY_URL, controller: this.controller })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(false)
          .onlineImageAccess(true)
          .zoomAccess(true)
          .width('100%')
          .layoutWeight(1)
      } else {
        Scroll() {
          Column({ space: 18 }) {
            Text('ArkPilot用户服务协议')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textPrimary())
              .textAlign(TextAlign.Center)
              .width('100%')
            Text(`更新日期：${AGREEMENT_DATE}`)
              .fontSize(14)
              .fontColor(this.textMuted())
              .textAlign(TextAlign.Center)
              .width('100%')

            ForEach(this.sections(), (section: LegalSection) => {
              Column() {
                Text(section.title)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.textPrimary())
                Text(section.body)
                  .fontSize(14)
                  .fontColor(this.textSecondary())
                  .lineHeight(24)
                  .textAlign(TextAlign.JUSTIFY)
                  .margin({ top: 8 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }, (section: LegalSection) => section.title)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 16, bottom: 40 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  private sections(): LegalSection[] {
    return AGREEMENT_SECTIONS;
  }
}
