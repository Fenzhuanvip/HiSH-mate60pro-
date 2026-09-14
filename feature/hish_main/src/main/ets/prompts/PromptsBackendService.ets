import { getPromptsRegistry, savePromptsRegistry, readAgentsMd, writeAgentsMd, enablePromptNative, disableAllPromptsNative } from '../backend/CodexNative';
import { PromptRecord, PromptImportResult } from './PromptTypes';
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const MAX_NAME_LEN = 100;
const MAX_CONTENT_PREVIEW_LEN = 500;
const AUTO_IMPORT_MARKER_NAME = '.prompts-auto-imported';
const BACKEND_LOG_DOMAIN: number = 0x0ff1;
const BACKEND_LOG_TAG: string = 'PromptsService';

export enum PromptErrorCode {
  INVALID_NAME = 'INVALID_NAME',
  NOT_FOUND = 'NOT_FOUND',
  CANNOT_DELETE_ENABLED = 'CANNOT_DELETE_ENABLED',
}

export class PromptError extends Error {
  code: PromptErrorCode;
  context: Map<string, string>;
  suggestion: string;

  constructor(code: PromptErrorCode, context: Map<string, string>, suggestion: string) {
    let ctxStr: string = '';
    let first: boolean = true;
    context.forEach((value: string, key: string) => {
      if (!first) {
        ctxStr += ', ';
      }
      ctxStr += key + '=' + value;
      first = false;
    });
    super('[' + code + '] ' + ctxStr);
    this.name = 'PromptError';
    this.code = code;
    this.context = context;
    this.suggestion = suggestion;
  }
}

export const PROMPT_ERROR_MESSAGES: Map<PromptErrorCode, string> = new Map([
  [PromptErrorCode.INVALID_NAME, '名称不合法，不能为空且不超过 100 个字符'],
  [PromptErrorCode.NOT_FOUND, '未找到指定的 Prompt'],
  [PromptErrorCode.CANNOT_DELETE_ENABLED, '不能删除正在启用的 Prompt，请先切换到其他 Prompt 或全部禁用'],
]);

function makeErrorCtx(): Map<string, string> {
  return new Map<string, string>();
}

const INDUSTRIAL_ENGINEER_FRAMEWORK = `# 工业软件设计工程师思维框架

你具备工业软件设计工程师的思维方式，在所有交互中默认遵循以下原则：

## 核心设计原则

- **分层解耦**：表示层 / 业务逻辑层 / 领域模型层 / 设备通信层 / 数据持久层，各层通过明确契约通信
- **设备抽象**：硬件通信统一接口，支持多协议热切换（OPC UA / Modbus / MQTT / CAN）
- **故障隔离**：单设备异常不扩散，必须有超时、重试、熔断、降级策略
- **数据流单向**：采集 → 处理 → 存储 → 展示，每层有明确的数据契约

## 编码铁律

- 浮点数禁止直接比较，必须用 epsilon 容差
- 所有 I/O 操作必须有超时，禁止无限等待
- UI 线程禁止网络请求、数据库查询、大量计算
- 状态用枚举不用魔数，状态转换必须校验合法性
- 内部统一 SI 单位制和 UTC 时间，展示层做转换
- 共享数据必须有同步保护，优先消息传递而非共享内存

## 决策偏好

- 安全性 > 性能 > 便利性
- 成熟稳定库 > 新潮库
- 契约优先：先定义接口，再实现
- 关键路径先做原型验证（数值算法、通信、实时性能）

## 反模式警觉

遇到以下模式时主动警告：上帝类、硬编码协议、无超时通信、UI 线程阻塞、浮点直接比较、状态魔数、日志不足。

## 回复铁律

- 完成推理、工具调用或命令执行后，必须向用户输出一段**完整、清晰的最终回答**（结论 + 关键依据），不得只输出推理或不输出正文就结束。
- 任务未完成时，不得自行判定"已完成"；若需用户决策或遇到阻塞，应明确说明当前进度与下一步。
- 长思考后必须收敛：把推理沉淀为可读的最终正文，避免"想了很久却不写出来"。
`;

export class PromptsBackendService {
  private codexHome: string;

  constructor(codexHome: string) {
    this.codexHome = codexHome;
  }

  private autoImportMarkerPath(): string {
    return `${this.codexHome}/${AUTO_IMPORT_MARKER_NAME}`;
  }

  private hasAutoImportMarker(): boolean {
    try {
      fileIo.statSync(this.autoImportMarkerPath());
      return true;
    } catch (_) {
      return false;
    }
  }

  private writeAutoImportMarker(): void {
    const markerFile = fileIo.openSync(
      this.autoImportMarkerPath(),
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
    );
    fileIo.closeSync(markerFile);
  }

  async getPrompts(): Promise<PromptRecord[]> {
    const json: string = getPromptsRegistry(this.codexHome);
    let promptsArr: Object[] = [];
    try {
      const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      promptsArr = (parsed['prompts'] as Object[]) ?? [] as Object[];
    } catch (_) {
      promptsArr = [];
    }
    const result: PromptRecord[] = [];
    for (let i: number = 0; i < promptsArr.length; i++) {
      result.push(PromptRecord.fromJSON(promptsArr[i] as Record<string, Object>));
    }
    return result;
  }

  private async savePrompts(prompts: PromptRecord[]): Promise<void> {
    const now: string = String(Math.floor(Date.now() / 1000));
    const registry: Record<string, Object> = {} as Record<string, Object>;
    registry['version'] = 1;
    registry['prompts'] = prompts;
    registry['updatedAt'] = now;
    const ok: boolean = savePromptsRegistry(this.codexHome, JSON.stringify(registry));
    if (!ok) {
      throw new Error('保存 Prompt 失败');
    }
  }

  async savePrompt(prompt: PromptRecord): Promise<void> {
    const name: string = prompt.name.trim();
    if (name.length === 0 || name.length > MAX_NAME_LEN) {
      const ctx: Map<string, string> = makeErrorCtx();
      ctx.set('name', prompt.name);
      throw new PromptError(PromptErrorCode.INVALID_NAME, ctx, '名称不能为空且不超过 100 个字符');
    }

    prompt.name = name;
    prompt.description = (prompt.description ?? '').trim();
    prompt.updatedAt = Date.now();

    const prompts: PromptRecord[] = await this.getPrompts();
    const index: number = prompts.findIndex((p: PromptRecord) => p.id === prompt.id);

    if (index >= 0) {
      prompts[index] = prompt;
    } else {
      prompts.push(prompt);
    }

    await this.savePrompts(prompts);

    if (prompt.enabled) {
      await this.enablePrompt(prompt.id);
    }
  }

  async deletePrompt(id: string): Promise<void> {
    const prompts: PromptRecord[] = await this.getPrompts();
    const prompt: PromptRecord | undefined = prompts.find((p: PromptRecord) => p.id === id);

    if (!prompt) {
      const ctx: Map<string, string> = makeErrorCtx();
      ctx.set('id', id);
      throw new PromptError(PromptErrorCode.NOT_FOUND, ctx, 'Prompt 不存在');
    }
    if (prompt.enabled) {
      const ctx: Map<string, string> = makeErrorCtx();
      ctx.set('id', id);
      ctx.set('name', prompt.name);
      throw new PromptError(PromptErrorCode.CANNOT_DELETE_ENABLED, ctx,
        '不能删除正在启用的 Prompt，请先切换到其他 Prompt 或全部禁用');
    }

    const filtered: PromptRecord[] = prompts.filter((p: PromptRecord) => p.id !== id);
    await this.savePrompts(filtered);
  }

  async enablePrompt(id: string): Promise<void> {
    const json: string = enablePromptNative(this.codexHome, id);
    const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    if (parsed['error'] !== undefined && parsed['error'] !== null) {
      const ctx: Map<string, string> = makeErrorCtx();
      ctx.set('id', id);
      throw new PromptError(PromptErrorCode.NOT_FOUND, ctx, String(parsed['error']));
    }
    if (!parsed['id'] || String(parsed['id']).length === 0) {
      const ctx: Map<string, string> = makeErrorCtx();
      ctx.set('id', id);
      throw new PromptError(PromptErrorCode.NOT_FOUND, ctx, 'Prompt 不存在');
    }
  }

  async disableAll(): Promise<void> {
    const ok: boolean = disableAllPromptsNative(this.codexHome);
    if (!ok) {
      throw new Error('Failed to disable all prompts');
    }
  }

  async getLiveContent(): Promise<string> {
    return readAgentsMd(this.codexHome);
  }

  async importFromFile(): Promise<PromptImportResult | null> {
    const content: string = readAgentsMd(this.codexHome);

    if (content.trim().length === 0) {
      return null;
    }

    const id: string = 'imported-' + Date.now();
    const firstLine: string = content.trimStart().split('\n')[0].replace(/^#\s*/, '');
    const name: string = firstLine.length > 0 ? 'Imported: ' + firstLine.substring(0, 50) : 'Imported';

    const prompt: PromptRecord = new PromptRecord(
      id, name, content,
      '从 AGENTS.md 导入', false, Date.now(), 0
    );

    const preview: string = content.length > MAX_CONTENT_PREVIEW_LEN
      ? content.substring(0, MAX_CONTENT_PREVIEW_LEN) + '...'
      : content;

    return new PromptImportResult(prompt, preview);
  }

  /** 幂等确保 AGENTS.md 含"回复铁律"段：缺则追加到末尾（保留用户已有内容）。 */
  async ensureReplyRules(): Promise<void> {
    const REPLY_RULES_MARKER: string = '## 回复铁律';
    const REPLY_RULES: string = `
## 回复铁律

- 完成推理、工具调用或命令执行后，必须向用户输出一段**完整、清晰的最终回答**（结论 + 关键依据），不得只输出推理或不输出正文就结束。
- 任务未完成时，不得自行判定"已完成"；若需用户决策或遇到阻塞，应明确说明当前进度与下一步。
- 长思考后必须收敛：把推理沉淀为可读的最终正文，避免"想了很久却不写出来"。`;
    try {
      const existingContent: string = readAgentsMd(this.codexHome);
      if (existingContent.indexOf(REPLY_RULES_MARKER) >= 0) {
        return;
      }
      const next: string = existingContent.trim().length > 0
        ? `${existingContent}\n${REPLY_RULES}`
        : REPLY_RULES;
      if (!writeAgentsMd(this.codexHome, next)) {
        throw new Error('写入 AGENTS.md 回复铁律失败');
      }
    } catch (err) {
      hilog.warn(BACKEND_LOG_DOMAIN, BACKEND_LOG_TAG, 'ensureReplyRules failed: %{public}s', err instanceof Error ? err.message : JSON.stringify(err));
    }
  }

  async autoImportOnFirstLaunch(): Promise<void> {
    if (this.hasAutoImportMarker()) {
      return;
    }

    const prompts: PromptRecord[] = await this.getPrompts();
    if (prompts.length > 0) {
      this.writeAutoImportMarker();
      return;
    }

    const existingContent: string = readAgentsMd(this.codexHome);
    const content: string = existingContent.trim().length > 0
      ? INDUSTRIAL_ENGINEER_FRAMEWORK + '\n\n' + existingContent
      : INDUSTRIAL_ENGINEER_FRAMEWORK;

    const id: string = 'auto-imported-' + Date.now();

    const prompt: PromptRecord = new PromptRecord(
      id, 'Industrial Engineer + Default', content,
      '首次启动自动注入', true, Date.now(), 0
    );

    prompts.push(prompt);
    await this.savePrompts(prompts);
    if (!writeAgentsMd(this.codexHome, content)) {
      throw new Error('写入 AGENTS.md 失败');
    }
    this.writeAutoImportMarker();
  }
}
