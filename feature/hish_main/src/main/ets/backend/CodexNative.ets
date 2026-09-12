import entry, {
  NativeCollaborationModeMask,
  EntryBridgeModule,
  NativeCodexHostStatus,
  NativeCodexProviderCatalog,
  NativeCodexProviderConfig,
  NativeCodexProviderRecord,
  NativeWorkspaceAccessStatus
} from 'libhish_main.so';
import { ProviderCatalog, ProviderRecord, TokenUsageAggregate, TodayTokenDetail, DailyTokenSnapshot } from './ConsoleModels';
import taskpool from '@ohos.taskpool';

const nativeBridge: EntryBridgeModule | null = entry ?? null;

export class CodexHostStatus {
  code: number;
  running: boolean;
  serverUrl: string;
  message: string;

  constructor(code: number, running: boolean, serverUrl: string, message: string) {
    this.code = code;
    this.running = running;
    this.serverUrl = serverUrl;
    this.message = message;
  }
}

export class CodexProviderConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  contextWindow: number;
  modelAutoCompactTokenLimit: number;

  constructor(
    baseUrl: string,
    apiKey: string,
    model: string,
    contextWindow: number = 0,
    modelAutoCompactTokenLimit: number = 0
  ) {
    this.baseUrl = baseUrl;
    this.apiKey = apiKey;
    this.model = model;
    this.contextWindow = contextWindow;
    this.modelAutoCompactTokenLimit = modelAutoCompactTokenLimit;
  }
}

export class WorkspaceAccessStatus {
  rootPath: string;
  accessKind: string;
  permissionState: string;
  writable: boolean;
  exists: boolean;
  message: string;

  constructor(rootPath: string, accessKind: string, permissionState: string, writable: boolean, exists: boolean, message: string) {
    this.rootPath = rootPath;
    this.accessKind = accessKind;
    this.permissionState = permissionState;
    this.writable = writable;
    this.exists = exists;
    this.message = message;
  }
}

export class CollaborationModeOption {
  name: string;
  mode: string;
  model?: string;
  reasoningEffort?: string | null;

  constructor(name: string, mode: string, model?: string, reasoningEffort?: string | null) {
    this.name = name;
    this.mode = mode;
    this.model = model;
    this.reasoningEffort = reasoningEffort;
  }
}

function nativeModuleUnavailable(): boolean {
  return nativeBridge === null || nativeBridge === undefined;
}

function missingNativeModuleStatus(): CodexHostStatus {
  return new CodexHostStatus(1, false, '', 'libhish_main.so failed to load.');
}

function normalizeProviderRecord(rawRecord: NativeCodexProviderRecord | undefined): ProviderRecord {
  const appType = (rawRecord?.appType ?? 'codex') === 'codex' ? 'codex' : 'codex';
  const mode = (rawRecord?.mode ?? 'exclusive') === 'additive' ? 'additive' : 'exclusive';
  const syncStatusRaw: string = rawRecord?.syncStatus ?? 'synced';
  const syncStatus = syncStatusRaw === 'dirty' ? 'dirty' : (syncStatusRaw === 'error' ? 'error' : 'synced');
  return new ProviderRecord(
    rawRecord?.id ?? '',
    rawRecord?.name ?? '未命名 Provider',
    appType,
    mode,
    rawRecord?.baseUrl ?? rawRecord?.base_url ?? '',
    rawRecord?.apiKey ?? rawRecord?.api_key ?? '',
    rawRecord?.model ?? '',
    rawRecord?.isActive === true,
    syncStatus,
    rawRecord?.updatedAt ?? '',
    'apiKey',
    [],
    'responses',
    'custom',
    '',
    '',
    '',
    '',
    [],
    'unknown',
    0,
    0,
    null,
    Date.now(),
    rawRecord?.contextWindow ?? 0,
    rawRecord?.modelAutoCompactTokenLimit ?? 0
  );
}

function normalizeProviderCatalog(rawCatalog: NativeCodexProviderCatalog | undefined): ProviderCatalog {
  if (rawCatalog === undefined) {
    return new ProviderCatalog(1, '', [], '');
  }
  const providers: ProviderRecord[] = rawCatalog.providers === undefined
    ? []
    : rawCatalog.providers.map((provider: NativeCodexProviderRecord) => normalizeProviderRecord(provider));
  return new ProviderCatalog(
    rawCatalog.version ?? 1,
    rawCatalog.activeProviderId ?? '',
    providers,
    rawCatalog.updatedAt ?? ''
  );
}

function normalizeStatus(rawStatus: NativeCodexHostStatus | undefined): CodexHostStatus {
  if (rawStatus === undefined) {
    return new CodexHostStatus(1, false, '', 'native bridge returned no status');
  }
  return new CodexHostStatus(
    rawStatus.code ?? 0,
    rawStatus.running === true,
    rawStatus.serverUrl ?? '',
    rawStatus.message ?? ''
  );
}

function normalizeProviderConfig(rawConfig: NativeCodexProviderConfig | undefined): CodexProviderConfig {
  if (rawConfig === undefined) {
    return new CodexProviderConfig('', '', '', 0, 0);
  }
  return new CodexProviderConfig(
    rawConfig.baseUrl ?? rawConfig.base_url ?? '',
    rawConfig.apiKey ?? rawConfig.api_key ?? '',
    rawConfig.model ?? '',
    rawConfig.contextWindow ?? 0,
    rawConfig.modelAutoCompactTokenLimit ?? 0
  );
}

function normalizeWorkspaceAccessStatus(rawStatus: NativeWorkspaceAccessStatus | undefined): WorkspaceAccessStatus {
  if (rawStatus === undefined) {
    return new WorkspaceAccessStatus('', 'unknown', 'unavailable', false, false, 'native bridge returned no workspace status');
  }
  return new WorkspaceAccessStatus(
    rawStatus.rootPath ?? '',
    rawStatus.accessKind ?? 'unknown',
    rawStatus.permissionState ?? 'unavailable',
    rawStatus.writable === true,
    rawStatus.exists === true,
    rawStatus.message ?? ''
  );
}

function parseProviderConfig(rawValue: string): CodexProviderConfig {
  if (rawValue.trim().length === 0) {
    return new CodexProviderConfig('', '', '', 0, 0);
  }
  try {
    const rawConfig: NativeCodexProviderConfig = JSON.parse(rawValue) as NativeCodexProviderConfig;
    return normalizeProviderConfig(rawConfig);
  } catch (_err) {
    return new CodexProviderConfig('', '', '', 0, 0);
  }
}

function parseProviderCatalog(rawValue: string): ProviderCatalog {
  if (rawValue.trim().length === 0) {
    return new ProviderCatalog(1, '', [], '');
  }
  try {
    const rawCatalog: NativeCodexProviderCatalog = JSON.parse(rawValue) as NativeCodexProviderCatalog;
    return normalizeProviderCatalog(rawCatalog);
  } catch (_err) {
    return new ProviderCatalog(1, '', [], '');
  }
}

function parseWorkspaceAccessStatus(rawValue: string): WorkspaceAccessStatus {
  if (rawValue.trim().length === 0) {
    return new WorkspaceAccessStatus('', 'unknown', 'unavailable', false, false, 'workspace status is empty');
  }
  try {
    const rawStatus: NativeWorkspaceAccessStatus = JSON.parse(rawValue) as NativeWorkspaceAccessStatus;
    return normalizeWorkspaceAccessStatus(rawStatus);
  } catch (_err) {
    return new WorkspaceAccessStatus('', 'unknown', 'unavailable', false, false, 'failed to parse workspace status');
  }
}

function normalizeCollaborationMode(rawMode: string | null | undefined): string {
  return rawMode === 'plan' ? 'plan' : 'default';
}

function normalizeCollaborationModeOption(rawOption: NativeCollaborationModeMask | undefined): CollaborationModeOption {
  const rawEffort = rawOption?.reasoning_effort;
  const reasoningEffort = rawEffort === undefined ? undefined : (rawEffort === null ? null : rawEffort);
  return new CollaborationModeOption(
    rawOption?.name ?? '',
    normalizeCollaborationMode(rawOption?.mode ?? 'default'),
    rawOption?.model ?? undefined,
    reasoningEffort
  );
}

function parseCollaborationModeList(rawValue: string): CollaborationModeOption[] {
  if (rawValue.trim().length === 0) {
    return [];
  }
  try {
    const payload = JSON.parse(rawValue) as Record<string, Object>;
    const data = Array.isArray(payload['data']) ? (payload['data'] as NativeCollaborationModeMask[]) : [];
    return data.map((item: NativeCollaborationModeMask) => normalizeCollaborationModeOption(item));
  } catch (_err) {
    return [];
  }
}

export function startEmbeddedCodexHost(codexHome: string, serverUrl: string): CodexHostStatus {
  if (nativeModuleUnavailable()) {
    return missingNativeModuleStatus();
  }
  try {
    return normalizeStatus(nativeBridge!.startHost(codexHome, serverUrl));
  } catch (_err) {
    return missingNativeModuleStatus();
  }
}

export function getEmbeddedCodexHostStatus(): CodexHostStatus {
  if (nativeModuleUnavailable()) {
    return missingNativeModuleStatus();
  }
  try {
    return normalizeStatus(nativeBridge!.getStatus());
  } catch (_err) {
    return missingNativeModuleStatus();
  }
}

export function getEmbeddedCodexProviderConfig(): CodexProviderConfig {
  if (nativeModuleUnavailable()) {
    return new CodexProviderConfig('', '', '', 0, 0);
  }
  try {
    const codexHome: string = (AppStorage.get('codexHome') as string) ?? '';
    return parseProviderConfig(nativeBridge!.getProviderConfig(codexHome));
  } catch (_err) {
    return new CodexProviderConfig('', '', '', 0, 0);
  }
}

export function saveEmbeddedCodexProviderConfig(
  baseUrl: string,
  apiKey: string,
  model: string,
  contextWindow?: number,
  modelAutoCompactTokenLimit?: number
): CodexProviderConfig {
  if (nativeModuleUnavailable()) {
    throw new Error('libhish_main.so failed to load.');
  }
  try {
    const codexHome: string = (AppStorage.get('codexHome') as string) ?? '';
    const currentConfig = contextWindow === undefined || modelAutoCompactTokenLimit === undefined
      ? getEmbeddedCodexProviderConfig()
      : null;
    const resolvedContextWindow = contextWindow ?? currentConfig?.contextWindow ?? 0;
    const resolvedModelAutoCompactTokenLimit = modelAutoCompactTokenLimit ?? currentConfig?.modelAutoCompactTokenLimit ?? 0;
    const response = nativeBridge!.saveProviderConfig(
      codexHome,
      baseUrl,
      apiKey,
      model,
      resolvedContextWindow > 0 ? String(resolvedContextWindow) : '',
      resolvedModelAutoCompactTokenLimit > 0 ? String(resolvedModelAutoCompactTokenLimit) : ''
    );
    const parsed = parseProviderConfig(response);
    if (parsed.baseUrl.trim().length === 0 && parsed.apiKey.trim().length === 0 && parsed.model.trim().length === 0) {
      throw new Error('native saveProviderConfig returned an empty provider config');
    }
    return parsed;
  } catch (err) {
    throw err instanceof Error ? err : new Error('Failed to save provider config.');
  }
}

export function getEmbeddedCodexProviderCatalog(): ProviderCatalog {
  if (nativeModuleUnavailable()) {
    return new ProviderCatalog(1, '', [], '');
  }
  try {
    const codexHome: string = (AppStorage.get('codexHome') as string) ?? '';
    return parseProviderCatalog(nativeBridge!.getProviderCatalog(codexHome));
  } catch (_err) {
    return new ProviderCatalog(1, '', [], '');
  }
}

export function saveEmbeddedCodexProviderCatalog(catalog: ProviderCatalog): ProviderCatalog {
  if (nativeModuleUnavailable()) {
    throw new Error('libhish_main.so failed to load.');
  }
  try {
    const codexHome: string = (AppStorage.get('codexHome') as string) ?? '';
    const parsed = parseProviderCatalog(nativeBridge!.saveProviderCatalog(codexHome, JSON.stringify(catalog)));
    if (parsed.providers.length === 0) {
      throw new Error('native saveProviderCatalog returned an empty provider catalog');
    }
    return parsed;
  } catch (err) {
    throw err instanceof Error ? err : new Error('Failed to save provider catalog.');
  }
}

export function getSkillsRegistry(codexHome: string): string {
  if (nativeModuleUnavailable()) {
    return '{"version":1,"skills":[],"updatedAt":"0"}';
  }
  try {
    const result = nativeBridge!.getSkillsRegistry(codexHome);
    return result !== undefined && result !== null && result.length > 0 ? result : '{"version":1,"skills":[],"updatedAt":"0"}';
  } catch (_err) {
    return '{"version":1,"skills":[],"updatedAt":"0"}';
  }
}

export function saveSkillsRegistry(codexHome: string, registryJson: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.saveSkillsRegistry(codexHome, registryJson) === 0;
  } catch (_err) {
    return false;
  }
}

export function getSkillsRepos(codexHome: string): string {
  if (nativeModuleUnavailable()) {
    return '{"version":1,"repos":[]}';
  }
  try {
    const result = nativeBridge!.getSkillsRepos(codexHome);
    return result !== undefined && result !== null && result.length > 0 ? result : '{"version":1,"repos":[]}';
  } catch (_err) {
    return '{"version":1,"repos":[]}';
  }
}

export function saveSkillsRepos(codexHome: string, reposJson: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.saveSkillsRepos(codexHome, reposJson) === 0;
  } catch (_err) {
    return false;
  }
}

export function computeDirHash(dirPath: string): string {
  if (nativeModuleUnavailable()) {
    return '';
  }
  try {
    return nativeBridge!.computeDirHash(dirPath) ?? '';
  } catch (_err) {
    return '';
  }
}

export function installSkillFromDir(codexHome: string, sourceDir: string, skillJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{"error":"native bridge unavailable"}';
  }
  try {
    const result = nativeBridge!.installSkillFromDir(codexHome, sourceDir, skillJson);
    return result !== undefined && result !== null && result.length > 0
      ? result
      : '{"error":"native bridge returned empty result"}';
  } catch (err) {
    const message = err instanceof Error ? err.message : JSON.stringify(err);
    return JSON.stringify({ error: `native bridge exception: ${message}` });
  }
}

export function uninstallSkill(codexHome: string, skillId: string): string {
  if (nativeModuleUnavailable()) {
    return '';
  }
  try {
    return nativeBridge!.uninstallSkill(codexHome, skillId) ?? '';
  } catch (_err) {
    return '';
  }
}

export function setSkillEnabledNative(codexHome: string, skillId: string, enabled: boolean): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    const result = nativeBridge!.setSkillEnabled(codexHome, skillId, enabled ? 1 : 0);
    return result !== undefined && result !== null && result.length > 0 ? result : '{}';
  } catch (_err) {
    return '{}';
  }
}

export function reconcileSkills(codexHome: string): string {
  if (nativeModuleUnavailable()) {
    return '{"removed":[],"registered":[]}';
  }
  try {
    const result = nativeBridge!.reconcileSkills(codexHome);
    return result !== undefined && result !== null && result.length > 0 ? result : '{"removed":[],"registered":[]}';
  } catch (_err) {
    return '{"removed":[],"registered":[]}';
  }
}

export function getPromptsRegistry(codexHome: string): string {
  if (nativeModuleUnavailable()) {
    return '{"version":1,"prompts":[],"updatedAt":"0"}';
  }
  try {
    const result = nativeBridge!.getPromptsRegistry(codexHome);
    return result !== undefined && result !== null && result.length > 0 ? result : '{"version":1,"prompts":[],"updatedAt":"0"}';
  } catch (_err) {
    return '{"version":1,"prompts":[],"updatedAt":"0"}';
  }
}

export function savePromptsRegistry(codexHome: string, registryJson: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.savePromptsRegistry(codexHome, registryJson) === 0;
  } catch (_err) {
    return false;
  }
}

export function readAgentsMd(codexHome: string): string {
  if (nativeModuleUnavailable()) {
    return '';
  }
  try {
    return nativeBridge!.readAgentsMd(codexHome) ?? '';
  } catch (_err) {
    return '';
  }
}

export function writeAgentsMd(codexHome: string, content: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.writeAgentsMd(codexHome, content) === 0;
  } catch (_err) {
    return false;
  }
}

export function enablePromptNative(codexHome: string, promptId: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    const result = nativeBridge!.enablePrompt(codexHome, promptId);
    return result !== undefined && result !== null && result.length > 0 ? result : '{}';
  } catch (_err) {
    return '{}';
  }
}

export function disableAllPromptsNative(codexHome: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.disableAllPrompts(codexHome) === 0;
  } catch (_err) {
    return false;
  }
}

export function initializeNative(configJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    return nativeBridge!.initialize(configJson);
  } catch (_err) {
    return '{}';
  }
}

export function collaborationModeListNative(paramsJson: string = '{}'): string {
  if (nativeModuleUnavailable()) {
    return '{"data":[]}';
  }
  try {
    return nativeBridge!.collaborationModeList(paramsJson);
  } catch (_err) {
    return '{"data":[]}';
  }
}

export function listCollaborationModes(): CollaborationModeOption[] {
  return parseCollaborationModeList(collaborationModeListNative('{}'));
}

export function threadStartNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    return nativeBridge!.threadStart(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export function threadListNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{"data":[],"nextCursor":null}';
  }
  try {
    return nativeBridge!.threadList(paramsJson);
  } catch (_err) {
    return '{"data":[],"nextCursor":null}';
  }
}

export function threadReadNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    return nativeBridge!.threadRead(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export function threadResumeNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    return nativeBridge!.threadResume(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export function threadNameSetNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{"ok":false}';
  }
  try {
    return nativeBridge!.threadNameSet(paramsJson);
  } catch (_err) {
    return '{"ok":false}';
  }
}

export function threadArchiveNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{"ok":false}';
  }
  try {
    return nativeBridge!.threadArchive(paramsJson);
  } catch (_err) {
    return '{"ok":false}';
  }
}

export function compactStartNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{"ok":false}';
  }
  try {
    return nativeBridge!.threadCompactStart(paramsJson);
  } catch (_err) {
    return '{"ok":false}';
  }
}

export function turnStartNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    return nativeBridge!.turnStart(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export function turnEventsNative(threadId: string, turnId: string): string {
  if (nativeModuleUnavailable()) {
    return '[]';
  }
  try {
    return nativeBridge!.turnEvents(threadId, turnId);
  } catch (_err) {
    return '[]';
  }
}

export function turnPollNative(threadId: string, turnId: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    return nativeBridge!.turnPoll(threadId, turnId);
  } catch (_err) {
    return '{}';
  }
}

export function turnInterruptNative(threadId: string, turnId: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    return nativeBridge!.turnInterrupt(threadId, turnId);
  } catch (_err) {
    return '{}';
  }
}

export function approvalPollNative(): string {
  if (nativeModuleUnavailable()) {
    return 'null';
  }
  try {
    return nativeBridge!.approvalPoll();
  } catch (_err) {
    return 'null';
  }
}

export function approvalApproveNative(paramsJson: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.approvalApprove(paramsJson) === 0;
  } catch (_err) {
    return false;
  }
}

export function approvalDeclineNative(paramsJson: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.approvalDecline(paramsJson) === 0;
  } catch (_err) {
    return false;
  }
}

export function mcpStatusListNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{"data":[],"nextCursor":null}';
  }
  try {
    return nativeBridge!.mcpStatusList(paramsJson);
  } catch (_err) {
    return '{"data":[],"nextCursor":null}';
  }
}

export function mcpConfigReadNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{"config":{}}';
  }
  try {
    return nativeBridge!.mcpConfigRead(paramsJson);
  } catch (_err) {
    return '{"config":{}}';
  }
}

export function mcpConfigWriteNative(paramsJson: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.mcpConfigWrite(paramsJson) === 0;
  } catch (_err) {
    return false;
  }
}

export function mcpConfigBatchWriteNative(paramsJson: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.mcpConfigBatchWrite(paramsJson) === 0;
  } catch (_err) {
    return false;
  }
}

export function mcpConfigAddNative(paramsJson: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.mcpConfigAdd(paramsJson) === 0;
  } catch (_err) {
    return false;
  }
}

export function mcpConfigRemoveNative(paramsJson: string): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.mcpConfigRemove(paramsJson) === 0;
  } catch (_err) {
    return false;
  }
}

export function mcpReloadNative(): boolean {
  if (nativeModuleUnavailable()) {
    return false;
  }
  try {
    return nativeBridge!.mcpReload() === 0;
  } catch (_err) {
    return false;
  }
}

export function mcpOauthStartNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    return nativeBridge!.mcpOauthStart(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export function accountLoginNative(paramsJson: string): string {
  if (nativeModuleUnavailable()) {
    return '{}';
  }
  try {
    return nativeBridge!.accountLogin(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export function accountReadNative(): string {
  if (nativeModuleUnavailable()) {
    return '{"account":null,"requiresOpenaiAuth":false}';
  }
  try {
    return nativeBridge!.accountRead();
  } catch (_err) {
    return '{"account":null,"requiresOpenaiAuth":false}';
  }
}

export function checkWorkspaceAccess(rootPath: string): WorkspaceAccessStatus {
  if (nativeModuleUnavailable()) {
    return new WorkspaceAccessStatus(rootPath, 'unknown', 'unavailable', false, false, 'native module unavailable');
  }
  try {
    return parseWorkspaceAccessStatus(nativeBridge!.checkWorkspaceAccess(JSON.stringify({ rootPath })));
  } catch (_err) {
    return new WorkspaceAccessStatus(rootPath, 'unknown', 'unavailable', false, false, 'workspace access check failed');
  }
}

function parseTokenUsageAggregate(raw: string | null | undefined): TokenUsageAggregate | null {
  if (raw === null || raw === undefined || raw.length === 0) return null;
  try {
    const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;

    const todayRaw = parsed['today'] as Record<string, Object> | undefined;
    const today = new TodayTokenDetail(
      typeof todayRaw?.['totalTokens'] === 'number' ? (todayRaw['totalTokens'] as number) : 0,
      typeof todayRaw?.['inputTokens'] === 'number' ? (todayRaw['inputTokens'] as number) : 0,
      typeof todayRaw?.['outputTokens'] === 'number' ? (todayRaw['outputTokens'] as number) : 0,
      typeof todayRaw?.['cachedInputTokens'] === 'number' ? (todayRaw['cachedInputTokens'] as number) : 0,
      typeof todayRaw?.['reasoningOutputTokens'] === 'number' ? (todayRaw['reasoningOutputTokens'] as number) : 0,
      typeof todayRaw?.['requestCount'] === 'number' ? (todayRaw['requestCount'] as number) : 0
    );

    const dailyRaw = parsed['daily'] as Array<Record<string, Object>> | undefined;
    const daily: DailyTokenSnapshot[] = [];
    if (Array.isArray(dailyRaw)) {
      for (let i = 0; i < dailyRaw.length; i++) {
        const item = dailyRaw[i];
        daily.push(new DailyTokenSnapshot(
          typeof item['date'] === 'string' ? (item['date'] as string) : '',
          typeof item['totalTokens'] === 'number' ? (item['totalTokens'] as number) : 0,
          typeof item['requestCount'] === 'number' ? (item['requestCount'] as number) : 0
        ));
      }
    }

    return new TokenUsageAggregate(today, daily);
  } catch (_err) {
    return null;
  }
}

export function fetchNativeTokenUsageAggregate(codexHome: string): TokenUsageAggregate | null {
  if (nativeModuleUnavailable()) {
    return null;
  }
  try {
    return parseTokenUsageAggregate(nativeBridge!.tokenUsageAggregate(codexHome));
  } catch (_err) {
    return null;
  }
}

// --- Async wrappers via taskpool (offload blocking native calls from UI thread) ---

@Concurrent
function initializeTask(configJson: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{}';
  }
  try {
    return mod.initialize(configJson);
  } catch (_err) {
    return '{}';
  }
}

export async function initializeAsyncNative(configJson: string): Promise<string> {
  try {
    const task = new taskpool.Task(initializeTask, configJson);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '{}';
  }
}

@Concurrent
function turnStartTask(paramsJson: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{}';
  }
  try {
    return mod.turnStart(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export async function turnStartAsyncNative(paramsJson: string): Promise<string> {
  try {
    const task = new taskpool.Task(turnStartTask, paramsJson);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '{}';
  }
}

@Concurrent
function turnPollTask(threadId: string, turnId: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    const message: string = 'libhish_main.so 未加载，无法继续轮询当前会话。';
    return JSON.stringify({
      status: 'failed',
      nativePollFailure: true,
      summaryTitle: '轮询失败',
      summary: [message]
    });
  }
  try {
    return mod.turnPoll(threadId, turnId);
  } catch (err) {
    const errorText: string = err instanceof Error ? err.message : JSON.stringify(err);
    return JSON.stringify({
      status: 'failed',
      nativePollFailure: true,
      summaryTitle: '轮询失败',
      summary: [`Native turn/poll 调用失败：${errorText}`]
    });
  }
}

export async function turnPollAsyncNative(threadId: string, turnId: string): Promise<string> {
  try {
    const task = new taskpool.Task(turnPollTask, threadId, turnId);
    return await taskpool.execute(task) as string;
  } catch (err) {
    const errorText: string = err instanceof Error ? err.message : JSON.stringify(err);
    return JSON.stringify({
      status: 'failed',
      nativePollFailure: true,
      summaryTitle: '轮询失败',
      summary: [`TaskPool 执行 turn/poll 失败：${errorText}`]
    });
  }
}

@Concurrent
function threadStartTask(paramsJson: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{}';
  }
  try {
    return mod.threadStart(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export async function threadStartAsyncNative(paramsJson: string): Promise<string> {
  try {
    const task = new taskpool.Task(threadStartTask, paramsJson);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '{}';
  }
}

@Concurrent
function threadResumeTask(paramsJson: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{}';
  }
  try {
    return mod.threadResume(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export async function threadResumeAsyncNative(paramsJson: string): Promise<string> {
  try {
    const task = new taskpool.Task(threadResumeTask, paramsJson);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '{}';
  }
}

@Concurrent
function getStatusTask(): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{"code":1,"running":false,"serverUrl":"","message":"libhish_main.so failed to load."}';
  }
  try {
    const raw = mod.getStatus();
    return JSON.stringify({
      code: raw.code ?? 0,
      running: raw.running === true,
      serverUrl: raw.serverUrl ?? '',
      message: raw.message ?? ''
    });
  } catch (_err) {
    return '{"code":1,"running":false,"serverUrl":"","message":"getStatus failed"}';
  }
}

export async function getEmbeddedCodexHostStatusAsync(): Promise<CodexHostStatus> {
  try {
    const task = new taskpool.Task(getStatusTask);
    const jsonStr: string = await taskpool.execute(task) as string;
    const parsed: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    return new CodexHostStatus(
      typeof parsed['code'] === 'number' ? (parsed['code'] as number) : 1,
      parsed['running'] === true,
      typeof parsed['serverUrl'] === 'string' ? (parsed['serverUrl'] as string) : '',
      typeof parsed['message'] === 'string' ? (parsed['message'] as string) : ''
    );
  } catch (_err) {
    return new CodexHostStatus(1, false, '', 'getStatus async failed');
  }
}

@Concurrent
function startHostTask(codexHome: string, serverUrl: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{"code":1,"running":false,"serverUrl":"","message":"libhish_main.so failed to load."}';
  }
  try {
    const status: NativeCodexHostStatus = mod.startHost(codexHome, serverUrl);
    return JSON.stringify({
      code: status.code ?? 0,
      running: status.running === true,
      serverUrl: status.serverUrl ?? '',
      message: status.message ?? ''
    });
  } catch (_err) {
    return '{"code":1,"running":false,"serverUrl":"","message":"startHost failed"}';
  }
}

export async function startEmbeddedCodexHostAsync(codexHome: string, serverUrl: string): Promise<CodexHostStatus> {
  try {
    const task = new taskpool.Task(startHostTask, codexHome, serverUrl);
    const jsonStr: string = await taskpool.execute(task) as string;
    const parsed: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    return new CodexHostStatus(
      typeof parsed['code'] === 'number' ? (parsed['code'] as number) : 1,
      parsed['running'] === true,
      typeof parsed['serverUrl'] === 'string' ? (parsed['serverUrl'] as string) : '',
      typeof parsed['message'] === 'string' ? (parsed['message'] as string) : ''
    );
  } catch (_err) {
    return new CodexHostStatus(1, false, '', 'start host async failed');
  }
}

// --- Async wrappers for RPC-blocking native calls (offload from UI thread) ---
// 这些函数在 Rust 侧会 block_on 等 app-server RPC 响应（现已加 15s 超时），
// 若在主线程同步调用，任何一次 RPC 挂起都会冻结 UI。taskpool 化后阻塞发生在工作线程。

@Concurrent
function threadReadTask(paramsJson: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{}';
  }
  try {
    return mod.threadRead(paramsJson);
  } catch (_err) {
    return '{}';
  }
}

export async function threadReadAsyncNative(paramsJson: string): Promise<string> {
  try {
    const task = new taskpool.Task(threadReadTask, paramsJson);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '{}';
  }
}

@Concurrent
function threadListTask(paramsJson: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{"data":[],"nextCursor":null}';
  }
  try {
    return mod.threadList(paramsJson);
  } catch (_err) {
    return '{"data":[],"nextCursor":null}';
  }
}

export async function threadListAsyncNative(paramsJson: string): Promise<string> {
  try {
    const task = new taskpool.Task(threadListTask, paramsJson);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '{"data":[],"nextCursor":null}';
  }
}

@Concurrent
function threadNameSetTask(paramsJson: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{"ok":false}';
  }
  try {
    return mod.threadNameSet(paramsJson);
  } catch (_err) {
    return '{"ok":false}';
  }
}

export async function threadNameSetAsyncNative(paramsJson: string): Promise<string> {
  try {
    const task = new taskpool.Task(threadNameSetTask, paramsJson);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '{"ok":false}';
  }
}

@Concurrent
function threadArchiveTask(paramsJson: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{"ok":false}';
  }
  try {
    return mod.threadArchive(paramsJson);
  } catch (_err) {
    return '{"ok":false}';
  }
}

export async function threadArchiveAsyncNative(paramsJson: string): Promise<string> {
  try {
    const task = new taskpool.Task(threadArchiveTask, paramsJson);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '{"ok":false}';
  }
}

@Concurrent
function turnEventsTask(threadId: string, turnId: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '[]';
  }
  try {
    return mod.turnEvents(threadId, turnId);
  } catch (_err) {
    return '[]';
  }
}

export async function turnEventsAsyncNative(threadId: string, turnId: string): Promise<string> {
  try {
    const task = new taskpool.Task(turnEventsTask, threadId, turnId);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '[]';
  }
}

@Concurrent
function collaborationModeListTask(paramsJson: string): string {
  const mod = entry ?? null;
  if (mod === null) {
    return '{"data":[]}';
  }
  try {
    return mod.collaborationModeList(paramsJson);
  } catch (_err) {
    return '{"data":[]}';
  }
}

export async function collaborationModeListAsyncNative(paramsJson: string = '{}'): Promise<string> {
  try {
    const task = new taskpool.Task(collaborationModeListTask, paramsJson);
    return await taskpool.execute(task) as string;
  } catch (_err) {
    return '{"data":[]}';
  }
}
