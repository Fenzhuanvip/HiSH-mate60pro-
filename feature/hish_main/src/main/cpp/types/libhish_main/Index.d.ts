export type NapiVmOptions = {
  argsLines: string
  unixSocket: string
  qmpSocket: string
  supportJit: boolean
}

export const startVM: (options: NapiVmOptions) => boolean;
export const onData: (callback: (ArrayBuffer) => void) => void;
export const onShutdown: (callback: () => void) => void;
export const sendInput: (content: ArrayBuffer) => void;
export const checkPortUsed: (port: number) => boolean;
export const getImageInfo: (imagePath: string) => string;
export const getSnapshots: (imagePath: string) => string;
export const createSnapshot: (imagePath: string, snapshotName: string) => string;
export const applySnapshot: (imagePath: string, snapshotName: string) => string;
export const deleteSnapshot: (imagePath: string, snapshotName: string) => string;
export const optimizeImage: (imagePath: string, outputPath: string, mode: 'sparse' | 'prealloc' | 'cleanup' | 'optimize') => string;

// QEMU 运行时诊断
export const getNativeLibDir: () => string;
export const getQemuLoadDiagnostic: () => string;
export const preflightQemuLibs: () => string;

// ===== ArkPilot codex host bridge types =====
export type NativeCodexHostStatus = {
  code: number;
  running: boolean;
  serverUrl: string;
  message: string;
};

export type NativeCollaborationModeMask = {
  name?: string;
  mode?: string;
  model?: string;
  reasoning_effort?: string | null;
};

export type NativeCodexProviderRecord = {
  id?: string;
  name?: string;
  baseUrl?: string;
  apiKey?: string;
  model?: string;
  contextWindow?: string;
  modelAutoCompactTokenLimit?: string;
  enabled?: boolean;
};

export type NativeCodexProviderCatalog = {
  providers?: NativeCodexProviderRecord[];
};

export type NativeCodexProviderConfig = {
  baseUrl?: string;
  apiKey?: string;
  model?: string;
  contextWindow?: string;
  modelAutoCompactTokenLimit?: string;
};

export type NativeWorkspaceAccessStatus = {
  rootPath?: string;
  accessKind?: string;
  permissionState?: string;
  writable?: boolean;
  exists?: boolean;
  message?: string;
};

export type EntryBridgeModule = {
  startHost: (codexHome?: string, serverUrl?: string) => NativeCodexHostStatus;
  getStatus: () => NativeCodexHostStatus;
  isHostRunning: () => boolean;
  getLastMessage: () => string;
  getServerUrl: () => string;
  getProviderConfig: (codexHome?: string) => string;
  saveProviderConfig: (codexHome?: string, baseUrl?: string, apiKey?: string, model?: string, contextWindow?: string, modelAutoCompactTokenLimit?: string) => string;
  getProviderCatalog: (codexHome?: string) => string;
  saveProviderCatalog: (codexHome?: string, catalogJson?: string) => string;
  getSkillsRegistry: (codexHome?: string) => string;
  saveSkillsRegistry: (codexHome?: string, registryJson?: string) => number;
  getSkillsRepos: (codexHome?: string) => string;
  saveSkillsRepos: (codexHome?: string, reposJson?: string) => number;
  computeDirHash: (dirPath?: string) => string;
  installSkillFromDir: (codexHome?: string, sourceDir?: string, skillJson?: string) => string;
  uninstallSkill: (codexHome?: string, skillId?: string) => string;
  setSkillEnabled: (codexHome?: string, skillId?: string, enabled?: number) => string;
  reconcileSkills: (codexHome?: string) => string;
  getPromptsRegistry: (codexHome?: string) => string;
  savePromptsRegistry: (codexHome?: string, registryJson?: string) => number;
  readAgentsMd: (codexHome?: string) => string;
  writeAgentsMd: (codexHome?: string, content?: string) => number;
  enablePrompt: (codexHome?: string, promptId?: string) => string;
  disableAllPrompts: (codexHome?: string) => number;
  initialize: (codexHome?: string) => string;
  collaborationModeList: (codexHome?: string) => string;
  threadStart: (codexHome?: string) => string;
  threadList: (codexHome?: string) => string;
  threadRead: (codexHome?: string) => string;
  threadResume: (codexHome?: string) => string;
  threadNameSet: (codexHome?: string) => string;
  threadArchive: (codexHome?: string) => string;
  threadCompactStart: (codexHome?: string) => string;
  turnStart: (codexHome?: string) => string;
  turnEvents: (codexHome?: string, arg1?: string) => string;
  turnPoll: (codexHome?: string, arg1?: string) => string;
  turnInterrupt: (codexHome?: string, arg1?: string) => string;
  approvalPoll: () => string;
  approvalApprove: (arg0?: string) => number;
  approvalDecline: (arg0?: string) => number;
  mcpStatusList: (codexHome?: string) => string;
  mcpConfigRead: (codexHome?: string) => string;
  mcpConfigWrite: (codexHome?: string) => number;
  mcpConfigBatchWrite: (codexHome?: string) => number;
  mcpConfigAdd: (codexHome?: string) => number;
  mcpConfigRemove: (codexHome?: string) => number;
  mcpReload: () => number;
  mcpOauthStart: (codexHome?: string) => string;
  accountLogin: (codexHome?: string) => string;
  accountRead: () => string;
  checkWorkspaceAccess: (codexHome?: string) => string;
  tokenUsageAggregate: (codexHome?: string) => string;
};

export const entry: EntryBridgeModule;
export const startHost: (codexHome?: string, serverUrl?: string) => NativeCodexHostStatus;
export const getStatus: () => NativeCodexHostStatus;
export const isHostRunning: () => boolean;
export const getLastMessage: () => string;
export const getServerUrl: () => string;
export const getProviderConfig: (codexHome?: string) => string;
export const saveProviderConfig: (codexHome?: string, baseUrl?: string, apiKey?: string, model?: string, contextWindow?: string, modelAutoCompactTokenLimit?: string) => string;
export const getProviderCatalog: (codexHome?: string) => string;
export const saveProviderCatalog: (codexHome?: string, catalogJson?: string) => string;
export const getSkillsRegistry: (codexHome?: string) => string;
export const saveSkillsRegistry: (codexHome?: string, registryJson?: string) => number;
export const getSkillsRepos: (codexHome?: string) => string;
export const saveSkillsRepos: (codexHome?: string, reposJson?: string) => number;
export const computeDirHash: (dirPath?: string) => string;
export const installSkillFromDir: (codexHome?: string, sourceDir?: string, skillJson?: string) => string;
export const uninstallSkill: (codexHome?: string, skillId?: string) => string;
export const setSkillEnabled: (codexHome?: string, skillId?: string, enabled?: number) => string;
export const reconcileSkills: (codexHome?: string) => string;
export const getPromptsRegistry: (codexHome?: string) => string;
export const savePromptsRegistry: (codexHome?: string, registryJson?: string) => number;
export const readAgentsMd: (codexHome?: string) => string;
export const writeAgentsMd: (codexHome?: string, content?: string) => number;
export const enablePrompt: (codexHome?: string, promptId?: string) => string;
export const disableAllPrompts: (codexHome?: string) => number;
export const initialize: (codexHome?: string) => string;
export const collaborationModeList: (codexHome?: string) => string;
export const threadStart: (codexHome?: string) => string;
export const threadList: (codexHome?: string) => string;
export const threadRead: (codexHome?: string) => string;
export const threadResume: (codexHome?: string) => string;
export const threadNameSet: (codexHome?: string) => string;
export const threadArchive: (codexHome?: string) => string;
export const threadCompactStart: (codexHome?: string) => string;
export const turnStart: (codexHome?: string) => string;
export const turnEvents: (codexHome?: string, arg1?: string) => string;
export const turnPoll: (codexHome?: string, arg1?: string) => string;
export const turnInterrupt: (codexHome?: string, arg1?: string) => string;
export const approvalPoll: () => string;
export const approvalApprove: (arg0?: string) => number;
export const approvalDecline: (arg0?: string) => number;
export const mcpStatusList: (codexHome?: string) => string;
export const mcpConfigRead: (codexHome?: string) => string;
export const mcpConfigWrite: (codexHome?: string) => number;
export const mcpConfigBatchWrite: (codexHome?: string) => number;
export const mcpConfigAdd: (codexHome?: string) => number;
export const mcpConfigRemove: (codexHome?: string) => number;
export const mcpReload: () => number;
export const mcpOauthStart: (codexHome?: string) => string;
export const accountLogin: (codexHome?: string) => string;
export const accountRead: () => string;
export const checkWorkspaceAccess: (codexHome?: string) => string;
export const tokenUsageAggregate: (codexHome?: string) => string;
