import util from '@ohos.util';
import { buffer } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import napi from 'libhish_main.so';
import { webview } from '@kit.ArkWeb';
import { pasteboard, deviceInfo } from '@kit.BasicServicesKit'
import appOption, { CursorShape, savePreference, UserFont, UserFontData } from '../model/appOption';
import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import stringToArrayBuffer from '../lib/stringToArrayBuffer';
import fileToDataUrl from '../lib/fileToDataUrl';

import {
  applyVirtualKeyModifiers,
  FunctionKeySequences,
  getVirtualKeyMetrics,
  NormalKeySequences
} from '../lib/terminalVirtualKeys';

const DOMAIN = 0x0000;

const VKeyMetrics = getVirtualKeyMetrics(deviceInfo.deviceType)
const VKeyMargin = VKeyMetrics.margin;
const VKeyPadding = VKeyMetrics.padding;
const VKeyHeight = VKeyMetrics.height;
const VKeyWidth = VKeyMetrics.width;
const VKeyFontSize = VKeyMetrics.fontSize;
const VKeyRadius = VKeyMetrics.radius;

@Component
export default struct WebTerminal {
  @Require virtKeyEnabled: boolean = true
  @State ctrlPressed: boolean = false
  @State shiftPressed: boolean = false
  @State fnPressed: boolean = false
  @Watch('onFontSizeChanged') @StorageProp(appOption.terminalFontSize) fontSize: number | null = null
  @Watch('onFontFamilyChanged') @StorageProp(appOption.terminalFontFamily) fontFamily: string = 'Default'
  @Watch('onCursorShapeChanged') @StorageProp(appOption.terminalCursorShape) cursorShape: CursorShape | null = null
  @Watch('onCursorBlinkChanged') @StorageProp(appOption.terminalCursorBlink) cursorBlink: boolean | null = null
  @Watch('saveShowVirtKey') @StorageProp(appOption.showVirtKey) showVirtKey: boolean = true
  @StorageProp(appOption.vncEnabled) vncEnabled: boolean = false
  @Watch('onLigaturesChanged') @StorageProp(appOption.terminalLigatures) termLigatures: boolean = false
  @Watch('onItalicChanged') @StorageProp(appOption.terminalItalic) termItalic: boolean = true
  @Watch('onBgColorChanged') @StorageProp(appOption.terminalBackgroundColor) termBgColor: string = '#000000'
  @Watch('onBgImageChanged') @StorageProp(appOption.terminalBackgroundImage) termBgImage: string = ''
  @Watch('onBgBlurChanged') @StorageProp(appOption.terminalBackgroundBlur) termBgBlur: number = 0
  @Watch('onUserFontsChanged') @StorageProp(appOption.terminalUserFonts) termUserFonts: UserFont[] = []
  webviewController: WebviewController = new webview.WebviewController()
  utf8Decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
  resizeTimeout?: number = undefined
  areaChangeFitTimer?: number = undefined
  applicationMode: boolean = false
  

  @Builder
  contextMenu(webController: WebviewController) {
    Flex({
      direction: FlexDirection.Column
    }) {
      MenuItem({ content: $r('app.string.copy_text') })
        .width('100%')
        .onClick(async () => {
          const selection = await webController.runJavaScript('exports.copy()')
          if (selection !== '""') {
            let text: string = JSON.parse(selection);
            const board = pasteboard.getSystemPasteboard()
            const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
            board.setData(pasteData)
          }
        })
      PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
        .onClick(async (event: ClickEvent, result: PasteButtonOnClickResult) => {
          if (PasteButtonOnClickResult.SUCCESS === result) {
            let board = pasteboard.getSystemPasteboard();
            const data = await board.getData()
            const text = data.getPrimaryText()
            const array = this.utf8Encoder.encodeInto(text)
            const base64 = this.base64Helper.encodeToStringSync(array)
            webController.runJavaScript(`exports.paste(atob('${base64}'))`)
          }
        })
        .fontColor(Color.White)
        .backgroundColor('#1A292B2E')
        .align(Alignment.Start)
        .padding({ left: 12, right: 12 })
        .width('100%')
      MenuItem({ content: $r('app.string.menu_clear_screen') })
        .width('100%')
        .onClick(() => {
          webController.runJavaScript('exports.clearScreen()')
        })
    }
    .width('160vp')
  }

  /**
   * @param appCode code used in application mode
   * @param keyName identifier for modifier handling (e.g. 'UP', 'TAB')
   */
  @Builder
  buildVKey(name: string, value: string, appCode?: string, keyName?: string) {
    Button(name, { buttonStyle: ButtonStyleMode.TEXTUAL })
      .height(VKeyHeight)
      .width(VKeyWidth)
      .borderRadius(VKeyRadius)
      .fontSize(VKeyFontSize)
      .fontColor($r('sys.color.white'))
      .margin(VKeyMargin)
      .padding({ left: VKeyPadding, right: VKeyPadding })
      
      .onClick(() => {
        if (this.applicationMode && appCode) {
          this.sendInput(appCode, keyName);
        } else {
          this.sendInput(value, keyName)
        }
      })
  }

  @Builder
  toggleCtrlKey(name: string, action: () => void) {
    Toggle({ type: ToggleType.Button, isOn: this.ctrlPressed }) {
      Text(name).fontSize(VKeyFontSize).fontWeight(FontWeight.Medium).fontColor($r('sys.color.white'))
    }
    .height(VKeyHeight)
    .width(VKeyWidth)
    .borderRadius(VKeyRadius)
    .margin(VKeyMargin)
    .padding({ left: VKeyPadding, right: VKeyPadding })
    .selectedColor($r('sys.color.interactive_active'))
    .onClick(() => action())
  }

  @Builder
  toggleShiftKey(name: string, action: () => void) {
    Toggle({ type: ToggleType.Button, isOn: this.shiftPressed }) {
      Text(name).fontSize(VKeyFontSize).fontWeight(FontWeight.Medium).fontColor($r('sys.color.white'))
    }
    .height(VKeyHeight)
    .width(VKeyWidth)
    .borderRadius(VKeyRadius)
    .margin(VKeyMargin)
    .padding({ left: VKeyPadding, right: VKeyPadding })
    .selectedColor($r('sys.color.interactive_active'))
    .onClick(() => action())
  }

  @Builder
  toggleFnKey(name: string, action: () => void) {
    Toggle({ type: ToggleType.Button, isOn: this.fnPressed }) {
      Text(name).fontSize(VKeyFontSize).fontWeight(FontWeight.Medium).fontColor($r('sys.color.white'))
    }
    .height(VKeyHeight)
    .width(VKeyWidth)
    .borderRadius(VKeyRadius)
    .margin(VKeyMargin)
    .padding({ left: VKeyPadding, right: VKeyPadding })
    .selectedColor($r('sys.color.interactive_active'))
    .onClick(() => action())
  }

  @Builder
  settingsButton() {
    Button({ buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Image($r('app.media.gearshape')).width(16).height(16).padding(0)
    }
    .height(VKeyHeight)
    .width(VKeyHeight)
    .borderRadius(VKeyRadius)
    .margin(VKeyMargin)
    
    .bindMenu(this.settingsButtonOptions())
  }

  private settingsButtonOptions(): MenuElement[] {
    const vncOptions: MenuElement[] = this.vncEnabled ? [{
      value: $r('app.string.vnc_console_title'),
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.display')).fontSize($r('sys.float.Title_S')),
      action: () => {
        const vncEnabled = AppStorage.get<boolean>(appOption.vncEnabled)!!
        if (vncEnabled) {
          this.getUIContext().getRouter().pushUrl({
            url: 'pages/VncPage'
          });
        } else {
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.vnc_service_not_started') });
        }
      }
    }] : []
    const regularOptions: MenuElement[] = [{
      value: $r('app.string.menu_emulator_management'),
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.more')).fontSize($r('sys.float.Title_S')),
      action: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/EmulatorManagementPage' })
    }, {
      value: $r('app.string.menu_shared_folder'),
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.folder')).fontSize($r('sys.float.Title_S')),
      action: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/SharedFolderPage' })
    }, {
      value: $r('app.string.menu_settings'),
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')).fontSize($r('sys.float.Title_S')),
      action: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' })
    }]
    return [...vncOptions, ...regularOptions];
  }

  @Builder
  hideVKeyButton() {
    Button('▼', { buttonStyle: ButtonStyleMode.TEXTUAL })
      .height(VKeyHeight)
      .width(VKeyHeight)
      .borderRadius(VKeyRadius)
      .margin(VKeyMargin)
      .padding({ left: VKeyPadding, right: VKeyPadding })
      .fontColor($r('sys.color.white'))
      
      .onClick(() => {
        this.showVirtKey = false
      })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Web({
          src: $rawfile('term/term.html'),
          controller: this.webviewController
        })
          .javaScriptProxy({
            object: this,
            name: 'native',
            methodList: ['sendInput', 'resize', 'load',
              'getFontSize', 'getFontFamily',
              'getCursorShape', 'getCursorBlink',
              'getLigatures', 'getItalic',
              'getBackgroundColor', 'getBackgroundImage', 'getBackgroundBlur',
              'getUserFonts',
              'setApplicationMode',
              'onAvailableFontsDetected'],
            controller: this.webviewController,
            asyncMethodList: [],
            permission: `{
          "javascriptProxyPermission": {
            "urlPermissionList": [
              {
                "scheme": "resource",
                "host": "rawfile",
                "port": "",
                "path": ""
              }
            ]
          }
        }`
          })
          .backgroundColor('#000')
          .width('100%')
          .layoutWeight(1)
          .onAreaChange(() => {
            // WebView 尺寸变化时（如隐藏/显示虚拟键）自动重新 fit
            if (this.areaChangeFitTimer !== undefined) {
              clearTimeout(this.areaChangeFitTimer)
            }
            this.areaChangeFitTimer = setTimeout(() => {
              this.areaChangeFitTimer = undefined
              this.webviewController.runJavaScript('exports.fit()')
            }, 60)
          })
          .bindContextMenu(this.contextMenu(this.webviewController), ResponseType.RightClick)
        if (this.virtKeyEnabled && this.showVirtKey) {
          this.buildVirtualKeys()
        } else if (this.virtKeyEnabled && !this.showVirtKey) {
          // 放在 Column 内而非 Stack 叠加，避免遮挡终端最后一行
          this.buildShowVirtualKeysButton()
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  buildShowVirtualKeysButton() {
    Row() {
      Button('▲', { buttonStyle: ButtonStyleMode.TEXTUAL })
        .width(48)
        .height(20)
        .fontSize(12)
        .borderRadius(VKeyRadius)
        .fontColor('#888')
        .padding({ left: VKeyPadding, right: VKeyPadding })
        
        .onClick(() => {
          this.showVirtKey = true
        })
    }
    .width('100%')
    .height(22)
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  buildVirtualKeys() {
    Column() {
      if (this.fnPressed) {
        Row() {
          this.toggleFnKey('FN', () => this.toggleFn());
          this.buildVKey('F1', FunctionKeySequences.F1);
          this.buildVKey('F2', FunctionKeySequences.F2);
          this.buildVKey('F3', FunctionKeySequences.F3);

          Row().layoutWeight(1);

          this.buildVKey('F4', FunctionKeySequences.F4);
          this.buildVKey('F5', FunctionKeySequences.F5);
          this.buildVKey('F6', FunctionKeySequences.F6);
          this.settingsButton();
        }
        .margin({ left: 5, right: 5 })

        Row() {
          this.buildVKey('F7', FunctionKeySequences.F7);
          this.buildVKey('F8', FunctionKeySequences.F8);
          this.buildVKey('F9', FunctionKeySequences.F9);

          Row().layoutWeight(1);

          this.buildVKey('F10', FunctionKeySequences.F10);
          this.buildVKey('F11', FunctionKeySequences.F11);
          this.buildVKey('F12', FunctionKeySequences.F12);
          this.hideVKeyButton();
        }
        .margin({ left: 5, right: 5 })
      } else {
        Row() {
          this.buildVKey('ESC', NormalKeySequences.ESC);
          this.toggleFnKey('FN', () => this.toggleFn());
          this.buildVKey('HOME', NormalKeySequences.HOME, NormalKeySequences.HOME_APP, 'HOME');

          Row().layoutWeight(1);

          this.buildVKey('PGUP', NormalKeySequences.PGUP);
          this.toggleShiftKey('SHIFT', () => this.toggleShift());
          this.buildVKey('↑', NormalKeySequences.UP, NormalKeySequences.UP_APP, 'UP');
          this.buildVKey('ENTER', '\r');

          this.settingsButton();
        }
        .margin({ left: 5, right: 5 })

        Row() {
          this.buildVKey('TAB', NormalKeySequences.TAB, NormalKeySequences.TAB, 'TAB');
          this.toggleCtrlKey('CTRL', () => this.toggleCtrl());
          this.buildVKey('END', NormalKeySequences.END, NormalKeySequences.END_APP, 'END');

          Row().layoutWeight(1);

          this.buildVKey('PGDN', NormalKeySequences.PGDN);
          this.buildVKey('←', NormalKeySequences.LEFT, NormalKeySequences.LEFT_APP, 'LEFT');
          this.buildVKey('↓', NormalKeySequences.DOWN, NormalKeySequences.DOWN_APP, 'DOWN');
          this.buildVKey('→', NormalKeySequences.RIGHT, NormalKeySequences.RIGHT_APP, 'RIGHT');
          this.hideVKeyButton();
        }
        .margin({ left: 5, right: 5 })
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .backgroundColor('#E6000000')
  }

  async saveShowVirtKey() {
    await savePreference(appOption.showVirtKey, this.showVirtKey, this.getUIContext())
    if (!this.showVirtKey) {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.hide_virtual_key_toast'),
        duration: 5000
      })
    }
    // 隐藏/显示虚拟键后，WebView 尺寸变化由 onAreaChange 自动触发 fit
    // 这里额外补几次 fit，确保 ArkUI 布局完全稳定后终端尺寸正确
    const fit = () => this.webviewController.runJavaScript('exports.fit()')
    setTimeout(fit, 80)
    setTimeout(fit, 200)
    setTimeout(fit, 400)
  }

  private toggleCtrl(): void {
    this.ctrlPressed = !this.ctrlPressed;
  }

  private toggleShift(): void {
    this.shiftPressed = !this.shiftPressed;
  }

  private toggleFn(): void {
    this.fnPressed = !this.fnPressed;
  }
  //  ============== for javascript in ArkWeb ================

  sendInput(data: string, keyName?: string): void {
    // 高频路径：避免每个按键都打 hilog，仅在调试构建时输出
    if (data.length <= 8) {
      hilog.debug(DOMAIN, 'WebTerminal', 'sendInput, len=%{public}d', data.length);
    }

    const modifierResult = applyVirtualKeyModifiers(data, this.ctrlPressed, this.shiftPressed, keyName)
    data = modifierResult.data

    if (modifierResult.ctrlConverted) {
      hilog.debug(DOMAIN, 'WebTerminal', 'sendInput with Ctrl, converted to control char');
    }
    if (modifierResult.shouldResetCtrl) {
      this.toggleCtrl()
    }
    if (modifierResult.shiftConverted) {
      hilog.debug(DOMAIN, 'WebTerminal', 'sendInput with Shift, converted');
    }

    let buffer = stringToArrayBuffer(data, 'utf-8');
    napi.sendInput(buffer)

    // Ctrl: 一次性模式，发送后自动重置 | Shift: 状态保持，需要用户手动点击取消
  }

  async load(): Promise<void> {
    this.webviewController.runJavaScript('exports.setFocused(true)')
    napi.onData((d: ArrayBuffer): void => this.onData(d))
    napi.onShutdown((): void => {
      void this.onShutdown()
    })
    const vmStatus = AppStorage.get(appOption.currentEmulatorStatus) as string | undefined
    if (vmStatus === 'ABNORMAL') {
      const message = this.getUIContext().getHostContext()?.resourceManager.getStringByNameSync('vm_start_failed_qemu_runtime')
        ?? 'VM failed to start: QEMU runtime library missing'
      const text = this.utf8Encoder.encodeInto('\r\n' + message + '\r\n')
      const base64 = this.base64Helper.encodeToStringSync(text)
      this.webviewController.runJavaScript(`exports.writeBase64("${base64}", ${this.applicationMode})`)
    }
  }

  async resize(width: number, height: number): Promise<void> {
    hilog.info(DOMAIN, "WebTerminal", 'on resize: %{public}d, %{public}d', width, height)

    if (this.resizeTimeout !== undefined) {
      clearTimeout(this.resizeTimeout!!)
    }
    this.resizeTimeout = setTimeout(() => this.sendInput('\x1b' + `[8;${height};${width}t`), 50)
  }

  // 性能优化：输出缓冲区
  private pendingChunks: Uint8Array[] = [];
  private flushTimeoutID: number | undefined = undefined;
  private readonly FLUSH_INTERVAL = 8;
  // 复用编解码器实例，避免高频 flush 时反复创建
  private base64Helper = new util.Base64Helper();
  private utf8Encoder = util.TextEncoder.create('utf-8');

  private onData(ab: ArrayBuffer) {
    try {
      // 将收到的数据块加入队列
      this.pendingChunks.push(new Uint8Array(ab));

      // 如果没有正在等待的 Flush 任务，则调度一个
      if (this.flushTimeoutID === undefined) {
        this.flushTimeoutID = setTimeout(() => {
          this.flushData();
        }, this.FLUSH_INTERVAL);
      }
    } catch (e) {
      hilog.error(DOMAIN, 'WebTerminal', 'onData failed: %{public}s', JSON.stringify(e));
    }
  }

  private flushData() {
    this.flushTimeoutID = undefined;

    if (this.pendingChunks.length === 0) return;

    try {
      // 1. 计算总长度
      let totalLength = 0;
      for (const chunk of this.pendingChunks) {
        totalLength += chunk.length;
      }

      // 2. 合并所有 Chunk
      const merged = new Uint8Array(totalLength);
      let offset = 0;
      for (const chunk of this.pendingChunks) {
        merged.set(chunk, offset);
        offset += chunk.length;
      }

      // 清空缓冲区
      this.pendingChunks = [];

      // 3. 检测清屏信号
      // 现在数据是原始字节，检测真正的转义序列 ESC[H ESC[J (6 字节)
      // \x1b[H 移动光标到左上角，\x1b[J 清屏（TUI 应用常用的清屏组合）
      if (merged.length >= 6 &&
        merged[0] === 0x1B && merged[1] === 0x5B && merged[2] === 0x48 && // ESC [ H
        merged[3] === 0x1B && merged[4] === 0x5B && merged[5] === 0x4A    // ESC [ J
      ) {
        const clearCmd = '\x1b[3J';
        const clearBytes = this.utf8Encoder.encodeInto(clearCmd);
        const clearBase64 = this.base64Helper.encodeToStringSync(clearBytes);
        this.webviewController.runJavaScript(`exports.writeBase64("${clearBase64}", ${this.applicationMode})`);
      }

      // 4. 发送合并后的数据
      const base64 = this.base64Helper.encodeToStringSync(merged);
      this.webviewController.runJavaScript(`exports.writeBase64("${base64}", ${this.applicationMode})`);

    } catch (e) {
      hilog.error(DOMAIN, 'WebTerminal', 'flushData failed: %{public}s', JSON.stringify(e));
      // 出错时也要清空缓冲区，避免积压
      this.pendingChunks = [];
    }
  }

  private async onShutdown() {
    hilog.info(DOMAIN, 'WebTerminal', 'qemu system exited');
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext
    await context?.terminateSelf()
  }

  getFontSize(): number | null {
    return this.fontSize
  }

  getFontFamily(): string {
    return this.fontFamily
  }

  getCursorShape(): string | null {
    return this.cursorShape
  }

  getCursorBlink(): boolean | null {
    return this.cursorBlink
  }

  getDeviceType(): string {
    return deviceInfo.deviceType;
  }

  onFontSizeChanged() {
    this.webviewController.runJavaScript(`exports.setFontSize(${this.fontSize})`)
  }

  onFontFamilyChanged() {
    // Read directly from AppStorage to ensure we get the updated value
    const family = AppStorage.get<string>(appOption.terminalFontFamily) ?? 'Default';
    hilog.info(DOMAIN, 'WebTerminal', 'onFontFamilyChanged: %{public}s', family);
    // Use JSON.stringify to safely escape any special characters in font name
    this.webviewController.runJavaScript(`exports.setFontFamily(${JSON.stringify(family)})`)
      .catch((err: Error) => {
        hilog.error(DOMAIN, 'WebTerminal', 'setFontFamily failed: %{public}s', JSON.stringify(err));
      })
  }

  onCursorShapeChanged() {
    this.webviewController.runJavaScript(`exports.setCursorShape('${this.cursorShape}')`)
  }

  onCursorBlinkChanged() {
    this.webviewController.runJavaScript(`exports.setCursorBlink(${this.cursorBlink})`)
  }

  getLigatures(): boolean {
    return this.termLigatures
  }

  getItalic(): boolean {
    return this.termItalic
  }

  getBackgroundColor(): string {
    return this.termBgColor
  }

  getBackgroundBlur(): number {
    return this.termBgBlur
  }

  getBackgroundImage(): string {
    return this.backgroundImageDataUrl()
  }

  getUserFonts(): string {
    const fonts = AppStorage.get<UserFont[]>(appOption.terminalUserFonts) ?? []
    const list: UserFontData[] = []
    for (const f of fonts) {
      const data: UserFontData = { name: f.name, dataUrl: fileToDataUrl(f.file) }
      if (data.dataUrl.length > 0) {
        list.push(data)
      }
    }
    return JSON.stringify(list)
  }

  private backgroundImageDataUrl(): string {
    const fileName = AppStorage.get<string>(appOption.terminalBackgroundImage) ?? ''
    if (fileName.length === 0) {
      return ''
    }
    const filesDir = AppStorage.get<string>(appOption.appFilesDir) ?? ''
    return fileToDataUrl(`${filesDir}/terminal_bg/${fileName}`)
  }

  onBgColorChanged() {
    this.webviewController.runJavaScript(`exports.setBackgroundColor(${JSON.stringify(this.termBgColor)})`)
  }

  onBgImageChanged() {
    this.webviewController.runJavaScript(`exports.setBackgroundImage(${JSON.stringify(this.backgroundImageDataUrl())})`)
  }

  onBgBlurChanged() {
    this.webviewController.runJavaScript(`exports.setBackgroundBlur(${this.termBgBlur})`)
  }

  onUserFontsChanged() {
    const json = this.getUserFonts()
    this.webviewController.runJavaScript(`exports.registerUserFonts(${JSON.stringify(json)})`)
  }

  onLigaturesChanged() {
    this.webviewController.runJavaScript(`exports.setLigatures(${this.termLigatures})`)
  }

  onItalicChanged() {
    this.webviewController.runJavaScript(`exports.setItalic(${this.termItalic})`)
  }

  setApplicationMode(mode: boolean) {
    this.applicationMode = mode
    hilog.info(DOMAIN, 'WebTerminal', 'set applicationMode to %{public}s', this.applicationMode);
  }

  // Called from WebView when monospace font detection completes.
  // Receives a JSON array of available monospace font names.
  onAvailableFontsDetected(json: string): void {
    try {
      const fonts: string[] = JSON.parse(json);
      hilog.info(DOMAIN, 'WebTerminal', 'Available monospace fonts: %{public}s', fonts.join(', '));
      AppStorage.setOrCreate(appOption.availableFontFamilies, fonts);
    } catch (e) {
      hilog.error(DOMAIN, 'WebTerminal', 'Failed to parse available fonts: %{public}s', JSON.stringify(e));
    }
  }
}
