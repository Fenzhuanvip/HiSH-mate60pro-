import { PromptsBackendService, PromptError, PROMPT_ERROR_MESSAGES } from './PromptsBackendService';
import { PromptRecord, PromptImportResult } from './PromptTypes';

@Observed
export class PromptsState {
  prompts: PromptRecord[] = [];
  liveContent: string = '';
  editingPrompt: PromptRecord | null = null;
  loading: boolean = false;
  saving: boolean = false;
  operating: boolean = false;
  statusMessage: string = '';
  statusType: string = '';
}

@Observed
export class PromptsViewModel {
  private service: PromptsBackendService;
  state: PromptsState = new PromptsState();

  constructor(service: PromptsBackendService) {
    this.service = service;
  }

  get activePrompt(): PromptRecord | null {
    for (let i: number = 0; i < this.state.prompts.length; i++) {
      if (this.state.prompts[i].enabled) {
        return this.state.prompts[i];
      }
    }
    return null;
  }

  get activePromptName(): string {
    const active: PromptRecord | null = this.activePrompt;
    if (active !== null) {
      return active.name;
    }
    return 'None';
  }

  private showStatus(message: string, type: string): void {
    this.state.statusMessage = message;
    this.state.statusType = type;
  }

  private clearStatus(): void {
    this.state.statusMessage = '';
    this.state.statusType = '';
  }

  private getErrorMessage(err: Object): string {
    if (err instanceof PromptError) {
      const mapped: string | undefined = PROMPT_ERROR_MESSAGES.get(err.code);
      return mapped ?? err.message;
    }
    if (err instanceof Error) {
      return err.message;
    }
    return '未知错误';
  }

  async loadAll(): Promise<void> {
    this.state.loading = true;
    try {
      this.state.prompts = await this.service.getPrompts();
      this.state.liveContent = await this.service.getLiveContent();
    } catch (err) {
      this.showStatus('加载失败: ' + this.getErrorMessage(err), 'error');
    } finally {
      this.state.loading = false;
    }
  }

  async reloadLiveContent(): Promise<void> {
    try {
      this.state.liveContent = await this.service.getLiveContent();
    } catch (err) {
      this.showStatus('刷新失败: ' + this.getErrorMessage(err), 'error');
    }
  }

  async savePrompt(prompt: PromptRecord): Promise<void> {
    this.state.saving = true;
    this.clearStatus();
    try {
      await this.service.savePrompt(prompt);

      let foundIndex: number = -1;
      for (let i: number = 0; i < this.state.prompts.length; i++) {
        if (this.state.prompts[i].id === prompt.id) {
          foundIndex = i;
          break;
        }
      }
      if (foundIndex >= 0) {
        this.state.prompts[foundIndex] = prompt;
      } else {
        const newPrompts: PromptRecord[] = [];
        for (let i: number = 0; i < this.state.prompts.length; i++) {
          newPrompts.push(this.state.prompts[i]);
        }
        newPrompts.push(prompt);
        this.state.prompts = newPrompts;
      }

      this.state.editingPrompt = null;

      if (prompt.enabled) {
        for (let i: number = 0; i < this.state.prompts.length; i++) {
          this.state.prompts[i].enabled = this.state.prompts[i].id === prompt.id;
        }
        this.state.liveContent = await this.service.getLiveContent();
      }

      this.showStatus('已保存', 'success');
    } catch (err) {
      this.showStatus('保存失败: ' + this.getErrorMessage(err), 'error');
    } finally {
      this.state.saving = false;
    }
  }

  async deletePrompt(id: string): Promise<void> {
    this.clearStatus();
    try {
      await this.service.deletePrompt(id);
      const filtered: PromptRecord[] = [];
      for (let i: number = 0; i < this.state.prompts.length; i++) {
        if (this.state.prompts[i].id !== id) {
          filtered.push(this.state.prompts[i]);
        }
      }
      this.state.prompts = filtered;
      this.showStatus('已删除', 'success');
    } catch (err) {
      const message: string = this.getErrorMessage(err);
      this.showStatus('删除失败: ' + message, 'error');
      // 状态已更新后，再以标准 Error 形式抛出，保证调用方 .catch() 仍能收到错误
      const normalized: string = message.length > 0 ? message : '未知错误';
      throw new Error(normalized);
    }
  }

  async enablePrompt(id: string): Promise<void> {
    this.state.operating = true;
    this.clearStatus();
    try {
      await this.service.enablePrompt(id);

      for (let i: number = 0; i < this.state.prompts.length; i++) {
        this.state.prompts[i].enabled = this.state.prompts[i].id === id;
      }

      this.state.liveContent = await this.service.getLiveContent();
      this.showStatus('已启用', 'success');
    } catch (err) {
      this.showStatus('启用失败: ' + this.getErrorMessage(err), 'error');
    } finally {
      this.state.operating = false;
    }
  }

  async disableAll(): Promise<void> {
    this.state.operating = true;
    this.clearStatus();
    try {
      await this.service.disableAll();

      for (let i: number = 0; i < this.state.prompts.length; i++) {
        this.state.prompts[i].enabled = false;
      }

      this.state.liveContent = '';
      this.showStatus('已全部禁用', 'success');
    } catch (err) {
      this.showStatus('禁用失败: ' + this.getErrorMessage(err), 'error');
    } finally {
      this.state.operating = false;
    }
  }

  async importFromFile(): Promise<void> {
    this.clearStatus();
    try {
      const result: PromptImportResult | null = await this.service.importFromFile();
      if (result === null) {
        this.showStatus('AGENTS.md 为空，无内容可导入', 'info');
        return;
      }
      this.state.editingPrompt = result.prompt;
      this.showStatus('已从 AGENTS.md 导入，请检查后保存', 'info');
    } catch (err) {
      this.showStatus('导入失败: ' + this.getErrorMessage(err), 'error');
    }
  }

  startEditing(prompt: PromptRecord | null): void {
    this.clearStatus();
    if (prompt) {
      this.state.editingPrompt = new PromptRecord(
        prompt.id, prompt.name, prompt.content,
        prompt.description, prompt.enabled,
        prompt.createdAt, prompt.updatedAt
      );
    } else {
      this.state.editingPrompt = new PromptRecord(
        'prompt-' + Date.now(), '', '',
        '', false, Date.now(), 0
      );
    }
  }

  cancelEditing(): void {
    this.state.editingPrompt = null;
  }
}
