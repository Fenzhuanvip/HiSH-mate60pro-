export type AiAppType = 'codex' | 'claude' | 'gemini' | 'opencode' | 'openclaw' | 'hermes';
export type ProviderMode = 'exclusive' | 'additive';
export type ProviderSyncStatus = 'synced' | 'dirty' | 'error';
export type McpSyncStatus = 'synced' | 'dirty' | 'error';
export type McpHealthStatus = 'unknown' | 'ok' | 'warning' | 'degraded' | 'error';
export type McpAuthStatus = 'notRequired' | 'required' | 'pending' | 'authenticated' | 'failed';
export type SidebarView = 'chat' | 'providers' | 'sessions' | 'usage' | 'mcp' | 'prompts' | 'skills' | 'openclaw' | 'hermes';
export type SettingsTab = 'mcp' | 'skills' | 'prompts' | 'api';

export type ApiWireFormat = 'responses';
export type ProviderCategory = 'official' | 'third_party' | 'cloud_provider' | 'aggregator' | 'custom';
export type WorkspaceAccessKind = 'sandbox' | 'user_granted' | 'readonly' | 'unknown';
export type WorkspacePermissionState = 'writable' | 'readonly' | 'unavailable' | 'revoked';

export class WorkspaceDescriptor {
  id: string;
  name: string;
  rootPath: string;
  accessKind: WorkspaceAccessKind;
  permissionState: WorkspacePermissionState;
  sourceUri: string;
  writableRoots: string[];
  grantedAt: number;
  lastCheckedAt: number;

  constructor(
    id: string,
    name: string,
    rootPath: string,
    accessKind: WorkspaceAccessKind,
    permissionState: WorkspacePermissionState,
    sourceUri: string,
    writableRoots: string[],
    grantedAt: number,
    lastCheckedAt: number
  ) {
    this.id = id;
    this.name = name;
    this.rootPath = rootPath;
    this.accessKind = accessKind;
    this.permissionState = permissionState;
    this.sourceUri = sourceUri;
    this.writableRoots = writableRoots;
    this.grantedAt = grantedAt;
    this.lastCheckedAt = lastCheckedAt;
  }
}

export class EndpointEntry {
  url: string;
  addedAt: number;
  lastUsed: number;
  latencyMs: number;
  isActive: boolean;

  constructor(url: string, addedAt: number, lastUsed: number, latencyMs: number, isActive: boolean) {
    this.url = url;
    this.addedAt = addedAt;
    this.lastUsed = lastUsed;
    this.latencyMs = latencyMs;
    this.isActive = isActive;
  }
}

export class CustomHeadersEntry {
  key: string;
  value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

export class UsageScriptEntry {
  enabled: boolean;
  scriptType: string;
  code: string;
  queryUrl: string;
  headers: CustomHeadersEntry[];
  autoQueryIntervalMin: number;

  constructor(
    enabled: boolean, scriptType: string, code: string,
    queryUrl: string, headers: CustomHeadersEntry[], autoQueryIntervalMin: number
  ) {
    this.enabled = enabled;
    this.scriptType = scriptType;
    this.code = code;
    this.queryUrl = queryUrl;
    this.headers = headers;
    this.autoQueryIntervalMin = autoQueryIntervalMin;
  }
}

export class ProviderRecord {
  id: string;
  name: string;
  appType: AiAppType;
  mode: ProviderMode;
  baseUrl: string;
  apiKey: string;
  model: string;
  isActive: boolean;
  syncStatus: ProviderSyncStatus;
  updatedAt: string;
  authMode: string;
  customHeaders: CustomHeadersEntry[];
  wireApi: ApiWireFormat;
  category: ProviderCategory;
  description: string;
  websiteUrl: string;
  icon: string;
  iconColor: string;
  endpoints: EndpointEntry[];
  healthStatus: string;
  healthLatencyMs: number;
  lastValidatedAt: number;
  usageScript: UsageScriptEntry | null;
  createdAt: number;
  contextWindow: number;
  modelAutoCompactTokenLimit: number;

  constructor(
    id: string,
    name: string,
    appType: AiAppType,
    mode: ProviderMode,
    baseUrl: string,
    apiKey: string,
    model: string,
    isActive: boolean,
    syncStatus: ProviderSyncStatus,
    updatedAt: string,
    authMode?: string,
    customHeaders?: CustomHeadersEntry[],
    wireApi?: ApiWireFormat,
    category?: ProviderCategory,
    description?: string,
    websiteUrl?: string,
    icon?: string,
    iconColor?: string,
    endpoints?: EndpointEntry[],
    healthStatus?: string,
    healthLatencyMs?: number,
    lastValidatedAt?: number,
    usageScript?: UsageScriptEntry | null,
    createdAt?: number,
    contextWindow?: number,
    modelAutoCompactTokenLimit?: number
  ) {
    this.id = id;
    this.name = name;
    this.appType = appType;
    this.mode = mode;
    this.baseUrl = baseUrl;
    this.apiKey = apiKey;
    this.model = model;
    this.isActive = isActive;
    this.syncStatus = syncStatus;
    this.updatedAt = updatedAt;
    this.authMode = authMode ?? 'apiKey';
    this.customHeaders = customHeaders ?? [];
    this.wireApi = wireApi ?? 'responses';
    this.category = category ?? 'custom';
    this.description = description ?? '';
    this.websiteUrl = websiteUrl ?? '';
    this.icon = icon ?? '';
    this.iconColor = iconColor ?? '';
    this.endpoints = endpoints ?? [];
    this.healthStatus = healthStatus ?? 'unknown';
    this.healthLatencyMs = healthLatencyMs ?? 0;
    this.lastValidatedAt = lastValidatedAt ?? 0;
    this.usageScript = usageScript ?? null;
    this.createdAt = createdAt ?? Date.now();
    this.contextWindow = contextWindow ?? 0;
    this.modelAutoCompactTokenLimit = modelAutoCompactTokenLimit ?? 0;
  }

  getHeaderValue(key: string): string {
    for (let i = 0; i < this.customHeaders.length; i++) {
      if (this.customHeaders[i].key === key) {
        return this.customHeaders[i].value;
      }
    }
    return '';
  }

  setHeader(key: string, value: string): void {
    for (let i = 0; i < this.customHeaders.length; i++) {
      if (this.customHeaders[i].key === key) {
        this.customHeaders[i].value = value;
        return;
      }
    }
    this.customHeaders.push(new CustomHeadersEntry(key, value));
  }

  copyHeaders(): CustomHeadersEntry[] {
    const result: CustomHeadersEntry[] = [];
    for (let i = 0; i < this.customHeaders.length; i++) {
      const h = this.customHeaders[i];
      result.push(new CustomHeadersEntry(h.key, h.value));
    }
    return result;
  }
}

export class ProviderCatalog {
  version: number;
  activeProviderId: string;
  providers: ProviderRecord[];
  updatedAt: string;

  constructor(version: number, activeProviderId: string, providers: ProviderRecord[], updatedAt: string) {
    this.version = version;
    this.activeProviderId = activeProviderId;
    this.providers = providers;
    this.updatedAt = updatedAt;
  }
}

export class ProviderDefinition {
  id: string;
  name: string;
  baseUrl: string;
  model: string;
  wireApi: string;
  isActive: boolean;
  appType: string;
  mode: string;
  syncStatus: string;
  updatedAt: string;
  contextWindow: number;
  modelAutoCompactTokenLimit: number;

  constructor(
    id: string, name: string, baseUrl: string, model: string,
    wireApi: string, isActive: boolean, appType: string, mode: string,
    syncStatus: string, updatedAt: string, contextWindow: number = 0,
    modelAutoCompactTokenLimit: number = 0
  ) {
    this.id = id;
    this.name = name;
    this.baseUrl = baseUrl;
    this.model = model;
    this.wireApi = wireApi;
    this.isActive = isActive;
    this.appType = appType;
    this.mode = mode;
    this.syncStatus = syncStatus;
    this.updatedAt = updatedAt;
    this.contextWindow = contextWindow;
    this.modelAutoCompactTokenLimit = modelAutoCompactTokenLimit;
  }
}

export class ModelsCacheEntry {
  slug: string;
  displayName: string;
  description: string;
  contextWindow: number;

  constructor(slug: string, displayName: string, description: string, contextWindow: number) {
    this.slug = slug;
    this.displayName = displayName;
    this.description = description;
    this.contextWindow = contextWindow;
  }
}

export class ModelsCache {
  fetchedAt: string;
  etag: string;
  providerId: string;
  models: ModelsCacheEntry[];

  constructor(fetchedAt: string, etag: string, providerId: string, models: ModelsCacheEntry[]) {
    this.fetchedAt = fetchedAt;
    this.etag = etag;
    this.providerId = providerId;
    this.models = models;
  }
}

export class McpServerRecord {
  id: string;
  name: string;
  enabled: boolean;
  transportType: string;
  command: string;
  argsText: string;
  url: string;
  envText: string;
  httpHeadersText: string;
  toolCount: number;
  resourceCount: number;
  healthStatus: McpHealthStatus;
  authStatus: McpAuthStatus;
  lastError: string;
  syncStatus: McpSyncStatus;
  updatedAt: string;

  constructor(
    id: string,
    name: string,
    enabled: boolean,
    transportType: string,
    command: string,
    argsText: string,
    url: string,
    envText: string,
    httpHeadersText: string,
    toolCount: number,
    resourceCount: number,
    healthStatus: McpHealthStatus,
    authStatus: McpAuthStatus,
    lastError: string,
    syncStatus: McpSyncStatus,
    updatedAt: string
  ) {
    this.id = id;
    this.name = name;
    this.enabled = enabled;
    this.transportType = transportType;
    this.command = command;
    this.argsText = argsText;
    this.url = url;
    this.envText = envText;
    this.httpHeadersText = httpHeadersText;
    this.toolCount = toolCount;
    this.resourceCount = resourceCount;
    this.healthStatus = healthStatus;
    this.authStatus = authStatus;
    this.lastError = lastError;
    this.syncStatus = syncStatus;
    this.updatedAt = updatedAt;
  }
}

export class SessionSummary {
  sessionId: string;
  title: string;
  workspaceId: string;
  workspaceName: string;
  workspaceRoot: string;
  workspacePermissionState: WorkspacePermissionState;
  workspaceAccessKind: WorkspaceAccessKind;
  messageCount: number;
  lastUpdatedAt: string;
  summaryTitle: string;
  status: string;
  changedFiles: string;

  constructor(
    sessionId: string,
    title: string,
    workspaceId: string,
    workspaceName: string,
    workspaceRoot: string,
    workspacePermissionState: WorkspacePermissionState,
    workspaceAccessKind: WorkspaceAccessKind,
    messageCount: number,
    lastUpdatedAt: string,
    summaryTitle: string,
    status: string,
    changedFiles: string
  ) {
    this.sessionId = sessionId;
    this.title = title;
    this.workspaceId = workspaceId;
    this.workspaceName = workspaceName;
    this.workspaceRoot = workspaceRoot;
    this.workspacePermissionState = workspacePermissionState;
    this.workspaceAccessKind = workspaceAccessKind;
    this.messageCount = messageCount;
    this.lastUpdatedAt = lastUpdatedAt;
    this.summaryTitle = summaryTitle;
    this.status = status;
    this.changedFiles = changedFiles;
  }
}

export class UsageSummary {
  sessionCount: number;
  activeTurnCount: number;
  turnCount: number;
  messageCount: number;
  diffLineCount: number;
  diffUpdateCount: number;
  lastTurnStatus: string;

  constructor(
    sessionCount: number,
    activeTurnCount: number,
    turnCount: number,
    messageCount: number,
    diffLineCount: number,
    diffUpdateCount: number,
    lastTurnStatus: string
  ) {
    this.sessionCount = sessionCount;
    this.activeTurnCount = activeTurnCount;
    this.turnCount = turnCount;
    this.messageCount = messageCount;
    this.diffLineCount = diffLineCount;
    this.diffUpdateCount = diffUpdateCount;
    this.lastTurnStatus = lastTurnStatus;
  }
}

export class TokenUsageBreakdown {
  inputTokens: number;
  outputTokens: number;
  cachedInputTokens: number;
  reasoningOutputTokens: number;
  totalTokens: number;
  blendedTotal: number;

  constructor(
    inputTokens: number, outputTokens: number, cachedInputTokens: number,
    reasoningOutputTokens: number, totalTokens: number, blendedTotal?: number
  ) {
    this.inputTokens = inputTokens;
    this.outputTokens = outputTokens;
    this.cachedInputTokens = cachedInputTokens;
    this.reasoningOutputTokens = reasoningOutputTokens;
    this.totalTokens = totalTokens;
    this.blendedTotal = blendedTotal ?? totalTokens;
  }
}

export class TurnTokenUsage {
  total: TokenUsageBreakdown;
  last: TokenUsageBreakdown;
  modelContextWindow: number;
  contextRemainingPercent: number;

  constructor(total: TokenUsageBreakdown, last: TokenUsageBreakdown, modelContextWindow: number, contextRemainingPercent?: number) {
    this.total = total;
    this.last = last;
    this.modelContextWindow = modelContextWindow;
    this.contextRemainingPercent = contextRemainingPercent ?? -1;
  }
}

export class CodexContextManagementSnapshot {
  memoryMode: string | null;
  recentArtifactRefs: string[] | null;
  memoryUsageCount: number | null;
  memoryLastUsageAt: number | null;
  memoryStage1GeneratedAt: number | null;
  memoryStage1UpToDate: boolean | null;
  memoryStage1JobStatus: string | null;
  memoryStage1RetryAt: number | null;
  memoryStage1RetryRemaining: number | null;
  memoryForgettingPending: boolean | null;
  memoryForgettingCompletedAt: number | null;
  memoryPhase2SelectedAt: number | null;
  memoryPhase2UpdatedAt: number | null;
  memoryPhase2SelectionCount: number | null;
  memoryPhase2AddedCount: number | null;
  memoryPhase2RetainedCount: number | null;
  memoryPhase2RemovedCount: number | null;
  memorySummaryUpdatedAt: number | null;
  memorySummaryPreview: string | null;
  lastMicroCompactionAt: number | null;
  lastMicroCompactionItemCount: number | null;
  lastMicroCompactionSavedTokens: number | null;
  compactionFailureCount: number | null;
  compactionCircuitOpen: boolean | null;
  lastFullCompactionTrigger: string | null;
  lastFullCompactionProviderMode: string | null;
  lastFullCompactionTrimmedItemCount: number | null;
  lastFullCompactionReferenceContextReestablished: boolean | null;
  lastContextCompactionAt: number | null;

  constructor(
    memoryMode?: string | null,
    recentArtifactRefs?: string[] | null,
    memoryUsageCount?: number | null,
    memoryLastUsageAt?: number | null,
    memoryStage1GeneratedAt?: number | null,
    memoryStage1UpToDate?: boolean | null,
    memoryStage1JobStatus?: string | null,
    memoryStage1RetryAt?: number | null,
    memoryStage1RetryRemaining?: number | null,
    memoryForgettingPending?: boolean | null,
    memoryForgettingCompletedAt?: number | null,
    memoryPhase2SelectedAt?: number | null,
    memoryPhase2UpdatedAt?: number | null,
    memoryPhase2SelectionCount?: number | null,
    memoryPhase2AddedCount?: number | null,
    memoryPhase2RetainedCount?: number | null,
    memoryPhase2RemovedCount?: number | null,
    memorySummaryUpdatedAt?: number | null,
    memorySummaryPreview?: string | null,
    lastMicroCompactionAt?: number | null,
    lastMicroCompactionItemCount?: number | null,
    lastMicroCompactionSavedTokens?: number | null,
    compactionFailureCount?: number | null,
    compactionCircuitOpen?: boolean | null,
    lastFullCompactionTrigger?: string | null,
    lastFullCompactionProviderMode?: string | null,
    lastFullCompactionTrimmedItemCount?: number | null,
    lastFullCompactionReferenceContextReestablished?: boolean | null,
    lastContextCompactionAt?: number | null
  ) {
    this.memoryMode = memoryMode ?? null;
    this.recentArtifactRefs = recentArtifactRefs ?? null;
    this.memoryUsageCount = memoryUsageCount ?? null;
    this.memoryLastUsageAt = memoryLastUsageAt ?? null;
    this.memoryStage1GeneratedAt = memoryStage1GeneratedAt ?? null;
    this.memoryStage1UpToDate = memoryStage1UpToDate ?? null;
    this.memoryStage1JobStatus = memoryStage1JobStatus ?? null;
    this.memoryStage1RetryAt = memoryStage1RetryAt ?? null;
    this.memoryStage1RetryRemaining = memoryStage1RetryRemaining ?? null;
    this.memoryForgettingPending = memoryForgettingPending ?? null;
    this.memoryForgettingCompletedAt = memoryForgettingCompletedAt ?? null;
    this.memoryPhase2SelectedAt = memoryPhase2SelectedAt ?? null;
    this.memoryPhase2UpdatedAt = memoryPhase2UpdatedAt ?? null;
    this.memoryPhase2SelectionCount = memoryPhase2SelectionCount ?? null;
    this.memoryPhase2AddedCount = memoryPhase2AddedCount ?? null;
    this.memoryPhase2RetainedCount = memoryPhase2RetainedCount ?? null;
    this.memoryPhase2RemovedCount = memoryPhase2RemovedCount ?? null;
    this.memorySummaryUpdatedAt = memorySummaryUpdatedAt ?? null;
    this.memorySummaryPreview = memorySummaryPreview ?? null;
    this.lastMicroCompactionAt = lastMicroCompactionAt ?? null;
    this.lastMicroCompactionItemCount = lastMicroCompactionItemCount ?? null;
    this.lastMicroCompactionSavedTokens = lastMicroCompactionSavedTokens ?? null;
    this.compactionFailureCount = compactionFailureCount ?? null;
    this.compactionCircuitOpen = compactionCircuitOpen ?? null;
    this.lastFullCompactionTrigger = lastFullCompactionTrigger ?? null;
    this.lastFullCompactionProviderMode = lastFullCompactionProviderMode ?? null;
    this.lastFullCompactionTrimmedItemCount = lastFullCompactionTrimmedItemCount ?? null;
    this.lastFullCompactionReferenceContextReestablished =
      lastFullCompactionReferenceContextReestablished ?? null;
    this.lastContextCompactionAt = lastContextCompactionAt ?? null;
  }
}

export class TodayTokenDetail {
  totalTokens: number;
  inputTokens: number;
  outputTokens: number;
  cachedInputTokens: number;
  reasoningOutputTokens: number;
  requestCount: number;

  constructor(
    totalTokens: number, inputTokens: number, outputTokens: number,
    cachedInputTokens: number, reasoningOutputTokens: number, requestCount: number
  ) {
    this.totalTokens = totalTokens;
    this.inputTokens = inputTokens;
    this.outputTokens = outputTokens;
    this.cachedInputTokens = cachedInputTokens;
    this.reasoningOutputTokens = reasoningOutputTokens;
    this.requestCount = requestCount;
  }
}

export class DailyTokenSnapshot {
  date: string;
  totalTokens: number;
  requestCount: number;

  constructor(date: string, totalTokens: number, requestCount: number) {
    this.date = date;
    this.totalTokens = totalTokens;
    this.requestCount = requestCount;
  }
}

export class TokenUsageAggregate {
  today: TodayTokenDetail;
  daily: DailyTokenSnapshot[];

  constructor(today: TodayTokenDetail, daily: DailyTokenSnapshot[]) {
    this.today = today;
    this.daily = daily;
  }
}

export class ProjectRecord {
  id: string;
  name: string;
  path: string;
  expanded: boolean;
  sourceUri: string;

  constructor(id: string, name: string, path: string, expanded?: boolean, sourceUri?: string) {
    this.id = id;
    this.name = name;
    this.path = path;
    this.expanded = expanded ?? true;
    this.sourceUri = sourceUri ?? '';
  }
}

export class ProjectStoreSnapshot {
  projects: ProjectRecord[];
  constructor(projects: ProjectRecord[]) {
    this.projects = projects;
  }
}

export class WorkspaceItem {
  id: number;
  title: string;
  description: string;
  workspaceId: string;
  projectId: string;

  constructor(id: number, title: string, description: string, workspaceId?: string, projectId?: string) {
    this.id = id;
    this.title = title;
    this.description = description;
    this.workspaceId = workspaceId ?? `session:${id.toString()}`;
    this.projectId = projectId ?? '';
  }
}

export class WorkspaceBindingDraft {
  id: number;
  title: string;
  description: string;
  workspaceId: string;
  workspaceRoot: string;
  workspaceUri: string;
  projectId: string;

  constructor(id: number, title: string, description: string, workspaceId: string, workspaceRoot: string, workspaceUri?: string, projectId?: string) {
    this.id = id;
    this.title = title;
    this.description = description;
    this.workspaceId = workspaceId;
    this.workspaceRoot = workspaceRoot;
    this.workspaceUri = workspaceUri ?? '';
    this.projectId = projectId ?? '';
  }
}

export class WorkspaceDirectorySelection {
  rootPath: string;
  sourceUri: string;

  constructor(rootPath: string, sourceUri: string) {
    this.rootPath = rootPath;
    this.sourceUri = sourceUri;
  }
}

export class SelectorOption {
  label: string;
  value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

export class SidebarItem {
  view: SidebarView;
  label: string;
  description: string;

  constructor(view: SidebarView, label: string, description: string) {
    this.view = view;
    this.label = label;
    this.description = description;
  }
}
