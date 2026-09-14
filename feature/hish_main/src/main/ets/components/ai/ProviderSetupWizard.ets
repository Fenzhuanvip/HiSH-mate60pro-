import { saveEmbeddedCodexProviderConfig } from '../../backend/CodexNative';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const WIZARD_DOMAIN = 0x0001;
const WIZARD_TAG = 'ProviderSetupWizard';

// 预置 Provider 模板
class ProviderTemplate {
  name: string;
  baseUrl: string;
  model: string;
  contextWindow: number;
  description: string;

  constructor(
    name: string,
    baseUrl: string,
    model: string,
    contextWindow: number,
    description: string
  ) {
    this.name = name;
    this.baseUrl = baseUrl;
    this.model = model;
    this.contextWindow = contextWindow;
    this.description = description;
  }
}

const PROVIDER_TEMPLATES: ProviderTemplate[] = [
  new ProviderTemplate(
    'OpenAI',
    'https://api.openai.com/v1',
    'gpt-4o',
    128000,
    'GPT-4o，OpenAI 旗舰模型，支持 128K 上下文'
  ),
  new ProviderTemplate(
    'DeepSeek',
    'https://api.deepseek.com/v1',
    'deepseek-chat',
    64000,
    'DeepSeek Chat，性价比高，支持 64K 上下文'
  ),
  new ProviderTemplate(
    'Anthropic Claude',
    'https://api.anthropic.com/v1',
    'claude-3-5-sonnet-20241022',
    200000,
    'Claude 3.5 Sonnet，擅长代码生成，200K 上下文'
  ),
  new ProviderTemplate(
    '通义千问',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'qwen-max',
    32000,
    '阿里通义千问 Max，国内访问快'
  ),
  new ProviderTemplate(
    '自定义',
    '',
    '',
    0,
    '手动填写 baseUrl、Model 和 API Key'
  )
];

@Component
export struct ProviderSetupWizard {
  @State private selectedTemplateIndex: number = 0
  @State private apiKey: string = ''
  @State private baseUrl: string = ''
  @State private model: string = ''
  @State private isSaving: boolean = false
  @State private errorText: string = ''
  private onComplete: () => void = (): void => {}

  aboutToAppear(): void {
    // 默认选中第一个模板
    this.applyTemplate(0)
  }

  private applyTemplate(index: number): void {
    const template = PROVIDER_TEMPLATES[index]
    this.selectedTemplateIndex = index
    this.baseUrl = template.baseUrl
    this.model = template.model
    this.errorText = ''
  }

  private async saveAndComplete(): Promise<void> {
    if (this.isSaving) {
      return
    }

    const trimmedBaseUrl = this.baseUrl.trim()
    const trimmedApiKey = this.apiKey.trim()
    const trimmedModel = this.model.trim()

    if (trimmedBaseUrl.length === 0) {
      this.errorText = '请填写 API Base URL'
      return
    }
    if (trimmedApiKey.length === 0) {
      this.errorText = '请填写 API Key'
      return
    }
    if (trimmedModel.length === 0) {
      this.errorText = '请填写模型名称'
      return
    }

    this.isSaving = true
    this.errorText = ''

    try {
      const template = PROVIDER_TEMPLATES[this.selectedTemplateIndex]
      saveEmbeddedCodexProviderConfig(
        trimmedBaseUrl,
        trimmedApiKey,
        trimmedModel,
        template.contextWindow,
        0
      )
      hilog.info(WIZARD_DOMAIN, WIZARD_TAG, 'Provider saved: baseUrl=%{public}s model=%{public}s', trimmedBaseUrl, trimmedModel)
      this.isSaving = false
      this.onComplete()
    } catch (err) {
      this.isSaving = false
      this.errorText = `保存失败: ${err}`
      hilog.error(WIZARD_DOMAIN, WIZARD_TAG, 'Save failed: %{public}s', JSON.stringify(err))
    }
  }

  build() {
    Column() {
      // 标题
      Row() {
        Text('配置 AI 模型')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#0F172A')
      }
      .width('100%')
      .margin({ bottom: 8 })

      Text('选择一个 AI 供应商，填入你的 API Key 即可开始使用。')
        .fontSize(13)
        .fontColor('#64748B')
        .margin({ bottom: 20 })
        .width('100%')

      // Provider 模板选择
      Text('选择供应商')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#334155')
        .margin({ bottom: 8 })
        .width('100%')

      // 模板列表
      ForEach(PROVIDER_TEMPLATES, (template: ProviderTemplate, index: number) => {
        Row() {
          Column() {
            Text(template.name)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.selectedTemplateIndex === index ? '#3B82F6' : '#0F172A')
            Text(template.description)
              .fontSize(11)
              .fontColor('#94A3B8')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.selectedTemplateIndex === index) {
            Text('✓')
              .fontSize(16)
              .fontColor('#3B82F6')
          }
        }
        .width('100%')
        .padding(12)
        .borderRadius(8)
        .backgroundColor(this.selectedTemplateIndex === index ? '#EFF6FF' : '#F8FAFC')
        .border({
          width: 1,
          color: this.selectedTemplateIndex === index ? '#3B82F6' : '#E2E8F0'
        })
        .margin({ bottom: 6 })
        .onClick(() => {
          this.applyTemplate(index)
        })
      })

      // API Key 输入
      Text('API Key')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#334155')
        .margin({ top: 16, bottom: 6 })
        .width('100%')

      TextInput({ text: this.apiKey, placeholder: 'sk-...' })
        .type(InputType.Password)
        .fontSize(14)
        .borderRadius(8)
        .backgroundColor('#F8FAFC')
        .border({ width: 1, color: '#E2E8F0' })
        .width('100%')
        .onChange((value: string) => {
          this.apiKey = value
        })

      // Base URL（自定义模板时可编辑）
      Text('API Base URL')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#334155')
        .margin({ top: 12, bottom: 6 })
        .width('100%')

      TextInput({ text: this.baseUrl, placeholder: 'https://api.openai.com/v1' })
        .fontSize(14)
        .borderRadius(8)
        .backgroundColor('#F8FAFC')
        .border({ width: 1, color: '#E2E8F0' })
        .width('100%')
        .enabled(PROVIDER_TEMPLATES[this.selectedTemplateIndex].name === '自定义')
        .onChange((value: string) => {
          this.baseUrl = value
        })

      // Model（自定义模板时可编辑）
      Text('模型名称')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#334155')
        .margin({ top: 12, bottom: 6 })
        .width('100%')

      TextInput({ text: this.model, placeholder: 'gpt-4o' })
        .fontSize(14)
        .borderRadius(8)
        .backgroundColor('#F8FAFC')
        .border({ width: 1, color: '#E2E8F0' })
        .width('100%')
        .enabled(PROVIDER_TEMPLATES[this.selectedTemplateIndex].name === '自定义')
        .onChange((value: string) => {
          this.model = value
        })

      // 错误提示
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(12)
          .fontColor('#EF4444')
          .margin({ top: 8 })
          .width('100%')
      }

      // 保存按钮
      Button(this.isSaving ? '保存中…' : '保存并开始使用')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(44)
        .margin({ top: 20 })
        .backgroundColor('#3B82F6')
        .fontColor('#FFFFFF')
        .enabled(!this.isSaving)
        .onClick(() => {
          void this.saveAndComplete()
        })
    }
    .width('100%')
    .padding(20)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
  }
}
