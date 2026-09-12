import { configManagerFacade, ConfigActionError } from '../backend/CodexBackend';
import {
  ProviderRecord, ProviderPreset,
  ApiValidationResult, EndpointSpeedResult, UsageQueryResult,
  BUILTIN_PROVIDER_PRESETS
} from './ApiTypes';

@Observed
export class ApiManagementState {
  providers: ProviderRecord[] = [];
  presets: ProviderPreset[] = BUILTIN_PROVIDER_PRESETS;
  editingProvider: ProviderRecord | null = null;
  validationResult: ApiValidationResult | null = null;
  speedResults: EndpointSpeedResult[] = [];
  discoveredModels: string[] = [];
  usageResult: UsageQueryResult | null = null;
  loading: boolean = false;
  validating: boolean = false;
  speedTesting: boolean = false;
  discoveringModels: boolean = false;
  queryingUsage: boolean = false;
  showAddFromPreset: boolean = false;
  selectedPresetId: string = '';
  newApiKey: string = '';
  statusText: string = '';
  errorText: string = '';
}

export class ApiManagementViewModel {
  state: ApiManagementState = new ApiManagementState();

  get activeProvider(): ProviderRecord | null {
    const providers = this.state.providers;
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].isActive) return providers[i];
    }
    return null;
  }

  get activeProviderName(): string {
    const active = this.activeProvider;
    return active !== null ? active.name : 'None';
  }

  loadProviders(): void {
    this.state.loading = true;
    try {
      const result = configManagerFacade.listProviders();
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.state.providers = result.data;
      this.state.errorText = '';
    } catch (err) {
      this.state.errorText = this.describeError(err);
    } finally {
      this.state.loading = false;
    }
  }

  startNewFromPreset(): void {
    this.state.showAddFromPreset = true;
    this.state.selectedPresetId = '';
    this.state.newApiKey = '';
  }

  confirmAddFromPreset(): void {
    if (this.state.selectedPresetId.length === 0) {
      return;
    }

    try {
      const result = configManagerFacade.addProviderFromPreset(
        this.state.selectedPresetId,
        this.state.newApiKey
      );
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.loadProviders();
      this.state.editingProvider = result.data;
      this.state.showAddFromPreset = false;
      this.state.errorText = '';
      this.state.statusText = `已从预设创建 "${result.data.name}"`;
    } catch (err) {
      this.state.errorText = this.describeError(err);
    }
  }

  cancelAddFromPreset(): void {
    this.state.showAddFromPreset = false;
    this.state.selectedPresetId = '';
    this.state.newApiKey = '';
  }

  startEditing(provider: ProviderRecord | null): void {
    if (provider !== null) {
      this.state.editingProvider = this.cloneProvider(provider);
    } else {
      this.state.editingProvider = new ProviderRecord(
        `provider-${Date.now()}-${Math.floor(Math.random() * 1000)}`,
        '', 'codex', 'exclusive',
        '', '', '',
        false, 'dirty', '',
        'apiKey', [], 'responses',
        'custom', '', '', '', '',
        [], 'unknown', 0, 0,
        null, Date.now()
      );
    }
  }

  cancelEditing(): void {
    this.state.editingProvider = null;
  }

  saveEditing(): void {
    const editing = this.state.editingProvider;
    if (editing === null) return;

    try {
      const result = configManagerFacade.saveProvider(editing);
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.loadProviders();
      this.state.editingProvider = null;
      this.state.errorText = '';
      this.state.statusText = `Provider "${result.data.name}" 已保存`;
    } catch (err) {
      this.state.errorText = this.describeError(err);
    }
  }

  reorderProviders(providers: ProviderRecord[]): void {
    try {
      const result = configManagerFacade.reorderProviders(providers);
      if (!result.ok) {
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.loadProviders();
      this.state.errorText = '';
    } catch (err) {
      this.state.errorText = this.describeError(err);
    }
  }

  activateProvider(id: string): void {
    try {
      const result = configManagerFacade.setActiveProvider(id);
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.loadProviders();
      this.state.errorText = '';
      this.state.statusText = `已激活 Provider "${result.data.name}"`;
    } catch (err) {
      this.state.errorText = this.describeError(err);
    }
  }

  deleteProvider(id: string): void {
    try {
      const providers = this.state.providers;
      let target: ProviderRecord | null = null;
      for (let i = 0; i < providers.length; i++) {
        if (providers[i].id === id) {
          target = providers[i];
          break;
        }
      }
      const result = configManagerFacade.removeProvider(id);
      if (!result.ok) {
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.loadProviders();
      if (this.state.editingProvider !== null && this.state.editingProvider.id === id) {
        this.state.editingProvider = null;
      }
      this.state.errorText = '';
      this.state.statusText = target !== null
        ? `Provider "${target.name}" 已删除`
        : 'Provider 已删除';
    } catch (err) {
      this.state.errorText = this.describeError(err);
    }
  }

  async validateProvider(provider: ProviderRecord): Promise<void> {
    this.state.validating = true;
    this.state.validationResult = null;
    try {
      const result = await configManagerFacade.validateProvider(provider);
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        this.state.validationResult = new ApiValidationResult(false, 0, 0, this.state.errorText, 0, '');
        return;
      }
      this.state.validationResult = result.data;
      this.state.errorText = result.data.success ? '' : result.data.errorMessage;
      this.state.statusText = result.data.success ? 'Provider 验证完成' : '';
    } catch (err) {
      this.state.errorText = this.describeError(err);
    } finally {
      this.state.validating = false;
    }
  }

  async testSpeed(provider: ProviderRecord, autoSelect: boolean): Promise<void> {
    this.state.speedTesting = true;
    this.state.speedResults = [];
    try {
      const result = await configManagerFacade.testProviderSpeed(provider, autoSelect);
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.state.speedResults = result.data;
      this.loadProviders();
      this.state.errorText = '';
      this.state.statusText = result.data.length > 0 ? 'Provider 测速完成' : '未获得测速结果';
    } catch (err) {
      this.state.errorText = this.describeError(err);
    } finally {
      this.state.speedTesting = false;
    }
  }

  async discoverModels(provider: ProviderRecord): Promise<void> {
    this.state.discoveringModels = true;
    this.state.discoveredModels = [];
    try {
      const result = await configManagerFacade.discoverProviderModels(provider);
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        this.state.statusText = '';
        return;
      }
      this.state.discoveredModels = result.data;
      this.state.errorText = '';
      this.state.statusText = result.data.length > 0 ? `已发现 ${result.data.length} 个模型` : '未发现可用模型';
    } catch (err) {
      this.state.errorText = this.describeError(err);
    } finally {
      this.state.discoveringModels = false;
    }
  }

  async queryUsage(provider: ProviderRecord): Promise<void> {
    this.state.queryingUsage = true;
    this.state.usageResult = null;
    try {
      const result = await configManagerFacade.queryProviderUsage(provider);
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        this.state.usageResult = new UsageQueryResult(false, provider.name, '', 0, 0, 0, '', '', Date.now(), this.state.errorText);
        return;
      }
      this.state.usageResult = result.data;
      this.state.errorText = result.data.success ? '' : result.data.errorMessage;
      this.state.statusText = result.data.success ? '用量查询完成' : '';
    } catch (err) {
      this.state.errorText = this.describeError(err);
    } finally {
      this.state.queryingUsage = false;
    }
  }

  exportProviders(): string {
    try {
      const result = configManagerFacade.exportProviders();
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        return '';
      }
      this.state.errorText = '';
      return result.data;
    } catch (err) {
      this.state.errorText = this.describeError(err);
      return '';
    }
  }

  exportProvidersMasked(): string {
    try {
      const result = configManagerFacade.exportProvidersMasked();
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        return '';
      }
      this.state.errorText = '';
      return result.data;
    } catch (err) {
      this.state.errorText = this.describeError(err);
      return '';
    }
  }

  importProviders(json: string): void {
    try {
      const result = configManagerFacade.importProviders(json);
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.loadProviders();
      this.state.statusText = `已导入 ${result.data} 个 Provider`;
      this.state.errorText = '';
    } catch (err) {
      this.state.errorText = this.describeError(err);
    }
  }

  private cloneProvider(src: ProviderRecord): ProviderRecord {
    return new ProviderRecord(
      src.id, src.name, src.appType, src.mode,
      src.baseUrl, src.apiKey, src.model,
      src.isActive, src.syncStatus, src.updatedAt,
      src.authMode,
      src.copyHeaders(),
      src.wireApi,
      src.category, src.description, src.websiteUrl,
      src.icon, src.iconColor,
      src.endpoints,
      src.healthStatus, src.healthLatencyMs, src.lastValidatedAt,
      src.usageScript, src.createdAt, src.contextWindow,
      src.modelAutoCompactTokenLimit
    );
  }

  private describeActionError(error: ConfigActionError | null): string {
    if (error === null) {
      return '操作失败';
    }
    return error.message;
  }

  private describeError(err: Object): string {
    if (err instanceof Error) {
      return err.message;
    }
    return JSON.stringify(err);
  }
}

export const apiManagementVM: ApiManagementViewModel =
  new ApiManagementViewModel();