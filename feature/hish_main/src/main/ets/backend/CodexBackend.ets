import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  accountLoginNative,
  accountReadNative,
  approvalApproveNative,
  approvalDeclineNative,
  approvalPollNative,
  CollaborationModeOption,
  CodexHostStatus,
  getEmbeddedCodexHostStatus,
  getEmbeddedCodexHostStatusAsync,
  initializeNative,
  initializeAsyncNative,
  mcpConfigAddNative,
  mcpConfigBatchWriteNative,
  mcpConfigReadNative,
  mcpConfigRemoveNative,
  mcpOauthStartNative,
  mcpReloadNative,
  mcpStatusListNative,
  compactStartNative,
  threadArchiveAsyncNative,
  threadListAsyncNative,
  threadNameSetAsyncNative,
  threadReadAsyncNative,
  threadResumeNative,
  threadResumeAsyncNative,
  threadStartNative,
  threadStartAsyncNative,
  turnInterruptNative,
  turnPollNative,
  turnPollAsyncNative,
  turnEventsAsyncNative,
  turnStartNative,
  turnStartAsyncNative,
  collaborationModeListAsyncNative,
  fetchNativeTokenUsageAggregate
} from './CodexNative';
import {
  CustomHeadersEntry,
  EndpointEntry,
  McpAuthStatus,
  McpHealthStatus,
  McpServerRecord,
  ProviderRecord,
  SessionSummary,
  UsageScriptEntry,
  UsageSummary,
  WorkspaceAccessKind,
  WorkspaceDescriptor,
  WorkspacePermissionState,
  TokenUsageBreakdown,
  TurnTokenUsage,
  TokenUsageAggregate,
  CodexContextManagementSnapshot
} from './ConsoleModels';
import {
  ApiError,
  ApiValidationResult,
  EndpointSpeedResult,
  UsageQueryResult
} from '../apim/ApiTypes';
import { providerCatalogService } from './ProviderCatalogService';
import { apiManagementService } from '../apim/ApiManagementService';
import {
  DiscoverableSkill,
  InstalledSkill,
  SkillRepo,
  SkillsShSearchResult,
  SkillUpdateInfo,
  UnmanagedSkill,
  ReconcileResult
} from '../skills/SkillTypes';
import { SkillError, SkillsBackendService } from '../skills/SkillsBackendService';
import { aigcProvenanceStore, AigcRecordTurnParams } from './AigcProvenanceStore';
import { AigcCommandRecord } from './AigcProvenance';

export type CodexMessageRole = 'user' | 'assistant' | 'system' | 'reasoning' | 'command' | 'tool' | 'file' | 'search' | 'plan' | 'image' | 'hook' | 'review';
export type CodexTurnStatus = 'completed' | 'failed' | 'inProgress' | 'interrupted';
export type CodexDiffKind = 'add' | 'delete' | 'context';
export type CodexConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error';
export type CodexApprovalKind = 'command' | 'fileChange' | 'permissions' | 'mcpToolApproval' | 'requestUserInput';
export type CodexAuthMode = 'none' | 'apiKey' | 'chatgpt' | 'chatgptAuthTokens' | 'unknown';
export type CodexCompactionStatus = 'idle' | 'starting' | 'running' | 'completed' | 'failed' | 'timeout';
export type CodexTurnUpdateHandler = (result: CodexTurnResult) => void;
type BackendListener = (snapshot: CodexBackendSnapshot) => void;

const DEFAULT_SERVER_URL: string = 'native://entry';
const BACKEND_LOG_DOMAIN: number = 0x0ff1;
const BACKEND_LOG_TAG: string = 'CodexBackend';
const TURN_POLL_INTERVAL_MS: number = 200; // 事件轮询间隔
const TURN_POLL_HEARTBEAT_INTERVAL_MS: number = 500;
// 轮询超时：deepseek 等推理模型可能推理超过 5 分钟才产出正文，5 分钟太短会误中断。
const TURN_POLL_TIMEOUT_MS: number = 1200000; // 20 分钟轮询超时
// 压缩超时：压缩是后台操作，保持 5 分钟。
const COMPACTION_TIMEOUT_MS: number = 300000;
const APPROVAL_POLL_INTERVAL_MS: number = 1000;
const TERMINAL_TURN_DRAIN_ATTEMPTS: number = 3;
const TERMINAL_TURN_DRAIN_INTERVAL_MS: number = 250;
const NO_FILE_CHANGES_TEXT: string = '\u5c1a\u672a\u4ea7\u751f\u6587\u4ef6\u6539\u52a8';
const UNRECOGNIZED_CHANGED_FILES_TEXT: string = '\u5c1a\u672a\u8bc6\u522b\u53d8\u66f4\u6587\u4ef6';
/** native \u4fa7 REASONING_PENDING_CONTENT \u7684\u9632\u5fa1\u6027\u955c\u50cf\uff1aappendMessageDelta \u547d\u4e2d\u65f6\u6574\u6761\u66ff\u6362\u800c\u975e\u62fc\u63a5\u3002 */
const REASONING_PLACEHOLDER_TEXT: string = '\u6b63\u5728\u601d\u8003...';
const GENERIC_RUNNING_SUMMARY_TEXTS: string[] = ['ArkPilot \u6b63\u5728\u5904\u7406\u8bf7\u6c42', '\u7b49\u5f85\u66f4\u591a\u8f6e\u8be2\u7ed3\u679c', '\u672c\u8f6e\u6267\u884c\u5df2\u7ed3\u675f'];

export type ConfigKind = 'provider' | 'skill';
export type ConfigAction = 'list' | 'get' | 'add' | 'update' | 'remove' | 'enable' | 'disable' | 'setActive';
export type SkillConfigScope = 'installed' | 'repos' | 'discoverable' | 'unmanaged' | 'updates';

export class ConfigActionError {
  code: string;
  message: string;
  details: string;

  constructor(code: string, message: string, details: string = '') {
    this.code = code;
    this.message = message;
    this.details = details;
  }
}

export class ConfigActionResult<T> {
  ok: boolean;
  data: T | null;
  error: ConfigActionError | null;

  constructor(ok: boolean, data: T | null, error: ConfigActionError | null) {
    this.ok = ok;
    this.data = data;
    this.error = error;
  }
}

export class ConfigActionRequest {
  kind: ConfigKind;
  action: ConfigAction;
  id: string;
  scope: string;
  payload: Object | null;

  constructor(kind: ConfigKind, action: ConfigAction, id: string = '', scope: string = '', payload: Object | null = null) {
    this.kind = kind;
    this.action = action;
    this.id = id;
    this.scope = scope;
    this.payload = payload;
  }
}

function configSuccess<T>(data: T): ConfigActionResult<T> {
  return new ConfigActionResult<T>(true, data, null);
}

function configFailure<T>(code: string, message: string, details: string = ''): ConfigActionResult<T> {
  return new ConfigActionResult<T>(false, null, new ConfigActionError(code, message, details));
}

export class ConfigManagerFacade {
  private providersLoaded: boolean = false;
  private providerStore: ProviderRecord[] = [];
  private skillsInstalledLoaded: boolean = false;
  private skillInstalledStore: InstalledSkill[] = [];
  private skillsReposLoaded: boolean = false;
  private skillRepoStore: SkillRepo[] = [];

  private skillsService(): SkillsBackendService {
    const codexHome: string = (AppStorage.get('codexHome') as string) ?? '';
    return new SkillsBackendService(codexHome);
  }

  private reloadProviders(): ProviderRecord[] {
    this.providerStore = this.cloneProviders(apiManagementService.getProviders());
    this.providersLoaded = true;
    return this.cloneProviders(this.providerStore);
  }

  private async reloadInstalledSkills(): Promise<InstalledSkill[]> {
    this.skillInstalledStore = this.cloneInstalledSkills(await this.skillsService().getInstalled());
    this.skillsInstalledLoaded = true;
    return this.cloneInstalledSkills(this.skillInstalledStore);
  }

  private async reloadSkillRepos(): Promise<SkillRepo[]> {
    this.skillRepoStore = this.cloneSkillRepos(await this.skillsService().getRepos());
    this.skillsReposLoaded = true;
    return this.cloneSkillRepos(this.skillRepoStore);
  }

  private configFailureFromError<T>(err: Object, fallbackCode: string, fallbackMessage: string): ConfigActionResult<T> {
    if (err instanceof ApiError) {
      return configFailure<T>(err.code, err.suggestion, err.context);
    }
    if (err instanceof SkillError) {
      return configFailure<T>(err.code, err.suggestion, err.context);
    }
    if (err instanceof Error) {
      return configFailure<T>(fallbackCode, err.message, err.stack ?? '');
    }
    return configFailure<T>(fallbackCode, fallbackMessage, JSON.stringify(err));
  }

  private ensureProvidersLoaded(): void {
    if (this.providersLoaded) {
      return;
    }
    try {
      this.providerStore = this.cloneProviders(apiManagementService.getProviders());
    } catch (_err) {
      this.providerStore = [];
    }
    this.providersLoaded = true;
  }

  private async ensureInstalledSkillsLoaded(): Promise<void> {
    if (this.skillsInstalledLoaded) {
      return;
    }
    try {
      this.skillInstalledStore = this.cloneInstalledSkills(await this.skillsService().getInstalled());
    } catch (_err) {
      this.skillInstalledStore = [];
    }
    this.skillsInstalledLoaded = true;
  }

  private async ensureSkillReposLoaded(): Promise<void> {
    if (this.skillsReposLoaded) {
      return;
    }
    try {
      this.skillRepoStore = this.cloneSkillRepos(await this.skillsService().getRepos());
    } catch (_err) {
      this.skillRepoStore = [];
    }
    this.skillsReposLoaded = true;
  }

  listProviders(): ConfigActionResult<ProviderRecord[]> {
    this.ensureProvidersLoaded();
    return configSuccess<ProviderRecord[]>(this.cloneProviders(this.providerStore));
  }

  addProviderFromPreset(presetId: string, apiKey: string): ConfigActionResult<ProviderRecord> {
    try {
      const provider = apiManagementService.createFromPreset(presetId, apiKey);
      apiManagementService.saveProvider(provider);
      const providers = this.reloadProviders();
      const saved = providers.find((item: ProviderRecord) => item.id === provider.id);
      return configSuccess<ProviderRecord>(saved ?? this.cloneProvider(provider));
    } catch (err) {
      return this.configFailureFromError<ProviderRecord>(err as Object, 'ADD_PROVIDER_FAILED', '新增 Provider 失败。');
    }
  }

  saveProvider(provider: ProviderRecord): ConfigActionResult<ProviderRecord> {
    try {
      const next: ProviderRecord = this.cloneProvider(provider);
      apiManagementService.saveProvider(next);
      const providers = this.reloadProviders();
      const saved = providers.find((item: ProviderRecord) => item.id === next.id);
      return configSuccess<ProviderRecord>(saved ?? next);
    } catch (err) {
      return this.configFailureFromError<ProviderRecord>(err as Object, 'SAVE_PROVIDER_FAILED', '保存 Provider 失败。');
    }
  }

  reorderProviders(providers: ProviderRecord[]): ConfigActionResult<void> {
    try {
      apiManagementService.reorderProviders(providers);
      this.reloadProviders();
      return configSuccess<void>(undefined);
    } catch (err) {
      return this.configFailureFromError<void>(err as Object, 'REORDER_PROVIDERS_FAILED', '保存排序失败。');
    }
  }

  setActiveProvider(id: string): ConfigActionResult<ProviderRecord> {
    try {
      const activated = apiManagementService.activateProvider(id);
      const providers = this.reloadProviders();
      const saved = providers.find((item: ProviderRecord) => item.id === activated.id);
      return configSuccess<ProviderRecord>(saved ?? this.cloneProvider(activated));
    } catch (err) {
      return this.configFailureFromError<ProviderRecord>(err as Object, 'SET_ACTIVE_PROVIDER_FAILED', '激活 Provider 失败。');
    }
  }

  removeProvider(id: string): ConfigActionResult<string> {
    try {
      apiManagementService.deleteProvider(id);
      this.reloadProviders();
      return configSuccess<string>(id);
    } catch (err) {
      return this.configFailureFromError<string>(err as Object, 'REMOVE_PROVIDER_FAILED', '删除 Provider 失败。');
    }
  }

  exportProviders(): ConfigActionResult<string> {
    try {
      return configSuccess<string>(apiManagementService.exportProviders());
    } catch (err) {
      return this.configFailureFromError<string>(err as Object, 'EXPORT_PROVIDER_FAILED', '导出 Provider 失败。');
    }
  }

  exportProvidersMasked(): ConfigActionResult<string> {
    try {
      return configSuccess<string>(apiManagementService.exportProvidersMasked());
    } catch (err) {
      return this.configFailureFromError<string>(err as Object, 'EXPORT_PROVIDER_FAILED', '导出 Provider 失败。');
    }
  }

  importProviders(json: string): ConfigActionResult<number> {
    try {
      const count = apiManagementService.importProviders(json);
      this.reloadProviders();
      return configSuccess<number>(count);
    } catch (err) {
      return this.configFailureFromError<number>(err as Object, 'IMPORT_PROVIDER_FAILED', '导入 Provider 失败。');
    }
  }

  async validateProvider(provider: ProviderRecord): Promise<ConfigActionResult<ApiValidationResult>> {
    try {
      const result = await apiManagementService.validateApiKey(provider.baseUrl, provider.apiKey);
      return configSuccess<ApiValidationResult>(result);
    } catch (err) {
      return this.configFailureFromError<ApiValidationResult>(err as Object, 'VALIDATE_PROVIDER_FAILED', '验证 Provider 失败。');
    }
  }

  async testProviderSpeed(provider: ProviderRecord, autoSelect: boolean): Promise<ConfigActionResult<EndpointSpeedResult[]>> {
    try {
      const results = await apiManagementService.testEndpointSpeed(this.cloneProvider(provider), autoSelect);
      this.reloadProviders();
      return configSuccess<EndpointSpeedResult[]>(results);
    } catch (err) {
      return this.configFailureFromError<EndpointSpeedResult[]>(err as Object, 'TEST_PROVIDER_SPEED_FAILED', 'Provider 测速失败。');
    }
  }

  async discoverProviderModels(provider: ProviderRecord): Promise<ConfigActionResult<string[]>> {
    try {
      const models = await apiManagementService.discoverModels(provider.baseUrl, provider.apiKey);
      return configSuccess<string[]>(models);
    } catch (err) {
      return this.configFailureFromError<string[]>(err as Object, 'DISCOVER_PROVIDER_MODELS_FAILED', '模型发现失败。');
    }
  }

  async queryProviderUsage(provider: ProviderRecord): Promise<ConfigActionResult<UsageQueryResult>> {
    try {
      const usage = await apiManagementService.queryUsage(this.cloneProvider(provider));
      return configSuccess<UsageQueryResult>(usage);
    } catch (err) {
      return this.configFailureFromError<UsageQueryResult>(err as Object, 'QUERY_PROVIDER_USAGE_FAILED', '用量查询失败。');
    }
  }

  async listInstalledSkills(): Promise<ConfigActionResult<InstalledSkill[]>> {
    await this.ensureInstalledSkillsLoaded();
    return configSuccess<InstalledSkill[]>(this.cloneInstalledSkills(this.skillInstalledStore));
  }

  async setSkillEnabled(id: string, enabled: boolean): Promise<ConfigActionResult<InstalledSkill>> {
    try {
      const updated = await this.skillsService().setSkillEnabled(id, enabled);
      for (let i = 0; i < this.skillInstalledStore.length; i++) {
        if (this.skillInstalledStore[i].id === id) {
          this.skillInstalledStore[i] = this.cloneInstalledSkill(updated);
          break;
        }
      }
      return configSuccess<InstalledSkill>(this.cloneInstalledSkill(updated));
    } catch (err) {
      return this.configFailureFromError<InstalledSkill>(err as Object, 'SET_SKILL_ENABLED_FAILED', '切换 Skill 启用状态失败。');
    }
  }

  async removeInstalledSkill(id: string): Promise<ConfigActionResult<string>> {
    try {
      await this.skillsService().uninstall(id);
      await this.reloadInstalledSkills();
      return configSuccess<string>(id);
    } catch (err) {
      return this.configFailureFromError<string>(err as Object, 'REMOVE_SKILL_FAILED', '卸载 Skill 失败。');
    }
  }

  async listSkillRepos(): Promise<ConfigActionResult<SkillRepo[]>> {
    await this.ensureSkillReposLoaded();
    return configSuccess<SkillRepo[]>(this.cloneSkillRepos(this.skillRepoStore));
  }

  async addSkillRepo(repo: SkillRepo): Promise<ConfigActionResult<SkillRepo>> {
    try {
      const owner: string = repo.owner.trim();
      const name: string = repo.name.trim();
      const branch: string = repo.branch.trim().length > 0 ? repo.branch.trim() : 'main';
      if (owner.length === 0 || name.length === 0) {
        return configFailure<SkillRepo>('INVALID_DRAFT', '仓库 owner 与 name 不能为空。');
      }
      const currentRepos = await this.reloadSkillRepos();
      if (currentRepos.some((item: SkillRepo) => item.owner === owner && item.name === name)) {
        return configFailure<SkillRepo>('DIRECTORY_CONFLICT', '仓库已存在，无需重复添加。', `${owner}/${name}`);
      }
      const next = new SkillRepo(owner, name, branch, repo.enabled);
      await this.skillsService().addRepo(next);
      const repos = await this.reloadSkillRepos();
      const saved = repos.find((item: SkillRepo) => item.owner === owner && item.name === name);
      return configSuccess<SkillRepo>(saved ?? next);
    } catch (err) {
      return this.configFailureFromError<SkillRepo>(err as Object, 'ADD_SKILL_REPO_FAILED', '添加 Skill 仓库失败。');
    }
  }

  async setSkillRepoEnabled(owner: string, name: string, enabled: boolean): Promise<ConfigActionResult<SkillRepo>> {
    try {
      const repos = await this.reloadSkillRepos();
      const target = repos.find((repo: SkillRepo) => repo.owner === owner && repo.name === name);
      if (target === undefined) {
        return configFailure<SkillRepo>('NOT_FOUND', '仓库不存在。', `${owner}/${name}`);
      }
      target.enabled = enabled;
      await this.skillsService().saveRepos(repos);
      const reloaded = await this.reloadSkillRepos();
      const saved = reloaded.find((repo: SkillRepo) => repo.owner === owner && repo.name === name);
      if (saved === undefined) {
        return configFailure<SkillRepo>('NOT_FOUND', '仓库不存在。', `${owner}/${name}`);
      }
      return configSuccess<SkillRepo>(new SkillRepo(saved.owner, saved.name, saved.branch, saved.enabled));
    } catch (err) {
      return this.configFailureFromError<SkillRepo>(err as Object, 'SET_SKILL_REPO_ENABLED_FAILED', '切换 Skill 仓库状态失败。');
    }
  }

  async removeSkillRepo(owner: string, name: string): Promise<ConfigActionResult<string>> {
    try {
      const repos = await this.reloadSkillRepos();
      const exists = repos.some((repo: SkillRepo) => repo.owner === owner && repo.name === name);
      if (!exists) {
        return configFailure<string>('NOT_FOUND', '仓库不存在。', `${owner}/${name}`);
      }
      await this.skillsService().removeRepo(owner, name);
      await this.reloadSkillRepos();
      return configSuccess<string>(`${owner}/${name}`);
    } catch (err) {
      return this.configFailureFromError<string>(err as Object, 'REMOVE_SKILL_REPO_FAILED', '移除 Skill 仓库失败。');
    }
  }

  async discoverableSkills(): Promise<ConfigActionResult<DiscoverableSkill[]>> {
    try {
      const result = await this.skillsService().discoverFromRepos();
      return configSuccess<DiscoverableSkill[]>(result);
    } catch (err) {
      return this.configFailureFromError<DiscoverableSkill[]>(err as Object, 'DISCOVER_SKILLS_FAILED', '发现 Skill 失败。');
    }
  }

  async discoverFromSingleRepo(owner: string, name: string, branch: string): Promise<ConfigActionResult<DiscoverableSkill[]>> {
    try {
      const result = await this.skillsService().discoverFromRepo(owner, name, branch);
      return configSuccess<DiscoverableSkill[]>(result);
    } catch (err) {
      return this.configFailureFromError<DiscoverableSkill[]>(err as Object, 'DISCOVER_SKILLS_FAILED', '扫描仓库失败。');
    }
  }

  async scanUnmanagedSkills(): Promise<ConfigActionResult<UnmanagedSkill[]>> {
    try {
      const result = await this.skillsService().scanUnmanaged();
      return configSuccess<UnmanagedSkill[]>(result);
    } catch (err) {
      return this.configFailureFromError<UnmanagedSkill[]>(err as Object, 'SCAN_UNMANAGED_SKILLS_FAILED', '扫描未管理 Skill 失败。');
    }
  }

  async checkSkillUpdates(): Promise<ConfigActionResult<SkillUpdateInfo[]>> {
    try {
      const result = await this.skillsService().checkUpdates();
      return configSuccess<SkillUpdateInfo[]>(result);
    } catch (err) {
      return this.configFailureFromError<SkillUpdateInfo[]>(err as Object, 'CHECK_SKILL_UPDATES_FAILED', '检测 Skill 更新失败。');
    }
  }

  async installSkill(skill: DiscoverableSkill): Promise<ConfigActionResult<InstalledSkill>> {
    try {
      const installed = await this.skillsService().installFromGithub(skill);
      await this.reloadInstalledSkills();
      return configSuccess<InstalledSkill>(this.cloneInstalledSkill(installed));
    } catch (err) {
      return this.configFailureFromError<InstalledSkill>(err as Object, 'INSTALL_SKILL_FAILED', '安装 Skill 失败。');
    }
  }

  async updateSkill(id: string): Promise<ConfigActionResult<InstalledSkill>> {
    try {
      const updated = await this.skillsService().update(id);
      await this.reloadInstalledSkills();
      return configSuccess<InstalledSkill>(this.cloneInstalledSkill(updated));
    } catch (err) {
      return this.configFailureFromError<InstalledSkill>(err as Object, 'UPDATE_SKILL_FAILED', '更新 Skill 失败。');
    }
  }

  async importLocalSkills(directories: string[]): Promise<ConfigActionResult<InstalledSkill[]>> {
    try {
      const imported = await this.skillsService().importFromLocal(directories);
      await this.reloadInstalledSkills();
      return configSuccess<InstalledSkill[]>(this.cloneInstalledSkills(imported));
    } catch (err) {
      return this.configFailureFromError<InstalledSkill[]>(err as Object, 'IMPORT_LOCAL_SKILLS_FAILED', '导入本地 Skill 失败。');
    }
  }

  async importFromZipFile(zipPath: string): Promise<ConfigActionResult<InstalledSkill[]>> {
    try {
      const imported = await this.skillsService().importFromZip(zipPath);
      await this.reloadInstalledSkills();
      return configSuccess<InstalledSkill[]>(this.cloneInstalledSkills(imported));
    } catch (err) {
      return this.configFailureFromError<InstalledSkill[]>(err as Object, 'IMPORT_ZIP_SKILLS_FAILED', '从 ZIP 导入 Skill 失败。');
    }
  }

  async searchSkillsSh(query: string, limit: number, offset: number): Promise<ConfigActionResult<SkillsShSearchResult>> {
    try {
      const result = await this.skillsService().searchSkillsSh(query, limit, offset);
      return configSuccess<SkillsShSearchResult>(result);
    } catch (err) {
      return this.configFailureFromError<SkillsShSearchResult>(err as Object, 'SEARCH_SKILLS_SH_FAILED', '搜索 skills.sh 失败。');
    }
  }

  async reconcileSkills(): Promise<ConfigActionResult<ReconcileResult>> {
    try {
      const result = await this.skillsService().reconcileSkills();
      await this.reloadInstalledSkills();
      return configSuccess<ReconcileResult>(result);
    } catch (err) {
      return this.configFailureFromError<ReconcileResult>(err as Object, 'RECONCILE_SKILLS_FAILED', 'Skill 一致性检查失败。');
    }
  }

  private cloneProvider(provider: ProviderRecord): ProviderRecord {
    const endpoints: EndpointEntry[] = [];
    for (let index = 0; index < provider.endpoints.length; index += 1) {
      const endpoint = provider.endpoints[index];
      endpoints.push(new EndpointEntry(endpoint.url, endpoint.addedAt, endpoint.lastUsed, endpoint.latencyMs, endpoint.isActive));
    }
    let usageScript: UsageScriptEntry | null = null;
    if (provider.usageScript !== null) {
      const usageHeaders: CustomHeadersEntry[] = [];
      for (let index = 0; index < provider.usageScript.headers.length; index += 1) {
        const header = provider.usageScript.headers[index];
        usageHeaders.push(new CustomHeadersEntry(header.key, header.value));
      }
      usageScript = new UsageScriptEntry(
        provider.usageScript.enabled,
        provider.usageScript.scriptType,
        provider.usageScript.code,
        provider.usageScript.queryUrl,
        usageHeaders,
        provider.usageScript.autoQueryIntervalMin
      );
    }
    return new ProviderRecord(
      provider.id,
      provider.name,
      provider.appType,
      provider.mode,
      provider.baseUrl,
      provider.apiKey,
      provider.model,
      provider.isActive,
      provider.syncStatus,
      provider.updatedAt,
      provider.authMode,
      provider.copyHeaders(),
      provider.wireApi,
      provider.category,
      provider.description,
      provider.websiteUrl,
      provider.icon,
      provider.iconColor,
      endpoints,
      provider.healthStatus,
      provider.healthLatencyMs,
      provider.lastValidatedAt,
      usageScript,
      provider.createdAt,
      provider.contextWindow,
      provider.modelAutoCompactTokenLimit
    );
  }

  private cloneProviders(providers: ProviderRecord[]): ProviderRecord[] {
    const cloned: ProviderRecord[] = [];
    for (let index = 0; index < providers.length; index += 1) {
      cloned.push(this.cloneProvider(providers[index]));
    }
    return cloned;
  }

  private cloneInstalledSkill(skill: InstalledSkill): InstalledSkill {
    return new InstalledSkill(
      skill.id,
      skill.name,
      skill.description,
      skill.directory,
      skill.source,
      skill.repoOwner,
      skill.repoName,
      skill.repoBranch,
      skill.readmeUrl,
      skill.enabled,
      skill.installedAt,
      skill.contentHash,
      skill.updatedAt
    );
  }

  private cloneInstalledSkills(skills: InstalledSkill[]): InstalledSkill[] {
    const cloned: InstalledSkill[] = [];
    for (let index = 0; index < skills.length; index += 1) {
      cloned.push(this.cloneInstalledSkill(skills[index]));
    }
    return cloned;
  }

  private cloneSkillRepos(repos: SkillRepo[]): SkillRepo[] {
    const cloned: SkillRepo[] = [];
    for (let index = 0; index < repos.length; index += 1) {
      cloned.push(new SkillRepo(repos[index].owner, repos[index].name, repos[index].branch, repos[index].enabled));
    }
    return cloned;
  }
}

class ThreadPayload {
  id: string = '';
}

class TurnErrorPayload {
  message?: string;
}

class TurnPayload {
  id: string = '';
  status: string = '';
  error?: TurnErrorPayload;
}

class ThreadStartResultPayload {
  thread: ThreadPayload = new ThreadPayload();
  error?: TurnErrorPayload;
}

class TurnStartResultPayload {
  turn: TurnPayload = new TurnPayload();
}

class AccountPayload {
  type?: string;
  email?: string;
  planType?: string;
}

class GetAccountResponsePayload {
  account?: AccountPayload;
  requiresOpenaiAuth: boolean = true;
}

class McpServerStatusPayload {
  name: string = '';
  tools: Record<string, Object> = {};
  resources: Object[] = [];
  resourceTemplates: Object[] = [];
  authStatus: string = 'unsupported';
}

class McpStatusListResponsePayload {
  data: McpServerStatusPayload[] = [];
  nextCursor: string | null = null;
}

class InitializeClientInfoPayload {
  name: string = 'codex_harmony_agent';
  title: string = 'ArkPilot Harmony Agent';
  version: string = '0.1.0';
}

class InitializeCapabilitiesPayload {
  experimentalApi: boolean = true;
}

class InitializeRequestPayload {
  clientInfo: InitializeClientInfoPayload = new InitializeClientInfoPayload();
  capabilities: InitializeCapabilitiesPayload = new InitializeCapabilitiesPayload();
}

class AccountLoginRequestPayload {
  type: string = 'apiKey';
  apiKey: string = '';
}

class ApprovalActionRequestPayload {
  requestId: string | number = '';
  threadId: string = '';
  turnId: string = '';
  itemId: string = '';
  kind: CodexApprovalKind = 'command';
  answers: Record<string, RequestUserInputAnswerPayload> = {};
}

class RequestUserInputAnswerPayload {
  answers: string[] = [];
}

class TurnInputItemPayload {
  type: string = 'text';
  text: string = '';
}

class TurnStartRequestPayload {
  threadId: string = '';
  input: TurnInputItemPayload[] = [];
  cwd?: string;
  model?: string;
  effort?: string;
  collaborationMode?: CollaborationModePayload;
}

class CollaborationModePayload {
  name: string = '';
  mode: string = 'default';
  model?: string;
  reasoningEffort?: string | null;
}

class McpStatusListRequestPayload {
  limit: number = 100;
}

class McpConfigBatchEditPayload {
  keyPath: string = '';
  value: Object = new Object() as Object;
  mergeStrategy: string = 'replace';
}

class McpConfigBatchWriteRequestPayload {
  edits: McpConfigBatchEditPayload[] = [];
  reloadUserConfig: boolean = true;
}

class McpOauthStartRequestPayload {
  name: string = '';
}

class McpConfigReadRequestPayload {
  includeLayers: boolean = false;
}

class McpConfigAddRequestPayload {
  name: string = '';
  config: Object = new Object() as Object;
}

class McpConfigRemoveRequestPayload {
  name: string = '';
}

class ThreadStartRequestPayload {
  cwd?: string;
  model?: string;
}

class ThreadListRequestPayload {
  limit: number = 100;
  archived: boolean = false;
}

class CollaborationModeListResponsePayload {
  data: Object[] = [];
}

class ThreadListResponsePayload {
  data: Object[] = [];
  nextCursor: string | null = null;
}

class ThreadReadRequestPayload {
  threadId: string = '';
  includeTurns: boolean = true;
}

class ThreadReadSnapshotPayload {
  thread: CodexThreadRecord;
  lastTurnId: string;
  lastTurnStatus: string;

  constructor(thread: CodexThreadRecord, lastTurnId: string, lastTurnStatus: string) {
    this.thread = thread;
    this.lastTurnId = lastTurnId;
    this.lastTurnStatus = lastTurnStatus;
  }
}

class ThreadResumeRequestPayload {
  threadId: string = '';
  cwd?: string;
  model?: string;
}

class ThreadNameSetRequestPayload {
  threadId: string = '';
  name: string = '';
}

class ThreadArchiveRequestPayload {
  threadId: string = '';
}

class TurnPollResponsePayload {
}

class McpConfigReadResponsePayload {
  config: Record<string, Object> = {};
}

class ParsedDiff {
  lines: CodexDiffLine[] = [];
  diffStat: string = '+0 -0';
  constructor() {
    this.changedFiles = UNRECOGNIZED_CHANGED_FILES_TEXT;
  }
  changedFiles: string = '尚未识别变更文件';
}

export class CodexChatMessage {
  messageId: string;
  sequence: number;
  author: string;
  role: CodexMessageRole;
  content: string;
  timestamp: string;
  itemType?: string;
  status?: string;
  metadata?: Record<string, Object>;

  constructor(
    messageId: string,
    sequence: number,
    author: string,
    role: CodexMessageRole,
    content: string,
    timestamp: string,
    itemType?: string,
    status?: string,
    metadata?: Record<string, Object>
  ) {
    this.messageId = messageId;
    this.sequence = sequence;
    this.author = author;
    this.role = role;
    this.content = content;
    this.timestamp = timestamp;
    this.itemType = itemType;
    this.status = status;
    this.metadata = metadata;
  }
}

export class CodexDiffLine {
  lineId: string;
  sequence: number;
  lineNumber: string;
  sign: string;
  content: string;
  kind: CodexDiffKind;
  filePath: string;

  constructor(lineId: string, sequence: number, lineNumber: string, sign: string, content: string, kind: CodexDiffKind, filePath?: string) {
    this.lineId = lineId;
    this.sequence = sequence;
    this.lineNumber = lineNumber;
    this.sign = sign;
    this.content = content;
    this.kind = kind;
    this.filePath = filePath ?? '';
  }
}

export class CodexTurnRequest {
  threadKey: string;
  title: string;
  workspaceId: string;
  workspaceRoot: string;
  workspacePermissionState: WorkspacePermissionState;
  workspaceAccessKind: WorkspaceAccessKind;
  writableRoots: string[];
  model: string;
  reasoningEffort: string;
  collaborationMode: CollaborationModeOption | null;
  prompt: string;

  constructor(
    threadKey: string,
    title: string,
    workspaceId: string,
    workspaceRoot: string,
    workspacePermissionState: WorkspacePermissionState,
    workspaceAccessKind: WorkspaceAccessKind,
    writableRoots: string[],
    model: string,
    reasoningEffort: string,
    collaborationMode: CollaborationModeOption | null,
    prompt: string
  ) {
    this.threadKey = threadKey;
    this.title = title;
    this.workspaceId = workspaceId;
    this.workspaceRoot = workspaceRoot;
    this.workspacePermissionState = workspacePermissionState;
    this.workspaceAccessKind = workspaceAccessKind;
    this.writableRoots = writableRoots;
    this.model = model;
    this.reasoningEffort = reasoningEffort;
    this.collaborationMode = collaborationMode;
    this.prompt = prompt;
  }
}

export class CodexTurnResult {
  threadId: string;
  turnId: string;
  status: CodexTurnStatus;
  messages: CodexChatMessage[];
  diffLines: CodexDiffLine[];
  summaryTitle: string;
  summaryPoints: string[];
  changedFiles: string;
  diffStat: string;
  tokenUsage: TurnTokenUsage | null;
  contextManagement: CodexContextManagementSnapshot | null;
  modelAutoCompactTokenLimit: number | null;
  effectiveAutoCompactTokenLimit: number | null;
  autoCompactCurrentTotalTokens: number | null;
  autoCompactWillCheckBeforeNextTurn: boolean;
  autoCompactWouldWaitForFollowUp: boolean;
  autoCompactEnabled: boolean;
  remainingToAutoCompact: number | null;
  autoCompactNearThreshold: boolean;

  constructor(threadId: string, turnId: string, status: CodexTurnStatus, messages: CodexChatMessage[], diffLines: CodexDiffLine[], summaryTitle: string, summaryPoints: string[], changedFiles: string, diffStat: string, tokenUsage?: TurnTokenUsage | null, contextManagement?: CodexContextManagementSnapshot | null, modelAutoCompactTokenLimit?: number | null, effectiveAutoCompactTokenLimit?: number | null, autoCompactCurrentTotalTokens?: number | null, autoCompactWillCheckBeforeNextTurn?: boolean, autoCompactWouldWaitForFollowUp?: boolean, autoCompactEnabled?: boolean, remainingToAutoCompact?: number | null, autoCompactNearThreshold?: boolean) {
    this.threadId = threadId;
    this.turnId = turnId;
    this.status = status;
    this.messages = messages;
    this.diffLines = diffLines;
    this.summaryTitle = summaryTitle;
    this.summaryPoints = summaryPoints;
    this.changedFiles = changedFiles;
    this.diffStat = diffStat;
    this.tokenUsage = tokenUsage ?? null;
    this.contextManagement = contextManagement ?? null;
    this.modelAutoCompactTokenLimit = modelAutoCompactTokenLimit ?? null;
    this.effectiveAutoCompactTokenLimit = effectiveAutoCompactTokenLimit ?? null;
    this.autoCompactCurrentTotalTokens = autoCompactCurrentTotalTokens ?? null;
    this.autoCompactWillCheckBeforeNextTurn = autoCompactWillCheckBeforeNextTurn ?? false;
    this.autoCompactWouldWaitForFollowUp = autoCompactWouldWaitForFollowUp ?? false;
    this.autoCompactEnabled = autoCompactEnabled ?? false;
    this.remainingToAutoCompact = remainingToAutoCompact ?? null;
    this.autoCompactNearThreshold = autoCompactNearThreshold ?? false;
  }
}

export class CodexApprovalRequest {
  requestId: string | number;
  kind: CodexApprovalKind;
  title: string;
  detail: string;
  threadId: string;
  turnId: string;
  itemId: string;
  grantedPermissions?: Object;

  constructor(requestId: string | number, kind: CodexApprovalKind, title: string, detail: string, threadId: string, turnId: string, itemId: string) {
    this.requestId = requestId;
    this.kind = kind;
    this.title = title;
    this.detail = detail;
    this.threadId = threadId;
    this.turnId = turnId;
    this.itemId = itemId;
  }
}

export class CodexRequestUserInputOption {
  label: string;
  description: string;

  constructor(label: string, description: string) {
    this.label = label;
    this.description = description;
  }
}

export class CodexRequestUserInputQuestion {
  id: string;
  header: string;
  question: string;
  isOther: boolean;
  isSecret: boolean;
  options: CodexRequestUserInputOption[];

  constructor(id: string, header: string, question: string, isOther: boolean, isSecret: boolean, options?: CodexRequestUserInputOption[]) {
    this.id = id;
    this.header = header;
    this.question = question;
    this.isOther = isOther;
    this.isSecret = isSecret;
    this.options = options ?? [];
  }
}

export class CodexRequestUserInput {
  requestId: string | number;
  title: string;
  detail: string;
  threadId: string;
  turnId: string;
  itemId: string;
  questions: CodexRequestUserInputQuestion[];

  constructor(requestId: string | number, title: string, detail: string, threadId: string, turnId: string, itemId: string, questions?: CodexRequestUserInputQuestion[]) {
    this.requestId = requestId;
    this.title = title;
    this.detail = detail;
    this.threadId = threadId;
    this.turnId = turnId;
    this.itemId = itemId;
    this.questions = questions ?? [];
  }
}

export class CodexCompactionSnapshot {
  threadId: string;
  status: CodexCompactionStatus;
  errorMessage: string;
  savedTokens: number;
  oldTotalTokens: number;
  newTotalTokens: number;

  constructor(
    threadId: string,
    status: CodexCompactionStatus,
    errorMessage: string = '',
    savedTokens: number = 0,
    oldTotalTokens: number = 0,
    newTotalTokens: number = 0
  ) {
    this.threadId = threadId;
    this.status = status;
    this.errorMessage = errorMessage;
    this.savedTokens = savedTokens;
    this.oldTotalTokens = oldTotalTokens;
    this.newTotalTokens = newTotalTokens;
  }
}

export class CodexBackendSnapshot {
  serverUrl: string;
  connectionState: CodexConnectionState;
  connectionText: string;
  pendingApproval: CodexApprovalRequest | null;
  pendingRequestUserInput: CodexRequestUserInput | null;
  authMode: CodexAuthMode;
  requiresOpenAIAuth: boolean;
  authStatusText: string;
  planTypeText: string;
  mcpStatusText: string;
  mcpServerCount: number;
  mcpErrorText: string;
  collaborationModes: CollaborationModeOption[];
  tokenUsage: TurnTokenUsage | null;
  activeThreadId: string;
  compaction: CodexCompactionSnapshot;
  contextManagement: CodexContextManagementSnapshot;
  modelAutoCompactTokenLimit: number | null;
  effectiveAutoCompactTokenLimit: number | null;
  autoCompactCurrentTotalTokens: number | null;
  autoCompactWillCheckBeforeNextTurn: boolean;
  autoCompactWouldWaitForFollowUp: boolean;
  autoCompactEnabled: boolean;
  remainingToAutoCompact: number | null;
  autoCompactNearThreshold: boolean;

  constructor(
    serverUrl: string,
    connectionState: CodexConnectionState,
    connectionText: string,
    pendingApproval: CodexApprovalRequest | null,
    pendingRequestUserInput: CodexRequestUserInput | null,
    authMode: CodexAuthMode,
    requiresOpenAIAuth: boolean,
    authStatusText: string,
    planTypeText: string,
    mcpStatusText: string,
    mcpServerCount: number,
    mcpErrorText: string,
    collaborationModes?: CollaborationModeOption[],
    tokenUsage?: TurnTokenUsage | null,
    activeThreadId?: string,
    compaction?: CodexCompactionSnapshot,
    contextManagement?: CodexContextManagementSnapshot | null,
    modelAutoCompactTokenLimit?: number | null,
    effectiveAutoCompactTokenLimit?: number | null,
    autoCompactCurrentTotalTokens?: number | null,
    autoCompactWillCheckBeforeNextTurn?: boolean,
    autoCompactWouldWaitForFollowUp?: boolean,
    autoCompactEnabled?: boolean,
    remainingToAutoCompact?: number | null,
    autoCompactNearThreshold?: boolean
  ) {
    this.serverUrl = serverUrl;
    this.connectionState = connectionState;
    this.connectionText = connectionText;
    this.pendingApproval = pendingApproval;
    this.pendingRequestUserInput = pendingRequestUserInput;
    this.authMode = authMode;
    this.requiresOpenAIAuth = requiresOpenAIAuth;
    this.authStatusText = authStatusText;
    this.planTypeText = planTypeText;
    this.mcpStatusText = mcpStatusText;
    this.mcpServerCount = mcpServerCount;
    this.mcpErrorText = mcpErrorText;
    this.collaborationModes = collaborationModes ?? [];
    this.tokenUsage = tokenUsage ?? null;
    this.activeThreadId = activeThreadId ?? '';
    this.compaction = compaction ?? new CodexCompactionSnapshot('', 'idle');
    this.contextManagement = contextManagement ?? new CodexContextManagementSnapshot();
    this.modelAutoCompactTokenLimit = modelAutoCompactTokenLimit ?? null;
    this.effectiveAutoCompactTokenLimit = effectiveAutoCompactTokenLimit ?? null;
    this.autoCompactCurrentTotalTokens = autoCompactCurrentTotalTokens ?? null;
    this.autoCompactWillCheckBeforeNextTurn = autoCompactWillCheckBeforeNextTurn ?? false;
    this.autoCompactWouldWaitForFollowUp = autoCompactWouldWaitForFollowUp ?? false;
    this.autoCompactEnabled = autoCompactEnabled ?? false;
    this.remainingToAutoCompact = remainingToAutoCompact ?? null;
    this.autoCompactNearThreshold = autoCompactNearThreshold ?? false;
  }
}

class PendingTurnState {
  threadKey: string;
  turnId: string = '';
  cancelled: boolean = false;
  listener?: CodexTurnUpdateHandler;
  completion: Promise<CodexTurnResult>;
  resolveCompletion: (result: CodexTurnResult) => void;
  startingTotalTokens: number;

  constructor(threadKey: string, listener?: CodexTurnUpdateHandler, startingTotalTokens: number = -1) {
    this.threadKey = threadKey;
    this.listener = listener;
    this.startingTotalTokens = startingTotalTokens;
    this.resolveCompletion = (_result: CodexTurnResult): void => {};
    this.completion = new Promise<CodexTurnResult>((resolve) => {
      this.resolveCompletion = resolve;
    });
  }
}

class CompactionRunState {
  threadId: string = '';
  baselineTurnId: string = '';
  turnId: string = '';
  oldTotalTokens: number = 0;
  newTotalTokens: number = 0;
  status: CodexCompactionStatus = 'idle';
  errorMessage: string = '';
  savedTokens: number = 0;
  observedReduction: boolean = false;
}

class CodexThreadRecord {
  localKey: string;
  title: string;
  remoteThreadId: string = '';
  loaded: boolean = false;
  workspaceId: string = '';
  workspaceName: string = '';
  cwd: string = '';
  workspacePermissionState: WorkspacePermissionState = 'unavailable';
  workspaceAccessKind: WorkspaceAccessKind = 'unknown';
  writableRoots: string[] = [];
  messages: CodexChatMessage[] = [];
  diffLines: CodexDiffLine[] = [];
  summaryTitle: string = '';
  summaryPoints: string[] = [];
  changedFiles: string = '尚未产生文件改动';
  diffStat: string = '+0 -0';
  activeTurn: PendingTurnState | null = null;
  turnCount: number = 0;
  diffUpdateCount: number = 0;
  lastTurnStatus: CodexTurnStatus = 'inProgress';
  lastTurnId: string = '';
  tokenUsage: TurnTokenUsage | null = null;
  contextManagement: CodexContextManagementSnapshot = new CodexContextManagementSnapshot();
  modelAutoCompactTokenLimit: number | null = null;
  effectiveAutoCompactTokenLimit: number | null = null;
  autoCompactCurrentTotalTokens: number | null = null;
  autoCompactWillCheckBeforeNextTurn: boolean = false;
  autoCompactWouldWaitForFollowUp: boolean = false;
  autoCompactEnabled: boolean = false;
  remainingToAutoCompact: number | null = null;
  autoCompactNearThreshold: boolean = false;
  lastCompactionAtMs: number = 0;
  lastCompactionTurnId: string = '';
  updatedAt: string = '';
  /** AIGC provenance：turn 开始前的工作区快照（relPath → 轻量指纹），用于 turn 结束后对比找文件变化。 */
  aigcBaselineFiles: Map<string, string> = new Map<string, string>();

  constructor(localKey: string, title: string) {
    this.localKey = localKey;
    this.title = title;
    this.updatedAt = currentThreadTimestamp();
    this.changedFiles = NO_FILE_CHANGES_TEXT;
  }
}

function currentTimestamp(): string {
  return formatShortTimestamp(new Date());
}

function formatShortTimestamp(date: Date): string {
  const hours: string = date.getHours().toString().padStart(2, '0');
  const minutes: string = date.getMinutes().toString().padStart(2, '0');
  return `${hours}:${minutes}`;
}

function formatDetailedTimestamp(date: Date): string {
  const year: string = date.getFullYear().toString();
  const month: string = (date.getMonth() + 1).toString().padStart(2, '0');
  const day: string = date.getDate().toString().padStart(2, '0');
  const hours: string = date.getHours().toString().padStart(2, '0');
  const minutes: string = date.getMinutes().toString().padStart(2, '0');
  return `${year}年${month}月${day}日 ${hours}:${minutes}`;
}

function currentThreadTimestamp(): string {
  return formatDetailedTimestamp(new Date());
}

function safeJsonParse(rawText: string): Object | null {
  try {
    return JSON.parse(rawText) as Object;
  } catch (_err) {
    return null;
  }
}

function parseJsonText(rawText: string, fallbackValue: Object): Object {
  const parsed: Object | null = safeJsonParse(rawText);
  return parsed ?? fallbackValue;
}

export class CodexBackend {
  private initialized: boolean = false;
  /** 检测到 remote app-server 断开/连接丢失后置位，允许 ensureConnected 重新连接。 */
  private connectionLost: boolean = false;
  private connectionState: CodexConnectionState = 'disconnected';
  private connectionText: string = '未连接';
  private readonly listeners: Map<number, BackendListener> = new Map();
  private readonly threads: Map<string, CodexThreadRecord> = new Map();
  private readonly threadKeysByRemoteId: Map<string, string> = new Map();
  private readonly workspaceCatalog: Map<string, WorkspaceDescriptor> = new Map();
  private activeThreadId: string = '';
  private serverUrl: string = DEFAULT_SERVER_URL;
  private listenerSequence: number = 1;
  private pendingApproval: CodexApprovalRequest | null = null;
  private pendingRequestUserInput: CodexRequestUserInput | null = null;
  private authMode: CodexAuthMode = 'none';
  private requiresOpenAIAuth: boolean = true;
  private authStatusText: string = '未登录';
  private planTypeText: string = '';
  private collaborationModes: CollaborationModeOption[] = [];
  private readonly compactionState: CompactionRunState = new CompactionRunState();
  private mcpServersCache: McpServerRecord[] = [];
  private readonly mcpConfigByName: Map<string, Object> = new Map();
  private mcpStatusText: string = '尚未加载 MCP 状态';
  private mcpErrorText: string = '';
  private approvalTimerId: number = -1;
  private lastSnapshotMessagesSignature: string = '';
  private cachedSnapshotMessages: CodexChatMessage[] = [];
  private lastEventBatchSignature: string = '';

  private logInfo(message: string): void {
    hilog.info(BACKEND_LOG_DOMAIN, BACKEND_LOG_TAG, '%{public}s', message);
  }

  subscribe(listener: BackendListener): number {
    const subscriptionId: number = this.listenerSequence;
    this.listenerSequence += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  snapshot(): CodexBackendSnapshot {
    const activeThread: CodexThreadRecord | null = this.activeThreadRecord();
    const activeTokenUsage: TurnTokenUsage | null = activeThread?.tokenUsage ?? null;
    const activeContextManagement: CodexContextManagementSnapshot = activeThread !== null
      ? this.cloneContextManagement(activeThread.contextManagement)
      : new CodexContextManagementSnapshot();
    return new CodexBackendSnapshot(
      this.serverUrl,
      this.connectionState,
      this.connectionText,
      this.cloneApproval(this.pendingApproval),
      this.cloneRequestUserInput(this.pendingRequestUserInput),
      this.authMode,
      this.requiresOpenAIAuth,
      this.authStatusText,
      this.planTypeText,
      this.mcpStatusText,
      this.mcpServersCache.length,
      this.mcpErrorText,
      this.collaborationModes.map((mode: CollaborationModeOption) => this.cloneCollaborationMode(mode)),
      activeTokenUsage,
      activeThread?.remoteThreadId ?? '',
      this.compactionSnapshot(),
      activeContextManagement,
      activeThread?.modelAutoCompactTokenLimit ?? null,
      activeThread?.effectiveAutoCompactTokenLimit ?? null,
      activeThread?.autoCompactCurrentTotalTokens ?? null,
      activeThread?.autoCompactWillCheckBeforeNextTurn ?? false,
      activeThread?.autoCompactWouldWaitForFollowUp ?? false,
      activeThread?.autoCompactEnabled ?? false,
      activeThread?.remainingToAutoCompact ?? null,
      activeThread?.autoCompactNearThreshold ?? false
    );
  }

  sessionSummaries(): SessionSummary[] {
    const sessions: SessionSummary[] = [];
    this.threads.forEach((thread: CodexThreadRecord) => {
      const workspace: WorkspaceDescriptor = this.workspaceDescriptorForThread(thread);
      sessions.push(new SessionSummary(
        thread.localKey,
        thread.title,
        workspace.id,
        workspace.name,
        workspace.rootPath,
        workspace.permissionState,
        workspace.accessKind,
        thread.messages.length,
        thread.updatedAt,
        thread.summaryTitle,
        thread.lastTurnStatus,
        thread.changedFiles
      ));
    });
    return sessions.sort((left: SessionSummary, right: SessionSummary) => {
      if (left.lastUpdatedAt === right.lastUpdatedAt) {
        return left.title.localeCompare(right.title);
      }
      return left.lastUpdatedAt < right.lastUpdatedAt ? 1 : -1;
    });
  }

  usageSummary(): UsageSummary {
    let activeTurnCount: number = 0;
    let turnCount: number = 0;
    let messageCount: number = 0;
    let diffLineCount: number = 0;
    let diffUpdateCount: number = 0;
    let lastTurnStatus: string = '尚无会话';
    this.threads.forEach((thread: CodexThreadRecord) => {
      if (thread.activeTurn !== null) {
        activeTurnCount += 1;
      }
      turnCount += thread.turnCount;
      messageCount += thread.messages.length;
      diffLineCount += thread.diffLines.length;
      diffUpdateCount += thread.diffUpdateCount;
      lastTurnStatus = thread.lastTurnStatus;
    });
    return new UsageSummary(this.threads.size, activeTurnCount, turnCount, messageCount, diffLineCount, diffUpdateCount, lastTurnStatus);
  }

  fetchTokenUsageAggregate(): TokenUsageAggregate | null {
    const codexHome = AppStorage.get<string>('codexHome');
    if (codexHome === undefined) return null;
    return fetchNativeTokenUsageAggregate(codexHome);
  }

  resultForThreadKey(threadKey: string): CodexTurnResult | null {
    const trimmedThreadKey: string = threadKey.trim();
    let thread: CodexThreadRecord | undefined = this.threads.get(trimmedThreadKey);
    if (thread === undefined) {
      const localKey: string | undefined = this.threadKeysByRemoteId.get(trimmedThreadKey);
      if (localKey !== undefined) {
        thread = this.threads.get(localKey);
      }
    }
    if (thread === undefined) {
      return null;
    }
    return this.snapshotForThread(thread, thread.lastTurnStatus);
  }

  mcpServers(): McpServerRecord[] {
    return this.mcpServersCache.map((server: McpServerRecord) => this.cloneMcpServer(server));
  }

  mcpConfig(serverName: string): Object | null {
    return this.mcpConfigByName.get(serverName) ?? null;
  }

  configureServerUrl(serverUrl: string): void {
    const nextServerUrl: string = serverUrl.trim();
    this.serverUrl = nextServerUrl.length > 0 ? nextServerUrl : DEFAULT_SERVER_URL;
    this.notifyListeners();
  }

  async connect(): Promise<void> {
    if (this.initialized && !this.connectionLost) {
      return;
    }
    this.updateConnectionState('connecting', this.connectionLost ? '检测到断线，正在重连' : '正在初始化原生桥接');
    const initRequest: InitializeRequestPayload = new InitializeRequestPayload();
    const initResult: Object = parseJsonText(await initializeAsyncNative(JSON.stringify(initRequest)), new Object() as Object);
    const initRecord: Record<string, Object> = initResult as Record<string, Object>;
    const ok: boolean = initRecord['ok'] === true;
    if (!ok) {
      const errorText: string = typeof initRecord['error'] === 'string'
        ? (initRecord['error'] as string)
        : 'initialize failed';
      this.updateConnectionState('error', `连接失败: ${errorText}`);
      throw new Error(`initialize failed: ${errorText}`);
    }
    this.initialized = true;
    this.connectionLost = false;
    await this.refreshCollaborationModes();
    await this.refreshAccountState();
    const platformOs: string = typeof initRecord['platformOs'] === 'string'
      ? (initRecord['platformOs'] as string)
      : 'ohos';
    this.updateConnectionState('connected', `已连接 · ${platformOs}`);
    this.ensureApprovalPolling();
  }

  async disconnect(): Promise<void> {
    this.initialized = false;
    this.connectionLost = false;
    this.stopApprovalPolling();
    this.pendingApproval = null;
    this.pendingRequestUserInput = null;
    this.updateConnectionState('disconnected', '已断开连接');
  }

  async loginWithApiKey(apiKey: string): Promise<void> {
    const trimmedApiKey: string = apiKey.trim();
    if (trimmedApiKey.length === 0) {
      throw new Error('请输入有效的 OpenAI API Key。');
    }
    await this.ensureConnected();
    const loginRequest: AccountLoginRequestPayload = new AccountLoginRequestPayload();
    loginRequest.apiKey = trimmedApiKey;
    accountLoginNative(JSON.stringify(loginRequest));
    await this.refreshAccountState();
  }

  async approvePendingRequest(): Promise<void> {
    if (this.pendingApproval === null) {
      return;
    }
    const request: CodexApprovalRequest = this.pendingApproval;
    this.pendingApproval = null;
    const approveRequest: ApprovalActionRequestPayload = new ApprovalActionRequestPayload();
    approveRequest.requestId = request.requestId;
    approveRequest.threadId = request.threadId;
    approveRequest.turnId = request.turnId;
    approveRequest.itemId = request.itemId;
    approveRequest.kind = request.kind;
    // AIGC provenance：收集被批准的命令（仅 kind === 'command'）
    aigcProvenanceStore.collectApproval(request.threadId, request.turnId, request.kind, request.detail);
    approvalApproveNative(JSON.stringify(approveRequest));
    this.notifyListeners();
  }

  async submitPendingUserInput(answers: Record<string, string[]>): Promise<void> {
    if (this.pendingRequestUserInput === null) {
      return;
    }
    const request: CodexRequestUserInput = this.pendingRequestUserInput;
    this.pendingRequestUserInput = null;
    const approveRequest: ApprovalActionRequestPayload = new ApprovalActionRequestPayload();
    approveRequest.requestId = request.requestId;
    approveRequest.threadId = request.threadId;
    approveRequest.turnId = request.turnId;
    approveRequest.itemId = request.itemId;
    approveRequest.kind = 'requestUserInput';
    Object.keys(answers).forEach((questionId: string) => {
      const values: string[] = answers[questionId]
        .map((value: string) => value.trim())
        .filter((value: string) => value.length > 0);
      const answerPayload: RequestUserInputAnswerPayload = new RequestUserInputAnswerPayload();
      answerPayload.answers = values;
      approveRequest.answers[questionId] = answerPayload;
    });
    approvalApproveNative(JSON.stringify(approveRequest));
    this.notifyListeners();
  }

  async declinePendingRequest(): Promise<void> {
    if (this.pendingApproval === null) {
      return;
    }
    const request: CodexApprovalRequest = this.pendingApproval;
    this.pendingApproval = null;
    const declineRequest: ApprovalActionRequestPayload = new ApprovalActionRequestPayload();
    declineRequest.requestId = request.requestId;
    declineRequest.threadId = request.threadId;
    declineRequest.turnId = request.turnId;
    declineRequest.itemId = request.itemId;
    declineRequest.kind = request.kind;
    approvalDeclineNative(JSON.stringify(declineRequest));
    this.notifyListeners();
  }

  async declinePendingUserInput(): Promise<void> {
    if (this.pendingRequestUserInput === null) {
      return;
    }
    const request: CodexRequestUserInput = this.pendingRequestUserInput;
    this.pendingRequestUserInput = null;
    const declineRequest: ApprovalActionRequestPayload = new ApprovalActionRequestPayload();
    declineRequest.requestId = request.requestId;
    declineRequest.threadId = request.threadId;
    declineRequest.turnId = request.turnId;
    declineRequest.itemId = request.itemId;
    declineRequest.kind = 'requestUserInput';
    approvalDeclineNative(JSON.stringify(declineRequest));
    this.notifyListeners();
  }

  async loadPersistedSessions(): Promise<SessionSummary[]> {
    await this.ensureConnected();
    const listRequest: ThreadListRequestPayload = new ThreadListRequestPayload();
    const payload: Record<string, Object> = parseJsonText(
      await threadListAsyncNative(JSON.stringify(listRequest)),
      new ThreadListResponsePayload() as Object
    ) as Record<string, Object>;
    const data: Object[] = Array.isArray(payload['data']) ? (payload['data'] as Object[]) : [];
    for (let index: number = 0; index < data.length; index += 1) {
      this.upsertThreadFromListPayload(data[index] as Record<string, Object>);
    }
    return this.sessionSummaries();
  }

  async loadThreadHistory(threadId: string): Promise<CodexTurnResult> {
    const snapshot: ThreadReadSnapshotPayload = await this.readThreadSnapshot(threadId);
    if (snapshot.thread.tokenUsage === null) {
      await this.hydrateThreadTokenUsage(snapshot.thread, snapshot.lastTurnId);
    }
    this.activeThreadId = snapshot.thread.remoteThreadId;
    this.notifyListeners();
    return this.snapshotForThread(snapshot.thread, snapshot.thread.lastTurnStatus, snapshot.lastTurnId);
  }

  async createThreadSession(
    title: string,
    workspaceId: string,
    workspaceRoot: string,
    workspacePermissionState: WorkspacePermissionState,
    workspaceAccessKind: WorkspaceAccessKind,
    writableRoots: string[],
    model: string
  ): Promise<SessionSummary> {
    await this.ensureConnected();
    const threadStartRequest: ThreadStartRequestPayload = new ThreadStartRequestPayload();
    const trimmedWorkspaceRoot: string = workspaceRoot.trim();
    threadStartRequest.cwd = trimmedWorkspaceRoot.length > 0 ? trimmedWorkspaceRoot : undefined;
    threadStartRequest.model = model !== 'default' ? model : undefined;
    const payload: ThreadStartResultPayload = parseJsonText(
      await threadStartAsyncNative(JSON.stringify(threadStartRequest)),
      new ThreadStartResultPayload()
    ) as ThreadStartResultPayload;
    const remoteThreadId: string = payload.thread?.id ?? '';
    if (remoteThreadId.trim().length === 0) {
      const message: string = payload.error?.message?.trim() ?? 'thread/start did not return a valid thread id.';
      throw new Error(`threadStart failed: ${message}`);
    }
    if (title.trim().length > 0) {
      const renameRequest: ThreadNameSetRequestPayload = new ThreadNameSetRequestPayload();
      renameRequest.threadId = remoteThreadId;
      renameRequest.name = title.trim();
      const renamePayload: Record<string, Object> = parseJsonText(
        await threadNameSetAsyncNative(JSON.stringify(renameRequest)),
        new Object() as Object
      ) as Record<string, Object>;
      if (renamePayload['ok'] === false) {
        const errorRecord: Record<string, Object> | undefined = renamePayload['error'] as Record<string, Object> | undefined;
        const errorMessage: string = typeof errorRecord?.['message'] === 'string' ? (errorRecord!['message'] as string) : '';
        if (errorMessage.trim().length > 0) {
          this.logInfo(`threadNameSet failed thread=${remoteThreadId} error=${errorMessage}`);
        }
      }
    }

    const thread: CodexThreadRecord = new CodexThreadRecord(remoteThreadId, title.trim().length > 0 ? title.trim() : '新会话');
    thread.remoteThreadId = remoteThreadId;
    thread.loaded = true;
    this.bindWorkspaceForSession(
      thread,
      thread.title,
      workspaceId.trim().length > 0 ? workspaceId : remoteThreadId,
      trimmedWorkspaceRoot,
      workspacePermissionState,
      workspaceAccessKind,
      writableRoots
    );
    thread.updatedAt = currentThreadTimestamp();
    this.threads.set(remoteThreadId, thread);
    this.threadKeysByRemoteId.set(remoteThreadId, remoteThreadId);
    return this.sessionSummaries().find((item: SessionSummary) => item.sessionId === remoteThreadId)
      ?? new SessionSummary(
        remoteThreadId,
        thread.title,
        thread.workspaceId,
        thread.workspaceName,
        thread.cwd,
        thread.workspacePermissionState,
        thread.workspaceAccessKind,
        thread.messages.length,
        thread.updatedAt,
        thread.summaryTitle,
        thread.lastTurnStatus,
        thread.changedFiles
      );
  }

  async renameSession(threadId: string, title: string): Promise<void> {
    await this.ensureConnected();
    const trimmedThreadId: string = threadId.trim();
    const trimmedTitle: string = title.trim();
    if (trimmedThreadId.length === 0 || trimmedTitle.length === 0) {
      return;
    }
    const renameRequest: ThreadNameSetRequestPayload = new ThreadNameSetRequestPayload();
    renameRequest.threadId = trimmedThreadId;
    renameRequest.name = trimmedTitle;
    const payload: Record<string, Object> = parseJsonText(
      await threadNameSetAsyncNative(JSON.stringify(renameRequest)),
      new Object() as Object
    ) as Record<string, Object>;
    if (payload['ok'] === false) {
      const errorRecord: Record<string, Object> | undefined = payload['error'] as Record<string, Object> | undefined;
      const errorMessage: string = typeof errorRecord?.['message'] === 'string' ? (errorRecord!['message'] as string) : '';
      throw new Error(errorMessage.trim().length > 0 ? errorMessage : 'thread/name/set failed');
    }
    const thread: CodexThreadRecord | undefined = this.threads.get(trimmedThreadId);
    if (thread !== undefined) {
      thread.title = trimmedTitle;
      if (thread.workspaceId.length > 0) {
        const descriptor: WorkspaceDescriptor | undefined = this.workspaceCatalog.get(thread.workspaceId);
        if (descriptor !== undefined) {
          descriptor.name = trimmedTitle;
          descriptor.lastCheckedAt = Date.now();
          this.workspaceCatalog.set(thread.workspaceId, descriptor);
        }
      }
    }
  }

  async archiveSession(threadId: string): Promise<void> {
    await this.ensureConnected();
    const trimmedThreadId: string = threadId.trim();
    if (trimmedThreadId.length === 0) {
      return;
    }
    const archiveRequest: ThreadArchiveRequestPayload = new ThreadArchiveRequestPayload();
    archiveRequest.threadId = trimmedThreadId;
    const payload: Record<string, Object> = parseJsonText(
      await threadArchiveAsyncNative(JSON.stringify(archiveRequest)),
      new Object() as Object
    ) as Record<string, Object>;
    if (payload['ok'] === false) {
      const errorRecord: Record<string, Object> | undefined = payload['error'] as Record<string, Object> | undefined;
      const errorMessage: string = typeof errorRecord?.['message'] === 'string' ? (errorRecord!['message'] as string) : '';
      throw new Error(errorMessage.trim().length > 0 ? errorMessage : 'thread/archive failed');
    }
    this.threads.delete(trimmedThreadId);
    this.threadKeysByRemoteId.delete(trimmedThreadId);
    if (this.activeThreadId === trimmedThreadId) {
      this.activeThreadId = '';
    }
    if (this.compactionState.threadId === trimmedThreadId) {
      this.clearCompactionState();
    }
  }

  async startTurn(request: CodexTurnRequest, onUpdate?: CodexTurnUpdateHandler): Promise<CodexTurnResult> {
    await this.ensureConnected();
    if (this.requiresOpenAIAuth && this.authMode === 'none') {
      throw new Error('当前后端尚未登录 OpenAI。请先填写 API Key 并登录。');
    }
    const thread: CodexThreadRecord = await this.ensureRemoteThread(request);
    this.activeThreadId = thread.remoteThreadId;
    await this.compactThreadBeforeTurnIfNeeded(thread);
    const startingTotalTokens: number = thread.tokenUsage?.total.totalTokens ?? -1;
    const pendingTurn: PendingTurnState = new PendingTurnState(request.threadKey, onUpdate, startingTotalTokens);
    thread.activeTurn = pendingTurn;
    const workspace: WorkspaceDescriptor = this.bindWorkspaceToThread(thread, request);

    const startedSnapshot: CodexTurnResult = this.beginLocalTurn(thread, request.prompt);
    this.emitTurnUpdate(thread, pendingTurn, startedSnapshot);

    const turnRequest: TurnStartRequestPayload = new TurnStartRequestPayload();
    turnRequest.threadId = thread.remoteThreadId;
    const inputItem: TurnInputItemPayload = new TurnInputItemPayload();
    inputItem.text = request.prompt;
    turnRequest.input = [inputItem];
    turnRequest.cwd = workspace.rootPath.trim().length > 0 ? workspace.rootPath.trim() : undefined;
    turnRequest.model = request.model !== 'default' ? request.model : undefined;
    turnRequest.effort = request.reasoningEffort !== 'default' ? request.reasoningEffort : undefined;
    turnRequest.collaborationMode = this.buildCollaborationModePayload(request.collaborationMode, turnRequest.model, turnRequest.effort);
    this.logInfo(`turnStart collaborationMode=${turnRequest.collaborationMode !== undefined ? JSON.stringify(turnRequest.collaborationMode) : 'undefined'}`);
    const turnResult: Object = parseJsonText(await turnStartAsyncNative(JSON.stringify(turnRequest)), new Object() as Object);

    const turnPayload: Record<string, Object> = ((turnResult as Record<string, Object>)['turn'] as Record<string, Object> | undefined) ?? {};
    pendingTurn.turnId = typeof turnPayload['id'] === 'string' ? (turnPayload['id'] as string) : '';
    const rawStatus: string = typeof turnPayload['status'] === 'string' ? (turnPayload['status'] as string) : 'unknown';
    const errorPayload: Record<string, Object> = (turnPayload['error'] as Record<string, Object> | undefined) ?? {};
    const errorMessage: string = typeof errorPayload['message'] === 'string' ? (errorPayload['message'] as string) : '';
    this.logInfo(`turnStart thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} rawStatus=${rawStatus} error=${errorMessage}`);
    if (rawStatus === 'failed' || pendingTurn.turnId.trim().length === 0) {
      thread.activeTurn = null;
      thread.lastTurnStatus = 'failed';
      thread.updatedAt = currentThreadTimestamp();
      thread.summaryTitle = '本轮失败';
      thread.summaryPoints = [errorMessage.trim().length > 0 ? errorMessage : 'turn/start 未返回有效的 turnId。'];
      const failedSnapshot: CodexTurnResult = this.snapshotForThread(thread, 'failed');
      this.emitTurnUpdate(thread, pendingTurn, failedSnapshot);
      pendingTurn.resolveCompletion(failedSnapshot);
      // 断线检测：若 turnStart 因连接丢失失败，触发自动重连供下次操作使用。
      if (this.markConnectionLostIfError(errorMessage)) {
        this.reconnectInBackground();
      }
      return failedSnapshot;
    }

    const result: CodexTurnResult = await this.pollTurnUntilCompleted(thread, pendingTurn);
    return result;
  }

  interruptTurn(): void {
    let activeThread: CodexThreadRecord | null = null;
    this.threads.forEach((thread: CodexThreadRecord) => {
      if (thread.activeTurn !== null && activeThread === null) {
        activeThread = thread;
      }
    });
    if (activeThread === null) {
      return;
    }
    this.interruptThread(activeThread);
  }

  interruptTurnForThreadKey(threadKey: string): void {
    const trimmedThreadKey: string = threadKey.trim();
    if (trimmedThreadKey.length === 0) {
      return;
    }
    let thread: CodexThreadRecord | undefined = this.threads.get(trimmedThreadKey);
    if (thread === undefined) {
      const localKey: string | undefined = this.threadKeysByRemoteId.get(trimmedThreadKey);
      if (localKey !== undefined) {
        thread = this.threads.get(localKey);
      }
    }
    if (thread === undefined) {
      const normalizedThreadId: string = this.normalizeThreadId(trimmedThreadKey);
      if (normalizedThreadId.length > 0) {
        thread = this.threads.get(normalizedThreadId);
      }
    }
    if (thread === undefined || thread.activeTurn === null) {
      return;
    }
    this.interruptThread(thread);
  }

  private interruptThread(thread: CodexThreadRecord): void {
    const activeTurn: PendingTurnState | null = thread.activeTurn;
    if (activeTurn === null) {
      return;
    }
    activeTurn.cancelled = true;
    turnInterruptNative(thread.remoteThreadId, activeTurn.turnId);
  }

  setActiveThread(threadId: string): void {
    const normalizedThreadId: string = this.normalizeThreadId(threadId);
    const changed: boolean = this.activeThreadId !== normalizedThreadId;
    this.activeThreadId = normalizedThreadId;
    if (!changed) {
      return;
    }
    this.notifyListeners();
    void this.refreshActiveThreadSnapshot(normalizedThreadId);
  }

  private lastCompactError: string = '';

  async compactThread(threadId: string, timeoutMs: number = COMPACTION_TIMEOUT_MS): Promise<void> {
    this.lastCompactError = '';
    const normalizedThreadId: string = this.normalizeThreadId(threadId);
    if (normalizedThreadId.length === 0) {
      const message: string = '当前会话还没有远端线程';
      this.failCompaction(message, threadId);
      throw new Error(message);
    }
    const thread: CodexThreadRecord | undefined = this.threads.get(normalizedThreadId);
    if (thread === undefined || thread.remoteThreadId.trim().length === 0) {
      const message: string = '没有可用的线程';
      this.failCompaction(message, normalizedThreadId);
      throw new Error(message);
    }
    if (thread.activeTurn !== null) {
      const message: string = '当前 turn 尚未结束，暂不允许压缩。';
      this.failCompaction(message, thread.remoteThreadId);
      throw new Error(message);
    }
    if ((this.compactionState.status === 'starting' || this.compactionState.status === 'running') &&
        this.compactionState.threadId !== thread.remoteThreadId) {
      const message: string = '已有其他会话正在压缩，请等待完成后再试。';
      throw new Error(message);
    }
    try {
      await this.resumeThread(thread);
      this.activeThreadId = thread.remoteThreadId;
      const baseline: ThreadReadSnapshotPayload = await this.readThreadSnapshot(thread.remoteThreadId);
      if (thread.tokenUsage === null) {
        await this.hydrateThreadTokenUsage(thread, baseline.lastTurnId);
      }
      const oldTotalTokens: number = thread.tokenUsage?.total.totalTokens ?? 0;
      const resp = parseJsonText(
        compactStartNative(JSON.stringify({ threadId: thread.remoteThreadId })),
        new Object() as Object
      ) as Record<string, Object>;
      const ok = resp['ok'] === true;
      if (!ok) {
        const err = resp['error'] as Record<string, Object> | undefined;
        const msg = typeof err?.['message'] === 'string' ? (err!['message'] as string) : 'compact 失败';
        this.failCompaction(msg, thread.remoteThreadId);
        this.logInfo(`compact failed: threadId=${thread.remoteThreadId} error=${msg}`);
        if (this.markConnectionLostIfError(msg)) {
          this.reconnectInBackground();
        }
        throw new Error(msg);
      }
      thread.lastCompactionAtMs = Date.now();
      this.compactionState.threadId = thread.remoteThreadId;
      this.compactionState.baselineTurnId = baseline.lastTurnId;
      this.compactionState.turnId = '';
      this.compactionState.oldTotalTokens = oldTotalTokens;
      this.compactionState.newTotalTokens = 0;
      this.compactionState.status = 'starting';
      this.compactionState.errorMessage = '';
      this.compactionState.savedTokens = 0;
      this.compactionState.observedReduction = false;
      this.notifyListeners();
      this.logInfo(`compact triggered: threadId=${thread.remoteThreadId}`);
      await this.pollCompactionUntilCompleted(thread, baseline.lastTurnId, timeoutMs);
    } catch (err) {
      const message: string = err instanceof Error ? err.message : JSON.stringify(err);
      if (this.compactionState.status !== 'failed' && this.compactionState.status !== 'timeout') {
        this.failCompaction(message, thread.remoteThreadId);
      }
      if (err instanceof Error) {
        throw err;
      }
      throw new Error(message);
    }
  }

  getLastCompactError(): string {
    return this.lastCompactError;
  }

  private async compactThreadBeforeTurnIfNeeded(thread: CodexThreadRecord): Promise<void> {
    if (thread.tokenUsage === null) {
      return;
    }
    this.applyAutoCompactDerivedState(thread);
    if (!thread.autoCompactEnabled || thread.remainingToAutoCompact !== 0) {
      return;
    }
    if (thread.remoteThreadId.trim().length === 0 || thread.activeTurn !== null) {
      return;
    }
    if (this.compactionState.status === 'starting' || this.compactionState.status === 'running') {
      return;
    }
    await this.compactThread(thread.remoteThreadId);
  }

  clearCompactionNotice(threadId: string): void {
    const normalizedThreadId: string = this.normalizeThreadId(threadId);
    if (normalizedThreadId.length === 0 || this.compactionState.threadId !== normalizedThreadId) {
      return;
    }
    this.clearCompactionState();
    this.notifyListeners();
  }

  private activeThreadRecord(): CodexThreadRecord | null {
    if (this.activeThreadId.trim().length === 0) {
      return null;
    }
    return this.threads.get(this.activeThreadId) ?? null;
  }

  private normalizeThreadId(threadId: string): string {
    const trimmedThreadId: string = threadId.trim();
    if (trimmedThreadId.length === 0 || trimmedThreadId.startsWith('session:')) {
      return '';
    }
    const direct: CodexThreadRecord | undefined = this.threads.get(trimmedThreadId);
    if (direct !== undefined && direct.remoteThreadId.trim().length > 0) {
      return direct.remoteThreadId;
    }
    const localKey: string | undefined = this.threadKeysByRemoteId.get(trimmedThreadId);
    if (localKey !== undefined) {
      const mapped: CodexThreadRecord | undefined = this.threads.get(localKey);
      if (mapped !== undefined && mapped.remoteThreadId.trim().length > 0) {
        return mapped.remoteThreadId;
      }
    }
    return trimmedThreadId;
  }

  private compactionSnapshot(): CodexCompactionSnapshot {
    return new CodexCompactionSnapshot(
      this.compactionState.threadId,
      this.compactionState.status,
      this.compactionState.errorMessage,
      this.compactionState.savedTokens,
      this.compactionState.oldTotalTokens,
      this.compactionState.newTotalTokens
    );
  }

  private clearCompactionState(): void {
    this.compactionState.threadId = '';
    this.compactionState.baselineTurnId = '';
    this.compactionState.turnId = '';
    this.compactionState.oldTotalTokens = 0;
    this.compactionState.newTotalTokens = 0;
    this.compactionState.status = 'idle';
    this.compactionState.errorMessage = '';
    this.compactionState.savedTokens = 0;
    this.compactionState.observedReduction = false;
  }

  private failCompaction(message: string, threadId: string, status: CodexCompactionStatus = 'failed'): void {
    const normalizedThreadId: string = this.normalizeThreadId(threadId);
    if (this.compactionState.observedReduction && normalizedThreadId === this.compactionState.threadId) {
      const thread: CodexThreadRecord | undefined = this.threads.get(normalizedThreadId);
      if (thread !== undefined) {
        this.completeCompaction(thread);
        return;
      }
    }
    this.lastCompactError = message;
    this.compactionState.threadId = normalizedThreadId;
    this.compactionState.status = status;
    this.compactionState.errorMessage = message;
    if (!this.compactionState.observedReduction) {
      this.compactionState.newTotalTokens = 0;
      this.compactionState.savedTokens = 0;
    }
    this.notifyListeners();
  }

  private completeCompaction(thread: CodexThreadRecord): void {
    this.updateCompactionTokenDelta(thread);
    const observedTotal: number = thread.tokenUsage?.total.totalTokens ?? 0;
    const newTotal: number = this.compactionState.newTotalTokens > 0
      ? this.compactionState.newTotalTokens
      : (observedTotal > 0 ? observedTotal : this.compactionState.oldTotalTokens);
    const saved: number = this.compactionState.oldTotalTokens - newTotal;
    this.compactionState.threadId = thread.remoteThreadId;
    this.compactionState.status = 'completed';
    this.compactionState.errorMessage = '';
    this.compactionState.newTotalTokens = newTotal;
    this.compactionState.savedTokens = saved > 0 ? saved : 0;
    this.lastCompactError = '';
    this.notifyListeners();
  }

  private resolveCompactionFailureMessage(result: CodexTurnResult): string {
    for (let index: number = 0; index < result.summaryPoints.length; index += 1) {
      const candidate: string = result.summaryPoints[index].trim();
      if (candidate.length === 0) {
        continue;
      }
      const normalized: string = candidate.replace(/[。.!！]+$/u, '');
      if (GENERIC_RUNNING_SUMMARY_TEXTS.indexOf(normalized) >= 0) {
        continue;
      }
      return candidate;
    }
    return '压缩失败';
  }

  private async readThreadSnapshot(threadId: string): Promise<ThreadReadSnapshotPayload> {
    await this.ensureConnected();
    const trimmedThreadId: string = threadId.trim();
    if (trimmedThreadId.length === 0) {
      throw new Error('thread/read requires a valid thread id.');
    }
    const readRequest: ThreadReadRequestPayload = new ThreadReadRequestPayload();
    readRequest.threadId = trimmedThreadId;
    readRequest.includeTurns = true;
    const payload: Record<string, Object> = parseJsonText(
      await threadReadAsyncNative(JSON.stringify(readRequest)),
      new Object() as Object
    ) as Record<string, Object>;
    const errorRecord: Record<string, Object> | undefined = payload['error'] as Record<string, Object> | undefined;
    const errorMessage: string = typeof errorRecord?.['message'] === 'string' ? (errorRecord!['message'] as string) : '';
    if (errorMessage.trim().length > 0) {
      throw new Error(errorMessage);
    }
    const thread: CodexThreadRecord = this.ensureThreadRecordFromReadPayload(trimmedThreadId, payload);
    const lastTurnId: string = typeof payload['lastTurnId'] === 'string' ? (payload['lastTurnId'] as string) : '';
    const lastTurnStatus: string = typeof payload['lastTurnStatus'] === 'string' ? (payload['lastTurnStatus'] as string) : 'completed';
    return new ThreadReadSnapshotPayload(thread, lastTurnId, lastTurnStatus);
  }

  private async refreshActiveThreadSnapshot(threadId: string): Promise<void> {
    const trimmedThreadId: string = threadId.trim();
    if (trimmedThreadId.length === 0) {
      return;
    }
    try {
      const snapshot: ThreadReadSnapshotPayload = await this.readThreadSnapshot(trimmedThreadId);
      if (this.activeThreadId !== trimmedThreadId) {
        return;
      }
      if (snapshot.thread.tokenUsage === null) {
        await this.hydrateThreadTokenUsage(snapshot.thread, snapshot.lastTurnId);
      }
      if (this.activeThreadId !== trimmedThreadId) {
        return;
      }
      this.notifyListeners();
    } catch (err) {
      const errorText: string = err instanceof Error ? err.message : JSON.stringify(err);
      this.logInfo(`refreshActiveThreadSnapshot failed thread=${trimmedThreadId} error=${errorText}`);
    }
  }

  private async hydrateThreadTokenUsage(thread: CodexThreadRecord, turnId: string): Promise<void> {
    const trimmedTurnId: string = turnId.trim();
    if (thread.remoteThreadId.trim().length === 0 || trimmedTurnId.length === 0) {
      return;
    }
    try {
      const payload: Record<string, Object> = parseJsonText(
        await turnPollAsyncNative(thread.remoteThreadId, trimmedTurnId),
        new TurnPollResponsePayload() as Object
      ) as Record<string, Object>;
      this.applyTokenUsagePayload(thread, payload['tokenUsage']);
      this.applyContextManagementPayload(thread, payload['contextManagement']);
      this.applyAutoCompactConfigPayload(thread, payload);
    } catch (err) {
      const errorText: string = err instanceof Error ? err.message : JSON.stringify(err);
      this.logInfo(`hydrateThreadTokenUsage failed thread=${thread.remoteThreadId} turnId=${trimmedTurnId} error=${errorText}`);
    }
  }

  private applyTokenUsagePayload(thread: CodexThreadRecord, tokenUsageRaw: Object | undefined): void {
    if (tokenUsageRaw === undefined || tokenUsageRaw === null) {
      return;
    }
    const tu = tokenUsageRaw as Record<string, Object>;
    const parseBreakdown = (raw: Object): TokenUsageBreakdown => {
      const b = raw as Record<string, Object>;
      return new TokenUsageBreakdown(
        typeof b['inputTokens'] === 'number' ? (b['inputTokens'] as number) : 0,
        typeof b['outputTokens'] === 'number' ? (b['outputTokens'] as number) : 0,
        typeof b['cachedInputTokens'] === 'number' ? (b['cachedInputTokens'] as number) : 0,
        typeof b['reasoningOutputTokens'] === 'number' ? (b['reasoningOutputTokens'] as number) : 0,
        typeof b['totalTokens'] === 'number' ? (b['totalTokens'] as number) : 0,
        typeof b['blendedTotal'] === 'number' ? (b['blendedTotal'] as number) : undefined
      );
    };
    const total = tu['total'] !== undefined ? parseBreakdown(tu['total'] as Object) : new TokenUsageBreakdown(0, 0, 0, 0, 0);
    const last = tu['last'] !== undefined ? parseBreakdown(tu['last'] as Object) : new TokenUsageBreakdown(0, 0, 0, 0, 0);
    const ctxWindow = typeof tu['modelContextWindow'] === 'number' ? (tu['modelContextWindow'] as number) : 0;
    const ctxRemainingPct = typeof tu['contextRemainingPercent'] === 'number' ? (tu['contextRemainingPercent'] as number) : -1;
    thread.tokenUsage = new TurnTokenUsage(total, last, ctxWindow, ctxRemainingPct);
    this.applyAutoCompactDerivedState(thread);
    this.updateCompactionTokenDelta(thread);
  }

  private applyContextManagementPayload(thread: CodexThreadRecord, contextManagementRaw: Object | undefined): void {
    if (contextManagementRaw === undefined || contextManagementRaw === null) {
      return;
    }
    const raw = contextManagementRaw as Record<string, Object>;
    thread.contextManagement = new CodexContextManagementSnapshot(
      typeof raw['memoryMode'] === 'string' ? (raw['memoryMode'] as string) : null,
      Array.isArray(raw['recentArtifactRefs'])
        ? (raw['recentArtifactRefs'] as Object[]).map(
            (item: Object) => typeof item === 'string' ? (item as string) : JSON.stringify(item)
          )
        : null,
      typeof raw['memoryUsageCount'] === 'number' ? (raw['memoryUsageCount'] as number) : null,
      typeof raw['memoryLastUsageAt'] === 'number' ? (raw['memoryLastUsageAt'] as number) : null,
      typeof raw['memoryStage1GeneratedAt'] === 'number' ? (raw['memoryStage1GeneratedAt'] as number) : null,
      typeof raw['memoryStage1UpToDate'] === 'boolean' ? (raw['memoryStage1UpToDate'] as boolean) : null,
      typeof raw['memoryStage1JobStatus'] === 'string' ? (raw['memoryStage1JobStatus'] as string) : null,
      typeof raw['memoryStage1RetryAt'] === 'number' ? (raw['memoryStage1RetryAt'] as number) : null,
      typeof raw['memoryStage1RetryRemaining'] === 'number' ? (raw['memoryStage1RetryRemaining'] as number) : null,
      typeof raw['memoryForgettingPending'] === 'boolean' ? (raw['memoryForgettingPending'] as boolean) : null,
      typeof raw['memoryForgettingCompletedAt'] === 'number' ? (raw['memoryForgettingCompletedAt'] as number) : null,
      typeof raw['memoryPhase2SelectedAt'] === 'number' ? (raw['memoryPhase2SelectedAt'] as number) : null,
      typeof raw['memoryPhase2UpdatedAt'] === 'number' ? (raw['memoryPhase2UpdatedAt'] as number) : null,
      typeof raw['memoryPhase2SelectionCount'] === 'number' ? (raw['memoryPhase2SelectionCount'] as number) : null,
      typeof raw['memoryPhase2AddedCount'] === 'number' ? (raw['memoryPhase2AddedCount'] as number) : null,
      typeof raw['memoryPhase2RetainedCount'] === 'number' ? (raw['memoryPhase2RetainedCount'] as number) : null,
      typeof raw['memoryPhase2RemovedCount'] === 'number' ? (raw['memoryPhase2RemovedCount'] as number) : null,
      typeof raw['memorySummaryUpdatedAt'] === 'number' ? (raw['memorySummaryUpdatedAt'] as number) : null,
      typeof raw['memorySummaryPreview'] === 'string' ? (raw['memorySummaryPreview'] as string) : null,
      typeof raw['lastMicroCompactionAt'] === 'number' ? (raw['lastMicroCompactionAt'] as number) : null,
      typeof raw['lastMicroCompactionItemCount'] === 'number' ? (raw['lastMicroCompactionItemCount'] as number) : null,
      typeof raw['lastMicroCompactionSavedTokens'] === 'number' ? (raw['lastMicroCompactionSavedTokens'] as number) : null,
      typeof raw['compactionFailureCount'] === 'number' ? (raw['compactionFailureCount'] as number) : null,
      typeof raw['compactionCircuitOpen'] === 'boolean' ? (raw['compactionCircuitOpen'] as boolean) : null,
      typeof raw['lastFullCompactionTrigger'] === 'string' ? (raw['lastFullCompactionTrigger'] as string) : null,
      typeof raw['lastFullCompactionProviderMode'] === 'string'
        ? (raw['lastFullCompactionProviderMode'] as string)
        : null,
      typeof raw['lastFullCompactionTrimmedItemCount'] === 'number'
        ? (raw['lastFullCompactionTrimmedItemCount'] as number)
        : null,
      typeof raw['lastFullCompactionReferenceContextReestablished'] === 'boolean'
        ? (raw['lastFullCompactionReferenceContextReestablished'] as boolean)
        : null,
      typeof raw['lastContextCompactionAt'] === 'number'
        ? (raw['lastContextCompactionAt'] as number)
        : null
    );
  }

  private applyAutoCompactConfigPayload(thread: CodexThreadRecord, payload: Record<string, Object>): void {
    const rawLimit: Object | undefined = payload['modelAutoCompactTokenLimit'];
    if (typeof rawLimit === 'number' && rawLimit === rawLimit) {
      thread.modelAutoCompactTokenLimit = rawLimit > 0 ? rawLimit : null;
    } else {
      thread.modelAutoCompactTokenLimit = null;
    }
    const rawEffectiveLimit: Object | undefined = payload['effectiveAutoCompactTokenLimit'];
    if (typeof rawEffectiveLimit === 'number' && rawEffectiveLimit === rawEffectiveLimit) {
      thread.effectiveAutoCompactTokenLimit = rawEffectiveLimit > 0 ? rawEffectiveLimit : null;
    } else {
      thread.effectiveAutoCompactTokenLimit = null;
    }
    const rawExplanation: Object | undefined = payload['autoCompactExplanation'];
    if (rawExplanation !== undefined && rawExplanation !== null && typeof rawExplanation === 'object') {
      const explanation = rawExplanation as Record<string, Object>;
      const rawCurrentTotal = explanation['autoCompactCurrentTotalTokens'];
      thread.autoCompactCurrentTotalTokens = typeof rawCurrentTotal === 'number' && rawCurrentTotal === rawCurrentTotal
        ? rawCurrentTotal
        : null;
      thread.autoCompactWillCheckBeforeNextTurn = explanation['autoCompactWillCheckBeforeNextTurn'] === true;
      thread.autoCompactWouldWaitForFollowUp = explanation['autoCompactWouldWaitForFollowUp'] === true;
    } else {
      thread.autoCompactCurrentTotalTokens = null;
      thread.autoCompactWillCheckBeforeNextTurn = false;
      thread.autoCompactWouldWaitForFollowUp = false;
    }
    this.applyAutoCompactDerivedState(thread);
  }

  private applyAutoCompactDerivedState(thread: CodexThreadRecord): void {
    const limit = thread.effectiveAutoCompactTokenLimit ?? thread.modelAutoCompactTokenLimit;
    if (typeof limit !== 'number' || limit !== limit || limit <= 0) {
      thread.effectiveAutoCompactTokenLimit = null;
      thread.modelAutoCompactTokenLimit = null;
      thread.autoCompactCurrentTotalTokens = null;
      thread.autoCompactWillCheckBeforeNextTurn = false;
      thread.autoCompactWouldWaitForFollowUp = false;
      thread.autoCompactEnabled = false;
      thread.remainingToAutoCompact = null;
      thread.autoCompactNearThreshold = false;
      return;
    }
    thread.autoCompactEnabled = true;
    const used = thread.tokenUsage?.total.totalTokens ?? 0;
    if (typeof used !== 'number' || used !== used || used <= 0) {
      thread.remainingToAutoCompact = null;
      thread.autoCompactNearThreshold = false;
      return;
    }
    thread.remainingToAutoCompact = used >= limit ? 0 : (limit - used);
    const remainingPct = thread.tokenUsage?.contextRemainingPercent ?? -1;
    thread.autoCompactNearThreshold = thread.remainingToAutoCompact === 0
      || (typeof remainingPct === 'number' && remainingPct === remainingPct && remainingPct >= 0 && remainingPct <= 15);
  }

  private updateCompactionTokenDelta(thread: CodexThreadRecord): void {
    if (this.compactionState.threadId.trim().length === 0 || thread.remoteThreadId !== this.compactionState.threadId) {
      return;
    }
    if (this.compactionState.oldTotalTokens <= 0 || thread.tokenUsage === null) {
      return;
    }
    const newTotal: number = thread.tokenUsage.total.totalTokens;
    if (typeof newTotal !== 'number' || newTotal !== newTotal || newTotal <= 0) {
      return;
    }
    this.compactionState.newTotalTokens = newTotal;
    const saved: number = this.compactionState.oldTotalTokens - newTotal;
    this.compactionState.savedTokens = saved > 0 ? saved : 0;
    if (saved > 0) {
      this.compactionState.observedReduction = true;
    }
  }

  private async pollCompactionUntilCompleted(thread: CodexThreadRecord, baselineTurnId: string, timeoutMs: number): Promise<void> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.compactionState.turnId.trim().length === 0) {
        const snapshot: ThreadReadSnapshotPayload = await this.readThreadSnapshot(thread.remoteThreadId);
        if (snapshot.lastTurnId.trim().length > 0 && snapshot.lastTurnId !== baselineTurnId) {
          const snapshotStatus: CodexTurnStatus = this.mapTurnStatus(snapshot.lastTurnStatus);
          this.compactionState.turnId = snapshot.lastTurnId;
          thread.lastCompactionTurnId = snapshot.lastTurnId;
          if (snapshotStatus === 'completed') {
            await this.drainCompactionTokenUsage(thread);
            this.completeCompaction(thread);
            return;
          }
          if (snapshotStatus === 'failed' || snapshotStatus === 'interrupted') {
            await this.drainCompactionTokenUsage(thread);
            if (this.compactionState.observedReduction) {
              this.completeCompaction(thread);
              return;
            }
            this.failCompaction('压缩失败', thread.remoteThreadId);
            return;
          }
          this.compactionState.status = 'running';
          this.notifyListeners();
        }
      }
      if (this.compactionState.turnId.trim().length > 0) {
        const pollObject: Record<string, Object> = parseJsonText(
          await turnPollAsyncNative(thread.remoteThreadId, this.compactionState.turnId),
          new TurnPollResponsePayload() as Object
        ) as Record<string, Object>;
        const result: CodexTurnResult = this.applyTurnPollResult(thread, this.compactionState.turnId, pollObject);
        this.logInfo(`compact turnPoll thread=${thread.remoteThreadId} turn=${this.compactionState.turnId} resultStatus=${result.status} ${this.turnPollLogSummary(pollObject)}`);
        if (this.compactionState.observedReduction) {
          this.completeCompaction(thread);
          return;
        }
        if (result.status === 'failed' || result.status === 'interrupted') {
          await this.drainCompactionTokenUsage(thread);
          if (this.compactionState.observedReduction) {
            this.completeCompaction(thread);
            return;
          }
          this.failCompaction(this.resolveCompactionFailureMessage(result), thread.remoteThreadId);
          return;
        }
        if (this.compactionState.status !== 'running') {
          this.compactionState.status = result.status === 'inProgress' ? 'running' : this.compactionState.status;
        }
        this.notifyListeners();
        if (result.status === 'completed') {
          await this.drainCompactionTokenUsage(thread);
          this.completeCompaction(thread);
          return;
        }
      }
      await new Promise<void>((resolve) => setTimeout(resolve, TURN_POLL_INTERVAL_MS));
    }
    if (this.compactionState.turnId.trim().length > 0) {
      turnInterruptNative(thread.remoteThreadId, this.compactionState.turnId);
    }
    this.failCompaction('压缩超时', thread.remoteThreadId, 'timeout');
    throw new Error('压缩超时');
  }

  private async drainCompactionTokenUsage(thread: CodexThreadRecord): Promise<void> {
    if (this.compactionState.turnId.trim().length === 0) {
      this.updateCompactionTokenDelta(thread);
      return;
    }
    for (let attempt: number = 0; attempt < TERMINAL_TURN_DRAIN_ATTEMPTS; attempt += 1) {
      this.updateCompactionTokenDelta(thread);
      if (this.compactionState.newTotalTokens > 0 && this.compactionState.newTotalTokens !== this.compactionState.oldTotalTokens) {
        return;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, TERMINAL_TURN_DRAIN_INTERVAL_MS));
      const pollObject: Record<string, Object> = parseJsonText(
        await turnPollAsyncNative(thread.remoteThreadId, this.compactionState.turnId),
        new TurnPollResponsePayload() as Object
      ) as Record<string, Object>;
      this.applyTurnPollResult(thread, this.compactionState.turnId, pollObject);
      this.notifyListeners();
      this.updateCompactionTokenDelta(thread);
      if (this.compactionState.newTotalTokens > 0 && this.compactionState.newTotalTokens !== this.compactionState.oldTotalTokens) {
        return;
      }
    }
  }

  async refreshMcpServers(): Promise<McpServerRecord[]> {
    await this.ensureConnected();
    this.readMcpConfig();

    // 构建状态索引（非阻塞，可能为空）
    const statusMap: Map<string, McpServerStatusPayload> = new Map();
    const statusListRequest: McpStatusListRequestPayload = new McpStatusListRequestPayload();
    const rawStatusJson: string = mcpStatusListNative(JSON.stringify(statusListRequest));
    const response: McpStatusListResponsePayload = parseJsonText(rawStatusJson, new McpStatusListResponsePayload()) as McpStatusListResponsePayload;
    for (const item of response.data) {
      statusMap.set(item.name, item);
    }

    // 基于配置构建服务器列表（始终有数据），叠加可用的状态信息
    const servers: McpServerRecord[] = [];
    this.mcpConfigByName.forEach((config: Object, name: string) => {
      const status: McpServerStatusPayload | undefined = statusMap.get(name);
      if (status !== undefined) {
        servers.push(this.buildMcpServerRecord(status));
      } else {
        servers.push(this.buildMcpServerRecordFromConfig(name, config));
      }
    });
    this.mcpServersCache = servers;
    this.mcpStatusText = servers.length > 0
      ? `已加载 ${servers.length} 个 MCP server`
      : '当前没有已配置的 MCP server';
    this.mcpErrorText = '';
    this.notifyListeners();
    return this.mcpServers();
  }

  async reloadMcpServers(): Promise<void> {
    await this.ensureConnected();
    const reloadOk: boolean = mcpReloadNative();
    if (!reloadOk) {
      throw new Error('MCP reload 失败');
    }
    this.mcpStatusText = 'MCP 配置已重载';
    this.mcpErrorText = '';
    await this.refreshMcpServers();
  }

  async batchWriteMcpConfig(edits: McpConfigBatchEditPayload[]): Promise<void> {
    await this.ensureConnected();
    const batchWriteRequest: McpConfigBatchWriteRequestPayload = new McpConfigBatchWriteRequestPayload();
    batchWriteRequest.edits = edits;
    const ok: boolean = mcpConfigBatchWriteNative(JSON.stringify(batchWriteRequest));
    if (!ok) {
      const hostStatus: CodexHostStatus = getEmbeddedCodexHostStatus();
      const detail: string = hostStatus.message.trim().length > 0 ? hostStatus.message : '未知错误';
      throw new Error(`MCP 配置写入失败: ${detail}`);
    }
    this.mcpStatusText = 'MCP 配置已保存';
    this.mcpErrorText = '';
    this.notifyListeners();
  }

  async saveMcpServerConfig(serverName: string, enabled: boolean, transportType: string, command: string, argsText: string, url: string, envText: string, httpHeadersText: string): Promise<void> {
    await this.ensureConnected();
    this.readMcpConfig();
    const existingConfig: Record<string, Object> = this.copyConfigObject((this.mcpConfigByName.get(serverName) as Record<string, Object> | undefined) ?? {});
    const nextConfig: Record<string, Object> = this.copyConfigObject(existingConfig);
    nextConfig['enabled'] = enabled;
    if (transportType === 'http') {
      nextConfig['url'] = url.trim();
      const headers: Object = parseJsonText(httpHeadersText, new Object() as Object);
      if (typeof headers === 'object' && headers !== null && Object.keys(headers as Record<string, Object>).length > 0) {
        nextConfig['http_headers'] = headers;
      }
    } else {
      nextConfig['command'] = command.trim();
      nextConfig['args'] = parseJsonText(argsText, new Array<Object>() as Object);
      nextConfig['env'] = parseJsonText(envText, new Object() as Object);
    }
    const edit: McpConfigBatchEditPayload = new McpConfigBatchEditPayload();
    edit.keyPath = `mcp_servers.${serverName}`;
    edit.value = nextConfig;
    edit.mergeStrategy = 'replace';
    await this.batchWriteMcpConfig([edit]);
    await this.reloadMcpServers();
  }

  async toggleMcpServerEnabled(serverName: string): Promise<void> {
    await this.ensureConnected();
    this.readMcpConfig();
    const existingConfig: Record<string, Object> = (this.mcpConfigByName.get(serverName) as Record<string, Object> | undefined) ?? {};
    const currentEnabled: boolean = this.readBooleanField(existingConfig, 'enabled', true);
    const edit: McpConfigBatchEditPayload = new McpConfigBatchEditPayload();
    edit.keyPath = `mcp_servers.${serverName}`;
    const toggleConfig: Record<string, Object> = this.copyConfigObject(existingConfig);
    toggleConfig['enabled'] = !currentEnabled;
    edit.value = toggleConfig as Object;
    edit.mergeStrategy = 'replace';
    await this.batchWriteMcpConfig([edit]);
    await this.reloadMcpServers();
  }

  async addMcpServer(serverName: string, transportType: string, command: string, argsText: string, url: string, envText: string, httpHeadersText: string): Promise<void> {
    await this.ensureConnected();
    const config: Record<string, Object> = {} as Record<string, Object>;
    config['enabled'] = true;
    if (transportType === 'http') {
      config['url'] = url.trim();
      const headers: Object = parseJsonText(httpHeadersText, new Object() as Object);
      if (typeof headers === 'object' && headers !== null && Object.keys(headers as Record<string, Object>).length > 0) {
        config['http_headers'] = headers;
      }
    } else {
      config['command'] = command.trim();
      config['args'] = parseJsonText(argsText, new Array<Object>() as Object);
      config['env'] = parseJsonText(envText, new Object() as Object);
    }
    const request: McpConfigAddRequestPayload = new McpConfigAddRequestPayload();
    request.name = serverName;
    request.config = config as Object;
    const ok: boolean = mcpConfigAddNative(JSON.stringify(request));
    if (!ok) {
      const hostStatus: CodexHostStatus = getEmbeddedCodexHostStatus();
      const detail: string = hostStatus.message.trim().length > 0 ? hostStatus.message : '未知错误';
      throw new Error(`添加 MCP server 失败: ${detail}`);
    }
    this.mcpStatusText = `已添加 MCP server: ${serverName}`;
    this.mcpErrorText = '';
    await this.reloadMcpServers();
  }

  async removeMcpServer(serverName: string): Promise<void> {
    await this.ensureConnected();
    const request: McpConfigRemoveRequestPayload = new McpConfigRemoveRequestPayload();
    request.name = serverName;
    const ok: boolean = mcpConfigRemoveNative(JSON.stringify(request));
    if (!ok) {
      throw new Error('删除 MCP server 失败');
    }
    this.mcpStatusText = `已删除 MCP server: ${serverName}`;
    this.mcpErrorText = '';
    await this.reloadMcpServers();
  }

  async startMcpOAuthLogin(serverName: string): Promise<void> {
    await this.ensureConnected();
    const oauthRequest: McpOauthStartRequestPayload = new McpOauthStartRequestPayload();
    oauthRequest.name = serverName;
    mcpOauthStartNative(JSON.stringify(oauthRequest));
    this.mcpStatusText = `已为 ${serverName} 发起 OAuth 登录`;
    this.mcpErrorText = '';
    this.notifyListeners();
  }

  private async ensureConnected(): Promise<void> {
    if (!this.initialized || this.connectionLost) {
      await this.connect();
      // 预热 MCP 状态缓存（非阻塞，后台刷新）
      this.refreshMcpServers().catch(() => {});
    }
  }

  /** 识别 remote app-server 断线/连接丢失的错误文本（Rust 侧 client 丢失或 worker 退出）。 */
  private isConnectionLostError(text: string): boolean {
    const normalized: string = text.toLowerCase();
    return normalized.indexOf('remote app-server client is not initialized') >= 0 ||
      normalized.indexOf('app-server client is not initialized') >= 0 ||
      normalized.indexOf('channel is closed') >= 0 ||
      normalized.indexOf('request timed out') >= 0 ||
      normalized.indexOf('disconnected') >= 0;
  }

  /** 检测到断线后标记 connectionLost；不在此处触发重连，由调用方决定。 */
  private markConnectionLostIfError(text: string): boolean {
    if (this.isConnectionLostError(text)) {
      this.connectionLost = true;
      this.updateConnectionState('error', '连接已断开');
      return true;
    }
    return false;
  }

  /** 后台触发一次重连（重新 initialize → Rust connect_remote_client_if_needed 重建 client）。 */
  private reconnectInBackground(): void {
    if (this.connectionLost) {
      this.connect().catch((err: Error) => {
        this.logInfo(`reconnect failed: ${err.message}`);
      });
    }
  }

  private async refreshAccountState(): Promise<void> {
    const payload: GetAccountResponsePayload = parseJsonText(accountReadNative(), new GetAccountResponsePayload()) as GetAccountResponsePayload;
    this.applyAccountState(payload);
  }

  private async refreshCollaborationModes(): Promise<void> {
    const rawJson: string = await collaborationModeListAsyncNative('{}');
    this.logInfo(`refreshCollaborationModes raw=${rawJson.substring(0, 200)}`);
    const payload: Record<string, Object> = parseJsonText(
      rawJson,
      new CollaborationModeListResponsePayload() as Object
    ) as Record<string, Object>;
    const data: Object[] = Array.isArray(payload['data']) ? (payload['data'] as Object[]) : [];
    this.collaborationModes = data.map((item: Object) => this.buildCollaborationMode(item as Record<string, Object>));
    this.logInfo(`refreshCollaborationModes count=${this.collaborationModes.length} names=${this.collaborationModes.map((m: CollaborationModeOption) => m.name).join(',')}`);
    this.notifyListeners();
  }

  private ensureApprovalPolling(): void {
    if (this.approvalTimerId >= 0) {
      return;
    }
    this.approvalTimerId = setInterval(() => {
      if (!this.initialized) {
        return;
      }
      if (!this.hasActiveTurn() && this.pendingApproval === null && this.pendingRequestUserInput === null) {
        return;
      }
      this.pollPendingApproval();
    }, APPROVAL_POLL_INTERVAL_MS);
  }

  private stopApprovalPolling(): void {
    if (this.approvalTimerId >= 0) {
      clearInterval(this.approvalTimerId);
      this.approvalTimerId = -1;
    }
  }

  private pollPendingApproval(): void {
    if (!this.initialized) {
      return;
    }
    const parsed: Object | null = safeJsonParse(approvalPollNative());
    if (parsed === null) {
      return;
    }
    const payload: Record<string, Object> = parsed as Record<string, Object>;
    const kindRaw: string = typeof payload['kind'] === 'string' ? (payload['kind'] as string) : '';
    let nextRequestUserInput: CodexRequestUserInput | null = null;
    let nextApproval: CodexApprovalRequest | null = null;
    if (kindRaw === 'requestUserInput') {
      nextRequestUserInput = this.buildRequestUserInputFromNative(payload);
    } else {
      nextApproval = this.buildApprovalFromNative(payload);
    }
    if (this.requestUserInputStateEquals(nextRequestUserInput, this.pendingRequestUserInput)
      && this.approvalStateEquals(nextApproval, this.pendingApproval)) {
      return;
    }
    this.pendingRequestUserInput = nextRequestUserInput;
    this.pendingApproval = nextApproval;
    this.notifyListeners();
  }

  private async ensureRemoteThread(request: CodexTurnRequest): Promise<CodexThreadRecord> {
    const existing: CodexThreadRecord | undefined = this.threads.get(request.threadKey);
    if (existing !== undefined && existing.remoteThreadId.length > 0) {
      existing.title = request.title;
      this.bindWorkspaceToThread(existing, request);
      try {
        await this.resumeThread(existing, request.model);
        return existing;
      } catch (resumeErr) {
        this.logInfo(`thread stale on server, recreating: ${existing.remoteThreadId} err=${resumeErr}`);
        this.threadKeysByRemoteId.delete(existing.remoteThreadId);
        existing.remoteThreadId = '';
        existing.loaded = false;
      }
    }
    const thread: CodexThreadRecord = existing ?? new CodexThreadRecord(request.threadKey, request.title);
    const workspace: WorkspaceDescriptor = this.bindWorkspaceToThread(thread, request);
    const threadStartRequest: ThreadStartRequestPayload = new ThreadStartRequestPayload();
    threadStartRequest.cwd = workspace.rootPath.trim().length > 0 ? workspace.rootPath.trim() : undefined;
    threadStartRequest.model = request.model !== 'default' ? request.model : undefined;
    const payload: ThreadStartResultPayload = parseJsonText(await threadStartAsyncNative(JSON.stringify(threadStartRequest)), new ThreadStartResultPayload()) as ThreadStartResultPayload;
    if (payload.thread === undefined || payload.thread.id.length === 0) {
      const message: string = payload.error?.message?.trim() ?? '';
      if (message.length > 0) {
        throw new Error(`threadStart failed: ${message}`);
      }
    }
    if (payload.thread === undefined || payload.thread.id.length === 0) {
      payload.thread = new ThreadPayload();
      payload.thread.id = `native-thread-${request.threadKey}`;
    }
    thread.remoteThreadId = payload.thread.id;
    thread.loaded = true;
    if (request.title.trim().length > 0) {
      thread.title = request.title.trim();
      void this.renameSession(thread.remoteThreadId, thread.title).catch((_err: Error) => {});
    }
    if (thread.localKey !== thread.remoteThreadId) {
      this.threads.delete(thread.localKey);
      thread.localKey = thread.remoteThreadId;
    }
    this.threads.set(thread.localKey, thread);
    this.threadKeysByRemoteId.set(payload.thread.id, thread.localKey);
    return thread;
  }

  private bindWorkspaceToThread(thread: CodexThreadRecord, request: CodexTurnRequest): WorkspaceDescriptor {
    return this.bindWorkspaceForSession(
      thread,
      request.title,
      request.workspaceId,
      request.workspaceRoot,
      request.workspacePermissionState,
      request.workspaceAccessKind,
      request.writableRoots
    );
  }

  private bindWorkspaceForSession(
    thread: CodexThreadRecord,
    title: string,
    workspaceId: string,
    workspaceRoot: string,
    workspacePermissionState: WorkspacePermissionState,
    workspaceAccessKind: WorkspaceAccessKind,
    writableRoots: string[]
  ): WorkspaceDescriptor {
    const workspace: WorkspaceDescriptor = this.upsertWorkspaceDescriptor(
      thread.localKey,
      title,
      workspaceId,
      workspaceRoot,
      workspacePermissionState,
      workspaceAccessKind,
      writableRoots
    );
    thread.workspaceId = workspace.id;
    thread.workspaceName = workspace.name;
    thread.cwd = workspace.rootPath;
    thread.workspacePermissionState = workspace.permissionState;
    thread.workspaceAccessKind = workspace.accessKind;
    thread.writableRoots = [...workspace.writableRoots];
    return workspace;
  }

  private upsertWorkspaceDescriptor(
    threadKey: string,
    title: string,
    workspaceId: string,
    workspaceRoot: string,
    workspacePermissionState: WorkspacePermissionState,
    workspaceAccessKind: WorkspaceAccessKind,
    writableRoots: string[]
  ): WorkspaceDescriptor {
    const trimmedRoot: string = workspaceRoot.trim();
    const normalizedWorkspaceId: string = workspaceId.trim().length > 0 ? workspaceId.trim() : `session:${threadKey}`;
    const existing: WorkspaceDescriptor | undefined = this.workspaceCatalog.get(normalizedWorkspaceId);
    const nextRoot: string = trimmedRoot.length > 0 ? trimmedRoot : (existing?.rootPath ?? '');
    const nextWritableRoots: string[] = writableRoots.length > 0
      ? [...writableRoots]
      : (nextRoot.length > 0 ? [nextRoot] : (existing?.writableRoots ?? []));
    const nextName: string = title.trim().length > 0 ? title.trim() : (existing?.name ?? normalizedWorkspaceId);
    const workspace: WorkspaceDescriptor = new WorkspaceDescriptor(
      normalizedWorkspaceId,
      nextName,
      nextRoot,
      workspaceAccessKind,
      workspacePermissionState,
      existing?.sourceUri ?? '',
      nextWritableRoots,
      existing?.grantedAt ?? Date.now(),
      Date.now()
    );
    this.workspaceCatalog.set(normalizedWorkspaceId, workspace);
    return workspace;
  }

  private workspaceDescriptorForThread(thread: CodexThreadRecord): WorkspaceDescriptor {
    const existing: WorkspaceDescriptor | undefined = thread.workspaceId.length > 0 ? this.workspaceCatalog.get(thread.workspaceId) : undefined;
    if (existing !== undefined) {
      return existing;
    }
    const inferredRoot: string = thread.cwd.trim();
    return new WorkspaceDescriptor(
      thread.workspaceId.length > 0 ? thread.workspaceId : `session:${thread.localKey}`,
      thread.workspaceName.length > 0 ? thread.workspaceName : thread.title,
      inferredRoot,
      thread.workspaceAccessKind,
      thread.workspacePermissionState,
      '',
      thread.writableRoots.length > 0 ? [...thread.writableRoots] : (inferredRoot.length > 0 ? [inferredRoot] : []),
      Date.now(),
      Date.now()
    );
  }

  private async resumeThread(thread: CodexThreadRecord, model: string = 'default'): Promise<void> {
    const workspace: WorkspaceDescriptor = this.workspaceDescriptorForThread(thread);
    const resumeRequest: ThreadResumeRequestPayload = new ThreadResumeRequestPayload();
    resumeRequest.threadId = thread.remoteThreadId;
    resumeRequest.cwd = workspace.rootPath.trim().length > 0 ? workspace.rootPath.trim() : undefined;
    resumeRequest.model = model !== 'default' ? model : undefined;
    const payload: Record<string, Object> = parseJsonText(
      await threadResumeAsyncNative(JSON.stringify(resumeRequest)),
      new Object() as Object
    ) as Record<string, Object>;
    const threadPayload: Record<string, Object> | undefined = payload['thread'] as Record<string, Object> | undefined;
    const threadId: string = typeof threadPayload?.['id'] === 'string' ? (threadPayload!['id'] as string) : '';
    if (threadId.trim().length === 0) {
      const errorRecord: Record<string, Object> | undefined = payload['error'] as Record<string, Object> | undefined;
      const errorMessage: string = typeof errorRecord?.['message'] === 'string' ? (errorRecord!['message'] as string) : '';
      throw new Error(errorMessage.trim().length > 0 ? errorMessage : 'thread/resume did not return a valid thread id.');
    }
    thread.remoteThreadId = threadId;
    thread.loaded = true;
    this.threadKeysByRemoteId.set(threadId, thread.localKey);
  }

  private upsertThreadFromListPayload(payload: Record<string, Object>): void {
    const remoteThreadId: string = typeof payload['id'] === 'string' ? (payload['id'] as string) : '';
    if (remoteThreadId.trim().length === 0) {
      return;
    }
    const title: string = this.threadTitleFromPayload(payload, remoteThreadId);
    const thread: CodexThreadRecord = this.threads.get(remoteThreadId) ?? new CodexThreadRecord(remoteThreadId, title);
    thread.localKey = remoteThreadId;
    thread.remoteThreadId = remoteThreadId;
    thread.title = title;
    thread.updatedAt = this.timestampFromPayload(payload['updatedAt']);
    const cwd: string = typeof payload['cwd'] === 'string' ? (payload['cwd'] as string) : thread.cwd;
    this.bindWorkspaceForSession(
      thread,
      title,
      thread.workspaceId.length > 0 ? thread.workspaceId : remoteThreadId,
      cwd,
      thread.workspacePermissionState,
      thread.workspaceAccessKind,
      cwd.trim().length > 0 ? [cwd] : thread.writableRoots
    );
    if (thread.summaryTitle.trim().length === 0) {
      thread.summaryTitle = '历史会话';
    }
    if (thread.summaryPoints.length === 0) {
      const preview: string = typeof payload['preview'] === 'string' ? (payload['preview'] as string) : '';
      thread.summaryPoints = [preview.trim().length > 0 ? preview : '会话元信息已从 app-server 恢复。'];
    }
    this.threads.set(remoteThreadId, thread);
    this.threadKeysByRemoteId.set(remoteThreadId, remoteThreadId);
  }

  private ensureThreadRecordFromReadPayload(threadId: string, payload: Record<string, Object>): CodexThreadRecord {
    const threadPayload: Record<string, Object> | undefined = payload['thread'] as Record<string, Object> | undefined;
    const existingThread: CodexThreadRecord | undefined = this.threads.get(threadId);
    const previousTokenUsage: TurnTokenUsage | null = existingThread?.tokenUsage ?? null;
    if (threadPayload !== undefined) {
      this.upsertThreadFromListPayload(threadPayload);
    }
    const remoteThreadId: string = threadPayload !== undefined && typeof threadPayload['id'] === 'string'
      ? (threadPayload['id'] as string)
      : threadId;
    const thread: CodexThreadRecord = this.threads.get(remoteThreadId) ?? new CodexThreadRecord(remoteThreadId, this.threadTitleFromPayload(threadPayload ?? {}, remoteThreadId));
    thread.localKey = remoteThreadId;
    thread.remoteThreadId = remoteThreadId;
    thread.loaded = true;
    if (threadPayload !== undefined) {
      thread.title = this.threadTitleFromPayload(threadPayload, remoteThreadId);
      thread.updatedAt = this.timestampFromPayload(threadPayload['updatedAt']);
      const cwd: string = typeof threadPayload['cwd'] === 'string' ? (threadPayload['cwd'] as string) : thread.cwd;
      this.bindWorkspaceForSession(
        thread,
        thread.title,
        thread.workspaceId.length > 0 ? thread.workspaceId : remoteThreadId,
        cwd,
        thread.workspacePermissionState,
        thread.workspaceAccessKind,
        cwd.trim().length > 0 ? [cwd] : thread.writableRoots
      );
    }
    const messagesRaw: Object[] = Array.isArray(payload['messages']) ? (payload['messages'] as Object[]) : [];
    thread.messages = this.mergeThreadMessages([], this.messagesFromPayload(messagesRaw));
    const diffText: string = typeof payload['diff'] === 'string' ? (payload['diff'] as string) : '';
    if (diffText.trim().length > 0) {
      const parsedDiff: ParsedDiff = this.parseUnifiedDiff(diffText);
      thread.diffLines = parsedDiff.lines;
      thread.diffStat = typeof payload['diffStat'] === 'string' ? (payload['diffStat'] as string) : parsedDiff.diffStat;
      thread.changedFiles = typeof payload['changedFilesText'] === 'string'
        ? (payload['changedFilesText'] as string)
        : parsedDiff.changedFiles;
    } else {
      thread.diffLines = [];
      thread.diffStat = typeof payload['diffStat'] === 'string' ? (payload['diffStat'] as string) : '+0 -0';
      thread.changedFiles = typeof payload['changedFilesText'] === 'string'
        ? (payload['changedFilesText'] as string)
        : '尚未产生文件改动';
    }
    thread.changedFiles = this.normalizeChangedFilesText(thread.changedFiles, diffText.trim().length > 0);
    const summaryRaw: Object[] = Array.isArray(payload['summary']) ? (payload['summary'] as Object[]) : [];
    thread.summaryTitle = typeof payload['summaryTitle'] === 'string' ? (payload['summaryTitle'] as string) : '历史会话';
    thread.summaryPoints = summaryRaw.length > 0
      ? summaryRaw.map((item: Object) => typeof item === 'string' ? (item as string) : JSON.stringify(item))
      : ['历史会话已从 app-server 恢复。'];
    thread.lastTurnId = typeof payload['lastTurnId'] === 'string' ? (payload['lastTurnId'] as string) : '';
    thread.lastTurnStatus = this.mapTurnStatus(
      typeof payload['lastTurnStatus'] === 'string' ? (payload['lastTurnStatus'] as string) : 'completed'
    );
    this.applyTokenUsagePayload(thread, payload['tokenUsage']);
    this.applyContextManagementPayload(thread, payload['contextManagement']);
    this.applyAutoCompactConfigPayload(thread, payload);
    if (thread.tokenUsage === null && previousTokenUsage !== null) {
      thread.tokenUsage = previousTokenUsage;
    }
    this.threads.set(remoteThreadId, thread);
    this.threadKeysByRemoteId.set(remoteThreadId, remoteThreadId);
    return thread;
  }

  private messagesFromPayload(messages: Object[]): CodexChatMessage[] {
    return messages.map((item: Object, index: number) => {
      return this.codexMessageFromRecord(item as Record<string, Object>, index);
    });
  }

  /** 单条 NativeMessage 解析：messageSnapshot / messageStarted / messageReplaced / turn_poll 共用，保证解析一致。 */
  private codexMessageFromRecord(message: Record<string, Object>, index: number): CodexChatMessage {
    const roleRaw: string = typeof message['role'] === 'string' ? (message['role'] as string) : 'assistant';
    const role: CodexMessageRole = this.mapMessageRole(roleRaw);
    const itemType: string | undefined = typeof message['itemType'] === 'string' ? (message['itemType'] as string) : undefined;
    const itemStatus: string | undefined = typeof message['status'] === 'string' ? (message['status'] as string) : undefined;
    const metadata: Record<string, Object> | undefined = message['metadata'] !== undefined && message['metadata'] !== null
      ? (message['metadata'] as Record<string, Object>)
      : undefined;
    return new CodexChatMessage(
      typeof message['messageId'] === 'string' ? (message['messageId'] as string) : `msg-${index + 1}`,
      index + 1,
      this.mapMessageAuthor(role, typeof message['author'] === 'string' ? (message['author'] as string) : ''),
      role,
      typeof message['content'] === 'string' ? (message['content'] as string) : '',
      this.messageTimestampFromPayload(this.messageTimestampSource(message)),
      itemType,
      itemStatus,
      metadata
    );
  }

  /** 事件里的单条消息：解析失败返回 null。 */
  private codexMessageFromEventPayload(raw: Object): CodexChatMessage | null {
    if (raw === null || raw === undefined || typeof raw !== 'object') {
      return null;
    }
    return this.codexMessageFromRecord(raw as Record<string, Object>, 1);
  }

  private threadTitleFromPayload(payload: Record<string, Object>, fallbackId: string): string {
    const title: string = typeof payload['title'] === 'string' ? (payload['title'] as string) : '';
    if (title.trim().length > 0) {
      return title.trim();
    }
    const name: string = typeof payload['name'] === 'string' ? (payload['name'] as string) : '';
    if (name.trim().length > 0) {
      return name.trim();
    }
    const preview: string = typeof payload['preview'] === 'string' ? (payload['preview'] as string) : '';
    if (preview.trim().length > 0) {
      return preview.trim().substring(0, 40);
    }
    return fallbackId;
  }

  private timestampFromPayload(rawValue: Object): string {
    if (typeof rawValue === 'number' && Number.isFinite(rawValue)) {
      const date: Date = new Date((rawValue as number) * 1000);
      return formatDetailedTimestamp(date);
    }
    if (typeof rawValue === 'string' && rawValue.trim().length > 0) {
      const parsedDate: Date = new Date(rawValue);
      if (!Number.isNaN(parsedDate.getTime())) {
        return formatDetailedTimestamp(parsedDate);
      }
    }
    return currentThreadTimestamp();
  }

  private messageTimestampSource(message: Record<string, Object>): Object {
    if (message['timestamp'] !== undefined && message['timestamp'] !== null) {
      return message['timestamp'];
    }
    const payload: Object | undefined = message['payload'];
    if (typeof payload === 'object' && payload !== null) {
      const payloadRecord: Record<string, Object> = payload as Record<string, Object>;
      if (payloadRecord['timestamp'] !== undefined && payloadRecord['timestamp'] !== null) {
        return payloadRecord['timestamp'];
      }
    }
    return '';
  }

  private messageTimestampFromPayload(rawValue: Object): string {
    if (typeof rawValue === 'number' && Number.isFinite(rawValue)) {
      return formatShortTimestamp(new Date((rawValue as number) * 1000));
    }
    if (typeof rawValue === 'string') {
      const trimmed: string = rawValue.trim();
      if (trimmed.length === 0) {
        return currentTimestamp();
      }
      const numericValue: number = Number(trimmed);
      if (Number.isFinite(numericValue) && /^\d+(\.\d+)?$/.test(trimmed)) {
        const millis: number = numericValue > 100000000000 ? numericValue : numericValue * 1000;
        return formatShortTimestamp(new Date(millis));
      }
      const parsedDate: Date = new Date(trimmed);
      if (!Number.isNaN(parsedDate.getTime())) {
        return formatShortTimestamp(parsedDate);
      }
      if (/^\d{1,2}:\d{2}$/.test(trimmed)) {
        return trimmed;
      }
    }
    return currentTimestamp();
  }
  private beginLocalTurn(thread: CodexThreadRecord, prompt: string): CodexTurnResult {
    this.upsertMessage(thread, `user-${Date.now()}`, '你', 'user', prompt, currentTimestamp());
    thread.turnCount += 1;
    thread.lastTurnStatus = 'inProgress';
    thread.updatedAt = currentThreadTimestamp();
    thread.changedFiles = NO_FILE_CHANGES_TEXT;
    thread.diffLines = [];
    thread.diffStat = '+0 -0';
    thread.changedFiles = 'å°šæœªäº§ç”Ÿæ–‡ä»¶æ”¹åŠ¨';
    thread.summaryTitle = '';
    thread.summaryPoints = [];
    // AIGC provenance：turn 开始前对工作区做快照，turn 结束后对比以捕获文件变化
    // （不依赖 Rust 的 FileChange diff，能覆盖 shell/脚本生成的文件）
    this.captureAigcBaseline(thread);
    return this.snapshotForThread(thread, 'inProgress');
  }

  /** AIGC provenance：生成 turn 开始前的工作区快照。 */
  private captureAigcBaseline(thread: CodexThreadRecord): void {
    try {
      const workspaceRoot: string = thread.cwd ?? '';
      if (workspaceRoot.trim().length === 0) {
        thread.aigcBaselineFiles = new Map<string, string>();
        return;
      }
      thread.aigcBaselineFiles = aigcProvenanceStore.snapshotWorkspace(workspaceRoot);
    } catch (err) {
      this.logInfo(`captureAigcBaseline failed: ${err}`);
      thread.aigcBaselineFiles = new Map<string, string>();
    }
  }

  private eventBatchSignature(events: Object[]): string {
    const count: number = events.length;
    if (count === 0) {
      return '0';
    }
    const last: Record<string, Object> = events[count - 1] as Record<string, Object>;
    const kind: string = typeof last['kind'] === 'string' ? (last['kind'] as string) : '';
    let contentText: string = '';
    if (kind === 'summaryLine') {
      contentText = typeof last['line'] === 'string' ? (last['line'] as string) : '';
    } else if (kind === 'messageSnapshot') {
      contentText = `${(Array.isArray(last['messages']) ? (last['messages'] as Object[]) : []).length}`;
    } else if (kind === 'diffSnapshot') {
      contentText = typeof last['diff'] === 'string' ? (last['diff'] as string) : '';
    } else if (kind === 'status') {
      contentText = typeof last['status'] === 'string' ? (last['status'] as string) : '';
    }
    return `${count}|${kind}|${contentText.length}`;
  }

  private async pollTurnUntilCompleted(thread: CodexThreadRecord, pendingTurn: PendingTurnState): Promise<CodexTurnResult> {
    this.lastEventBatchSignature = '';
    const startedAt: number = Date.now();
    const deadline: number = startedAt + TURN_POLL_TIMEOUT_MS;
    let lastHeartbeatPollAt: number = 0;
    while (true) {
      if (pendingTurn.cancelled) {
        thread.lastTurnStatus = 'interrupted';
        const interruptedSnapshot: CodexTurnResult = this.snapshotForThread(thread, 'interrupted', pendingTurn.turnId);
        this.emitTurnUpdate(thread, pendingTurn, interruptedSnapshot);
        // AIGC provenance：取消分支也要落库生成事件
        this.recordAigcTurn(thread, pendingTurn, 'interrupted');
        thread.activeTurn = null;
        pendingTurn.resolveCompletion(interruptedSnapshot);
        return interruptedSnapshot;
      }
      if (Date.now() > deadline) {
        this.logInfo(`turnPoll timeout thread=${thread.remoteThreadId} turn=${pendingTurn.turnId}`);
        turnInterruptNative(thread.remoteThreadId, pendingTurn.turnId);
        thread.lastTurnStatus = 'failed';
        const timeoutSnapshot: CodexTurnResult = this.snapshotForThread(thread, 'failed', pendingTurn.turnId);
        timeoutSnapshot.summaryTitle = '轮询超时';
        timeoutSnapshot.summaryPoints = ['API 响应时间过长，已自动中断。请稍后重试或检查网络连接。'];
        this.emitTurnUpdate(thread, pendingTurn, timeoutSnapshot);
        // AIGC provenance：超时分支也要落库生成事件
        this.recordAigcTurn(thread, pendingTurn, 'failed');
        thread.activeTurn = null;
        pendingTurn.resolveCompletion(timeoutSnapshot);
        return timeoutSnapshot;
      }
      const eventPayload: Object[] = parseJsonText(
        await turnEventsAsyncNative(thread.remoteThreadId, pendingTurn.turnId),
        [] as Object
      ) as Object[];
      if (eventPayload.length > 0) {
        this.logInfo(`turnEvents thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} count=${eventPayload.length}`);
        const nextSnapshot: CodexTurnResult = this.applyTurnEventBatch(thread, pendingTurn.turnId, eventPayload);
        if (nextSnapshot.status !== 'inProgress') {
          this.emitTurnUpdate(thread, pendingTurn, nextSnapshot);
          return await this.finalizeTerminalTurnSnapshot(thread, pendingTurn, nextSnapshot);
        }
        const eventSignature: string = this.eventBatchSignature(eventPayload);
        if (eventSignature !== this.lastEventBatchSignature) {
          this.lastEventBatchSignature = eventSignature;
          this.emitTurnUpdate(thread, pendingTurn, nextSnapshot);
        }
      }
      const now: number = Date.now();
      if ((now - lastHeartbeatPollAt) >= TURN_POLL_HEARTBEAT_INTERVAL_MS) {
        lastHeartbeatPollAt = now;
        const pollObject: Record<string, Object> = parseJsonText(
          await turnPollAsyncNative(thread.remoteThreadId, pendingTurn.turnId),
          new TurnPollResponsePayload() as Object
        ) as Record<string, Object>;
        this.logInfo(`turnPoll thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} ${this.turnPollLogSummary(pollObject)}`);
        if (this.shouldRecoverFromPollPayload(pollObject)) {
          const recoveredSnapshot: CodexTurnResult | null = await this.recoverTurnFromThreadHistory(thread, pendingTurn, pollObject);
          if (recoveredSnapshot !== null) {
            this.emitTurnUpdate(thread, pendingTurn, recoveredSnapshot);
            return await this.finalizeTerminalTurnSnapshot(thread, pendingTurn, recoveredSnapshot);
          }
          const failureMessage: string = this.turnPollFailureMessage(pollObject);
          this.logInfo(`turnPoll failure detail thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} message=${failureMessage}`);
          const failedSnapshot: CodexTurnResult = this.buildTurnFailureSnapshot(
            thread,
            pendingTurn.turnId,
            this.turnPollFailureTitle(pollObject),
            failureMessage
          );
          this.emitTurnUpdate(thread, pendingTurn, failedSnapshot);
          thread.activeTurn = null;
          pendingTurn.resolveCompletion(failedSnapshot);
          // 断线检测：轮询失败若因连接丢失，触发自动重连。
          if (this.markConnectionLostIfError(failureMessage)) {
            this.reconnectInBackground();
          }
          return failedSnapshot;
        }
        const nextSnapshot: CodexTurnResult = this.applyTurnPollResult(thread, pendingTurn.turnId, pollObject);
        this.emitTurnUpdate(thread, pendingTurn, nextSnapshot);
        if (nextSnapshot.status !== 'inProgress') {
          return await this.finalizeTerminalTurnSnapshot(thread, pendingTurn, nextSnapshot);
        }
      }
      // 注意：推理期间不发起 thread_read 对账——thread_read 是 app-server RPC，
      // 推理时 app-server 不响应会导致 await 阻塞轮询（最长 15s 超时），
      // 累积后触发 5 分钟轮询超时。turn 完成靠 turnEvents/turnPoll 感知，
      // 轮询失败时的 recoverTurnFromThreadHistory 承担兜底对账。
      await new Promise<void>((resolve) => setTimeout(resolve, TURN_POLL_INTERVAL_MS));
    }
  }

  private shouldRecoverFromPollPayload(payload: Record<string, Object>): boolean {
    return this.isNativePollFailurePayload(payload) || !this.hasTurnPollStatus(payload);
  }

  private isNativePollFailurePayload(payload: Record<string, Object>): boolean {
    return payload['nativePollFailure'] === true;
  }

  private hasTurnPollStatus(payload: Record<string, Object>): boolean {
    return typeof payload['status'] === 'string' && (payload['status'] as string).trim().length > 0;
  }

  private turnPollLogSummary(payload: Record<string, Object>): string {
    const status: string = typeof payload['status'] === 'string' ? (payload['status'] as string) : 'missing';
    const messages: Object[] = Array.isArray(payload['messages']) ? (payload['messages'] as Object[]) : [];
    const diffLines: Object[] = Array.isArray(payload['diffLines']) ? (payload['diffLines'] as Object[]) : [];
    let lastMessage: string = 'none';
    if (messages.length > 0) {
      const last: Record<string, Object> = messages[messages.length - 1] as Record<string, Object>;
      const id: string = typeof last['messageId'] === 'string' ? (last['messageId'] as string) : '';
      const role: string = typeof last['role'] === 'string' ? (last['role'] as string) : '';
      const type: string = typeof last['itemType'] === 'string' ? (last['itemType'] as string) : '';
      const content: string = typeof last['content'] === 'string' ? (last['content'] as string) : '';
      lastMessage = `${id}:${role}:${type}:${content.length}`;
    }
    return `status=${status} messages=${messages.length} last=${lastMessage} diffLines=${diffLines.length}`;
  }

  private turnPollFailureTitle(payload: Record<string, Object>): string {
    const title: string = typeof payload['summaryTitle'] === 'string' ? (payload['summaryTitle'] as string).trim() : '';
    return title.length > 0 ? title : '轮询失败';
  }

  private turnPollFailureMessage(payload: Record<string, Object>): string {
    const summaryRaw: Object[] = Array.isArray(payload['summary']) ? (payload['summary'] as Object[]) : [];
    if (summaryRaw.length > 0) {
      const first: Object = summaryRaw[0];
      const firstText: string = typeof first === 'string' ? (first as string).trim() : JSON.stringify(first);
      if (firstText.length > 0) {
        return firstText;
      }
    }
    if (!this.hasTurnPollStatus(payload)) {
      return 'turn/poll 未返回有效状态，已结束当前轮次。';
    }
    return 'turn/poll 失败，已结束当前轮次。';
  }

  private buildTurnFailureSnapshot(thread: CodexThreadRecord, turnId: string, title: string, message: string): CodexTurnResult {
    thread.lastTurnStatus = 'failed';
    thread.updatedAt = currentThreadTimestamp();
    thread.summaryTitle = title;
    thread.summaryPoints = [message];
    return this.snapshotForThread(thread, 'failed', turnId);
  }

  private buildRecoveredTurnResult(snapshot: ThreadReadSnapshotPayload, turnId: string, status: CodexTurnStatus): CodexTurnResult {
    return new CodexTurnResult(
      snapshot.thread.remoteThreadId,
      turnId,
      status,
      snapshot.thread.messages.map((message: CodexChatMessage) => this.cloneMessage(message)),
      snapshot.thread.diffLines.map((line: CodexDiffLine) => this.cloneDiffLine(line)),
      snapshot.thread.summaryTitle,
      [...snapshot.thread.summaryPoints],
      snapshot.thread.changedFiles,
      snapshot.thread.diffStat,
      snapshot.thread.tokenUsage,
      this.cloneContextManagement(snapshot.thread.contextManagement),
      snapshot.thread.modelAutoCompactTokenLimit,
      snapshot.thread.effectiveAutoCompactTokenLimit,
      snapshot.thread.autoCompactCurrentTotalTokens,
      snapshot.thread.autoCompactWillCheckBeforeNextTurn,
      snapshot.thread.autoCompactWouldWaitForFollowUp,
      snapshot.thread.autoCompactEnabled,
      snapshot.thread.remainingToAutoCompact,
      snapshot.thread.autoCompactNearThreshold
    );
  }

  private async recoverTurnFromThreadHistory(
    thread: CodexThreadRecord,
    pendingTurn: PendingTurnState,
    payload: Record<string, Object>
  ): Promise<CodexTurnResult | null> {
    if (thread.remoteThreadId.trim().length === 0) {
      return null;
    }
    try {
      const snapshot: ThreadReadSnapshotPayload = await this.readThreadSnapshot(thread.remoteThreadId);
      const recoveredStatus: CodexTurnStatus = this.mapTurnStatus(snapshot.lastTurnStatus);
      if (recoveredStatus === 'inProgress') {
        this.logInfo(
          `threadRead turn recovery skipped thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} reason=stillInProgress ${this.turnPollLogSummary(payload)}`
        );
        return null;
      }
      thread.activeTurn = pendingTurn;
      this.logInfo(
        `threadRead turn recovery thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} recoveredStatus=${recoveredStatus}`
      );
      return this.buildRecoveredTurnResult(snapshot, pendingTurn.turnId, recoveredStatus);
    } catch (err) {
      const errorText: string = err instanceof Error ? err.message : JSON.stringify(err);
      this.logInfo(`threadRead turn recovery failed thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} error=${errorText}`);
      return null;
    }
  }

  private async finalizeTerminalTurnSnapshot(
    thread: CodexThreadRecord,
    pendingTurn: PendingTurnState,
    snapshot: CodexTurnResult
  ): Promise<CodexTurnResult> {
    let finalSnapshot: CodexTurnResult = snapshot;
    if (this.shouldDrainLateTurnUpdates(thread)) {
      finalSnapshot = await this.drainLateTurnUpdates(thread, pendingTurn, finalSnapshot);
    }
    if (this.shouldDrainLateTokenUsage(thread, pendingTurn)) {
      finalSnapshot = await this.drainLateTokenUsage(thread, pendingTurn, finalSnapshot);
    }
    if (this.shouldDrainLateTurnUpdates(thread)) {
      finalSnapshot = await this.recoverDiffFromThreadHistory(thread, pendingTurn, finalSnapshot);
    }
    // AIGC provenance：正常终态统一在此记录生成事件
    this.recordAigcTurn(thread, pendingTurn, finalSnapshot.status);
    thread.activeTurn = null;
    pendingTurn.resolveCompletion(finalSnapshot);
    return finalSnapshot;
  }

  /**
   * AIGC provenance：记录一个 turn 的生成事件（命令 + 文件 diff 归因）。
   * 主动快照 diff 字段（beginLocalTurn 每次清空），取命令缓冲。
   */
  private recordAigcTurn(thread: CodexThreadRecord, pendingTurn: PendingTurnState, status: string): void {
    try {
      const workspaceRoot: string = thread.cwd ?? '';
      if (workspaceRoot.trim().length === 0) {
        return;
      }
      // 合并两个来源的文件变化：
      // 1. Rust diff（thread.diffLines/changedFiles）—— 覆盖 file_writer/apply_patch 工具写的文件
      // 2. turn 前后快照对比 —— 覆盖 shell/脚本生成的文件（echo > file 等），不依赖 Rust diff
      const changedFilePaths: string[] = this.uniqueDiffFilePaths(thread);
      const snapshotChanges: string[] = this.diffAigcBaseline(thread, workspaceRoot);
      const merged: string[] = this.mergeChangedFilePaths(changedFilePaths, snapshotChanges);
      const commands: AigcCommandRecord[] = aigcProvenanceStore.takePendingCommands(
        thread.remoteThreadId,
        pendingTurn.turnId
      );
      const turnRecord: AigcRecordTurnParams = {
        workspaceRoot,
        threadId: thread.remoteThreadId,
        turnId: pendingTurn.turnId,
        status,
        promptTitle: thread.summaryTitle,
        changedFilePaths: merged,
        commands
      };
      aigcProvenanceStore.recordTurn(turnRecord);
    } catch (err) {
      this.logInfo(`recordAigcTurn failed: ${err}`);
    }
  }

  /** AIGC provenance：对比 turn 前后工作区快照，返回新增/修改的文件路径。 */
  private diffAigcBaseline(thread: CodexThreadRecord, workspaceRoot: string): string[] {
    try {
      const afterSnapshot: Map<string, string> = aigcProvenanceStore.snapshotWorkspace(workspaceRoot);
      return aigcProvenanceStore.diffWorkspaceSnapshot(thread.aigcBaselineFiles, afterSnapshot);
    } catch (err) {
      this.logInfo(`diffAigcBaseline failed: ${err}`);
      return [];
    }
  }

  /** AIGC provenance：合并两个文件路径列表并去重。 */
  private mergeChangedFilePaths(first: string[], second: string[]): string[] {
    const result: string[] = [];
    const seen: Set<string> = new Set<string>();
    const all: string[] = first.concat(second);
    all.forEach((path: string) => {
      const normalized: string = path.replace(/\\/g, '/');
      if (normalized.length > 0 && normalized !== '.aigc_list.json' && !seen.has(normalized)) {
        seen.add(normalized);
        result.push(normalized);
      }
    });
    return result;
  }

  /** 从 thread.diffLines 去重提取变更文件相对路径；空则回退 changedFiles 逗号串。 */
  private uniqueDiffFilePaths(thread: CodexThreadRecord): string[] {
    const result: string[] = [];
    const seen: Set<string> = new Set<string>();
    if (thread.diffLines.length > 0) {
      thread.diffLines.forEach((line: CodexDiffLine) => {
        const filePath: string = line.filePath ?? '';
        if (filePath.length > 0 && !seen.has(filePath)) {
          seen.add(filePath);
          result.push(filePath);
        }
      });
    }
    if (result.length > 0) {
      return result;
    }
    const changedFilesText: string = thread.changedFiles ?? '';
    if (changedFilesText.length === 0 || changedFilesText === NO_FILE_CHANGES_TEXT || changedFilesText === UNRECOGNIZED_CHANGED_FILES_TEXT) {
      return [];
    }
    changedFilesText.split(',').forEach((part: string) => {
      const trimmed: string = part.trim();
      if (trimmed.length > 0 && !seen.has(trimmed)) {
        seen.add(trimmed);
        result.push(trimmed);
      }
    });
    return result;
  }

  private shouldDrainLateTurnUpdates(thread: CodexThreadRecord): boolean {
    return thread.diffLines.length === 0 || thread.diffStat === '+0 -0';
  }

  private shouldDrainLateTokenUsage(thread: CodexThreadRecord, pendingTurn: PendingTurnState): boolean {
    if (thread.tokenUsage === null) {
      return true;
    }
    if (pendingTurn.startingTotalTokens < 0) {
      return false;
    }
    return thread.tokenUsage.total.totalTokens <= pendingTurn.startingTotalTokens;
  }

  private async drainLateTurnUpdates(
    thread: CodexThreadRecord,
    pendingTurn: PendingTurnState,
    snapshot: CodexTurnResult
  ): Promise<CodexTurnResult> {
    let currentSnapshot: CodexTurnResult = snapshot;
    for (let attempt: number = 0; attempt < TERMINAL_TURN_DRAIN_ATTEMPTS; attempt += 1) {
      await new Promise<void>((resolve) => setTimeout(resolve, TERMINAL_TURN_DRAIN_INTERVAL_MS));
      const pollObject: Record<string, Object> = parseJsonText(
        await turnPollAsyncNative(thread.remoteThreadId, pendingTurn.turnId),
        new TurnPollResponsePayload() as Object
      ) as Record<string, Object>;
      this.logInfo(`turnPoll drain thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} ${this.turnPollLogSummary(pollObject)}`);
      if (this.shouldRecoverFromPollPayload(pollObject)) {
        this.logInfo(`turnPoll drain skipped invalid payload thread=${thread.remoteThreadId} turn=${pendingTurn.turnId}`);
        break;
      }
      currentSnapshot = this.applyTurnPollResult(thread, pendingTurn.turnId, pollObject);
      this.logInfo(`turnPoll drain applied thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} status=${currentSnapshot.status} messageCount=${thread.messages.length}`);
      this.emitTurnUpdate(thread, pendingTurn, currentSnapshot);
      if (!this.shouldDrainLateTurnUpdates(thread)) {
        break;
      }
    }
    return currentSnapshot;
  }

  private async drainLateTokenUsage(
    thread: CodexThreadRecord,
    pendingTurn: PendingTurnState,
    snapshot: CodexTurnResult
  ): Promise<CodexTurnResult> {
    let currentSnapshot: CodexTurnResult = snapshot;
    for (let attempt: number = 0; attempt < TERMINAL_TURN_DRAIN_ATTEMPTS; attempt += 1) {
      await new Promise<void>((resolve) => setTimeout(resolve, TERMINAL_TURN_DRAIN_INTERVAL_MS));
      const pollObject: Record<string, Object> = parseJsonText(
        await turnPollAsyncNative(thread.remoteThreadId, pendingTurn.turnId),
        new TurnPollResponsePayload() as Object
      ) as Record<string, Object>;
      this.logInfo(`turnPoll tokenUsage drain thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} ${this.turnPollLogSummary(pollObject)}`);
      if (this.shouldRecoverFromPollPayload(pollObject)) {
        this.logInfo(`turnPoll tokenUsage drain skipped invalid payload thread=${thread.remoteThreadId} turn=${pendingTurn.turnId}`);
        break;
      }
      currentSnapshot = this.applyTurnPollResult(thread, pendingTurn.turnId, pollObject);
      this.logInfo(`turnPoll tokenUsage drain applied thread=${thread.remoteThreadId} turn=${pendingTurn.turnId} status=${currentSnapshot.status} totalTokens=${thread.tokenUsage?.total.totalTokens ?? -1}`);
      this.emitTurnUpdate(thread, pendingTurn, currentSnapshot);
      if (!this.shouldDrainLateTokenUsage(thread, pendingTurn)) {
        break;
      }
    }
    return currentSnapshot;
  }

  private async recoverDiffFromThreadHistory(
    thread: CodexThreadRecord,
    pendingTurn: PendingTurnState,
    snapshot: CodexTurnResult
  ): Promise<CodexTurnResult> {
    if (thread.remoteThreadId.trim().length === 0) {
      return snapshot;
    }
    let currentSnapshot: CodexTurnResult = snapshot;
    for (let attempt: number = 0; attempt < TERMINAL_TURN_DRAIN_ATTEMPTS; attempt += 1) {
      try {
        const recovered: CodexTurnResult = await this.loadThreadHistory(thread.remoteThreadId);
        currentSnapshot = new CodexTurnResult(
          recovered.threadId,
          pendingTurn.turnId,
          recovered.status,
          recovered.messages,
          recovered.diffLines,
          recovered.summaryTitle,
          recovered.summaryPoints,
          recovered.changedFiles,
          recovered.diffStat,
          recovered.tokenUsage,
          recovered.contextManagement,
          recovered.modelAutoCompactTokenLimit,
          recovered.effectiveAutoCompactTokenLimit,
          recovered.autoCompactCurrentTotalTokens,
          recovered.autoCompactWillCheckBeforeNextTurn,
          recovered.autoCompactWouldWaitForFollowUp,
          recovered.autoCompactEnabled,
          recovered.remainingToAutoCompact,
          recovered.autoCompactNearThreshold
        );
        this.logInfo(
          `threadRead diff recovery thread=${thread.remoteThreadId} attempt=${attempt + 1} diffStat=${currentSnapshot.diffStat}`
        );
        this.emitTurnUpdate(thread, pendingTurn, currentSnapshot);
        if (!this.shouldDrainLateTurnUpdates(thread)) {
          return currentSnapshot;
        }
      } catch (err) {
        const errorText: string = err instanceof Error ? err.message : JSON.stringify(err);
        this.logInfo(`threadRead diff recovery failed thread=${thread.remoteThreadId} attempt=${attempt + 1} error=${errorText}`);
      }
      if (attempt + 1 < TERMINAL_TURN_DRAIN_ATTEMPTS) {
        await new Promise<void>((resolve) => setTimeout(resolve, TERMINAL_TURN_DRAIN_INTERVAL_MS));
      }
    }
    return currentSnapshot;
  }

  private applyTurnEventBatch(thread: CodexThreadRecord, turnId: string, events: Object[]): CodexTurnResult {
    for (let index: number = 0; index < events.length; index += 1) {
      const event: Record<string, Object> = events[index] as Record<string, Object>;
      const kind: string = typeof event['kind'] === 'string' ? (event['kind'] as string) : '';
      if (kind === 'status') {
        const statusRaw: string = typeof event['status'] === 'string' ? (event['status'] as string) : `${thread.lastTurnStatus}`;
        const summaryTitleRaw: string = typeof event['summaryTitle'] === 'string'
          ? (event['summaryTitle'] as string)
          : (typeof event['summary_title'] === 'string' ? (event['summary_title'] as string) : '');
        thread.lastTurnStatus = this.mapTurnStatus(statusRaw);
        if (summaryTitleRaw.trim().length > 0) {
          thread.summaryTitle = summaryTitleRaw;
        }
        continue;
      }
      if (kind === 'summaryLine') {
        const line: string = typeof event['line'] === 'string' ? (event['line'] as string).trim() : '';
        if (line.length > 0) {
          const previousLine: string = thread.summaryPoints.length > 0 ? thread.summaryPoints[thread.summaryPoints.length - 1] : '';
          if (previousLine !== line) {
            thread.summaryPoints = [...thread.summaryPoints, line];
            if (thread.summaryPoints.length > 12) {
              thread.summaryPoints = thread.summaryPoints.slice(thread.summaryPoints.length - 12);
            }
          }
        }
        continue;
      }
      if (kind === 'messageStarted') {
        const message: CodexChatMessage | null = this.codexMessageFromEventPayload(event['message']);
        if (message !== null) {
          this.upsertMessageFromEvent(thread, message, false);
        }
        continue;
      }
      if (kind === 'messageDelta') {
        const messageId: string = typeof event['messageId'] === 'string' ? (event['messageId'] as string) : '';
        const delta: string = typeof event['delta'] === 'string' ? (event['delta'] as string) : '';
        if (messageId.trim().length > 0 && delta.length > 0) {
          this.appendMessageDelta(thread, messageId, delta);
        }
        continue;
      }
      if (kind === 'messageReplaced') {
        const message: CodexChatMessage | null = this.codexMessageFromEventPayload(event['message']);
        if (message !== null) {
          this.upsertMessageFromEvent(thread, message, true);
        }
        continue;
      }
      if (kind === 'messageSnapshot') {
        const messagesRaw: Object[] = Array.isArray(event['messages']) ? (event['messages'] as Object[]) : [];
        thread.messages = this.mergeThreadMessages(thread.messages, this.messagesFromPayload(messagesRaw));
        continue;
      }
      if (kind === 'diffSnapshot') {
        const diffText: string = typeof event['diff'] === 'string' ? (event['diff'] as string) : '';
        if (diffText.trim().length > 0) {
          const parsedDiff: ParsedDiff = this.parseUnifiedDiff(diffText);
          thread.diffLines = parsedDiff.lines;
          thread.diffStat = parsedDiff.diffStat;
          thread.changedFiles = this.normalizeChangedFilesText(parsedDiff.changedFiles, true);
        }
        continue;
      }
      if (kind === 'tokenUsage') {
        const tokenUsagePayload: Object | undefined = event['tokenUsage'] !== undefined
          ? (event['tokenUsage'] as Object)
          : (event['token_usage'] as Object | undefined);
        this.applyTokenUsagePayload(thread, tokenUsagePayload);
      }
    }
    thread.lastTurnId = turnId;
    thread.updatedAt = currentThreadTimestamp();
    return this.snapshotForThread(thread, thread.lastTurnStatus, turnId);
  }

  private applyTurnPollResult(thread: CodexThreadRecord, turnId: string, payload: Record<string, Object>): CodexTurnResult {
    const hasStatus: boolean = this.hasTurnPollStatus(payload);
    if (!hasStatus) {
      this.logInfo(`turnPoll empty status payload thread=${thread.remoteThreadId} turn=${turnId} ${this.turnPollLogSummary(payload)}`);
    }
    const statusRaw: string = hasStatus ? (payload['status'] as string) : 'failed';
    const status: CodexTurnStatus = this.mapTurnStatus(statusRaw);
    const previousDiffStat: string = thread.diffStat;
    const previousChangedFiles: string = thread.changedFiles;
    const previousDiffLineCount: number = thread.diffLines.length;
    const messages: Object[] = Array.isArray(payload['messages']) ? (payload['messages'] as Object[]) : [];
    if (messages.length > 0) {
      const nextMessages: CodexChatMessage[] = this.messagesFromPayload(messages);
      thread.messages = this.mergeThreadMessages(thread.messages, nextMessages);
    }
    const diffText: string = typeof payload['diff'] === 'string' ? (payload['diff'] as string) : '';
    if (diffText.trim().length > 0) {
      const parsed: ParsedDiff = this.parseUnifiedDiff(diffText);
      thread.diffLines = parsed.lines;
      thread.diffStat = parsed.diffStat;
      thread.changedFiles = parsed.changedFiles;
      if (
        thread.diffStat !== previousDiffStat ||
        thread.changedFiles !== previousChangedFiles ||
        thread.diffLines.length !== previousDiffLineCount
      ) {
        thread.diffUpdateCount += 1;
        this.logInfo(
          `turnDiffApplied thread=${thread.remoteThreadId} turn=${turnId} diffStat=${thread.diffStat} changedFiles=${thread.changedFiles} updates=${thread.diffUpdateCount}`
        );
      }
    }
    thread.changedFiles = this.normalizeChangedFilesText(thread.changedFiles, diffText.trim().length > 0);
    const summaryRaw: Object[] = Array.isArray(payload['summary']) ? (payload['summary'] as Object[]) : [];
    const summaryPoints: string[] = summaryRaw.map((item: Object) => typeof item === 'string' ? (item as string) : JSON.stringify(item));
    thread.summaryTitle = typeof payload['summaryTitle'] === 'string'
      ? (payload['summaryTitle'] as string)
      : (status === 'completed' ? '本轮已完成' : (status === 'failed' ? '本轮失败' : '执行中'));
    thread.summaryPoints = summaryPoints.length > 0
      ? summaryPoints
      : [status === 'completed' ? '本轮执行已结束。' : (status === 'failed' ? '未收到有效轮询结果。' : '等待更多轮询结果。')];
    thread.lastTurnId = turnId;
    this.applyTokenUsagePayload(thread, payload['tokenUsage']);
    this.applyContextManagementPayload(thread, payload['contextManagement']);
    this.applyAutoCompactConfigPayload(thread, payload);
    thread.lastTurnStatus = status;
    thread.updatedAt = currentThreadTimestamp();
    return this.snapshotForThread(thread, status, turnId);
  }

  private mergeThreadMessages(existing: CodexChatMessage[], incoming: CodexChatMessage[]): CodexChatMessage[] {
    if (existing.length === 0) {
      return incoming.map((message: CodexChatMessage) => this.cloneMessage(message));
    }
    const merged: CodexChatMessage[] = existing.map((message: CodexChatMessage) => this.cloneMessage(message));
    // O(N) 精确定位：一次构建 messageId→index，避免逐条全表线性扫描（历史长时 O(N²)）。
    const messageIndex: Map<string, number> = new Map<string, number>();
    for (let index: number = 0; index < merged.length; index += 1) {
      const messageId: string = merged[index].messageId;
      if (!messageIndex.has(messageId)) {
        messageIndex.set(messageId, index);
      }
    }
    for (const message of incoming) {
      const exactIndex: number | undefined = messageIndex.get(message.messageId);
      if (exactIndex !== undefined) {
        merged[exactIndex] = this.mergeThreadMessage(merged[exactIndex], message);
      } else {
        const aliasIndex: number = this.findMergeThreadMessageAliasIndex(merged, message);
        if (aliasIndex >= 0) {
          merged[aliasIndex] = this.mergeThreadMessage(merged[aliasIndex], message);
        } else {
          merged.push(this.cloneMessage(message));
          messageIndex.set(message.messageId, merged.length - 1);
        }
      }
    }
    for (let index: number = 0; index < merged.length; index += 1) {
      const current: CodexChatMessage = merged[index];
      merged[index] = new CodexChatMessage(
        current.messageId,
        index + 1,
        current.author,
        current.role,
        current.content,
        current.timestamp,
        current.itemType,
        current.status,
        current.metadata
      );
    }
    return merged;
  }

  /** 仅精确 id 未命中时的 alias 兜底（id 前缀漂移），仍为线性，但只对个别漏网消息触发。 */
  private findMergeThreadMessageAliasIndex(messages: CodexChatMessage[], incoming: CodexChatMessage): number {
    for (let index: number = 0; index < messages.length; index += 1) {
      if (messages[index].messageId === incoming.messageId) {
        continue;
      }
      if (this.isSameThreadMessageAlias(messages[index], incoming)) {
        return index;
      }
    }
    return -1;
  }

  private isSameThreadMessageAlias(left: CodexChatMessage, right: CodexChatMessage): boolean {
    if (left.role !== right.role) {
      return false;
    }
    const leftHasTurnPrefix: boolean = left.messageId.indexOf(':') >= 0;
    const rightHasTurnPrefix: boolean = right.messageId.indexOf(':') >= 0;
    if (!leftHasTurnPrefix && !rightHasTurnPrefix) {
      return false;
    }
    if (this.messageItemAlias(left.messageId) !== this.messageItemAlias(right.messageId)) {
      return false;
    }
    return this.isMergeCompatibleMessageContent(left.content, right.content);
  }

  private messageItemAlias(messageId: string): string {
    const separatorIndex: number = messageId.lastIndexOf(':');
    return separatorIndex >= 0 ? messageId.substring(separatorIndex + 1) : messageId;
  }

  private isMergeCompatibleMessageContent(left: string, right: string): boolean {
    if (left.trim().length === 0 || right.trim().length === 0) {
      return true;
    }
    if (left.indexOf(right) >= 0 || right.indexOf(left) >= 0) {
      return true;
    }
    return this.messageContentOverlapSize(left, right) > 0 || this.messageContentOverlapSize(right, left) > 0;
  }

  private mergeThreadMessage(existing: CodexChatMessage, incoming: CodexChatMessage): CodexChatMessage {
    return new CodexChatMessage(
      existing.messageId,
      existing.sequence,
      incoming.author.trim().length > 0 ? incoming.author : existing.author,
      incoming.role,
      this.mergeThreadMessageContent(existing.content, incoming.content),
      existing.timestamp.trim().length > 0 ? existing.timestamp : incoming.timestamp,
      incoming.itemType ?? existing.itemType,
      incoming.status ?? existing.status,
      incoming.metadata ?? existing.metadata
    );
  }

  private mergeThreadMessageContent(existingContent: string, incomingContent: string): string {
    if (existingContent.length === 0 || incomingContent.startsWith(existingContent)) {
      return incomingContent;
    }
    if (incomingContent.length === 0 || existingContent.indexOf(incomingContent) >= 0) {
      return existingContent;
    }
    const overlapSize: number = this.messageContentOverlapSize(existingContent, incomingContent);
    if (overlapSize > 0) {
      return `${existingContent}${incomingContent.substring(overlapSize)}`;
    }
    return incomingContent.length >= existingContent.length ? incomingContent : existingContent;
  }

  private messageContentOverlapSize(left: string, right: string): number {
    const maxOverlap: number = Math.min(left.length, right.length);
    for (let size: number = maxOverlap; size > 0; size -= 1) {
      if (left.endsWith(right.substring(0, size))) {
        return size;
      }
    }
    return 0;
  }

  private buildCollaborationModePayload(mode: CollaborationModeOption | null, fallbackModel?: string, fallbackEffort?: string): CollaborationModePayload | undefined {
    if (mode === null) {
      return undefined;
    }
    const payload: CollaborationModePayload = new CollaborationModePayload();
    payload.name = mode.name;
    payload.mode = mode.mode;
    payload.model = mode.model !== undefined ? mode.model : fallbackModel;
    if (mode.reasoningEffort !== undefined && mode.reasoningEffort !== null) {
      payload.reasoningEffort = mode.reasoningEffort;
    } else if (fallbackEffort !== undefined) {
      payload.reasoningEffort = fallbackEffort;
    }
    return payload;
  }

  private buildCollaborationMode(payload: Record<string, Object>): CollaborationModeOption {
    const reasoningEffortRaw = payload['reasoning_effort'];
    let reasoningEffort: string | null | undefined = undefined;
    if (typeof reasoningEffortRaw === 'string') {
      reasoningEffort = reasoningEffortRaw as string;
    } else if (reasoningEffortRaw === null) {
      reasoningEffort = null;
    }
    const modeRaw: string = typeof payload['mode'] === 'string' ? (payload['mode'] as string) : 'default';
    return new CollaborationModeOption(
      typeof payload['name'] === 'string' ? (payload['name'] as string) : modeRaw,
      modeRaw === 'plan' ? 'plan' : 'default',
      typeof payload['model'] === 'string' ? (payload['model'] as string) : undefined,
      reasoningEffort
    );
  }

  private buildRequestUserInputFromNative(payload: Record<string, Object>): CodexRequestUserInput | null {
    const requestId: string | number = typeof payload['requestId'] === 'string' || typeof payload['requestId'] === 'number'
      ? payload['requestId'] as string | number
      : `request-user-input-${Date.now()}`;
    const questionsRaw: Object[] = Array.isArray(payload['questions'])
      ? (payload['questions'] as Object[])
      : this.questionsFromDetail(typeof payload['detail'] === 'string' ? (payload['detail'] as string) : '');
    const questions: CodexRequestUserInputQuestion[] = questionsRaw.map((item: Object, index: number) => {
      const question = item as Record<string, Object>;
      const optionsRaw: Object[] = Array.isArray(question['options']) ? (question['options'] as Object[]) : [];
      const options: CodexRequestUserInputOption[] = optionsRaw.map((option: Object) => {
        const optionRecord = option as Record<string, Object>;
        return new CodexRequestUserInputOption(
          typeof optionRecord['label'] === 'string' ? (optionRecord['label'] as string) : '',
          typeof optionRecord['description'] === 'string' ? (optionRecord['description'] as string) : ''
        );
      });
      return new CodexRequestUserInputQuestion(
        typeof question['id'] === 'string' ? (question['id'] as string) : `question-${index + 1}`,
        typeof question['header'] === 'string' ? (question['header'] as string) : `Question ${index + 1}`,
        typeof question['question'] === 'string' ? (question['question'] as string) : '',
        question['isOther'] === true || question['is_other'] === true,
        question['isSecret'] === true || question['is_secret'] === true,
        options
      );
    });
    return new CodexRequestUserInput(
      requestId,
      typeof payload['title'] === 'string' ? (payload['title'] as string) : 'Need user input',
      typeof payload['detail'] === 'string' ? (payload['detail'] as string) : '',
      typeof payload['threadId'] === 'string' ? (payload['threadId'] as string) : '',
      typeof payload['turnId'] === 'string' ? (payload['turnId'] as string) : '',
      typeof payload['itemId'] === 'string' ? (payload['itemId'] as string) : '',
      questions
    );
  }

  private questionsFromDetail(detail: string): Object[] {
    const parsed: Object | null = safeJsonParse(detail);
    if (parsed === null) {
      return [];
    }
    const record = parsed as Record<string, Object>;
    return Array.isArray(record['questions']) ? (record['questions'] as Object[]) : [];
  }

  private buildApprovalFromNative(payload: Record<string, Object>): CodexApprovalRequest | null {
    const kindRaw: string = typeof payload['kind'] === 'string' ? (payload['kind'] as string) : '';
    if (kindRaw.length === 0) {
      return null;
    }
    const kind: CodexApprovalKind = kindRaw === 'fileChange' || kindRaw === 'permissions' || kindRaw === 'mcpToolApproval' ? kindRaw : 'command';
    const approval = new CodexApprovalRequest(
      typeof payload['requestId'] === 'string' || typeof payload['requestId'] === 'number' ? payload['requestId'] as string | number : `approval-${Date.now()}`,
      kind,
      typeof payload['title'] === 'string' ? (payload['title'] as string) : '需要审批',
      typeof payload['detail'] === 'string' ? (payload['detail'] as string) : '',
      typeof payload['threadId'] === 'string' ? (payload['threadId'] as string) : '',
      typeof payload['turnId'] === 'string' ? (payload['turnId'] as string) : '',
      typeof payload['itemId'] === 'string' ? (payload['itemId'] as string) : ''
    );
    approval.grantedPermissions = payload['grantedPermissions'];
    return approval;
  }

  private applyAccountState(payload: GetAccountResponsePayload): void {
    this.requiresOpenAIAuth = payload.requiresOpenaiAuth !== false;
    if (!this.requiresOpenAIAuth) {
      this.authMode = 'unknown';
      this.authStatusText = '当前模型提供方不要求 OpenAI 认证';
      this.planTypeText = '';
      this.notifyListeners();
      return;
    }
    const account: AccountPayload | undefined = payload.account;
    if (account === undefined) {
      this.authMode = 'none';
      this.authStatusText = '未登录';
      this.planTypeText = '';
      this.notifyListeners();
      return;
    }
    this.authMode = this.normalizeAuthMode(account.type);
    if (this.authMode === 'chatgpt' || this.authMode === 'chatgptAuthTokens') {
      this.authStatusText = account.email ?? '已登录 ChatGPT';
    } else if (this.authMode === 'apiKey') {
      this.authStatusText = '已使用 API Key 登录';
    } else {
      this.authStatusText = '已登录';
    }
    this.planTypeText = account.planType ?? this.planTypeText;
    this.notifyListeners();
  }

  private normalizeAuthMode(rawMode?: string): CodexAuthMode {
    if (rawMode === 'apiKey') {
      return 'apiKey';
    }
    if (rawMode === 'chatgpt') {
      return 'chatgpt';
    }
    if (rawMode === 'chatgptAuthTokens') {
      return 'chatgptAuthTokens';
    }
    if (rawMode === undefined || rawMode.length === 0) {
      return 'none';
    }
    return 'unknown';
  }

  private mapTurnStatus(status: string): CodexTurnStatus {
    if (status === 'completed') {
      return 'completed';
    }
    if (status === 'failed') {
      return 'failed';
    }
    if (status === 'interrupted') {
      return 'interrupted';
    }
    return 'inProgress';
  }

  private mapMessageRole(role: string): CodexMessageRole {
    if (role === 'user' || role === 'system') {
      return role;
    }
    if (role === 'reasoning' || role === 'command' || role === 'tool' || role === 'file' || role === 'search' || role === 'plan' || role === 'image' || role === 'hook' || role === 'review') {
      return role;
    }
    return 'assistant';
  }

  private mapMessageAuthor(role: CodexMessageRole, author: string): string {
    if (role === 'user') {
      return author.trim().length > 0 ? author : '你';
    }
    if (role === 'system') {
      return author.trim().length > 0 ? author : '系统';
    }
    return 'ArkPilot';
  }
  private normalizeChangedFilesText(value: string, hasDiff: boolean): string {
    const trimmed: string = value.trim();
    if (trimmed.length === 0 || this.isMojibakeText(trimmed)) {
      return hasDiff ? UNRECOGNIZED_CHANGED_FILES_TEXT : NO_FILE_CHANGES_TEXT;
    }
    return trimmed;
  }

  private isMojibakeText(value: string): boolean {
    return value.indexOf('Ã') >= 0 || value.indexOf('å°') >= 0 || value.indexOf('灏') >= 0;
  }

  // 注意：每轮 O(N) 克隆一次全量消息是 CodexTurnResult 携带完整列表的固有下限（线性，可接受）。
  private cachedMessagesForThread(thread: CodexThreadRecord): CodexChatMessage[] {
    const signature: string = this.messagesSignature(thread);
    if (signature === this.lastSnapshotMessagesSignature && this.cachedSnapshotMessages.length === thread.messages.length) {
      return this.cachedSnapshotMessages;
    }
    this.cachedSnapshotMessages = thread.messages.map((message: CodexChatMessage) => this.cloneMessage(message));
    this.lastSnapshotMessagesSignature = signature;
    return this.cachedSnapshotMessages;
  }

  private messagesSignature(thread: CodexThreadRecord): string {
    const count: number = thread.messages.length;
    let signature: string = `${count}`;
    for (let index: number = 0; index < count; index += 1) {
      const message: CodexChatMessage = thread.messages[index];
      signature += `|${message.messageId}|${message.content.length}|${message.status ?? ''}|${message.sequence}|${message.role}`;
    }
    return signature;
  }

  private snapshotForThread(thread: CodexThreadRecord, status: CodexTurnStatus, turnId: string = ''): CodexTurnResult {
    return new CodexTurnResult(
      thread.remoteThreadId,
      turnId,
      status,
      this.cachedMessagesForThread(thread),
      thread.diffLines.map((line: CodexDiffLine) => this.cloneDiffLine(line)),
      thread.summaryTitle,
      [...thread.summaryPoints],
      thread.changedFiles,
      thread.diffStat,
      thread.tokenUsage,
      this.cloneContextManagement(thread.contextManagement),
      thread.modelAutoCompactTokenLimit,
      thread.effectiveAutoCompactTokenLimit,
      thread.autoCompactCurrentTotalTokens,
      thread.autoCompactWillCheckBeforeNextTurn,
      thread.autoCompactWouldWaitForFollowUp,
      thread.autoCompactEnabled,
      thread.remainingToAutoCompact,
      thread.autoCompactNearThreshold
    );
  }

  private emitTurnUpdate(thread: CodexThreadRecord, pendingTurn: PendingTurnState | null, result: CodexTurnResult): void {
    if (pendingTurn !== null && pendingTurn.listener !== undefined) {
      pendingTurn.listener(result);
    }
    if (thread.activeTurn !== null && thread.activeTurn !== pendingTurn && thread.activeTurn.listener !== undefined) {
      thread.activeTurn.listener(result);
    }
  }

  private upsertMessage(thread: CodexThreadRecord, messageId: string, author: string, role: CodexMessageRole, content: string, timestamp: string): void {
    const index: number = this.findMessageIndex(thread, messageId);
    if (index >= 0) {
      const current: CodexChatMessage = thread.messages[index];
      thread.messages[index] = new CodexChatMessage(current.messageId, current.sequence, author, role, content, timestamp);
      return;
    }
    thread.messages.push(new CodexChatMessage(messageId, thread.messages.length + 1, author, role, content, timestamp));
  }

  private findMessageIndex(thread: CodexThreadRecord, messageId: string): number {
    for (let index: number = 0; index < thread.messages.length; index += 1) {
      if (thread.messages[index].messageId === messageId) {
        return index;
      }
    }
    return -1;
  }

  /**
   * 增量事件 messageDelta：按 messageId 追加内容（O(1) 精确定位，避免全量合并）。
   * native 保证任何 delta 前必先有 MessageStarted/MessageReplaced，未知 id 是防御性兜底。
   */
  private appendMessageDelta(thread: CodexThreadRecord, messageId: string, delta: string): void {
    const trimmedMessageId: string = messageId.trim();
    if (trimmedMessageId.length === 0 || delta.length === 0) {
      return;
    }
    const index: number = this.findMessageIndex(thread, trimmedMessageId);
    if (index >= 0) {
      const existing: CodexChatMessage = thread.messages[index];
      const content: string = existing.content.trim() === REASONING_PLACEHOLDER_TEXT
        ? delta
        : `${existing.content}${delta}`;
      thread.messages[index] = new CodexChatMessage(
        existing.messageId,
        existing.sequence,
        existing.author,
        existing.role,
        content,
        existing.timestamp,
        existing.itemType,
        existing.status,
        existing.metadata
      );
      return;
    }
    // 精确 id 未命中：仅对助手/推理消息按 item alias 兜底（避免误匹配 user/system）。
    const targetAlias: string = this.messageItemAlias(trimmedMessageId);
    for (let i: number = 0; i < thread.messages.length; i += 1) {
      const candidate: CodexChatMessage = thread.messages[i];
      if (candidate.role !== 'assistant' && candidate.role !== 'reasoning') {
        continue;
      }
      if (this.messageItemAlias(candidate.messageId) !== targetAlias) {
        continue;
      }
      const content: string = candidate.content.trim() === REASONING_PLACEHOLDER_TEXT
        ? delta
        : `${candidate.content}${delta}`;
      thread.messages[i] = new CodexChatMessage(
        candidate.messageId,
        candidate.sequence,
        candidate.author,
        candidate.role,
        content,
        candidate.timestamp,
        candidate.itemType,
        candidate.status,
        candidate.metadata
      );
      return;
    }
    // 仍未命中：防御性创建助手消息，靠后续 turn_poll 全量/终态快照对账收敛。
    this.logInfo(`messageDelta unknown messageId=${trimmedMessageId} thread=${thread.remoteThreadId} — creating fallback assistant message`);
    thread.messages.push(new CodexChatMessage(
      trimmedMessageId,
      thread.messages.length + 1,
      'ArkPilot',
      'assistant',
      delta,
      currentTimestamp(),
      undefined,
      undefined,
      undefined
    ));
  }

  /**
   * 增量事件 messageStarted / messageReplaced：按 messageId upsert。
   * replace=true 整条替换（保留 sequence 与非空 timestamp）；false 走合并语义。
   */
  private upsertMessageFromEvent(thread: CodexThreadRecord, incoming: CodexChatMessage, replace: boolean): void {
    const index: number = this.findMessageIndex(thread, incoming.messageId);
    if (index >= 0) {
      const existing: CodexChatMessage = thread.messages[index];
      if (replace) {
        thread.messages[index] = new CodexChatMessage(
          existing.messageId,
          existing.sequence,
          incoming.author.trim().length > 0 ? incoming.author : existing.author,
          incoming.role,
          incoming.content,
          existing.timestamp.trim().length > 0 ? existing.timestamp : incoming.timestamp,
          incoming.itemType ?? existing.itemType,
          incoming.status ?? existing.status,
          incoming.metadata ?? existing.metadata
        );
      } else {
        thread.messages[index] = this.mergeThreadMessage(existing, incoming);
      }
      return;
    }
    // alias 兜底：处理 id 前缀漂移。
    for (let i: number = 0; i < thread.messages.length; i += 1) {
      const candidate: CodexChatMessage = thread.messages[i];
      if (this.isSameThreadMessageAlias(candidate, incoming)) {
        if (replace) {
          thread.messages[i] = new CodexChatMessage(
            candidate.messageId,
            candidate.sequence,
            incoming.author.trim().length > 0 ? incoming.author : candidate.author,
            incoming.role,
            incoming.content,
            candidate.timestamp.trim().length > 0 ? candidate.timestamp : incoming.timestamp,
            incoming.itemType ?? candidate.itemType,
            incoming.status ?? candidate.status,
            incoming.metadata ?? candidate.metadata
          );
        } else {
          thread.messages[i] = this.mergeThreadMessage(candidate, incoming);
        }
        return;
      }
    }
    thread.messages.push(new CodexChatMessage(
      incoming.messageId,
      thread.messages.length + 1,
      incoming.author,
      incoming.role,
      incoming.content,
      incoming.timestamp,
      incoming.itemType,
      incoming.status,
      incoming.metadata
    ));
  }

  private parseUnifiedDiff(diff: string): ParsedDiff {
    const parsed: ParsedDiff = new ParsedDiff();
    const rawLines: string[] = diff.split('\n');
    const changedFiles: string[] = [];
    let addCount: number = 0;
    let deleteCount: number = 0;
    let oldLineNumber: number = 0;
    let newLineNumber: number = 0;
    let lineSequence: number = 1;
    let currentFilePath: string = '';
    rawLines.forEach((line: string) => {
      if (line.startsWith('diff --git ')) {
        const match: RegExpMatchArray | null = line.match(/ b\/(.+)$/);
        if (match !== null && match.length > 1) {
          currentFilePath = match[1];
          if (changedFiles.indexOf(match[1]) < 0) {
            changedFiles.push(match[1]);
          }
        }
        return;
      }
      if (line.startsWith('+++ b/')) {
        const filePath: string = line.substring(6);
        currentFilePath = filePath;
        if (changedFiles.indexOf(filePath) < 0) {
          changedFiles.push(filePath);
        }
        return;
      }
      if (line.startsWith('@@')) {
        const match: RegExpMatchArray | null = line.match(/@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
        if (match !== null && match.length > 2) {
          oldLineNumber = Number(match[1]);
          newLineNumber = Number(match[2]);
        }
        return;
      }
      if (line.startsWith('+++ ') || line.startsWith('--- ') || line.startsWith('index ')) {
        return;
      }
      if (line.startsWith('+')) {
        parsed.lines.push(new CodexDiffLine(`diff-${lineSequence}`, lineSequence, newLineNumber.toString(), '+', line.substring(1), 'add', currentFilePath));
        lineSequence += 1;
        newLineNumber += 1;
        addCount += 1;
        return;
      }
      if (line.startsWith('-')) {
        parsed.lines.push(new CodexDiffLine(`diff-${lineSequence}`, lineSequence, oldLineNumber.toString(), '-', line.substring(1), 'delete', currentFilePath));
        lineSequence += 1;
        oldLineNumber += 1;
        deleteCount += 1;
        return;
      }
      if (line.startsWith(' ')) {
        parsed.lines.push(new CodexDiffLine(`diff-${lineSequence}`, lineSequence, newLineNumber.toString(), ' ', line.substring(1), 'context', currentFilePath));
        lineSequence += 1;
        oldLineNumber += 1;
        newLineNumber += 1;
      }
    });
    parsed.diffStat = `+${addCount} -${deleteCount}`;
    if (changedFiles.length === 0) {
      parsed.changedFiles = UNRECOGNIZED_CHANGED_FILES_TEXT;
    }
    parsed.changedFiles = changedFiles.length > 0 ? changedFiles.join(', ') : UNRECOGNIZED_CHANGED_FILES_TEXT;
    parsed.changedFiles = changedFiles.length > 0 ? changedFiles.join(', ') : '尚未识别变更文件';
    parsed.changedFiles = changedFiles.length > 0 ? changedFiles.join(', ') : UNRECOGNIZED_CHANGED_FILES_TEXT;
    return parsed;
  }

  private updateConnectionState(connectionState: CodexConnectionState, connectionText: string): void {
    this.connectionState = connectionState;
    this.connectionText = connectionText;
    if (connectionState !== 'connected') {
      this.pendingApproval = null;
      this.pendingRequestUserInput = null;
    }
    this.notifyListeners();
  }

  hasActiveTurn(): boolean {
    let found: boolean = false;
    this.threads.forEach((t: CodexThreadRecord) => {
      if (t.activeTurn !== null) found = true;
    });
    return found;
  }

  private notifyListeners(): void {
    const snapshot: CodexBackendSnapshot = this.snapshot();
    this.listeners.forEach((listener: BackendListener) => {
      listener(snapshot);
    });
  }

  private cloneApproval(approval: CodexApprovalRequest | null): CodexApprovalRequest | null {
    if (approval === null) {
      return null;
    }
    const cloned: CodexApprovalRequest = new CodexApprovalRequest(approval.requestId, approval.kind, approval.title, approval.detail, approval.threadId, approval.turnId, approval.itemId);
    cloned.grantedPermissions = approval.grantedPermissions;
    return cloned;
  }

  private cloneRequestUserInput(request: CodexRequestUserInput | null): CodexRequestUserInput | null {
    if (request === null) {
      return null;
    }
    return new CodexRequestUserInput(
      request.requestId,
      request.title,
      request.detail,
      request.threadId,
      request.turnId,
      request.itemId,
      request.questions.map((question: CodexRequestUserInputQuestion) => this.cloneRequestUserInputQuestion(question))
    );
  }

  private cloneRequestUserInputQuestion(question: CodexRequestUserInputQuestion): CodexRequestUserInputQuestion {
    return new CodexRequestUserInputQuestion(
      question.id,
      question.header,
      question.question,
      question.isOther,
      question.isSecret,
      question.options.map((option: CodexRequestUserInputOption) => new CodexRequestUserInputOption(option.label, option.description))
    );
  }

  private approvalStateEquals(left: CodexApprovalRequest | null, right: CodexApprovalRequest | null): boolean {
    if (left === null || right === null) {
      return left === right;
    }
    return this.approvalIdentityString(left) === this.approvalIdentityString(right);
  }

  private approvalIdentityString(approval: CodexApprovalRequest): string {
    return `${approval.requestId}|${approval.kind}|${approval.title}|${approval.detail}|${approval.threadId}|${approval.turnId}|${approval.itemId}`;
  }

  private requestUserInputStateEquals(left: CodexRequestUserInput | null, right: CodexRequestUserInput | null): boolean {
    if (left === null || right === null) {
      return left === right;
    }
    return this.requestUserInputIdentityString(left) === this.requestUserInputIdentityString(right);
  }

  private requestUserInputIdentityString(request: CodexRequestUserInput): string {
    let questionsSignature: string = '';
    for (let index: number = 0; index < request.questions.length; index += 1) {
      const question: CodexRequestUserInputQuestion = request.questions[index];
      questionsSignature += `${question.id}|${question.header}|${question.question}|${question.isOther}|${question.isSecret}|${question.options.length};`;
    }
    return `${request.requestId}|${request.title}|${request.detail}|${request.threadId}|${request.turnId}|${request.itemId}|${questionsSignature}`;
  }

  private cloneCollaborationMode(mode: CollaborationModeOption): CollaborationModeOption {
    return new CollaborationModeOption(mode.name, mode.mode, mode.model, mode.reasoningEffort);
  }

  private cloneContextManagement(snapshot: CodexContextManagementSnapshot): CodexContextManagementSnapshot {
    return new CodexContextManagementSnapshot(
      snapshot.memoryMode,
      snapshot.recentArtifactRefs !== null ? snapshot.recentArtifactRefs.slice() : null,
      snapshot.memoryUsageCount,
      snapshot.memoryLastUsageAt,
      snapshot.memoryStage1GeneratedAt,
      snapshot.memoryStage1UpToDate,
      snapshot.memoryStage1JobStatus,
      snapshot.memoryStage1RetryAt,
      snapshot.memoryStage1RetryRemaining,
      snapshot.memoryForgettingPending,
      snapshot.memoryForgettingCompletedAt,
      snapshot.memoryPhase2SelectedAt,
      snapshot.memoryPhase2UpdatedAt,
      snapshot.memoryPhase2SelectionCount,
      snapshot.memoryPhase2AddedCount,
      snapshot.memoryPhase2RetainedCount,
      snapshot.memoryPhase2RemovedCount,
      snapshot.memorySummaryUpdatedAt,
      snapshot.memorySummaryPreview,
      snapshot.lastMicroCompactionAt,
      snapshot.lastMicroCompactionItemCount,
      snapshot.lastMicroCompactionSavedTokens,
      snapshot.compactionFailureCount,
      snapshot.compactionCircuitOpen,
      snapshot.lastFullCompactionTrigger,
      snapshot.lastFullCompactionProviderMode,
      snapshot.lastFullCompactionTrimmedItemCount,
      snapshot.lastFullCompactionReferenceContextReestablished,
      snapshot.lastContextCompactionAt
    );
  }

  private cloneMessage(message: CodexChatMessage): CodexChatMessage {
    return new CodexChatMessage(message.messageId, message.sequence, message.author, message.role, message.content, message.timestamp, message.itemType, message.status, message.metadata);
  }

  private cloneDiffLine(line: CodexDiffLine): CodexDiffLine {
    return new CodexDiffLine(line.lineId, line.sequence, line.lineNumber, line.sign, line.content, line.kind, line.filePath);
  }

  private cloneMcpServer(server: McpServerRecord): McpServerRecord {
    return new McpServerRecord(server.id, server.name, server.enabled, server.transportType, server.command, server.argsText, server.url, server.envText, server.httpHeadersText, server.toolCount, server.resourceCount, server.healthStatus, server.authStatus, server.lastError, server.syncStatus, server.updatedAt);
  }

  private readMcpConfig(): void {
    const configReadRequest: McpConfigReadRequestPayload = new McpConfigReadRequestPayload();
    const rawResponse: Record<string, Object> = parseJsonText(mcpConfigReadNative(JSON.stringify(configReadRequest)), new McpConfigReadResponsePayload() as Object) as Record<string, Object>;
    const configObject: Record<string, Object> | undefined = rawResponse['config'] as Record<string, Object> | undefined;
    this.mcpConfigByName.clear();
    if (configObject === undefined) {
      return;
    }
    const mcpServers: Record<string, Object> | undefined = configObject['mcp_servers'] as Record<string, Object> | undefined;
    if (mcpServers === undefined) {
      return;
    }
    const names: string[] = Object.keys(mcpServers);
    for (let index: number = 0; index < names.length; index += 1) {
      const name: string = names[index];
      const value: Object | undefined = mcpServers[name] as Object | undefined;
      if (value !== undefined) {
        this.mcpConfigByName.set(name, value);
      }
    }
  }

  private buildMcpServerRecord(status: McpServerStatusPayload): McpServerRecord {
    const config: Record<string, Object> = (this.mcpConfigByName.get(status.name) as Record<string, Object> | undefined) ?? {};
    const command: string = this.readStringField(config, 'command');
    const url: string = this.readStringField(config, 'url');
    const argsText: string = this.stringifyJsonField(config['args']);
    const envText: string = this.stringifyJsonField(config['env']);
    const httpHeadersText: string = this.stringifyJsonField(config['http_headers']);
    const enabled: boolean = this.readBooleanField(config, 'enabled', true);
    const transportType: string = url.trim().length > 0 ? 'http' : (command.trim().length > 0 ? 'stdio' : 'unknown');
    const tools: Record<string, Object> = status.tools as Record<string, Object>;
    const toolCount: number = Object.keys(tools).length;
    const resourceCount: number = status.resources.length + status.resourceTemplates.length;
    const inferredHealth: McpHealthStatus = toolCount > 0 ? 'ok' : 'warning';
    return new McpServerRecord(status.name, status.name, enabled, transportType, command, argsText, url, envText, httpHeadersText, toolCount, resourceCount, inferredHealth, this.normalizeMcpAuthStatus(status.authStatus), '', 'synced', currentTimestamp());
  }

  private buildMcpServerRecordFromConfig(name: string, config: Object): McpServerRecord {
    const cfg: Record<string, Object> = config as Record<string, Object>;
    const command: string = this.readStringField(cfg, 'command');
    const url: string = this.readStringField(cfg, 'url');
    const argsText: string = this.stringifyJsonField(cfg['args']);
    const envText: string = this.stringifyJsonField(cfg['env']);
    const httpHeadersText: string = this.stringifyJsonField(cfg['http_headers']);
    const enabled: boolean = this.readBooleanField(cfg, 'enabled', true);
    const transportType: string = url.trim().length > 0 ? 'http' : (command.trim().length > 0 ? 'stdio' : 'unknown');
    return new McpServerRecord(name, name, enabled, transportType, command, argsText, url, envText, httpHeadersText, 0, 0, 'unknown', 'notRequired', '', 'synced', currentTimestamp());
  }

  private normalizeMcpAuthStatus(rawStatus: string): McpAuthStatus {
    if (rawStatus === 'oAuth' || rawStatus === 'bearerToken') {
      return 'authenticated';
    }
    if (rawStatus === 'notLoggedIn') {
      return 'required';
    }
    return 'notRequired';
  }

  private normalizeMcpHealthStatus(rawStatus: string, error: string | null): McpHealthStatus {
    if (error !== null && error.trim().length > 0) {
      return 'error';
    }
    if (rawStatus === 'ready') {
      return 'ok';
    }
    if (rawStatus === 'starting') {
      return 'degraded';
    }
    if (rawStatus === 'failed' || rawStatus === 'cancelled') {
      return 'error';
    }
    return 'unknown';
  }

  private readStringField(source: Record<string, Object>, fieldName: string): string {
    const value: Object | undefined = source[fieldName];
    return typeof value === 'string' ? value : '';
  }

  private readBooleanField(source: Record<string, Object>, fieldName: string, defaultValue: boolean): boolean {
    const value: Object | undefined = source[fieldName];
    return typeof value === 'boolean' ? value : defaultValue;
  }

  private stringifyJsonField(value: Object | undefined): string {
    if (value === undefined) {
      return '';
    }
    try {
      return JSON.stringify(value);
    } catch (_err) {
      return '';
    }
  }

  private copyConfigObject(source: Record<string, Object>): Record<string, Object> {
    const target: Record<string, Object> = {};
    const keys: string[] = Object.keys(source);
    for (let index: number = 0; index < keys.length; index += 1) {
      const key: string = keys[index];
      target[key] = source[key];
    }
    return target;
  }
}

export const codexBackend: CodexBackend = new CodexBackend();
export const configManagerFacade: ConfigManagerFacade = new ConfigManagerFacade();
