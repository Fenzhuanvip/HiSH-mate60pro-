/**
 * AIGC 隐式标识 provenance 存储 —— 清单持久化 + 生成事件落库。
 *
 * - 清单文件：${workspaceRoot}/.aigc_list.json
 * - 原子写：先写临时文件再 rename，避免写一半损坏
 * - 内容指纹：轻量 (size,mtime)，不做全文件 SHA-256（避免主线程阻塞导致 ANR）
 * - 命令收集：内存缓冲 key=threadId:turnId，防抖增量保存
 */
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AigcApprovalDetail,
  AigcCommandRecord,
  AigcEvent,
  AigcFileEntry,
  AigcManifest,
  AigcOrigin,
  AigcLabel,
  AigcTurnClassification,
  DEFAULT_AIGC_PRODUCER,
  AIGC_MANIFEST_FILE_NAME,
  capEvents,
  classifyTurnChanges,
  computeContentFingerprint,
  computeProduceId,
  isoNow,
  nextEventId,
  normalizeRelPath,
  parseApprovalDetail
} from './AigcProvenance';

const STORE_DOMAIN: number = 0x0ff5;
const STORE_TAG: string = 'AigcProvenanceStore';
const EVENTS_CAP: number = 500;
const DEBOUNCE_SAVE_INTERVAL_MS: number = 2000;
const DEBOUNCE_SAVE_BATCH_COUNT: number = 5;

function manifestPath(workspaceRoot: string): string {
  return `${workspaceRoot}/${AIGC_MANIFEST_FILE_NAME}`;
}

function ensureParentDirectory(path: string): void {
  const slashIndex: number = path.lastIndexOf('/');
  if (slashIndex <= 0) {
    return;
  }
  const parentPath: string = path.substring(0, slashIndex);
  try {
    fileIo.mkdirSync(parentPath, true);
  } catch (err) {
    hilog.error(STORE_DOMAIN, STORE_TAG, 'ensureParentDirectory failed: %{public}s', `${err}`);
  }
}

function fileExists(path: string): boolean {
  try {
    fileIo.statSync(path);
    return true;
  } catch (_err) {
    return false;
  }
}

function safeParseManifest(rawText: string): AigcManifest {
  const manifest: AigcManifest = new AigcManifest(1, DEFAULT_AIGC_PRODUCER, '', isoNow());
  try {
    const parsed: Object = JSON.parse(rawText) as Object;
    const record: Record<string, Object> = parsed as Record<string, Object>;
    manifest.version = typeof record['version'] === 'number' ? (record['version'] as number) : 1;
    manifest.producer = typeof record['producer'] === 'string' ? (record['producer'] as string) : DEFAULT_AIGC_PRODUCER;
    manifest.producerId = typeof record['producerId'] === 'string' ? (record['producerId'] as string) : '';
    manifest.updatedAt = typeof record['updatedAt'] === 'string' ? (record['updatedAt'] as string) : isoNow();

    const filesRaw: Object | undefined = record['files'];
    if (filesRaw !== undefined) {
      const filesRecord: Record<string, Object> = filesRaw as Record<string, Object>;
      Object.keys(filesRecord).forEach((key: string) => {
        const item: Record<string, Object> = filesRecord[key] as Record<string, Object>;
        const label: string = typeof item['label'] === 'string' ? (item['label'] as string) : '1';
        const origin: string = typeof item['origin'] === 'string' ? (item['origin'] as string) : 'direct';
        const produceId: string = typeof item['produceId'] === 'string' ? (item['produceId'] as string) : '';
        const sourceScripts: string[] = [];
        const scriptsRaw: Object | undefined = item['sourceScripts'];
        if (Array.isArray(scriptsRaw)) {
          scriptsRaw.forEach((s: Object) => {
            if (typeof s === 'string') {
              sourceScripts.push(s as string);
            }
          });
        }
        const contentSha256: string = typeof item['contentSha256'] === 'string' ? (item['contentSha256'] as string) : '';
        const firstCreatedAt: string = typeof item['firstCreatedAt'] === 'string' ? (item['firstCreatedAt'] as string) : '';
        const updatedAt: string = typeof item['updatedAt'] === 'string' ? (item['updatedAt'] as string) : '';
        const entry: AigcFileEntry = new AigcFileEntry(
          (label === '2' || label === '3') ? (label as AigcLabel) : '1',
          (origin === 'derived' || origin === 'transformed') ? (origin as AigcOrigin) : 'direct',
          produceId,
          sourceScripts,
          contentSha256,
          firstCreatedAt,
          updatedAt
        );
        manifest.files[key] = entry;
      });
    }

    const eventsRaw: Object | undefined = record['events'];
    if (Array.isArray(eventsRaw)) {
      eventsRaw.forEach((eventRaw: Object) => {
        const eventRecord: Record<string, Object> = eventRaw as Record<string, Object>;
        const commands: AigcCommandRecord[] = [];
        const cmdsRaw: Object | undefined = eventRecord['commands'];
        if (Array.isArray(cmdsRaw)) {
          cmdsRaw.forEach((cmdRaw: Object) => {
            const cmdRecord: Record<string, Object> = cmdRaw as Record<string, Object>;
            commands.push(new AigcCommandRecord(
              typeof cmdRecord['command'] === 'string' ? (cmdRecord['command'] as string) : '',
              typeof cmdRecord['cwd'] === 'string' ? (cmdRecord['cwd'] as string) : '',
              typeof cmdRecord['kind'] === 'string' ? (cmdRecord['kind'] as string) : 'command',
              typeof cmdRecord['approvedAt'] === 'string' ? (cmdRecord['approvedAt'] as string) : ''
            ));
          });
        }
        const changedFiles: string[] = [];
        const cfRaw: Object | undefined = eventRecord['changedFiles'];
        if (Array.isArray(cfRaw)) {
          cfRaw.forEach((cf: Object) => {
            if (typeof cf === 'string') {
              changedFiles.push(cf as string);
            }
          });
        }
        const event: AigcEvent = new AigcEvent(
          typeof eventRecord['id'] === 'string' ? (eventRecord['id'] as string) : '',
          typeof eventRecord['turnId'] === 'string' ? (eventRecord['turnId'] as string) : '',
          typeof eventRecord['threadId'] === 'string' ? (eventRecord['threadId'] as string) : '',
          typeof eventRecord['workspaceRoot'] === 'string' ? (eventRecord['workspaceRoot'] as string) : '',
          typeof eventRecord['status'] === 'string' ? (eventRecord['status'] as string) : 'completed',
          typeof eventRecord['promptTitle'] === 'string' ? (eventRecord['promptTitle'] as string) : '',
          commands,
          changedFiles,
          typeof eventRecord['recordedAt'] === 'string' ? (eventRecord['recordedAt'] as string) : ''
        );
        manifest.events.push(event);
      });
    }
    manifest.events = capEvents(manifest.events);
  } catch (err) {
    hilog.warn(STORE_DOMAIN, STORE_TAG, 'safeParseManifest fallback: %{public}s', `${err}`);
  }
  return manifest;
}

/** recordTurn 参数。 */
export interface AigcRecordTurnParams {
  workspaceRoot: string;
  threadId: string;
  turnId: string;
  status: string;
  promptTitle: string;
  changedFilePaths: string[];
  commands: AigcCommandRecord[];
}

export class AigcProvenanceStore {
  private cachedManifestByRoot: Map<string, AigcManifest> = new Map<string, AigcManifest>();
  private pendingCommandsByKey: Map<string, AigcCommandRecord[]> = new Map<string, AigcCommandRecord[]>();
  private dirtyRoots: Set<string> = new Set<string>();
  private debounceTimerId: number = -1;
  private pendingDirtyCount: number = 0;

  /** 读取指定工作区的清单；不存在返回空清单。 */
  loadManifest(workspaceRoot: string): AigcManifest {
    const normalizedRoot: string = this.normalizeRoot(workspaceRoot);
    const cached: AigcManifest | undefined = this.cachedManifestByRoot.get(normalizedRoot);
    if (cached !== undefined) {
      return cached;
    }
    const path: string = manifestPath(normalizedRoot);
    let manifest: AigcManifest = new AigcManifest(1, DEFAULT_AIGC_PRODUCER, '', isoNow());
    if (fileExists(path)) {
      try {
        manifest = safeParseManifest(fileIo.readTextSync(path));
      } catch (err) {
        hilog.error(STORE_DOMAIN, STORE_TAG, 'loadManifest read failed: %{public}s', `${err}`);
      }
    }
    if (manifest.producerId.trim().length === 0) {
      manifest.producerId = this.ensureProducerId();
    }
    this.cachedManifestByRoot.set(normalizedRoot, manifest);
    return manifest;
  }

  /** 原子保存指定工作区清单。 */
  saveManifest(workspaceRoot: string): void {
    const normalizedRoot: string = this.normalizeRoot(workspaceRoot);
    const manifest: AigcManifest | undefined = this.cachedManifestByRoot.get(normalizedRoot);
    if (manifest === undefined) {
      return;
    }
    manifest.updatedAt = isoNow();
    manifest.events = capEvents(manifest.events);
    const path: string = manifestPath(normalizedRoot);
    ensureParentDirectory(path);
    const tmpPath: string = `${path}.tmp-${Date.now().toString(36)}`;
    const payload: string = JSON.stringify(manifest, null, 2);
    try {
      const tmpFile = fileIo.openSync(tmpPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(tmpFile.fd, payload);
      fileIo.closeSync(tmpFile);
      // rename 覆盖目标（原子性：先尝试删除旧文件再改名，或直接 rename）
      try {
        fileIo.renameSync(tmpPath, path);
      } catch (_err) {
        try {
          if (fileExists(path)) {
            fileIo.unlinkSync(path);
          }
          fileIo.renameSync(tmpPath, path);
        } catch (renameErr) {
          hilog.error(STORE_DOMAIN, STORE_TAG, 'saveManifest rename failed: %{public}s', `${renameErr}`);
        }
      }
    } catch (err) {
      hilog.error(STORE_DOMAIN, STORE_TAG, 'saveManifest write failed: %{public}s', `${err}`);
    }
    this.dirtyRoots.delete(normalizedRoot);
  }

  /**
   * 收集一条被批准的审批（命令）。
   * kind === 'command' 时解析 detail 里的 command+cwd 进内存缓冲。
   */
  collectApproval(threadId: string, turnId: string, kind: string, detail: string): void {
    if (kind !== 'command') {
      return;
    }
    const parsed: AigcApprovalDetail | null = parseApprovalDetail(detail);
    if (parsed === null) {
      return;
    }
    const key: string = this.turnKey(threadId, turnId);
    const list: AigcCommandRecord[] | undefined = this.pendingCommandsByKey.get(key);
    const record: AigcCommandRecord = new AigcCommandRecord(parsed.command, parsed.cwd, kind, isoNow());
    if (list === undefined) {
      this.pendingCommandsByKey.set(key, [record]);
    } else {
      list.push(record);
    }
    // 防抖：每 N 条触发一次增量保存（不丢账），但真实保存依赖 workspaceRoot 已知
    this.pendingDirtyCount += 1;
    if (this.pendingDirtyCount >= DEBOUNCE_SAVE_BATCH_COUNT) {
      this.pendingDirtyCount = 0;
      // 命令尚未绑定 workspaceRoot，此处仅标记有挂起命令，不强制保存
    }
  }

  /** 取出并清空指定 turn 的挂起命令。 */
  takePendingCommands(threadId: string, turnId: string): AigcCommandRecord[] {
    const key: string = this.turnKey(threadId, turnId);
    const list: AigcCommandRecord[] | undefined = this.pendingCommandsByKey.get(key);
    this.pendingCommandsByKey.delete(key);
    return list !== undefined ? list : [];
  }

  /**
   * 记录一个 turn 结束事件：归因 + 更新 files + 追加 events + 保存。
   * changedFilePaths 为相对 workspaceRoot 的路径（来自 diff）。
   */
  recordTurn(params: AigcRecordTurnParams): void {
    const normalizedRoot: string = this.normalizeRoot(params.workspaceRoot);
    if (normalizedRoot.length === 0) {
      return;
    }
    const manifest: AigcManifest = this.loadManifest(normalizedRoot);

    // 清理变更路径中已不在磁盘的文件（ArkTS 不支持 delete，用重建对象排除）
    const surviving: string[] = [];
    const removedKeys: string[] = [];
    params.changedFilePaths.forEach((relPath: string) => {
      const normalized: string = normalizeRelPath(relPath);
      if (normalized.length === 0 || normalized === AIGC_MANIFEST_FILE_NAME) {
        return;
      }
      if (fileExists(`${normalizedRoot}/${normalized}`)) {
        surviving.push(normalized);
      } else {
        removedKeys.push(normalized);
      }
    });
    if (removedKeys.length > 0) {
      const nextFiles: Record<string, AigcFileEntry> = {};
      const fileKeys: string[] = Object.keys(manifest.files);
      fileKeys.forEach((key: string) => {
        if (removedKeys.indexOf(key) < 0) {
          nextFiles[key] = manifest.files[key];
        }
      });
      manifest.files = nextFiles;
    }

    // 归因
    const classification: Map<string, AigcTurnClassification> = classifyTurnChanges(
      surviving, params.commands, manifest.files
    );

    const nowIso: string = isoNow();
    classification.forEach((value: AigcTurnClassification, relPath: string) => {
      const existing: AigcFileEntry | undefined = manifest.files[relPath];
      const fingerprint: string = this.computeFileFingerprintSync(`${normalizedRoot}/${relPath}`);
      const produceId: string = computeProduceId(manifest.producerId, relPath, fingerprint);
      if (existing === undefined) {
        manifest.files[relPath] = new AigcFileEntry(
          value.label, value.origin, produceId, value.sourceScripts, fingerprint, nowIso, nowIso
        );
      } else {
        existing.label = value.label;
        existing.origin = value.origin;
        existing.produceId = produceId;
        existing.sourceScripts = value.sourceScripts;
        existing.contentSha256 = fingerprint;
        existing.updatedAt = nowIso;
      }
    });

    // 追加事件
    const event: AigcEvent = new AigcEvent(
      nextEventId(`${params.threadId}`, manifest.events.length + 1),
      params.turnId,
      params.threadId,
      normalizedRoot,
      params.status,
      params.promptTitle,
      params.commands,
      surviving,
      nowIso
    );
    manifest.events.push(event);
    manifest.events = capEvents(manifest.events);

    this.cachedManifestByRoot.set(normalizedRoot, manifest);
    this.dirtyRoots.add(normalizedRoot);
    this.scheduleDebouncedSave(normalizedRoot);
  }

  /** 查询指定文件是否在清单中。 */
  lookup(workspaceRoot: string, relativePath: string): AigcFileEntry | null {
    const manifest: AigcManifest = this.loadManifest(workspaceRoot);
    const entry: AigcFileEntry | undefined = manifest.files[normalizeRelPath(relativePath)];
    return entry !== undefined ? entry : null;
  }

  /** 合并导入回来的外部清单（回流时保留标识）。 */
  mergeImportedManifest(workspaceRoot: string, rawText: string): void {
    const normalizedRoot: string = this.normalizeRoot(workspaceRoot);
    if (rawText.trim().length === 0) {
      return;
    }
    const external: AigcManifest = safeParseManifest(rawText);
    const manifest: AigcManifest = this.loadManifest(normalizedRoot);
    Object.keys(external.files).forEach((key: string) => {
      const existing: AigcFileEntry | undefined = manifest.files[key];
      if (existing === undefined) {
        manifest.files[key] = external.files[key];
      } else if (external.files[key].updatedAt > existing.updatedAt) {
        manifest.files[key] = external.files[key];
      }
    });
    if (manifest.producerId.trim().length === 0) {
      manifest.producerId = this.ensureProducerId();
    }
    manifest.events = capEvents(manifest.events);
    this.cachedManifestByRoot.set(normalizedRoot, manifest);
    this.dirtyRoots.add(normalizedRoot);
    this.saveManifest(normalizedRoot);
  }

  /** 同步计算单文件指纹：优先内容哈希，失败降级 (size,mtime)。 */
  computeFileFingerprintSync(absPath: string): string {
    try {
      const stat = fileIo.statSync(absPath);
      if (stat.isFile()) {
        const size: number = stat.size;
        const mtimeMs: number = stat.mtime;
        const hash: string = this.tryComputeSha256Sync(absPath);
        return computeContentFingerprint(hash, size, mtimeMs);
      }
    } catch (_err) {
    }
    return '';
  }

  /**
   * 对工作区做快照：递归扫描，返回 relPath → 轻量指纹 (size+mtime)。
   * 用于 turn 前后对比，捕获 shell/脚本生成的文件（不依赖 Rust 的 FileChange diff）。
   */
  snapshotWorkspace(workspaceRoot: string): Map<string, string> {
    const result: Map<string, string> = new Map<string, string>();
    const normalizedRoot: string = this.normalizeRoot(workspaceRoot);
    if (normalizedRoot.length === 0) {
      return result;
    }
    this.scanDirectoryForSnapshot(normalizedRoot, normalizedRoot, result);
    return result;
  }

  private scanDirectoryForSnapshot(absRoot: string, absDir: string, result: Map<string, string>): void {
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(absDir) as string[];
    } catch (_err) {
      return;
    }
    for (let i: number = 0; i < entries.length; i += 1) {
      const entry: string = entries[i];
      // 跳过常见缓存/依赖目录，避免扫描超大目录导致主线程卡顿
      if (entry === '.git' || entry === 'node_modules' || entry === 'oh_modules' || entry === '.hvigor') {
        continue;
      }
      const absPath: string = `${absDir}/${entry}`;
      try {
        const stat = fileIo.statSync(absPath);
        if (stat.isDirectory()) {
          this.scanDirectoryForSnapshot(absRoot, absPath, result);
        } else if (stat.isFile() && entry !== AIGC_MANIFEST_FILE_NAME) {
          const relPath: string = normalizeRelPath(absPath.substring(absRoot.length + 1));
          const fingerprint: string = computeContentFingerprint('', stat.size, stat.mtime);
          result.set(relPath, fingerprint);
        }
      } catch (_err) {
        // 跳过无法访问的条目
      }
    }
  }

  /**
   * 对比 turn 前后的工作区快照，返回新增或修改的文件路径（相对路径）。
   * - before 里没有的 → 新增
   * - before 和 after 都有但指纹不同 → 修改
   */
  diffWorkspaceSnapshot(before: Map<string, string>, after: Map<string, string>): string[] {
    const changed: string[] = [];
    const afterKeys: string[] = Array.from(after.keys());
    for (let i: number = 0; i < afterKeys.length; i += 1) {
      const relPath: string = afterKeys[i];
      const afterFingerprint: string | undefined = after.get(relPath);
      const beforeFingerprint: string | undefined = before.get(relPath);
      if (beforeFingerprint === undefined || afterFingerprint !== beforeFingerprint) {
        changed.push(relPath);
      }
    }
    return changed;
  }

  /**
   * 尽力计算内容指纹。
   *
   * 说明：早期版本对每个变更文件同步做全文件 SHA-256（cryptoFramework.createMd + 分块
   * readSync + updateSync）。实测在 HarmonyOS 上该同步路径会长时间占用调用线程（主线程），
   * 在 Agent 一次生成多文件/大文件时造成主线程阻塞 → ANR → 未响应/被系统强杀
   * （日志特征：LIFECYCLE_TIMEOUT + signal 9 + XCollie hungtask）。
   *
   * 修复：改为纯轻量指纹 —— 只读取文件 stat（size + mtime），不再做全文件内容哈希。
   * - 消除主线程阻塞（statSync 为 O(1) 轻量操作）
   * - 指纹仍确定性（同文件同 size+mtime → 同 ProduceID），足以用于变更检测与去重
   * - 如需精确内容哈希，后续应放到后台线程（taskpool）实现，不在主线程同步执行
   */
  private tryComputeSha256Sync(absPath: string): string {
    // 返回空串 → computeContentFingerprint 降级为 (size, mtime) 指纹，避免主线程阻塞
    return '';
  }

  private ensureProducerId(): string {
    const existing: string | undefined = this.cachedProducerId;
    if (existing !== undefined && existing.length > 0) {
      return existing;
    }
    const raw: string = `${DEFAULT_AIGC_PRODUCER}-${Date.now().toString(36)}-${Math.floor(Math.random() * 0xffffff).toString(36)}`;
    const id: string = this.hashString(raw).slice(0, 32);
    this.cachedProducerId = id;
    return id;
  }

  private cachedProducerId: string = '';

  private hashString(input: string): string {
    let hash: number = 0x811c9dc5;
    for (let i: number = 0; i < input.length; i += 1) {
      hash ^= input.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
    return (hash >>> 0).toString(16).padStart(8, '0');
  }

  private scheduleDebouncedSave(workspaceRoot: string): void {
    this.dirtyRoots.add(workspaceRoot);
    if (this.debounceTimerId >= 0) {
      return;
    }
    this.debounceTimerId = setTimeout(() => {
      this.debounceTimerId = -1;
      const roots: string[] = Array.from(this.dirtyRoots);
      this.dirtyRoots.clear();
      roots.forEach((root: string) => {
        this.saveManifest(root);
      });
    }, DEBOUNCE_SAVE_INTERVAL_MS);
  }

  private turnKey(threadId: string, turnId: string): string {
    return `${threadId}:${turnId}`;
  }

  private normalizeRoot(workspaceRoot: string): string {
    let result: string = (workspaceRoot ?? '').trim().replace(/\\/g, '/');
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}

export const aigcProvenanceStore: AigcProvenanceStore = new AigcProvenanceStore();
