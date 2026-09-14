/**
 * AIGC 隐式标识注入器 —— 导出时对清单命中的文件写目标副本（源文件不动）。
 *
 * - 只给导出副本注入：源文件只读，目标用 CREATE|READ_WRITE|TRUNC 覆盖
 * - .aigc_list.json 自身永不注入（它是合规证据，照常导出）
 * - 分派：inline（文本/代码/md）→ 头部注释；sidecar（json/csv/OOXML/PDF）→ 伴随 .aigc.json
 */
import fileIo from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import { fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AigcAIGCPayload,
  AigcFileEntry,
  AigcManifest,
  AigcInjectMode,
  AigcSidecarPayload,
  aigcPayload,
  buildAigcCommentLine,
  buildUofCustomMetaXml,
  escapeJsonForXml,
  extractExistingProduceId,
  formatToInjectMode,
  isManifestFileName,
  normalizeRelPath
} from './AigcProvenance';
import { zipModifierForExt } from './AigcZipModifiers';
import { injectPdfIncremental } from './AigcPdfInjector';
import { buildExplicitMarkerLine, hasExplicitMarker, insertExplicitAfterImplicit, isValidJson, isWellFormedXml } from './AigcExplicitMarker';

const INJECTOR_DOMAIN: number = 0x0ff6;
const INJECTOR_TAG: string = 'AigcInjector';
const SIDECAR_SUFFIX: string = '.aigc.json';
const MAX_INLINE_BYTES: number = 50 * 1024 * 1024; // >50MB 不内容注入
const MAX_CONTAINER_BYTES: number = 200 * 1024 * 1024; // zip 容器大小上限

export class AigcExportInjector {
  private sourceRoot: string;
  private manifest: AigcManifest | null;
  private codexHome: string;

  private constructor(sourceRoot: string, manifest: AigcManifest | null, codexHome: string) {
    this.sourceRoot = sourceRoot;
    this.manifest = manifest;
    this.codexHome = codexHome;
  }

  /** 从源项目根目录构造注入器；无清单时返回 null（调用方走原复制）。 */
  static fromSourceRoot(sourceRoot: string, codexHome: string = ''): AigcExportInjector | null {
    const normalizedRoot: string = AigcExportInjector.normalizeRoot(sourceRoot);
    if (normalizedRoot.length === 0) {
      return null;
    }
    let manifest: AigcManifest | null = null;
    const manifestPath: string = `${normalizedRoot}/.aigc_list.json`;
    try {
      fileIo.statSync(manifestPath);
      const rawText: string = fileIo.readTextSync(manifestPath);
      if (rawText.trim().length > 0) {
        const parsed: Object = JSON.parse(rawText) as Object;
        const record: Record<string, Object> = parsed as Record<string, Object>;
        manifest = new AigcManifest(
          typeof record['version'] === 'number' ? (record['version'] as number) : 1,
          typeof record['producer'] === 'string' ? (record['producer'] as string) : 'ArkPilot',
          typeof record['producerId'] === 'string' ? (record['producerId'] as string) : '',
          typeof record['updatedAt'] === 'string' ? (record['updatedAt'] as string) : ''
        );
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
            manifest!.files[key] = new AigcFileEntry(
              (label === '2' || label === '3') ? (label as '2' | '3') : '1',
              (origin === 'derived' || origin === 'transformed') ? (origin as 'derived' | 'transformed') : 'direct',
              produceId,
              sourceScripts,
              typeof item['contentSha256'] === 'string' ? (item['contentSha256'] as string) : '',
              typeof item['firstCreatedAt'] === 'string' ? (item['firstCreatedAt'] as string) : '',
              typeof item['updatedAt'] === 'string' ? (item['updatedAt'] as string) : ''
            );
          });
        }
      }
    } catch (err) {
      hilog.debug(INJECTOR_DOMAIN, INJECTOR_TAG, 'fromSourceRoot manifest read skipped: %{public}s', `${err}`);
    }
    if (manifest === null) {
      return null;
    }
    return new AigcExportInjector(normalizedRoot, manifest, codexHome);
  }

  /** 源绝对路径是否命中清单。 */
  hasEntry(sourceAbsPath: string): boolean {
    return this.entryFor(sourceAbsPath) !== null;
  }

  /** 源绝对路径对应的清单 entry。 */
  entryFor(sourceAbsPath: string): AigcFileEntry | null {
    if (this.manifest === null) {
      return null;
    }
    const relPath: string = this.relativePathOf(sourceAbsPath);
    if (relPath.length === 0) {
      return null;
    }
    const entry: AigcFileEntry | undefined = this.manifest.files[relPath];
    return entry !== undefined ? entry : null;
  }

  /**
   * 注入主入口：命中清单且可注入则写目标副本并返回 true；否则返回 false（调用方走原复制）。
   * 注意：即使返回 true，调用方也不应再复制该文件。
   */
  async injectIfNeeded(sourceAbsPath: string, targetUri: string): Promise<boolean> {
    if (isManifestFileName(AigcExportInjector.fileNameOf(sourceAbsPath))) {
      return false; // 清单自身照常导出
    }
    const entry: AigcFileEntry | null = this.entryFor(sourceAbsPath);
    if (entry === null) {
      return false; // 未命中清单
    }
    const fileName: string = AigcExportInjector.fileNameOf(sourceAbsPath);
    const mode: AigcInjectMode = formatToInjectMode(fileName);
    if (mode === 'skip') {
      return false; // 不可注入格式，原样复制
    }
    const targetPath: string = AigcExportInjector.uriToPath(targetUri);
    this.ensureTargetParent(targetPath);
    const producer: string = this.manifest !== null ? this.manifest.producer : 'ArkPilot';
    const payloadJson: string = aigcPayload(producer, entry.produceId, entry.label);
    switch (mode) {
      case 'inline': {
        return this.injectTextInline(sourceAbsPath, targetPath, fileName, entry);
      }
      case 'container': {
        const injected: boolean = await this.injectContainerFormat(sourceAbsPath, targetPath, fileName, payloadJson);
        if (injected) {
          return true;
        }
        return this.injectWithSidecar(sourceAbsPath, targetPath, fileName, entry);
      }
      case 'pdf': {
        const injected: boolean = this.injectPdfFile(sourceAbsPath, targetPath, payloadJson);
        if (injected) {
          return true;
        }
        return this.injectWithSidecar(sourceAbsPath, targetPath, fileName, entry);
      }
      case 'uof': {
        const injected: boolean = this.injectUofXml(sourceAbsPath, targetPath, payloadJson);
        if (injected) {
          return true;
        }
        return this.injectWithSidecar(sourceAbsPath, targetPath, fileName, entry);
      }
      case 'sidecar': {
        return this.injectWithSidecar(sourceAbsPath, targetPath, fileName, entry);
      }
      default:
        return false;
    }
  }

  /** 确保目标文件父目录存在（幂等）。 */
  private ensureTargetParent(targetPath: string): void {
    const cleaned: string = targetPath.replace(/\\/g, '/');
    const slashIndex: number = cleaned.lastIndexOf('/');
    if (slashIndex <= 0) {
      return;
    }
    const parentPath: string = cleaned.substring(0, slashIndex);
    try {
      fileIo.mkdirSync(parentPath, true);
    } catch (_err) {
    }
  }

  /** zip 容器格式注入：解压→改条目→重打包。任何一步失败返回 false（调用方降级 sidecar）。 */
  private async injectContainerFormat(
    sourceAbsPath: string,
    targetPath: string,
    fileName: string,
    payloadJson: string
  ): Promise<boolean> {
    // 前置校验：zip 魔数 + 大小上限
    if (!this.isZipMagic(sourceAbsPath)) {
      return false;
    }
    try {
      const stat = fileIo.statSync(sourceAbsPath);
      if (stat.size > MAX_CONTAINER_BYTES) {
        return false;
      }
    } catch (_err) {
      return false;
    }
    const ext: string = this.extOf(fileName);
    const modifier = zipModifierForExt(ext);
    if (modifier === null) {
      return false;
    }

    const tmpBase: string = `${this.codexHome}/.tmp_aigc_${Date.now().toString(36)}_${Math.floor(Math.random() * 0xfffff).toString(36)}`;
    const extracted: string = `${tmpBase}/x`;
    const outZip: string = `${tmpBase}/out.zip`;
    const verifyDir: string = `${tmpBase}/verify`;
    try {
      fileIo.mkdirSync(extracted, true);
      // 1) 解压到临时目录
      await zlib.decompressFile(sourceAbsPath, extracted);
      // 2) 就地修改目标条目
      if (!modifier.modify(extracted, payloadJson, fileName)) {
        return false;
      }
      // 3) 重打包
      const options: zlib.Options = {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
        memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
        strategy: zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY
      };
      await zlib.compressFile(extracted, outZip, options);
      // 4) 验证门：重解压 → 检查根验证条目存在（兜住根条目前缀问题）
      fileIo.mkdirSync(verifyDir, true);
      await zlib.decompressFile(outZip, verifyDir);
      if (!this.pathExists(`${verifyDir}/${modifier.rootVerifyEntry}`)) {
        return false;
      }
      // 显式内容条目良构校验：内容条目损坏 → 降级 sidecar（不交付损坏文件）
      if (!this.verifyContentEntries(verifyDir, modifier.contentVerifyEntries)) {
        return false;
      }
      // 5) 原子落目标
      this.copyBinary(outZip, targetPath);
      return true;
    } catch (err) {
      hilog.warn(INJECTOR_DOMAIN, INJECTOR_TAG, 'injectContainerFormat failed: %{public}s', `${err}`);
      return false;
    } finally {
      try {
        this.removeDir(tmpBase);
      } catch (_err) {
      }
    }
  }

  /** PDF 注入：追加 /AIGC 增量段。 */
  private injectPdfFile(sourceAbsPath: string, targetPath: string, payloadJson: string): boolean {
    return injectPdfIncremental(sourceAbsPath, targetPath, payloadJson);
  }

  /** UOF 注入：单文件 XML 加自定义元数据。 */
  private injectUofXml(sourceAbsPath: string, targetPath: string, payloadJson: string): boolean {
    try {
      const stat = fileIo.statSync(sourceAbsPath);
      if (stat.size > MAX_INLINE_BYTES) {
        return false;
      }
      const text: string = fileIo.readTextSync(sourceAbsPath);
      const newElem: string = buildUofCustomMetaXml(payloadJson);
      // 已有 AIGC 元数据 → 幂等/替换
      const existing = text.match(/<自定义元数据_5210[^>]*名称_5211="AIGC"[^>]*>[\s\S]*?<\/自定义元数据_5210>/);
      if (existing !== null) {
        this.writeTextTarget(targetPath, text.replace(existing[0], newElem));
        return true;
      }
      const dataSetClose: number = text.lastIndexOf('</自定义元数据集_520F>');
      if (dataSetClose >= 0) {
        this.writeTextTarget(targetPath, `${text.substring(0, dataSetClose)}${newElem}${text.substring(dataSetClose)}`);
        return true;
      }
      return false;
    } catch (err) {
      hilog.warn(INJECTOR_DOMAIN, INJECTOR_TAG, 'injectUofXml failed: %{public}s', `${err}`);
      return false;
    }
  }

  /** 判断文件是否为 zip（PK\x03\x04 魔数）。 */
  private isZipMagic(absPath: string): boolean {
    try {
      const file = fileIo.openSync(absPath, fileIo.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(4);
        const bytesRead: number = fileIo.readSync(file.fd, buffer, { offset: 0, length: 4 });
        if (bytesRead < 4) {
          return false;
        }
        const view = new DataView(buffer);
        return view.getUint32(0, true) === 0x04034b50;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_err) {
      return false;
    }
  }

  private pathExists(absPath: string): boolean {
    try {
      fileIo.statSync(absPath);
      return true;
    } catch (_err) {
      return false;
    }
  }

  /** 验证显式内容条目存在且良构（损坏则返回 false → 降级 sidecar）。 */
  private verifyContentEntries(verifyDir: string, contentVerifyEntries: string[]): boolean {
    for (let i: number = 0; i < contentVerifyEntries.length; i += 1) {
      const entry: string = contentVerifyEntries[i];
      const entryPath: string = `${verifyDir}/${entry}`;
      if (!this.pathExists(entryPath)) {
        return false;
      }
      try {
        const text: string = fileIo.readTextSync(entryPath);
        if (entry.toLowerCase().endsWith('.json')) {
          if (!isValidJson(text)) {
            return false;
          }
        } else if (!isWellFormedXml(text)) {
          return false;
        }
      } catch (_err) {
        return false;
      }
    }
    return true;
  }

  private extOf(fileName: string): string {
    const lower: string = fileName.toLowerCase();
    const idx: number = lower.lastIndexOf('.');
    return idx >= 0 ? lower.substring(idx + 1) : '';
  }

  /** 递归删除目录/文件。 */
  private removeDir(absPath: string): void {
    try {
      const stat = fileIo.statSync(absPath);
      if (stat.isDirectory()) {
        const entries: string[] = fileIo.listFileSync(absPath) as string[];
        for (let i: number = 0; i < entries.length; i += 1) {
          this.removeDir(`${absPath}/${entries[i]}`);
        }
        fileIo.rmdirSync(absPath);
      } else {
        fileIo.unlinkSync(absPath);
      }
    } catch (_err) {
    }
  }

  /** 文本类内联注入。 */
  private injectTextInline(sourceAbsPath: string, targetPath: string, fileName: string, entry: AigcFileEntry): boolean {
    try {
      const stat = fileIo.statSync(sourceAbsPath);
      if (stat.size > MAX_INLINE_BYTES) {
        return this.injectWithSidecar(sourceAbsPath, targetPath, fileName, entry);
      }
      const rawText: string = fileIo.readTextSync(sourceAbsPath);
      const existingProduceId: string = extractExistingProduceId(rawText);
      const markerLine: string = buildAigcCommentLine(
        fileName,
        this.manifest !== null ? this.manifest.producer : 'ArkPilot',
        entry.produceId,
        entry.label
      );
      // 显式标注：隐式标注之后、正文开头插入"本文件由AI生成，请注意甄别"
      const explicitLine: string = buildExplicitMarkerLine(fileName);

      let result: string;
      if (existingProduceId.length > 0) {
        if (existingProduceId === entry.produceId) {
          // 已有且 ProduceID 一致：幂等。已有显式则原样，否则补显式
          if (hasExplicitMarker(rawText)) {
            result = rawText;
          } else {
            result = insertExplicitAfterImplicit(rawText, explicitLine);
          }
        } else {
          // 已有但 ProduceID 不一致 → 替换隐式块；显式补齐
          if (hasExplicitMarker(rawText)) {
            result = this.replaceFirstAigcMarker(rawText, markerLine);
          } else {
            result = this.replaceFirstAigcMarker(rawText, `${markerLine}\n${explicitLine}`);
          }
        }
      } else {
        // 无隐式标记 → 插"隐式+显式"整块（insertMarkerAtHead 处理 shebang/XML 声明/doctype）
        result = this.insertMarkerAtHead(rawText, `${markerLine}\n${explicitLine}`);
      }

      this.writeTextTarget(targetPath, result);
      return true;
    } catch (err) {
      hilog.warn(INJECTOR_DOMAIN, INJECTOR_TAG, 'injectTextInline failed, fallback copy: %{public}s', `${err}`);
      return false; // 失败走原复制
    }
  }

  /** sidecar 降级：复制原文件字节 + 生成伴随 .aigc.json。 */
  private injectWithSidecar(sourceAbsPath: string, targetPath: string, fileName: string, entry: AigcFileEntry): boolean {
    try {
      this.copyBinary(sourceAbsPath, targetPath);
      const sidecarPath: string = `${targetPath}${SIDECAR_SUFFIX}`;
      const producer: string = this.manifest !== null ? this.manifest.producer : 'ArkPilot';
      const aigc: AigcAIGCPayload = {
        Label: entry.label,
        ContentProducer: producer,
        ProduceID: entry.produceId,
        ReservedCode1: '',
        ContentPropagator: producer,
        PropagateID: entry.produceId,
        ReservedCode2: ''
      };
      const sidecarPayload: AigcSidecarPayload = {
        AIGC: aigc,
        sourceFile: fileName,
        reason: '该格式未内联写入隐式标识，采用伴随文件形式记录'
      };
      this.writeTextTarget(sidecarPath, JSON.stringify(sidecarPayload, null, 2));
      return true;
    } catch (err) {
      hilog.warn(INJECTOR_DOMAIN, INJECTOR_TAG, 'injectWithSidecar failed, fallback copy: %{public}s', `${err}`);
      return false;
    }
  }

  /** 在文本头部插入标记行，处理 shebang / XML 声明 / doctype。 */
  private insertMarkerAtHead(rawText: string, markerLine: string): string {
    const lines: string[] = rawText.split('\n');
    let insertIndex: number = 0;
    if (lines.length > 0 && lines[0].startsWith('#!')) {
      insertIndex = 1; // shebang 之后
    } else if (lines.length > 0 && lines[0].startsWith('<?xml')) {
      insertIndex = 1; // XML 声明之后
    } else if (lines.length > 0 && /^<!DOCTYPE/i.test(lines[0])) {
      insertIndex = 1; // doctype 之后
    }
    const head: string = lines.slice(0, insertIndex).join('\n');
    const tail: string = lines.slice(insertIndex).join('\n');
    if (head.length > 0) {
      return `${head}\n${markerLine}${tail.length > 0 ? '\n' + tail : ''}`;
    }
    return `${markerLine}${tail.length > 0 ? '\n' + tail : ''}`;
  }

  /** 替换已有的 AIGC 标记（支持 YAML frontmatter 块和单行注释）。 */
  private replaceFirstAigcMarker(rawText: string, markerLine: string): string {
    // YAML frontmatter 块：--- 开头，含 AIGC:，到 --- 结束
    const frontmatterPattern: RegExp = /^(?:---\n?AIGC:[\s\S]*?ReservedCode2:[^\n]*\n?---\n?)/;
    if (frontmatterPattern.test(rawText)) {
      return rawText.replace(frontmatterPattern, `${markerLine}\n`);
    }
    // 多行键值对块：以 AIGC: 开头，包含缩进字段，到 ReservedCode2 结束（无 ---）
    const multiLinePattern: RegExp = /^(?:AIGC:[\s\S]*?ReservedCode2:[^\n]*\n?)/;
    if (multiLinePattern.test(rawText)) {
      return rawText.replace(multiLinePattern, `${markerLine}\n`);
    }
    const pattern: RegExp = /^(?:<!--AIGC:.*?-->\s*\n?|#\s*AIGC:.*?\n?|\/\/\s*AIGC:.*?\n?|\/\*\s*AIGC:.*?\*\/\s*\n?)/;
    if (pattern.test(rawText)) {
      return rawText.replace(pattern, `${markerLine}\n`);
    }
    return this.insertMarkerAtHead(rawText, markerLine);
  }

  /** 写文本目标文件（UTF-8）。 */
  private writeTextTarget(targetPath: string, content: string): void {
    const file = fileIo.openSync(targetPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 二进制复制（sidecar 用）。 */
  private copyBinary(sourcePath: string, targetPath: string): void {
    let source: fileIo.File | null = null;
    let target: fileIo.File | null = null;
    try {
      source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      target = fileIo.openSync(targetPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      const stat = fileIo.statSync(sourcePath);
      const chunkSize: number = 64 * 1024;
      let offset: number = 0;
      while (offset < stat.size) {
        const readLength: number = Math.min(chunkSize, stat.size - offset);
        const buffer = new ArrayBuffer(readLength);
        const bytesRead: number = fileIo.readSync(source.fd, buffer, { offset, length: readLength });
        if (bytesRead <= 0) {
          break;
        }
        const data: ArrayBuffer = bytesRead === readLength ? buffer : buffer.slice(0, bytesRead);
        fileIo.writeSync(target.fd, data);
        offset += bytesRead;
      }
    } finally {
      if (source !== null) {
        fileIo.closeSync(source);
      }
      if (target !== null) {
        fileIo.closeSync(target);
      }
    }
  }

  /** 源绝对路径 → 相对 sourceRoot 的正斜杠路径。 */
  private relativePathOf(sourceAbsPath: string): string {
    const normalized: string = AigcExportInjector.normalizeRoot(sourceAbsPath);
    const root: string = this.sourceRoot;
    if (normalized === root) {
      return '';
    }
    if (normalized.startsWith(`${root}/`)) {
      return normalizeRelPath(normalized.substring(root.length + 1));
    }
    return normalizeRelPath(normalized);
  }

  private static uriToPath(rawUri: string): string {
    try {
      return new fileUri.FileUri(rawUri).path;
    } catch (_err) {
      return rawUri;
    }
  }

  private static fileNameOf(path: string): string {
    const cleaned: string = path.replace(/\\/g, '/');
    const slashIndex: number = cleaned.lastIndexOf('/');
    return slashIndex >= 0 ? cleaned.substring(slashIndex + 1) : cleaned;
  }

  private static normalizeRoot(path: string): string {
    let result: string = (path ?? '').trim().replace(/\\/g, '/');
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
