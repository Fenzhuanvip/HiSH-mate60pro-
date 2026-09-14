import fileIo from '@ohos.file.fs';
import util from '@ohos.util';
import {
  AiAppType, ProviderMode, ProviderSyncStatus, ApiWireFormat,
  ProviderDefinition,
  ProviderCatalog,
  ProviderRecord,
  ModelsCache,
  ModelsCacheEntry
} from './ConsoleModels';
import {
  saveEmbeddedCodexProviderCatalog,
  saveEmbeddedCodexProviderConfig
} from './CodexNative';

// ── helpers ──

function getCodexHome(): string {
  return (AppStorage.get('codexHome') as string) ?? '';
}

function configTomlPath(): string {
  return `${getCodexHome()}/provider-definitions.toml`;
}

function credentialsPath(): string {
  return `${getCodexHome()}/provider-credentials.json`;
}

function modelsCachePath(): string {
  return `${getCodexHome()}/models-cache.json`;
}

function fileExists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (_) {
    return false;
  }
}

function readTextFile(path: string): string {
  try {
    return fileIo.readTextSync(path);
  } catch (_) {
    return '';
  }
}

function writeTextFile(path: string, content: string): void {
  console.info('[writeTextFile] writing to path=' + path + ' contentLen=' + content.length);
  try {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    const encoder = new util.TextEncoder();
    const encoded = encoder.encodeInto(content);
    fileIo.writeSync(file.fd, encoded.buffer);
    fileIo.closeSync(file);
    console.info('[writeTextFile] success');
  } catch (err) {
    console.error('[writeTextFile] error: ' + JSON.stringify(err));
    throw new Error('writeTextFile failed: ' + JSON.stringify(err));
  }
}

function currentIsoTimestamp(): string {
  return new Date().toISOString();
}

// ── TOML parser (minimal, for our config.toml format) ──

function parseTomlString(value: string): string {
  const trimmed = value.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

function parseTomlBool(value: string): boolean {
  return value.trim() === 'true';
}

function parseTomlInt(value: string, fallback: number = 0): number {
  const n = parseInt(value.trim());
  return isNaN(n) ? fallback : n;
}

function parseToml(content: string): ParsedToml {
  const result: ParsedToml = new ParsedToml();
  const lines: string[] = content.split('\n');
  let currentSection: string = '';
  let inArrayTable: boolean = false;
  let currentTable: Map<string, string> = new Map();

  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0 || line.startsWith('#')) continue;

    if (line === '[[providers]]') {
      if (inArrayTable && currentTable.size > 0) {
        result.providers.push(currentTable);
      }
      inArrayTable = true;
      currentTable = new Map();
      continue;
    }

    if (line.startsWith('[') && line.endsWith(']')) {
      if (inArrayTable && currentTable.size > 0) {
        result.providers.push(currentTable);
        inArrayTable = false;
      }
      currentSection = line.substring(1, line.length - 1);
      continue;
    }

    const eqIndex: number = line.indexOf('=');
    if (eqIndex > 0) {
      const key: string = line.substring(0, eqIndex).trim();
      const value: string = line.substring(eqIndex + 1).trim();

      if (inArrayTable) {
        currentTable.set(key, value);
      } else if (currentSection.length === 0) {
        result.root.set(key, value);
      }
    }
  }

  if (inArrayTable && currentTable.size > 0) {
    result.providers.push(currentTable);
  }

  return result;
}

class ParsedToml {
  root: Map<string, string> = new Map();
  providers: Array<Map<string, string>> = [];
}

// ── TOML serializer ──

function escapeTomlString(value: string): string {
  let escaped: string = '';
  for (let i = 0; i < value.length; i++) {
    const ch: string = value.charAt(i);
    if (ch === '"') {
      escaped += '\\"';
    } else if (ch === '\\') {
      escaped += '\\\\';
    } else {
      escaped += ch;
    }
  }
  return `"${escaped}"`;
}

function serializeProviderDefToml(def: ProviderDefinition): string {
  let result: string = '[[providers]]\n';
  result += `id = ${escapeTomlString(def.id)}\n`;
  result += `name = ${escapeTomlString(def.name)}\n`;
  result += `base_url = ${escapeTomlString(def.baseUrl)}\n`;
  result += `model = ${escapeTomlString(def.model)}\n`;
  result += `wire_api = ${escapeTomlString(def.wireApi)}\n`;
  result += `is_active = ${def.isActive}\n`;
  result += `app_type = ${escapeTomlString(def.appType)}\n`;
  result += `mode = ${escapeTomlString(def.mode)}\n`;
  result += `sync_status = ${escapeTomlString(def.syncStatus)}\n`;
  result += `updated_at = ${escapeTomlString(def.updatedAt)}\n`;
  if (def.contextWindow > 0) {
    result += `context_window = ${def.contextWindow}\n`;
  }
  if (def.modelAutoCompactTokenLimit > 0) {
    result += `model_auto_compact_token_limit = ${def.modelAutoCompactTokenLimit}\n`;
  }
  return result;
}

function serializeConfigToml(activeId: string, defs: ProviderDefinition[]): string {
  let result: string = '# ArkPilot Provider Configuration\n';
  result += `active_provider_id = ${escapeTomlString(activeId)}\n`;
  for (let i = 0; i < defs.length; i++) {
    result += '\n';
    result += serializeProviderDefToml(defs[i]);
  }
  return result;
}

// ── credentials JSON ──

function parseCredentialsJson(content: string): Map<string, string> {
  const result: Map<string, string> = new Map();
  if (content.length === 0) return result;
  try {
    const parsed: Record<string, string> = JSON.parse(content) as Record<string, string>;
    const keys: string[] = Object.keys(parsed);
    for (let i = 0; i < keys.length; i++) {
      result.set(keys[i], parsed[keys[i]]);
    }
  } catch (_) {
    // ignore parse errors
  }
  return result;
}

function serializeCredentialsJson(creds: Map<string, string>): string {
  const obj: Record<string, string> = {};
  const keys: string[] = Array.from(creds.keys());
  for (let i = 0; i < keys.length; i++) {
    obj[keys[i]] = creds.get(keys[i]) ?? '';
  }
  return JSON.stringify(obj, null, 2);
}

// ── models cache JSON ──

function parseModelsCacheJson(content: string): ModelsCache | null {
  if (content.length === 0) return null;
  try {
    const raw: ModelsCacheJsonRaw = JSON.parse(content) as ModelsCacheJsonRaw;
    const models: ModelsCacheEntry[] = [];
    if (raw.models !== undefined && raw.models !== null) {
      for (let i = 0; i < raw.models.length; i++) {
        const m: ModelsCacheEntryJsonRaw = raw.models[i];
        models.push(new ModelsCacheEntry(
          m.slug ?? '',
          m.displayName ?? '',
          m.description ?? '',
          m.contextWindow ?? 0
        ));
      }
    }
    return new ModelsCache(
      raw.fetchedAt ?? '',
      raw.etag ?? '',
      raw.providerId ?? '',
      models
    );
  } catch (_) {
    return null;
  }
}

class ModelsCacheEntryJsonRaw {
  slug: string = '';
  displayName: string = '';
  description: string = '';
  contextWindow: number = 0;
}

class ModelsCacheJsonRaw {
  fetchedAt: string = '';
  etag: string = '';
  providerId: string = '';
  models: ModelsCacheEntryJsonRaw[] = [];
}

// ── TOML mapping helpers ──

function tomlMapToDefinition(m: Map<string, string>): ProviderDefinition {
  const rawWireApi: string = parseTomlString(m.get('wire_api') ?? '"responses"');
  const wireApi: string = rawWireApi === 'responses' ? rawWireApi : 'responses';
  return new ProviderDefinition(
    parseTomlString(m.get('id') ?? '""'),
    parseTomlString(m.get('name') ?? '""'),
    parseTomlString(m.get('base_url') ?? '""'),
    parseTomlString(m.get('model') ?? '""'),
    wireApi,
    parseTomlBool(m.get('is_active') ?? 'false'),
    parseTomlString(m.get('app_type') ?? '"codex"'),
    parseTomlString(m.get('mode') ?? '"exclusive"'),
    parseTomlString(m.get('sync_status') ?? '"synced"'),
    parseTomlString(m.get('updated_at') ?? '""'),
    parseTomlInt(m.get('context_window') ?? '0', 0),
    parseTomlInt(m.get('model_auto_compact_token_limit') ?? '0', 0)
  );
}

function definitionToRecord(
  def: ProviderDefinition,
  apiKey: string
): ProviderRecord {
  return new ProviderRecord(
    def.id, def.name, def.appType as AiAppType, def.mode as ProviderMode,
    def.baseUrl, apiKey, def.model,
    def.isActive, def.syncStatus as ProviderSyncStatus, def.updatedAt,
    'apiKey', [], def.wireApi as ApiWireFormat,
    'custom', '', '', '', '',
    [], 'unknown', 0, 0, null, Date.now(), def.contextWindow,
    def.modelAutoCompactTokenLimit
  );
}

function recordToDefinition(rec: ProviderRecord): ProviderDefinition {
  return new ProviderDefinition(
    rec.id, rec.name, rec.baseUrl, rec.model,
    rec.wireApi, rec.isActive, rec.appType, rec.mode,
    rec.syncStatus, rec.updatedAt, rec.contextWindow,
    rec.modelAutoCompactTokenLimit
  );
}

// ── public API ──

export class ProviderConfigStore {
  loadDefinitions(): ProviderDefinition[] {
    const content: string = readTextFile(configTomlPath());
    if (content.length === 0) return [];
    const parsed: ParsedToml = parseToml(content);
    const defs: ProviderDefinition[] = [];
    for (let i = 0; i < parsed.providers.length; i++) {
      defs.push(tomlMapToDefinition(parsed.providers[i]));
    }
    return defs;
  }

  loadActiveId(): string {
    const content: string = readTextFile(configTomlPath());
    if (content.length === 0) return '';
    const parsed: ParsedToml = parseToml(content);
    return parseTomlString(parsed.root.get('active_provider_id') ?? '""');
  }

  loadCredentials(): Map<string, string> {
    return parseCredentialsJson(readTextFile(credentialsPath()));
  }

  loadModelsCache(): ModelsCache | null {
    return parseModelsCacheJson(readTextFile(modelsCachePath()));
  }

  saveDefinitions(defs: ProviderDefinition[], activeId: string): void {
    console.info('[ProviderConfigStore] saveDefinitions: start, defs=' + defs.length + ' activeId=' + activeId);
    const toml: string = serializeConfigToml(activeId, defs);
    console.info('[ProviderConfigStore] saveDefinitions: toml length=' + toml.length + ' path=' + configTomlPath());
    writeTextFile(configTomlPath(), toml);
    console.info('[ProviderConfigStore] saveDefinitions: done');
  }

  saveCredentials(creds: Map<string, string>): void {
    console.info('[ProviderConfigStore] saveCredentials: start, creds=' + creds.size);
    const json: string = serializeCredentialsJson(creds);
    console.info('[ProviderConfigStore] saveCredentials: json length=' + json.length + ' path=' + credentialsPath());
    writeTextFile(credentialsPath(), json);
    console.info('[ProviderConfigStore] saveCredentials: done');
  }

  saveModelsCache(cache: ModelsCache): void {
    const json: string = JSON.stringify(cache, null, 2);
    writeTextFile(modelsCachePath(), json);
  }

  hasExistingConfig(): boolean {
    return fileExists(configTomlPath()) && fileExists(credentialsPath());
  }

  migrateFromCatalog(catalog: ProviderCatalog): void {
    const defs: ProviderDefinition[] = [];
    const creds: Map<string, string> = new Map();

    for (let i = 0; i < catalog.providers.length; i++) {
      const rec: ProviderRecord = catalog.providers[i];
      defs.push(recordToDefinition(rec));
      creds.set(rec.id, rec.apiKey);
    }

    this.saveDefinitions(defs, catalog.activeProviderId);
    this.saveCredentials(creds);
  }

  syncToNativeCatalog(defs: ProviderDefinition[], creds: Map<string, string>): void {
    console.info('[ProviderConfigStore] syncToNativeCatalog: start, defs=' + defs.length);
    const providers: ProviderRecord[] = [];
    for (let i = 0; i < defs.length; i++) {
      const def: ProviderDefinition = defs[i];
      const apiKey: string = creds.get(def.id) ?? '';
      providers.push(definitionToRecord(def, apiKey));
    }

    let activeId: string = '';
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].isActive) {
        activeId = providers[i].id;
        break;
      }
    }
    console.info('[ProviderConfigStore] syncToNativeCatalog: activeId=' + activeId + ' providers=' + providers.length);

    const catalog: ProviderCatalog = new ProviderCatalog(
      2, activeId, providers, currentIsoTimestamp()
    );
    console.info('[ProviderConfigStore] syncToNativeCatalog: calling saveEmbeddedCodexProviderCatalog');
    // 失败必须抛出，调用方（saveProvidersToStore）据此在写文件前中止
    try {
      saveEmbeddedCodexProviderCatalog(catalog);
    } catch (err) {
      const message = err instanceof Error ? err.message : JSON.stringify(err);
      console.error('[ProviderConfigStore] syncToNativeCatalog failed: ' + message);
      throw new Error('同步 native provider catalog 失败: ' + message);
    }
    console.info('[ProviderConfigStore] syncToNativeCatalog: done');
  }

  activateOnNative(def: ProviderDefinition, apiKey: string): void {
    saveEmbeddedCodexProviderConfig(
      def.baseUrl,
      apiKey,
      def.model,
      def.contextWindow,
      def.modelAutoCompactTokenLimit
    );
  }
}

export const providerConfigStore: ProviderConfigStore = new ProviderConfigStore();
