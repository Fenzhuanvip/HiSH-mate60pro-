import router from '@ohos.router';
import mediaQuery from '@ohos.mediaquery';
import { ProviderPreset, BUILTIN_PROVIDER_PRESETS } from '../apim/ApiTypes';
import { CustomHeadersEntry, ProviderCategory, ProviderRecord } from '../backend/ConsoleModels';
import { configManagerFacade } from '../backend/CodexBackend';
import { ArkPilotBreakpoint } from '../adaptive/BreakpointTypes';
import { breakpointManager } from '../adaptive/BreakpointManager';

type ToastTone = 'info' | 'success' | 'warning' | 'error';

class UiToastItem {
  id: number;
  tone: ToastTone;
  message: string;

  constructor(id: number, tone: ToastTone, message: string) {
    this.id = id;
    this.tone = tone;
    this.message = message;
  }
}

@Entry
@Component
struct AddProviderPage {
  @StorageProp('arkPilotBreakpoint') currentBreakpoint: ArkPilotBreakpoint = 'sm';
  @State private isSubmitting: boolean = false;
  @State private sparkSeed: number = 0;
  @State private toasts: UiToastItem[] = [];
  @State private toastIdSeed: number = 1;
  @State private selectedPresetId: string = 'custom';
  @State private providerName: string = '';
  @State private providerNote: string = '';
  @State private websiteUrl: string = '';
  @State private apiKey: string = '';
  @State private baseUrl: string = '';
  @State private defaultModel: string = '';
  @State private editId: string = '';
  @State private contextWindowStr: string = '';
  private modelAutoCompactTokenLimit: number = 0;
  private toastTimerId: number = -1;
  private backTimerId: number = -1;

  private get isPhone(): boolean {
    return this.currentBreakpoint === 'xs' || this.currentBreakpoint === 'sm';
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

  private inputSurface(): string {
    return '#FFFFFF';
  }

  private get pagePadding(): number {
    return this.isPhone ? 12 : 24;
  }

  private get pageMargin(): number {
    return this.isPhone ? 8 : 24;
  }

  aboutToAppear(): void {
    breakpointManager.initialize((condition: string) => mediaQuery.matchMediaSync(condition));
    const rawParams: Object = router.getParams();
    if (rawParams !== undefined && rawParams !== null) {
      const params = rawParams as Record<string, string>;
      if (params['editId'] !== undefined && params['editId'].length > 0) {
        this.editId = params['editId'];
        this.loadProviderForEdit(this.editId);
        return;
      }
    }
    this.applyPreset(this.selectedPresetId, false);
  }

  aboutToDisappear(): void {
    if (this.toastTimerId >= 0) {
      clearTimeout(this.toastTimerId);
      this.toastTimerId = -1;
    }
    if (this.backTimerId >= 0) {
      clearTimeout(this.backTimerId);
      this.backTimerId = -1;
    }
  }

  private loadProviderForEdit(providerId: string): void {
    const result = configManagerFacade.listProviders();
    if (!result.ok || result.data === null) {
      this.triggerFeedback('加载 Provider 失败。', 'error');
      return;
    }
    const provider = result.data.find((p: ProviderRecord) => p.id === providerId);
    if (provider === undefined) {
      this.triggerFeedback('未找到该 Provider。', 'error');
      return;
    }
    this.providerName = provider.name;
    this.providerNote = provider.description;
    this.websiteUrl = provider.websiteUrl;
    this.apiKey = provider.apiKey;
    this.baseUrl = provider.baseUrl;
    this.defaultModel = provider.model;
    this.contextWindowStr = provider.contextWindow > 0 ? String(provider.contextWindow) : '';
    this.modelAutoCompactTokenLimit = provider.modelAutoCompactTokenLimit;
    this.selectedPresetId = 'custom';
    this.triggerFeedback('已加载 Provider 数据。', 'success');
  }

  private triggerFeedback(message: string, tone: ToastTone = 'info'): void {
    this.sparkSeed += 1;
    this.showToast(message, tone);
  }

  private showToast(message: string, tone: ToastTone = 'info', duration: number = 1800): void {
    if (this.toastTimerId >= 0) {
      clearTimeout(this.toastTimerId);
      this.toastTimerId = -1;
    }
    const toastId = this.toastIdSeed;
    this.toastIdSeed += 1;
    this.toasts = [new UiToastItem(toastId, tone, message)];
    const timerId: number = setTimeout(() => {
      if (this.toastTimerId === timerId) {
        this.toastTimerId = -1;
      }
      this.dismissToast(toastId);
    }, duration);
    this.toastTimerId = timerId;
  }

  private dismissToast(toastId: number): void {
    this.toasts = this.toasts.filter((toast: UiToastItem) => toast.id !== toastId);
  }

  private toneBackground(tone: ToastTone): string {
    switch (tone) {
      case 'success':
        return '#DCFCE7';
      case 'warning':
        return '#FEF3C7';
      case 'error':
        return '#FEE2E2';
      default:
        return '#E0F2FE';
    }
  }

  private toneColor(tone: ToastTone): string {
    switch (tone) {
      case 'success':
        return '#166534';
      case 'warning':
        return '#92400E';
      case 'error':
        return '#B91C1C';
      default:
        return '#0C4A6E';
    }
  }

  private categoryLabel(category: ProviderCategory): string {
    switch (category) {
      case 'official':
        return '官方';
      case 'third_party':
        return '第三方';
      case 'cloud_provider':
        return '云服务商';
      case 'aggregator':
        return '聚合';
      case 'custom':
        return '自定义';
      default:
        return category;
    }
  }

  private presetAccent(presetId: string): string {
    const preset = this.findPreset(presetId);
    if (preset !== null && preset.iconColor.trim().length > 0) {
      return preset.iconColor;
    }
    return '#8B5CF6';
  }

  private presetIconText(): string {
    if (this.selectedPresetId === 'custom') {
      return 'P';
    }
    const preset = this.findPreset(this.selectedPresetId);
    if (preset === null) {
      return 'P';
    }
    const name = preset.name.trim();
    if (name.length > 0) {
      return name.substring(0, 1).toUpperCase();
    }
    return 'P';
  }

  private selectedPreset(): ProviderPreset | null {
    return this.findPreset(this.selectedPresetId);
  }

  private selectedPresetCategoryLabel(): string {
    const preset = this.selectedPreset();
    if (preset === null) {
      return '';
    }
    return this.categoryLabel(preset.category);
  }

  private findPreset(presetId: string): ProviderPreset | null {
    for (let index = 0; index < BUILTIN_PROVIDER_PRESETS.length; index += 1) {
      if (BUILTIN_PROVIDER_PRESETS[index].id === presetId) {
        return BUILTIN_PROVIDER_PRESETS[index];
      }
    }
    return null;
  }

  private visiblePresets(): ProviderPreset[] {
    const result: ProviderPreset[] = [];
    for (let index = 0; index < BUILTIN_PROVIDER_PRESETS.length; index += 1) {
      result.push(BUILTIN_PROVIDER_PRESETS[index]);
    }
    return result;
  }

  private currentPresetModels(): string[] {
    const preset = this.findPreset(this.selectedPresetId);
    if (preset === null) {
      return [];
    }
    return preset.models;
  }

  private applyPreset(presetId: string, withToast: boolean = true): void {
    this.selectedPresetId = presetId;
    if (presetId === 'custom') {
      this.providerName = '';
      this.providerNote = '';
      this.websiteUrl = '';
      this.apiKey = '';
      this.baseUrl = '';
      this.defaultModel = '';
      this.modelAutoCompactTokenLimit = 0;
      if (withToast) {
        this.triggerFeedback('已切换到自定义配置。', 'info');
      }
      return;
    }

    const preset = this.findPreset(presetId);
    if (preset === null) {
      return;
    }

    this.providerName = preset.name;
    this.providerNote = preset.description;
    this.websiteUrl = preset.websiteUrl;
    this.baseUrl = preset.baseUrl;
    this.defaultModel = preset.defaultModel;
    this.modelAutoCompactTokenLimit = 0;
    if (withToast) {
      this.triggerFeedback(`已载入 ${preset.name} 预设。`, 'success');
    }
  }

  private submitAddProvider(): void {
    if (this.isSubmitting) {
      return;
    }
    if (this.providerName.trim().length === 0) {
      this.triggerFeedback('请先填写供应商名称。', 'error');
      return;
    }
    if (this.apiKey.trim().length === 0) {
      this.triggerFeedback('请先填写 API Key。', 'error');
      return;
    }
    if (this.baseUrl.trim().length === 0) {
      this.triggerFeedback('请先填写请求地址。', 'error');
      return;
    }

    this.isSubmitting = true;
    try {
      const preset: ProviderPreset | null = this.findPreset(this.selectedPresetId);
      const category: ProviderCategory = preset !== null ? preset.category : 'custom';
      const icon: string = preset !== null ? preset.icon : '';
      const iconColor: string = preset !== null ? preset.iconColor : '';
      const defaultModel: string = this.defaultModel.trim().length > 0
        ? this.defaultModel
        : (preset !== null ? preset.defaultModel : '');
      const authMode: string = preset !== null ? preset.authMode : 'apiKey';
      const headers: CustomHeadersEntry[] = [];
      if (preset !== null) {
        for (let hi: number = 0; hi < preset.customHeaders.length; hi += 1) {
          const h = preset.customHeaders[hi];
          headers.push(new CustomHeadersEntry(h.key, h.value));
        }
      }

      const providerId: string = this.editId.length > 0
        ? this.editId
        : `provider-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
      const contextWindow: number = this.contextWindowStr.trim().length > 0
        ? parseInt(this.contextWindowStr.trim()) || 0
        : 0;
      const provider = new ProviderRecord(
        providerId,
        this.providerName,
        'codex',
        'exclusive',
        this.baseUrl,
        this.apiKey,
        defaultModel,
        false,
        'dirty',
        '',
        authMode,
        headers,
        'responses',
        category,
        this.providerNote,
        this.websiteUrl,
        icon,
        iconColor,
        [],
        'unknown',
        0,
        0,
        null,
        Date.now(),
        contextWindow,
        this.modelAutoCompactTokenLimit
      );
      const result = configManagerFacade.saveProvider(provider);
      if (!result.ok || result.data === null) {
        const msg = result.error !== null ? result.error.message : '保存 Provider 失败。';
        this.triggerFeedback(msg, 'error');
        this.isSubmitting = false;
        return;
      }
      const actionLabel: string = this.editId.length > 0 ? '已更新' : '已添加';
      this.triggerFeedback(`${actionLabel} "${result.data.name}"。`, 'success');
      if (this.backTimerId >= 0) {
        clearTimeout(this.backTimerId);
        this.backTimerId = -1;
      }
      const backTimerId: number = setTimeout(() => {
        if (this.backTimerId === backTimerId) {
          this.backTimerId = -1;
        }
        router.back();
      }, 600);
      this.backTimerId = backTimerId;
    } catch (_err) {
      this.isSubmitting = false;
      this.triggerFeedback('保存失败，请检查配置后重试。', 'error');
    }
  }

  @Builder
  private backdropLayer() {
    if (!this.isPhone) {
      Stack() {
        Column()
          .width(320)
          .height(320)
          .backgroundColor('#D7E8FF')
          .opacity(0.34)
          .borderRadius(180)
          .position({ x: -72, y: -36 })

        Column()
          .width(240)
          .height(240)
          .backgroundColor('#FFF3D6')
          .opacity(0.28)
          .borderRadius(160)
          .position({ x: 760, y: 116 })
      }
      .width('100%')
      .height('100%')
    }
  }

  @Builder
  private particleCluster() {
    Row() {
      ForEach([0, 1, 2, 3, 4], (index: number) => {
        Column()
          .width(index % 2 === 0 ? 8 : 5)
          .height(index % 2 === 0 ? 8 : 5)
          .backgroundColor(index % 3 === 0 ? '#60A5FA' : (index % 3 === 1 ? '#34D399' : '#FBBF24'))
          .borderRadius(12)
          .opacity((this.sparkSeed + index) % 2 === 0 ? 0.95 : 0.35)
          .scale({ x: (this.sparkSeed + index) % 2 === 0 ? 1.18 : 0.82, y: (this.sparkSeed + index) % 2 === 0 ? 1.18 : 0.82 })
          .margin({ left: index === 0 ? 0 : 8, top: index % 2 === 0 ? 0 : 10 })
          .animation({ duration: 220, curve: Curve.EaseOut })
      })
    }
  }

  @Builder
  private topBar() {
    Row() {
      Button() {
        Row() {
          Text('←')
            .fontSize(16)
            .fontColor(this.textPrimary())
          Text('返回')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textPrimary())
            .margin({ left: 8 })
        }
      }
      .height(42)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.surface())
      .borderRadius(18)
      .border({ width: 1, color: '#D8E1EE' })
      .onClick(() => { router.back(); })

      Column() {
        Text(this.editId.length > 0 ? '编辑供应商' : '添加新供应商')
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(this.isPhone ? 18 : 24)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textPrimary())
        if (!this.isPhone) {
          Text(this.editId.length > 0 ? '修改配置后保存' : '选择预设并配置服务商')
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(11)
            .fontColor(this.textSecondary())
            .margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 18 })

      Blank()
        .layoutWeight(1)

      if (!this.isPhone) {
        this.particleCluster()
      }
    }
    .width('100%')
    .padding({ left: this.pagePadding, right: this.pagePadding, top: this.isPhone ? 16 : 24, bottom: 16 })
  }

  @Builder
  private formLabel(label: string) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.textPrimary())
      .margin({ top: 16 })
  }

  @Builder
  private chip(label: string, background: string, color: string) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(10)
      .fontColor(color)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor(background)
      .borderRadius(10)
  }

  @Builder
  private sectionCard(title: string, subtitle: string) {
    Column() {
      Text(title)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textPrimary())
      Text(subtitle)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(11)
        .fontColor(this.textSecondary())
        .lineHeight(18)
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  private presetSection() {
    Column() {
      this.sectionCard('预设供应商', '选择预设开始配置')

      Flex({ wrap: FlexWrap.Wrap }) {
        Button('自定义配置')
          .height(36)
          .fontSize(11)
          .fontWeight(this.selectedPresetId === 'custom' ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.selectedPresetId === 'custom' ? '#FFFFFF' : this.textMuted())
          .backgroundColor(this.selectedPresetId === 'custom' ? '#2284F6' : '#F5F7FB')
          .borderRadius(12)
          .border({ width: this.selectedPresetId === 'custom' ? 0 : 1, color: '#E1E7F0' })
          .padding({ left: 14, right: 14 })
          .margin({ right: 10, bottom: 10 })
          .onClick(() => { this.applyPreset('custom'); })

        ForEach(this.visiblePresets(), (preset: ProviderPreset) => {
          Button(preset.name)
            .height(36)
            .fontSize(11)
            .fontWeight(this.selectedPresetId === preset.id ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.selectedPresetId === preset.id ? '#FFFFFF' : this.textMuted())
            .backgroundColor(this.selectedPresetId === preset.id ? '#2284F6' : '#F5F7FB')
            .borderRadius(12)
            .border({ width: this.selectedPresetId === preset.id ? 0 : 1, color: '#E1E7F0' })
            .padding({ left: 14, right: 14 })
            .margin({ right: 10, bottom: 10 })
            .onClick(() => { this.applyPreset(preset.id); })
        }, (preset: ProviderPreset) => preset.id)
      }
      .width('100%')
      .margin({ top: 14 })
      
      Row() {
        Text('💡')
          .fontSize(11)
        Text('自定义配置需手动填写所有必要字段')
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(10)
          .fontColor(this.textMuted())
          .margin({ left: 6 })
      }
      .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(18)
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#E2EAF3' })
    .borderRadius(24)
  }

  @Builder
  private previewBadge() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(78)
          .height(78)
          .backgroundColor(this.inputSurface())
          .border({ width: 1, color: '#E3E8F2' })
          .borderRadius(22)

        Text(this.presetIconText())
          .copyOption(CopyOptions.None)
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.presetAccent(this.selectedPresetId))
      }

      if (this.selectedPresetId !== 'custom' && this.selectedPreset() !== null) {
        Row() {
          this.chip(this.selectedPresetCategoryLabel(), '#EEF4FF', '#3563C8')
        }
        .margin({ top: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 14, bottom: 8 })
  }

  @Builder
  private requestHint() {
    Text('请填写 OpenAI 格式（Responses API）的请求地址，通常以 /v1 结尾')
      .copyOption(CopyOptions.LocalDevice)
      .fontSize(11)
      .fontColor(this.textSecondary())
      .margin({ top: 8 })
  }

  @Builder
  private contentPanel() {
    Column() {
      this.presetSection()

      this.previewBadge()

      if (this.isPhone) {
        Column() {
          this.formLabel('供应商名称')
          TextInput({ text: $$this.providerName, placeholder: '例如：OpenAI 官方' })
            .width('100%').height(42).backgroundColor(this.inputSurface())
            .border({ width: 1, color: '#DEE6F2' }).borderRadius(14)
            .padding({ left: 14, right: 14 }).margin({ top: 8 })

          this.formLabel('备注')
          TextInput({ text: $$this.providerNote, placeholder: '例如：公司专用账号' })
            .width('100%').height(42).backgroundColor(this.inputSurface())
            .border({ width: 1, color: '#DEE6F2' }).borderRadius(14)
            .padding({ left: 14, right: 14 }).margin({ top: 8 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      } else {
        Row() {
          Column() {
            this.formLabel('供应商名称')
            TextInput({ text: $$this.providerName, placeholder: '例如：OpenAI 官方' })
              .width('100%').height(42).backgroundColor(this.inputSurface())
              .border({ width: 1, color: '#DEE6F2' }).borderRadius(14)
              .padding({ left: 14, right: 14 }).margin({ top: 8 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column() {
            this.formLabel('备注')
            TextInput({ text: $$this.providerNote, placeholder: '例如：公司专用账号' })
              .width('100%').height(42).backgroundColor(this.inputSurface())
              .border({ width: 1, color: '#DEE6F2' }).borderRadius(14)
              .padding({ left: 14, right: 14 }).margin({ top: 8 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 14 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }

      this.formLabel('官网链接')
      TextInput({ text: $$this.websiteUrl, placeholder: 'https://example.com（可选）' })
        .width('100%').height(42).backgroundColor(this.inputSurface())
        .border({ width: 1, color: '#DEE6F2' }).borderRadius(14)
        .padding({ left: 14, right: 14 }).margin({ top: 8 })

      this.formLabel('API Key')
      TextInput({ text: $$this.apiKey, placeholder: '只需要填这里，下方配置会自动填充' })
        .width('100%').height(42).backgroundColor(this.inputSurface())
        .border({ width: 1, color: '#DEE6F2' }).borderRadius(14)
        .padding({ left: 14, right: 14 }).margin({ top: 8 })

      this.formLabel('默认模型')
      TextInput({ text: $$this.defaultModel, placeholder: '例如：gpt-5.4' })
        .width('100%').height(42).backgroundColor(this.inputSurface())
        .border({ width: 1, color: '#DEE6F2' }).borderRadius(14)
        .padding({ left: 14, right: 14 }).margin({ top: 8 })

      if (this.currentPresetModels().length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.currentPresetModels(), (model: string) => {
            Button(model)
              .height(28)
              .fontSize(10)
              .fontWeight(this.defaultModel === model ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.defaultModel === model ? '#FFFFFF' : this.textMuted())
              .backgroundColor(this.defaultModel === model ? '#2284F6' : '#F5F7FB')
              .borderRadius(10)
              .border({ width: this.defaultModel === model ? 0 : 1, color: '#E1E7F0' })
              .padding({ left: 10, right: 10 })
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.defaultModel = model;
                this.triggerFeedback(`已选择模型 ${model}`, 'success');
              })
          }, (model: string) => model)
        }
        .width('100%')
        .margin({ top: 10 })

        Row() {
          Text('💡')
            .fontSize(11)
          Text('以上为快捷填入按钮，具体模型名请以你实际使用的为准')
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(10)
            .fontColor(this.textMuted())
            .margin({ left: 6 })
        }
        .margin({ top: 4 })
      }

      this.formLabel('上下文窗口大小（可选）')
      TextInput({ text: $$this.contextWindowStr, placeholder: '例如：1000000（留空使用模型默认值）' })
        .width('100%').height(42).backgroundColor(this.inputSurface())
        .border({ width: 1, color: '#DEE6F2' }).borderRadius(14)
        .padding({ left: 14, right: 14 }).margin({ top: 8 })
        .type(InputType.Number)

      Row() {
        Text('请求地址')
          .copyOption(CopyOptions.None)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textPrimary())
        Blank()
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 16 })

      TextInput({ text: $$this.baseUrl, placeholder: 'https://your-api-endpoint.com' })
        .width('100%').height(42).backgroundColor(this.inputSurface())
        .border({ width: 1, color: '#DEE6F2' }).borderRadius(14)
        .padding({ left: 14, right: 14 }).margin({ top: 8 })
      this.requestHint()
    }
    .alignItems(HorizontalAlign.Start)
    .padding(18)
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#E2EAF3' })
    .borderRadius(24)
  }

  @Builder
  private bottomBar() {
    Row() {
      Blank()
        .layoutWeight(1)

      Button('取消')
        .height(40)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textSecondary())
      .backgroundColor(this.surface())
        .borderRadius(14)
        .border({ width: 1, color: '#D5E0ED' })
        .padding({ left: 18, right: 18 })
        .onClick(() => { router.back(); })

      Button(this.editId.length > 0 ? '保存' : '+ 添加')
        .height(40)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .backgroundColor('#2284F6')
        .borderRadius(14)
        .padding({ left: 20, right: 20 })
        .margin({ left: 12 })
        .enabled(!this.isSubmitting)
        .onClick(() => { this.submitAddProvider(); })
    }
    .padding({ left: this.isPhone ? 12 : 24, right: this.isPhone ? 12 : 24, top: 14, bottom: 18 })
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#E3EAF4' })
    .borderRadius(22)
    .margin({ top: 16 })
  }

  @Builder
  private toastHost() {
    Column() {
      ForEach(this.toasts, (toast: UiToastItem) => {
        Row() {
          Column()
            .width(8)
            .height(8)
            .backgroundColor(this.toneColor(toast.tone))
            .borderRadius(8)

          Text(toast.message)
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor(this.textPrimary())
            .margin({ left: 10 })
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .constraintSize({ maxWidth: 360 })
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(this.toneBackground(toast.tone))
        .border({ width: 1, color: '#FFFFFF' })
        .borderRadius(18)
        .margin({ top: 10 })
      }, (toast: UiToastItem) => `${toast.id}`)
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .alignItems(HorizontalAlign.End)
    .position({ x: 0, y: 28 })
  }

  build() {
    Stack() {
      this.backdropLayer()

      Column() {
        this.topBar()

        Scroll() {
          Column() {
            this.contentPanel()
            this.bottomBar()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: this.pagePadding, right: this.pagePadding, bottom: 24 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')

      this.toastHost()
    }
    .width('100%')
    .height('100%')
      .backgroundColor('#E9EEF6')
  }
}
