import router from '@ohos.router';
import { LoginWithHuaweiIDButton, loginComponentManager } from '@kit.AccountKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { huaweiAccountService } from '../account/HuaweiAccountService';
import { accountErrorMessage } from '../account/AccountModels';

const LOGIN_DOMAIN = 0x0ff4;
const LOGIN_TAG = 'LoginPage';
const HUAWEI_ID_LOGIN_SYSCAP: string = 'SystemCapability.AuthenticationServices.HuaweiID.UIComponent';

@Entry
@Component
struct LoginPage {
  @State private errorText: string = '';
  @State private capabilitySupported: boolean = true;
  @State private lastAccount: string = '';
  @State private loginBusy: boolean = false;
  @State private agreed: boolean = false;

  private loginController: loginComponentManager.LoginWithHuaweiIDButtonController = new loginComponentManager.LoginWithHuaweiIDButtonController();
  private loginCallbackRegistered: boolean = false;

  private loginParams: loginComponentManager.LoginWithHuaweiIDButtonParams = {
    style: loginComponentManager.Style.BUTTON_RED,
    borderRadius: 28,
    supportDarkMode: false,
    loginType: loginComponentManager.LoginType.ID,
    textAndIconStyle: true
  };

  aboutToAppear(): void {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext !== undefined) {
      huaweiAccountService.ensureInit(hostContext);
    } else {
      hilog.warn(LOGIN_DOMAIN, LOGIN_TAG, '%{public}s', 'host context unavailable, skip account init');
    }
    this.capabilitySupported = canIUse(HUAWEI_ID_LOGIN_SYSCAP);
    this.lastAccount = huaweiAccountService.lastAccountMasked();
    this.registerLoginCallback();
    if (huaweiAccountService.isLoggedIn) {
      router.replaceUrl({ url: 'pages/AiWorkbench' });
    }
  }

  aboutToDisappear(): void {
    this.loginBusy = false;
    this.unregisterLoginCallback();
  }

  private registerLoginCallback(): void {
    if (this.loginCallbackRegistered) {
      return;
    }
    this.loginCallbackRegistered = true;
    this.loginController.onClickLoginWithHuaweiIDButton((err: BusinessError, credential: loginComponentManager.HuaweiIDCredential) => {
      if (this.loginBusy) {
        return;
      }
      // 未勾选同意时拦截，引导用户先阅读并同意协议
      if (!this.agreed) {
        this.errorText = '请先阅读并勾选同意《用户协议》与《隐私政策》。';
        return;
      }
      if (err !== null && err !== undefined) {
        this.loginBusy = false;
        this.errorText = accountErrorMessage(err.code);
        return;
      }
      this.handleLoginSuccess(credential);
    });
  }

  private unregisterLoginCallback(): void {
    this.loginCallbackRegistered = false;
  }

  private handleLoginSuccess(credential: loginComponentManager.HuaweiIDCredential): void {
    this.loginBusy = true;
    huaweiAccountService.applyCredential(credential);
    this.leaveLoginPage();
  }

  private leaveLoginPage(): void {
    router.replaceUrl({ url: 'pages/AiWorkbench' });
  }

  private async openSwitchAccount(): Promise<void> {
    if (this.loginBusy) {
      return;
    }
    this.loginBusy = true;
    this.errorText = '';
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      this.loginBusy = false;
      this.errorText = '切换账号失败，请稍后重试';
      return;
    }
    // 切换账号 = 彻底退出本地登录态 + 撤销系统级授权，
    // 重新登录时必须重新走授权流程（可重新选择账号/输入密码）。
    await huaweiAccountService.logout(hostContext);
    this.loginBusy = false;
    this.lastAccount = '';
    this.errorText = '';
  }

  private openAgreement(): void {
    router.pushUrl({ url: 'pages/AiLegalPage', params: { kind: 'agreement' } });
  }

  private openPrivacy(): void {
    router.pushUrl({ url: 'pages/AiLegalPage', params: { kind: 'privacy' } });
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
    Stack() {
      Column() {}
        .width('100%')
        .height('100%')
        .backgroundColor('#EEF2F7')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Text('ArkPilot')
          .copyOption(CopyOptions.None)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textPrimary())

        Text('登录后使用全部功能')
          .copyOption(CopyOptions.None)
          .fontSize(14)
          .fontColor(this.textSecondary())
          .margin({ top: 10 })

        if (this.capabilitySupported) {
          LoginWithHuaweiIDButton({
            params: this.loginParams,
            controller: this.loginController
          })
            .width('100%')
            .height(48)
            .margin({ top: 36 })
        } else {
          Column() {
            Text('当前设备不支持华为账号登录')
              .copyOption(CopyOptions.None)
              .fontSize(14)
              .fontColor(this.textPrimary())
            Text('需要支持 SystemCapability.AuthenticationServices.HuaweiID.UIComponent 能力的设备。')
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontColor(this.textMuted())
              .lineHeight(18)
              .textAlign(TextAlign.Center)
              .margin({ top: 8 })
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
          .margin({ top: 36 })
        }

        if (this.lastAccount.length > 0) {
          Row() {
            Text(`上次登录：${this.lastAccount}`)
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontColor(this.textSecondary())

            Blank()
              .layoutWeight(1)

            Text('切换账号')
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2563EB')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick(() => {
                this.openSwitchAccount();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 12, top: 12, bottom: 12 })
          .backgroundColor('#F5F7FA')
          .borderRadius(14)
          .margin({ top: 18 })
        }

        if (this.errorText.length > 0) {
          Text(this.errorText)
            .copyOption(CopyOptions.None)
            .fontSize(13)
            .fontColor('#B91C1C')
            .textAlign(TextAlign.Center)
            .lineHeight(19)
            .width('100%')
            .margin({ top: 20 })
        }

        Row() {
          Checkbox({ name: 'agreement', group: 'legal' })
            .select(this.agreed)
            .selectedColor('#2563EB')
            .width(18)
            .height(18)
            .onChange((value: boolean) => {
              this.agreed = value;
              if (this.agreed) {
                this.errorText = '';
              }
            })

          Text('我已阅读并同意')
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor(this.textMuted())

          Text('《用户协议》')
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor('#2563EB')
            .onClick(() => { this.openAgreement(); })

          Text('《隐私政策》')
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor('#2563EB')
            .margin({ left: 4 })
            .onClick(() => { this.openPrivacy(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 40 })
      }
      .width('100%')
      .constraintSize({ maxWidth: 380 })
      .padding({ left: 28, right: 28, top: 48, bottom: 48 })
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.surface())
      .borderRadius(24)
      .shadow({ radius: 24, color: '#26000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .height('100%')
  }
}
