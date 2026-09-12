import {
  ProviderRecord, ProviderCategory, ApiWireFormat, ProviderSyncStatus,
  EndpointEntry, CustomHeadersEntry, UsageScriptEntry
} from '../backend/ConsoleModels';

export { ProviderRecord, ProviderCategory, ApiWireFormat, ProviderSyncStatus, EndpointEntry, CustomHeadersEntry, UsageScriptEntry } from '../backend/ConsoleModels';

export class ProviderPreset {
  id: string;
  name: string;
  category: ProviderCategory;
  baseUrl: string;
  defaultModel: string;
  models: string[];
  wireApi: ApiWireFormat;
  websiteUrl: string;
  apiKeyUrl: string;
  icon: string;
  iconColor: string;
  description: string;
  authMode: string;
  customHeaders: CustomHeadersEntry[];
  isOfficial: boolean;

  constructor(
    id: string, name: string, category: ProviderCategory,
    baseUrl: string, defaultModel: string, models: string[],
    wireApi: ApiWireFormat, websiteUrl: string, apiKeyUrl: string,
    icon: string, iconColor: string, description: string,
    authMode: string, customHeaders: CustomHeadersEntry[],
    isOfficial: boolean
  ) {
    this.id = id;
    this.name = name;
    this.category = category;
    this.baseUrl = baseUrl;
    this.defaultModel = defaultModel;
    this.models = models;
    this.wireApi = wireApi;
    this.websiteUrl = websiteUrl;
    this.apiKeyUrl = apiKeyUrl;
    this.icon = icon;
    this.iconColor = iconColor;
    this.description = description;
    this.authMode = authMode;
    this.customHeaders = customHeaders;
    this.isOfficial = isOfficial;
  }

  toProviderRecord(apiKey: string): ProviderRecord {
    const headers: CustomHeadersEntry[] = [];
    for (let i = 0; i < this.customHeaders.length; i++) {
      const h = this.customHeaders[i];
      headers.push(new CustomHeadersEntry(h.key, h.value));
    }
    return new ProviderRecord(
      `provider-${Date.now()}-${Math.floor(Math.random() * 1000)}`,
      this.name, 'codex', 'exclusive',
      this.baseUrl, apiKey, this.defaultModel,
      false, 'dirty', '',
      this.authMode, headers,
      this.wireApi, this.category,
      '', this.websiteUrl,
      this.icon, this.iconColor,
      [], 'unknown', 0, 0,
      null, Date.now()
    );
  }
}

export const BUILTIN_PROVIDER_PRESETS: ProviderPreset[] = [
  // ── 官方 ──
  new ProviderPreset(
    'openai-official', 'OpenAI', 'official',
    'https://api.openai.com/v1', 'gpt-5.4',
    ['gpt-5.4', 'gpt-5.2', 'gpt-5.1', 'gpt-5-mini', 'gpt-4.1', 'o4-mini'],
    'responses', 'https://platform.openai.com', 'https://platform.openai.com/api-keys',
    'openai', '#00A67E', 'OpenAI 官方 API，支持 Responses API',
    'apiKey', [], true
  ),
  new ProviderPreset(
    'google-official', 'Google AI', 'official',
    'https://generativelanguage.googleapis.com/v1beta/openai', 'gemini-3.1-pro',
    ['gemini-3.1-pro', 'gemini-3-flash-preview', 'gemini-2.5-pro', 'gemini-2.5-flash'],
    'responses', 'https://ai.google.dev/gemini-api', 'https://aistudio.google.com/apikey',
    'google', '#4285F4', 'Google AI 官方 API，Gemini 系列模型',
    'apiKey', [], true
  ),
  new ProviderPreset(
    'deepseek', 'DeepSeek', 'official',
    'https://api.deepseek.com/v1', 'deepseek-v4-pro',
    ['deepseek-v4-pro', 'deepseek-v4-flash', 'deepseek-v4-reasoner'],
    'responses', 'https://platform.deepseek.com', 'https://platform.deepseek.com/api_keys',
    'deepseek', '#4D6BFE', 'DeepSeek 官方 API，OpenAI 兼容格式',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'zhipu', 'ZhipuGLM (智谱)', 'official',
    'https://open.bigmodel.cn/api/paas/v4', 'glm-5',
    ['glm-5'],
    'responses', 'https://open.bigmodel.cn', 'https://open.bigmodel.cn/usercenter/apikeys',
    'zhipu', '#1677FF', '智谱 AI，GLM-5 模型，OpenAI 兼容格式',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'kimi', 'Kimi', 'official',
    'https://api.moonshot.cn/v1', 'kimi-k2.6',
    ['kimi-k2.6'],
    'responses', 'https://platform.moonshot.cn/console', 'https://platform.moonshot.cn/console/api-keys',
    'moonshot', '#000000', 'Moonshot AI Kimi 平台，kimi-k2.6 模型',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'dashscope', 'Bailian (阿里百炼)', 'official',
    'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen3-coder-plus',
    ['qwen3.5-plus', 'qwen3-coder-plus', 'qwen3-max', 'qwen-plus'],
    'responses', 'https://bailian.console.aliyun.com', 'https://bailian.console.aliyun.com/?apiKey=1',
    'alibaba', '#FF6A00', '阿里云百炼平台，通义千问系列，OpenAI 兼容',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'minimax', 'MiniMax', 'official',
    'https://api.minimaxi.com/v1', 'MiniMax-M2.7',
    ['MiniMax-M2.7'],
    'responses', 'https://platform.minimaxi.com', 'https://platform.minimaxi.com',
    'minimax', '#6B21A8', 'MiniMax 开放平台，MiniMax-M2.7 模型',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'doubao', 'DouBaoSeed (豆包)', 'official',
    'https://ark.cn-beijing.volces.com/api/v3', 'doubao-seed-2-0-code-preview-latest',
    ['doubao-seed-2-0-code-preview-latest'],
    'responses', 'https://www.volcengine.com/product/doubao', 'https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey',
    'bytedance', '#325AB4', '火山引擎豆包 Seed 系列代码模型',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'mimo', 'Xiaomi MiMo', 'official',
    'https://api.xiaomimimo.com/v1', 'mimo-v2-pro',
    ['mimo-v2-pro'],
    'responses', 'https://platform.xiaomimimo.com', 'https://platform.xiaomimimo.com',
    'xiaomi', '#FF6900', '小米 MiMo 开放平台，mimo-v2-pro 模型',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'stepfun', 'StepFun (阶跃星辰)', 'official',
    'https://api.stepfun.com/v1', 'step-3.5-flash-2603',
    ['step-3.5-flash-2603', 'step-3.5-flash'],
    'responses', 'https://platform.stepfun.com/step-plan', 'https://platform.stepfun.com/step-plan',
    'stepfun', '#0052D9', '阶跃星辰 Step API',
    'apiKey', [], false
  ),
  // ── 聚合商 ──
  new ProviderPreset(
    'openrouter', 'OpenRouter', 'aggregator',
    'https://openrouter.ai/api/v1', 'anthropic/claude-sonnet-4.6',
    ['anthropic/claude-opus-4.7', 'anthropic/claude-sonnet-4.6', 'openai/gpt-5.4',
     'google/gemini-3.1-pro', 'deepseek/deepseek-v4-pro'],
    'responses', 'https://openrouter.ai', 'https://openrouter.ai/keys',
    'openrouter', '#6366F1', 'OpenRouter 多模型聚合平台',
    'apiKey', [new CustomHeadersEntry('HTTP-Referer', 'https://github.com/ArkPilot'),
              new CustomHeadersEntry('X-Title', 'ArkPilot')], false
  ),
  new ProviderPreset(
    'shengsuanyun', 'Shengsuanyun (盛算云)', 'aggregator',
    'https://router.shengsuanyun.com/api', 'claude-sonnet-4-6',
    ['claude-opus-4-7', 'claude-sonnet-4-6', 'gpt-5.4', 'gemini-3.1-pro'],
    'responses', 'https://www.shengsuanyun.com', 'https://www.shengsuanyun.com',
    'shengsuanyun', '#E11D48', '盛算云，多模型聚合平台',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'aihubmix', 'AiHubMix', 'aggregator',
    'https://aihubmix.com', 'claude-sonnet-4-6',
    ['claude-opus-4-7', 'claude-sonnet-4-6', 'gpt-5.4'],
    'responses', 'https://aihubmix.com', 'https://aihubmix.com',
    'aihubmix', '#8B5CF6', 'AiHubMix 多模型聚合平台',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'dmxapi', 'DMXAPI', 'aggregator',
    'https://www.dmxapi.cn', 'claude-sonnet-4-6',
    ['claude-opus-4-7', 'claude-sonnet-4-6', 'gpt-5.4'],
    'responses', 'https://www.dmxapi.cn', 'https://www.dmxapi.cn',
    'dmxapi', '#0EA5E9', 'DMXAPI 聚合平台',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'therouter', 'TheRouter', 'aggregator',
    'https://api.therouter.ai/v1', 'anthropic/claude-sonnet-4.6',
    ['anthropic/claude-sonnet-4.6', 'openai/gpt-5.4', 'google/gemini-3.1-pro',
     'deepseek/deepseek-v4-pro', 'qwen/qwen3-coder-480b'],
    'responses', 'https://therouter.ai', 'https://therouter.ai',
    'therouter', '#10B981', 'TheRouter 多模型聚合平台',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'siliconflow', 'SiliconFlow (硅基流动)', 'aggregator',
    'https://api.siliconflow.cn/v1', 'Pro/MiniMaxAI/MiniMax-M2.7',
    ['Pro/MiniMaxAI/MiniMax-M2.7', 'deepseek-ai/DeepSeek-V4',
     'Qwen/Qwen3-235B-A22B', 'ZhipuAI/GLM-5'],
    'responses', 'https://siliconflow.cn', 'https://cloud.siliconflow.cn/account/ak',
    'siliconflow', '#5B21B6', '硅基流动，国产模型聚合平台',
    'apiKey', [], false
  ),
  // ── 第三方 ──
  new ProviderPreset(
    'newapi', 'NewAPI (通用中转)', 'aggregator',
    'https://your-newapi-instance.com/v1', 'claude-sonnet-4-6',
    ['claude-sonnet-4-6', 'claude-opus-4-7', 'gpt-5.4', 'gemini-3.1-pro'],
    'responses', 'https://github.com/Calcium-Ion/new-api', '',
    'newapi', '#10B981', 'NewAPI 自建中转站，支持多模型接入',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'packycode', 'PackyCode', 'third_party',
    'https://www.packyapi.com/v1', 'claude-sonnet-4-6',
    ['claude-opus-4-7', 'claude-sonnet-4-6'],
    'responses', 'https://www.packyapi.com', 'https://www.packyapi.com',
    'packycode', '#F59E0B', 'PackyCode 第三方 API 服务',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'cubence', 'Cubence', 'third_party',
    'https://api.cubence.com/v1', 'claude-sonnet-4-6',
    ['claude-opus-4-7', 'claude-sonnet-4-6'],
    'responses', 'https://cubence.com', 'https://cubence.com',
    'cubence', '#EC4899', 'Cubence 第三方 API 服务',
    'apiKey', [], false
  ),
  new ProviderPreset(
    'aigocode', 'AIGoCode', 'third_party',
    'https://api.aigocode.com/v1', 'claude-sonnet-4-6',
    ['claude-opus-4-7', 'claude-sonnet-4-6'],
    'responses', 'https://aigocode.com', 'https://aigocode.com',
    'aigocode', '#3B82F6', 'AIGoCode 第三方 API 服务',
    'apiKey', [], false
  ),
];

export function findPresetById(id: string): ProviderPreset | undefined {
  const presets = BUILTIN_PROVIDER_PRESETS;
  for (let i = 0; i < presets.length; i++) {
    if (presets[i].id === id) {
      return presets[i];
    }
  }
  return undefined;
}

export function getPresetsByCategory(category: ProviderCategory): ProviderPreset[] {
  const result: ProviderPreset[] = [];
  const presets = BUILTIN_PROVIDER_PRESETS;
  for (let i = 0; i < presets.length; i++) {
    if (presets[i].category === category) {
      result.push(presets[i]);
    }
  }
  return result;
}

export class ApiValidationResult {
  success: boolean;
  statusCode: number;
  latencyMs: number;
  errorMessage: string;
  modelsCount: number;
  accountInfo: string;

  constructor(
    success: boolean, statusCode: number, latencyMs: number,
    errorMessage: string, modelsCount: number, accountInfo: string
  ) {
    this.success = success;
    this.statusCode = statusCode;
    this.latencyMs = latencyMs;
    this.errorMessage = errorMessage;
    this.modelsCount = modelsCount;
    this.accountInfo = accountInfo;
  }
}

export class ChatProbeResult {
  success: boolean;
  latencyMs: number;
  statusCode: number;
  errorMessage: string;

  constructor(success: boolean, latencyMs: number, statusCode: number, errorMessage: string) {
    this.success = success;
    this.latencyMs = latencyMs;
    this.statusCode = statusCode;
    this.errorMessage = errorMessage;
  }
}

export class EndpointSpeedResult {
  endpointUrl: string;
  latencyMs: number;
  statusCode: number;
  success: boolean;
  errorMessage: string;
  timestamp: number;
  chatProbe: ChatProbeResult | null;

  constructor(
    endpointUrl: string, latencyMs: number,
    statusCode: number, success: boolean,
    errorMessage: string, timestamp: number,
    chatProbe: ChatProbeResult | null = null
  ) {
    this.endpointUrl = endpointUrl;
    this.latencyMs = latencyMs;
    this.statusCode = statusCode;
    this.success = success;
    this.errorMessage = errorMessage;
    this.timestamp = timestamp;
    this.chatProbe = chatProbe;
  }
}

export class UsageQueryResult {
  success: boolean;
  providerName: string;
  planName: string;
  totalAmount: number;
  usedAmount: number;
  remainingAmount: number;
  unit: string;
  extraInfo: string;
  queriedAt: number;
  errorMessage: string;

  constructor(
    success: boolean, providerName: string, planName: string,
    totalAmount: number, usedAmount: number, remainingAmount: number,
    unit: string, extraInfo: string, queriedAt: number, errorMessage: string
  ) {
    this.success = success;
    this.providerName = providerName;
    this.planName = planName;
    this.totalAmount = totalAmount;
    this.usedAmount = usedAmount;
    this.remainingAmount = remainingAmount;
    this.unit = unit;
    this.extraInfo = extraInfo;
    this.queriedAt = queriedAt;
    this.errorMessage = errorMessage;
  }
}

export enum ApiErrorCode {
  PRESET_NOT_FOUND = 'PRESET_NOT_FOUND',
  INVALID_NAME = 'INVALID_NAME',
  INVALID_URL = 'INVALID_URL',
  PROVIDER_NOT_FOUND = 'PROVIDER_NOT_FOUND',
  CANNOT_DELETE_ACTIVE = 'CANNOT_DELETE_ACTIVE',
  VALIDATION_FAILED = 'VALIDATION_FAILED',
  SYNC_FAILED = 'SYNC_FAILED',
  MODEL_FETCH_FAILED = 'MODEL_FETCH_FAILED',
  USAGE_NOT_CONFIGURED = 'USAGE_NOT_CONFIGURED',
  USAGE_UNSUPPORTED = 'USAGE_UNSUPPORTED',
  CUSTOM_SCRIPT_NOT_IMPLEMENTED = 'CUSTOM_SCRIPT_NOT_IMPLEMENTED',
  TOO_MANY_ENDPOINTS = 'TOO_MANY_ENDPOINTS',
}

export class ApiError extends Error {
  code: ApiErrorCode;
  context: string;
  suggestion: string;

  constructor(code: ApiErrorCode, context: string, suggestion: string) {
    super(`[${code}] ${context}`);
    this.name = 'ApiError';
    this.code = code;
    this.context = context;
    this.suggestion = suggestion;
  }
}

const ERROR_MESSAGES: string[] = [];
ERROR_MESSAGES[0] = '预设不存在，请刷新预设列表';
ERROR_MESSAGES[1] = '名称不合法，不能为空且不超过 100 个字符';
ERROR_MESSAGES[2] = 'URL 格式不合法，请输入完整地址（含 http:// 或 https://）';
ERROR_MESSAGES[3] = '未找到指定的 Provider';
ERROR_MESSAGES[4] = '无法删除当前已激活的 Provider，请先切换到其他 Provider';
ERROR_MESSAGES[5] = 'API Key 连通性验证失败';
ERROR_MESSAGES[6] = '写入配置文件失败，Provider 切换可能未生效';
ERROR_MESSAGES[7] = '获取模型列表失败，请检查 Base URL 和 API Key 是否正确';
ERROR_MESSAGES[8] = '未配置用量查询';
ERROR_MESSAGES[9] = '不支持的用量查询类型';
ERROR_MESSAGES[10] = '自定义用量脚本暂不支持';
ERROR_MESSAGES[11] = '端点数量超过上限';

export function getApiErrorMessage(code: ApiErrorCode): string {
  switch (code) {
    case ApiErrorCode.PRESET_NOT_FOUND: return ERROR_MESSAGES[0];
    case ApiErrorCode.INVALID_NAME: return ERROR_MESSAGES[1];
    case ApiErrorCode.INVALID_URL: return ERROR_MESSAGES[2];
    case ApiErrorCode.PROVIDER_NOT_FOUND: return ERROR_MESSAGES[3];
    case ApiErrorCode.CANNOT_DELETE_ACTIVE: return ERROR_MESSAGES[4];
    case ApiErrorCode.VALIDATION_FAILED: return ERROR_MESSAGES[5];
    case ApiErrorCode.SYNC_FAILED: return ERROR_MESSAGES[6];
    case ApiErrorCode.MODEL_FETCH_FAILED: return ERROR_MESSAGES[7];
    case ApiErrorCode.USAGE_NOT_CONFIGURED: return ERROR_MESSAGES[8];
    case ApiErrorCode.USAGE_UNSUPPORTED: return ERROR_MESSAGES[9];
    case ApiErrorCode.CUSTOM_SCRIPT_NOT_IMPLEMENTED: return ERROR_MESSAGES[10];
    case ApiErrorCode.TOO_MANY_ENDPOINTS: return ERROR_MESSAGES[11];
  }
}
