import { http } from '@kit.NetworkKit';
import {
  saveEmbeddedCodexProviderConfig,
  CodexProviderConfig
} from '../backend/CodexNative';
import {
  AiAppType, ProviderMode, ProviderSyncStatus, ApiWireFormat,
  ProviderRecord, EndpointEntry, CustomHeadersEntry, ProviderCatalog,
  ProviderDefinition
} from '../backend/ConsoleModels';
import { providerConfigStore } from '../backend/ProviderConfigStore';
import {
  ProviderPreset, BUILTIN_PROVIDER_PRESETS, findPresetById,
  ApiValidationResult, EndpointSpeedResult, ChatProbeResult, UsageQueryResult,
  ApiError, ApiErrorCode
} from './ApiTypes';

const DEFAULT_TIMEOUT_MS = 10000;
const MAX_NAME_LEN = 100;
const MAX_ENDPOINTS_PER_PROVIDER = 5;

// ── JSON data classes for API responses ──

class ModelIdEntry {
  id: string = '';
}

class ModelsData {
  data: ModelIdEntry[] = [];
}

class ChatErrorDetail {
  message: string = '';
}

class ChatErrorBody {
  error: ChatErrorDetail = new ChatErrorDetail();
}

class UsagePlanItem {
  title: string = '';
}

class OpenAIUsageData {
  plan: UsagePlanItem = new UsagePlanItem();
  hard_limit_usd: number = 0;
  total_usage: number = 0;
  soft_limit_usd: string = '';
}

class ResponsesProbeBody {
  model: string = '';
  input: string = '';
  max_output_tokens: number = 0;
}

class ProviderImportEntry {
  name: string = '';
  baseUrl: string = '';
  apiKey: string = '';
  model: string = '';
}

class ProviderExportDoc {
  version: number = 1;
  exportedAt: string = '';
  providers: ProviderRecord[] = [];
}

function currentTimestamp(): string {
  const now: Date = new Date();
  const year: string = now.getFullYear().toString();
  const month: string = (now.getMonth() + 1).toString().padStart(2, '0');
  const day: string = now.getDate().toString().padStart(2, '0');
  const hours: string = now.getHours().toString().padStart(2, '0');
  const minutes: string = now.getMinutes().toString().padStart(2, '0');
  return `${year}-${month}-${day} ${hours}:${minutes}`;
}

function isValidUrl(url: string): boolean {
  if (url.length === 0) return false;
  const lower = url.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

function parseModelsResponse(body: string): ApiValidationResult {
  const excludeList = [
    'embedding', 'moderation', 'tts', 'whisper',
    'dall-e', 'dalle', 'audio', 'text-embedding',
    'babbage', 'davinci', 'gpt-3.5-turbo-instruct'
  ];
  try {
    const parsed: ModelsData = JSON.parse(body) as ModelsData;
    const dataArr: ModelIdEntry[] = parsed.data;
    const models: string[] = [];
    for (let i = 0; i < dataArr.length; i++) {
      const id = dataArr[i].id;
      if (id.length === 0) continue;
      let excluded = false;
      const idLower = id.toLowerCase();
      for (let j = 0; j < excludeList.length; j++) {
        if (idLower.includes(excludeList[j])) {
          excluded = true;
          break;
        }
      }
      if (!excluded) {
        models.push(id);
        if (models.length >= 100) break;
      }
    }
    models.sort();
    const info = models.length > 0
      ? `${models.length} 个模型可用`
      : '未找到可用模型';
    return new ApiValidationResult(true, 200, 0, '', models.length, info);
  } catch (e) {
    return new ApiValidationResult(true, 200, 0, '', 0, '无法解析模型列表');
  }
}

function cleanBaseUrl(url: string): string {
  let result = url.trim();
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

// ── config store helpers ──

function loadProvidersFromStore(): ProviderRecord[] {
  const defs: ProviderDefinition[] = providerConfigStore.loadDefinitions();
  const creds: Map<string, string> = providerConfigStore.loadCredentials();
  const providers: ProviderRecord[] = [];
  for (let i = 0; i < defs.length; i++) {
    const def: ProviderDefinition = defs[i];
    const apiKey: string = creds.get(def.id) ?? '';
    providers.push(new ProviderRecord(
      def.id, def.name, def.appType as AiAppType, def.mode as ProviderMode,
      def.baseUrl, apiKey, def.model,
      def.isActive, def.syncStatus as ProviderSyncStatus, def.updatedAt,
      'apiKey', [], def.wireApi as ApiWireFormat,
      'custom', '', '', '', '',
      [], 'unknown', 0, 0, null, Date.now(),
      def.contextWindow,
      def.modelAutoCompactTokenLimit
    ));
  }
  return providers;
}

function saveProvidersToStore(providers: ProviderRecord[]): void {
  const defs: ProviderDefinition[] = [];
  const creds: Map<string, string> = new Map();
  for (let i = 0; i < providers.length; i++) {
    const rec: ProviderRecord = providers[i];
    defs.push(new ProviderDefinition(
      rec.id, rec.name, rec.baseUrl, rec.model,
      rec.wireApi, rec.isActive, rec.appType, rec.mode,
      rec.syncStatus, rec.updatedAt, rec.contextWindow,
      rec.modelAutoCompactTokenLimit
    ));
    creds.set(rec.id, rec.apiKey);
  }
  let activeId: string = '';
  for (let i = 0; i < providers.length; i++) {
    if (providers[i].isActive) {
      activeId = providers[i].id;
      break;
    }
  }
  // 先同步 native catalog；若失败则中止，不落盘（避免文件与内存/native 状态不一致）
  providerConfigStore.syncToNativeCatalog(defs, creds);
  providerConfigStore.saveDefinitions(defs, activeId);
  providerConfigStore.saveCredentials(creds);
}

export class ApiManagementService {
  getProviders(): ProviderRecord[] {
    return loadProvidersFromStore();
  }

  private saveProviders(providers: ProviderRecord[]): void {
    saveProvidersToStore(providers);
  }

  reorderProviders(providers: ProviderRecord[]): void {
    saveProvidersToStore(providers);
  }

  createFromPreset(presetId: string, apiKey: string): ProviderRecord {
    const preset = findPresetById(presetId);
    if (preset === undefined) {
      throw new ApiError(ApiErrorCode.PRESET_NOT_FOUND, presetId, '预设不存在');
    }
    return preset.toProviderRecord(apiKey);
  }

  saveProvider(provider: ProviderRecord): void {
    const name = provider.name.trim();
    if (name.length === 0 || name.length > MAX_NAME_LEN) {
      throw new ApiError(ApiErrorCode.INVALID_NAME, provider.name,
        '名称不能为空且不超过 100 个字符');
    }

    const baseUrl = provider.baseUrl.trim();
    if (baseUrl.length > 0 && !isValidUrl(baseUrl)) {
      throw new ApiError(ApiErrorCode.INVALID_URL, baseUrl,
        'Base URL 格式不合法');
    }

    provider.name = name;
    provider.baseUrl = baseUrl;
    provider.updatedAt = currentTimestamp();

    const providers = this.getProviders();
    let found = false;
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].id === provider.id) {
        providers[i] = provider;
        found = true;
        break;
      }
    }
    if (!found) {
      providers.push(provider);
    }

    this.saveProviders(providers);
  }

  deleteProvider(id: string): void {
    const providers = this.getProviders();
    let target: ProviderRecord | null = null;
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].id === id) {
        target = providers[i];
        break;
      }
    }

    if (target === null) {
      throw new ApiError(ApiErrorCode.PROVIDER_NOT_FOUND, id, 'Provider 不存在');
    }
    if (target.isActive) {
      throw new ApiError(ApiErrorCode.CANNOT_DELETE_ACTIVE,
        `${id} ${target.name}`,
        '无法删除当前已激活的 Provider，请先切换到其他 Provider');
    }

    const filtered: ProviderRecord[] = [];
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].id !== id) {
        filtered.push(providers[i]);
      }
    }
    this.saveProviders(filtered);
  }

  activateProvider(id: string): ProviderRecord {
    const providers = this.getProviders();
    let target: ProviderRecord | null = null;
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].id === id) {
        target = providers[i];
        break;
      }
    }

    if (target === null) {
      throw new ApiError(ApiErrorCode.PROVIDER_NOT_FOUND, id, 'Provider 不存在');
    }
    if (target.isActive) {
      return target;
    }

    for (let i = 0; i < providers.length; i++) {
      providers[i].isActive = false;
      providers[i].syncStatus = 'dirty';
    }
    target.isActive = true;

    try {
      const saved: CodexProviderConfig = saveEmbeddedCodexProviderConfig(
        target.baseUrl,
        target.apiKey,
        target.model,
        target.contextWindow,
        target.modelAutoCompactTokenLimit
      );
      target.baseUrl = saved.baseUrl;
      target.apiKey = saved.apiKey;
      target.model = saved.model;
      target.contextWindow = saved.contextWindow;
      target.modelAutoCompactTokenLimit = saved.modelAutoCompactTokenLimit;
      target.syncStatus = 'synced';
    } catch (e) {
      target.syncStatus = 'error';
      throw new ApiError(ApiErrorCode.SYNC_FAILED,
        `${target.name} ${e}`,
        '写入 live 配置文件失败，Provider 切换可能未生效');
    }

    target.updatedAt = currentTimestamp();
    this.saveProviders(providers);

    return target;
  }

  // ========== API Key 连通性验证 ==========

  async validateApiKey(
    baseUrl: string, apiKey: string
  ): Promise<ApiValidationResult> {
    const trimmedBaseUrl = cleanBaseUrl(baseUrl);
    const trimmedApiKey = apiKey.trim();

    if (trimmedBaseUrl.length === 0) {
      return new ApiValidationResult(false, 0, 0, 'Base URL 为空', 0, '');
    }
    if (trimmedApiKey.length === 0) {
      return new ApiValidationResult(false, 0, 0, 'API Key 为空', 0, '');
    }

    const startTime = Date.now();

    // Strategy 1: GET /models
    const modelsUrl = `${trimmedBaseUrl}/models`;
    const httpRequest = http.createHttp();
    try {
      const modelsResponse = await httpRequest.request(modelsUrl, {
        method: http.RequestMethod.GET,
        header: {
          'Authorization': `Bearer ${trimmedApiKey}`,
          'Content-Type': 'application/json'
        },
        connectTimeout: DEFAULT_TIMEOUT_MS,
        readTimeout: DEFAULT_TIMEOUT_MS
      });

      const latency = Date.now() - startTime;

      if (modelsResponse.responseCode === 200) {
        const body = modelsResponse.result as string;
        const result = parseModelsResponse(body);
        result.latencyMs = latency;
        result.statusCode = modelsResponse.responseCode;
        return result;
      }
    } catch (e) {
      // /models failed, fall through to strategy 2
    } finally {
      httpRequest.destroy();
    }

    // Strategy 2: POST /responses minimal probe
    const responsesUrl = `${trimmedBaseUrl}/responses`;
    const httpRequest2 = http.createHttp();
    try {
      const probeObj: ResponsesProbeBody = new ResponsesProbeBody();
      probeObj.model = 'gpt-4o-mini';
      probeObj.input = 'hi';
      probeObj.max_output_tokens = 1;
      const probeBody = JSON.stringify(probeObj);

      const chatResponse = await httpRequest2.request(responsesUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${trimmedApiKey}`,
          'Content-Type': 'application/json'
        },
        extraData: probeBody,
        connectTimeout: DEFAULT_TIMEOUT_MS,
        readTimeout: DEFAULT_TIMEOUT_MS
      });

      const latency = Date.now() - startTime;
      const status = chatResponse.responseCode;

      if (status === 200 || status === 201) {
        return new ApiValidationResult(
          true, status, latency,
          '', 0, 'API 连通性正常（通过 Responses API 探测）'
        );
      }

      const errorBody = (chatResponse.result as string) ?? '';
      let errorMsg = '';
      try {
        const errParsed: ChatErrorBody = JSON.parse(errorBody) as ChatErrorBody;
        const errDetail: ChatErrorDetail = errParsed.error;
        if (errDetail !== null && errDetail.message.length > 0) {
          errorMsg = errDetail.message;
        }
      } catch (e2) {
        // ignore parse error
      }
      if (errorMsg.length === 0) {
        errorMsg = `API 返回 HTTP ${status}`;
      }

      return new ApiValidationResult(false, status, latency, errorMsg, 0, '');
    } catch (e) {
      const latency = Date.now() - startTime;
      return new ApiValidationResult(
        false, 0, latency,
        `连接失败：${e}`,
        0, ''
      );
    } finally {
      httpRequest2.destroy();
    }
  }

  // ========== 端点测速 ==========

  private async probeChatEndpoint(
    baseUrl: string, apiKey: string, model: string
  ): Promise<ChatProbeResult> {
    const trimmedUrl = cleanBaseUrl(baseUrl);
    const effectiveModel: string = model.length > 0 ? model : 'gpt-4o-mini';
    const chatUrl = `${trimmedUrl}/responses`;
    const respBody = new ResponsesProbeBody();
    respBody.model = effectiveModel;
    respBody.input = 'hi';
    respBody.max_output_tokens = 1;
    const body = JSON.stringify(respBody);

    const startTime: number = Date.now();
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(chatUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiKey}`
        },
        extraData: body,
        connectTimeout: 15000,
        readTimeout: 15000
      });

      const latency: number = Date.now() - startTime;
      const status: number = response.responseCode;
      const ok: boolean = status === 200 || status === 201;

      if (ok) {
        return new ChatProbeResult(true, latency, status, '');
      }

      let errMsg: string = `HTTP ${status}`;
      try {
        const errBody: string = response.result as string;
        const errJson: ChatErrorBody = JSON.parse(errBody) as ChatErrorBody;
        if (errJson.error !== null && errJson.error !== undefined &&
          errJson.error.message !== null && errJson.error.message !== undefined &&
          errJson.error.message.length > 0) {
          errMsg = errJson.error.message;
        }
      } catch (_) {
        // use default error message
      }
      return new ChatProbeResult(false, latency, status, errMsg);
    } catch (e) {
      return new ChatProbeResult(false, Date.now() - startTime, 0, `${e}`);
    } finally {
      httpRequest.destroy();
    }
  }

  async testEndpointSpeed(
    provider: ProviderRecord, autoSelect: boolean
  ): Promise<EndpointSpeedResult[]> {
    const urls: string[] = [];
    if (provider.endpoints.length > 0) {
      for (let i = 0; i < provider.endpoints.length; i++) {
        urls.push(provider.endpoints[i].url);
      }
    } else {
      urls.push(provider.baseUrl);
    }

    const results: EndpointSpeedResult[] = [];

    for (let i = 0; i < urls.length; i++) {
      const url = urls[i];
      const trimmedUrl = cleanBaseUrl(url);
      const startTime = Date.now();

      try {
        const httpRequest = http.createHttp();
        try {
          const response = await httpRequest.request(`${trimmedUrl}/models`, {
            method: http.RequestMethod.GET,
            header: {
              'Authorization': `Bearer ${provider.apiKey}`,
              'Content-Type': 'application/json'
            },
            connectTimeout: 8000,
            readTimeout: 8000
          });

          const latency = Date.now() - startTime;
          const modelsOk = response.responseCode === 200;

          // /models 通过后再测真实对话
          let chatProbe: ChatProbeResult | null = null;
          if (modelsOk) {
            chatProbe = await this.probeChatEndpoint(
              trimmedUrl, provider.apiKey, provider.model
            );
          }

          results.push(new EndpointSpeedResult(
            trimmedUrl, latency, response.responseCode,
            modelsOk, '', Date.now(), chatProbe
          ));
        } finally {
          httpRequest.destroy();
        }
      } catch (e) {
        results.push(new EndpointSpeedResult(
          trimmedUrl, 0, 0, false, `${e}`, Date.now()
        ));
      }
    }

    // Sort: success first, then by latency
    results.sort((a: EndpointSpeedResult, b: EndpointSpeedResult): number => {
      if (a.success !== b.success) return a.success ? -1 : 1;
      if (a.success) return a.latencyMs - b.latencyMs;
      return 0;
    });

    // 始终更新健康状态（综合 /models + 对话探测）
    if (results.length > 0) {
      const best = results[0];
      if (best.success && best.chatProbe !== null && best.chatProbe.success) {
        provider.healthStatus = 'healthy';
        provider.healthLatencyMs = best.chatProbe.latencyMs;
      } else if (best.success) {
        provider.healthStatus = 'degraded';
        provider.healthLatencyMs = best.latencyMs;
      } else {
        provider.healthStatus = 'error';
        provider.healthLatencyMs = 0;
      }
      provider.lastValidatedAt = Date.now();

      for (let i = 0; i < provider.endpoints.length; i++) {
        const e = provider.endpoints[i];
        for (let j = 0; j < results.length; j++) {
          if (results[j].endpointUrl === e.url) {
            e.latencyMs = results[j].latencyMs;
            break;
          }
        }
      }
    }

    // autoSelect 时自动切换到最快的端点
    if (autoSelect && results.length > 0 && results[0].success) {
      const fastest = results[0];
      provider.baseUrl = fastest.endpointUrl;
      for (let i = 0; i < provider.endpoints.length; i++) {
        provider.endpoints[i].isActive = provider.endpoints[i].url === fastest.endpointUrl;
      }
    }

    this.saveProvider(provider);

    return results;
  }

  // ========== 模型发现 ==========

  async discoverModels(baseUrl: string, apiKey: string): Promise<string[]> {
    const trimmedUrl = cleanBaseUrl(baseUrl);
    const modelsUrl = `${trimmedUrl}/models`;

    try {
      const httpRequest = http.createHttp();
      try {
        const response = await httpRequest.request(modelsUrl, {
          method: http.RequestMethod.GET,
          header: {
            'Authorization': `Bearer ${apiKey}`,
            'Content-Type': 'application/json'
          },
          connectTimeout: DEFAULT_TIMEOUT_MS,
          readTimeout: DEFAULT_TIMEOUT_MS
        });

        if (response.responseCode !== 200) {
          throw new ApiError(ApiErrorCode.MODEL_FETCH_FAILED,
            `${response.responseCode}`,
            `获取模型列表失败，HTTP ${response.responseCode}`);
        }

        const body = response.result as string;
        const models: string[] = [];
        try {
          const parsed: ModelsData = JSON.parse(body) as ModelsData;
          const dataArr: ModelIdEntry[] = parsed.data;
          for (let i = 0; i < dataArr.length; i++) {
            const id = dataArr[i].id;
            if (id.length > 0) {
              models.push(id);
              if (models.length >= 100) break;
            }
          }
          models.sort();
        } catch (e2) {
          // ignore
        }

        return models;
      } finally {
        httpRequest.destroy();
      }
    } catch (e) {
      if (e instanceof ApiError) throw e;
      throw new ApiError(ApiErrorCode.MODEL_FETCH_FAILED,
        `${e}`,
        `获取模型列表失败: ${e}`);
    }
  }

  // ========== 用量查询 ==========

  async queryUsage(provider: ProviderRecord): Promise<UsageQueryResult> {
    if (provider.usageScript === null || !provider.usageScript.enabled) {
      throw new ApiError(ApiErrorCode.USAGE_NOT_CONFIGURED, '',
        '此 Provider 未配置用量查询');
    }

    if (provider.usageScript.scriptType === 'openai') {
      return this.queryOpenAIUsage(provider);
    }

    throw new ApiError(ApiErrorCode.USAGE_UNSUPPORTED,
      provider.usageScript.scriptType,
      `不支持的用量查询类型: ${provider.usageScript.scriptType}`);
  }

  private async queryOpenAIUsage(provider: ProviderRecord): Promise<UsageQueryResult> {
    const baseUrl = cleanBaseUrl(provider.baseUrl);
    const subscriptionUrl = `${baseUrl}/dashboard/billing/subscription`;

    try {
      const httpRequest = http.createHttp();
      try {
        const response = await httpRequest.request(subscriptionUrl, {
          method: http.RequestMethod.GET,
          header: {
            'Authorization': `Bearer ${provider.apiKey}`,
            'Content-Type': 'application/json'
          },
          connectTimeout: DEFAULT_TIMEOUT_MS,
          readTimeout: DEFAULT_TIMEOUT_MS
        });

        if (response.responseCode !== 200) {
          return new UsageQueryResult(
            false, provider.name, '', 0, 0, 0, 'USD', '',
            Date.now(), `HTTP ${response.responseCode}`
          );
        }

        const data: OpenAIUsageData = JSON.parse(response.result as string) as OpenAIUsageData;
        const planTitle = data.plan.title.length > 0 ? data.plan.title : 'Unknown Plan';
        const hardLimit: number = data.hard_limit_usd;
        const totalUsage: number = data.total_usage;
        const softLimit = data.soft_limit_usd.length > 0 ? data.soft_limit_usd : 'N/A';
        const hardLimitStr = data.hard_limit_usd.toString();

        return new UsageQueryResult(
          true, provider.name,
          planTitle,
          hardLimit,
          totalUsage,
          hardLimit - totalUsage,
          'USD',
          `软限制: ${softLimit} / 硬限制: ${hardLimitStr}`,
          Date.now(),
          ''
        );
      } finally {
        httpRequest.destroy();
      }
    } catch (e) {
      return new UsageQueryResult(
        false, provider.name, '', 0, 0, 0, 'USD', '',
        Date.now(), `${e}`
      );
    }
  }

  // ========== 端点管理 ==========

  addEndpoint(provider: ProviderRecord, url: string): void {
    const trimmedUrl = url.trim();
    if (!isValidUrl(trimmedUrl)) {
      throw new ApiError(ApiErrorCode.INVALID_URL, url, '端点 URL 格式不合法');
    }

    if (provider.endpoints.length >= MAX_ENDPOINTS_PER_PROVIDER) {
      throw new ApiError(ApiErrorCode.TOO_MANY_ENDPOINTS,
        `${MAX_ENDPOINTS_PER_PROVIDER}`,
        `每个 Provider 最多 ${MAX_ENDPOINTS_PER_PROVIDER} 个端点`);
    }

    provider.endpoints.push(new EndpointEntry(trimmedUrl, Date.now(), 0, 0, false));
    this.saveProvider(provider);
  }

  removeEndpoint(provider: ProviderRecord, url: string): void {
    const newEndpoints: EndpointEntry[] = [];
    for (let i = 0; i < provider.endpoints.length; i++) {
      if (provider.endpoints[i].url !== url) {
        newEndpoints.push(provider.endpoints[i]);
      }
    }
    provider.endpoints = newEndpoints;
    this.saveProvider(provider);
  }

  // ========== 预设管理 ==========

  getPresets(): ProviderPreset[] {
    return BUILTIN_PROVIDER_PRESETS;
  }

  getPresetsByCategory(category: string): ProviderPreset[] {
    const result: ProviderPreset[] = [];
    const presets = BUILTIN_PROVIDER_PRESETS;
    for (let i = 0; i < presets.length; i++) {
      if (presets[i].category === category) {
        result.push(presets[i]);
      }
    }
    return result;
  }

  // ========== 导入导出 ==========

  exportProviders(): string {
    const providers = this.getProviders();
    const exportDoc: ProviderExportDoc = new ProviderExportDoc();
    exportDoc.version = 1;
    exportDoc.exportedAt = new Date().toISOString();
    exportDoc.providers = providers;
    return JSON.stringify(exportDoc, null, 2);
  }

  exportProvidersMasked(): string {
    const providers = this.getProviders();
    const masked: ProviderRecord[] = [];
    for (let i = 0; i < providers.length; i++) {
      const rec: ProviderRecord = providers[i];
      masked.push(new ProviderRecord(
        rec.id, rec.name, rec.appType, rec.mode,
        rec.baseUrl, '***', rec.model,
        rec.isActive, rec.syncStatus, rec.updatedAt,
        rec.authMode, rec.copyHeaders(), rec.wireApi,
        rec.category, rec.description, rec.websiteUrl,
        rec.icon, rec.iconColor, rec.endpoints,
        rec.healthStatus, rec.healthLatencyMs, rec.lastValidatedAt,
        rec.usageScript, rec.createdAt, rec.contextWindow,
        rec.modelAutoCompactTokenLimit
      ));
    }
    const exportDoc: ProviderExportDoc = new ProviderExportDoc();
    exportDoc.version = 1;
    exportDoc.exportedAt = new Date().toISOString();
    exportDoc.providers = masked;
    return JSON.stringify(exportDoc, null, 2);
  }

  importProviders(json: string): number {
    const data: ProviderExportDoc = JSON.parse(json) as ProviderExportDoc;
    const importedProviders: ProviderRecord[] = data.providers;
    const existing = this.getProviders();
    let count = 0;

    for (let i = 0; i < importedProviders.length; i++) {
      const raw = importedProviders[i];
      const name = raw.name;
      const baseUrl = raw.baseUrl;
      const apiKey = raw.apiKey;
      const model = raw.model;
      const contextWindow = raw.contextWindow ?? 0;
      const modelAutoCompactTokenLimit = raw.modelAutoCompactTokenLimit ?? 0;

      let duplicateFound = false;
      for (let j = 0; j < existing.length; j++) {
        if (existing[j].baseUrl === baseUrl && existing[j].name === name) {
          duplicateFound = true;
          break;
        }
      }
      if (duplicateFound) continue;

      const provider = new ProviderRecord(
        `provider-${Date.now()}-${Math.floor(Math.random() * 1000)}`,
        name, 'codex', 'exclusive',
        baseUrl, apiKey, model,
        false, 'dirty', '',
        'apiKey', [], 'responses',
        'custom', '', '', '', '',
        [], 'unknown', 0, 0,
        null, Date.now(), contextWindow, modelAutoCompactTokenLimit
      );

      existing.push(provider);
      count++;
    }

    if (count > 0) {
      this.saveProviders(existing);
    }

    return count;
  }

  // ========== 健康检查 ==========

  checkProviderHealth(provider: ProviderRecord): void {
    if (provider.apiKey.trim().length === 0) {
      provider.healthStatus = 'unknown';
      return;
    }
    if (provider.lastValidatedAt > 0 &&
      (Date.now() - provider.lastValidatedAt) < 300000) {
      return;
    }
    provider.healthStatus = 'unknown';
  }
}

function findActiveId(providers: ProviderRecord[]): string {
  for (let i = 0; i < providers.length; i++) {
    if (providers[i].isActive) {
      return providers[i].id;
    }
  }
  return '';
}

export const apiManagementService: ApiManagementService = new ApiManagementService();
