/**
 * AIGC 隐式标识 provenance 模块 —— 纯逻辑与共享类型（无 fileIo 依赖，可单测）。
 *
 * 依据：TC260《网络安全标准实践指南——人工智能生成合成内容标识方法
 *       文件元数据隐式标识 文本文件》（TC260-PG-20258A，V1.0-202508）。
 *
 * 关键规范（各格式的 JSON 一律【无外层包装】的直接字段结构）：
 *   {"Label":"1","ContentProducer":"...","ProduceID":"...",
 *    "ReservedCode1":"","ContentPropagator":"...","PropagateID":"...","ReservedCode2":""}
 * - Markdown：嵌入文件头部（图1）
 * - OOXML（docx/xlsx/pptx）：docProps/custom.xml 的 property name="AIGC" + lpwstr
 * - PDF：Document Information Dictionary，/AIGC({json})
 * - OFD：CustomDatas 的 CustomData name="AIGC"
 * - xmind：metadata.json 新建 AIGC 节点
 * - posm/posf：meta.json 新建 AIGC 节点
 *
 * 注意：附录 E（GB 45438）的 {"AIGC":{...}} 是通用结构示意；
 * 具体格式写入按 TC260 文本指南不带外层包装。带外层会导致检测平台找不到顶层字段。
 *
 * 本文件只包含数据模型与纯函数，不做任何文件 I/O；I/O 在 AigcProvenanceStore / AigcInjector 中。
 */

export type AigcOrigin = 'direct' | 'derived' | 'transformed';

/**
 * 注入模式：
 * - inline = 文本内容内嵌（md/ts/py 等，头部注释或 frontmatter）
 * - container = zip 包内容级写入（docx/xlsx/pptx/ofd/xmind/posm/posf，解压→改→重打包）
 * - pdf = PDF Document Information Dictionary 增量段写入
 * - uof = UOF 单文件 XML 写入
 * - sidecar = 相邻伴随文件（json/csv 或内容级失败降级）
 * - skip = 不注入
 */
export type AigcInjectMode = 'inline' | 'container' | 'pdf' | 'uof' | 'sidecar' | 'skip';

/** 附录 E 中 Label 字段取值：1=属于 AI 生成，2=可能，3=疑似 */
export type AigcLabel = '1' | '2' | '3';

export class AigcCommandRecord {
  command: string;
  cwd: string;
  kind: string;
  approvedAt: string;

  constructor(command: string, cwd: string, kind: string, approvedAt: string) {
    this.command = command;
    this.cwd = cwd;
    this.kind = kind;
    this.approvedAt = approvedAt;
  }
}

export class AigcEvent {
  id: string;
  turnId: string;
  threadId: string;
  workspaceRoot: string;
  status: string;
  promptTitle: string;
  commands: AigcCommandRecord[];
  changedFiles: string[];
  recordedAt: string;

  constructor(
    id: string, turnId: string, threadId: string, workspaceRoot: string,
    status: string, promptTitle: string, commands: AigcCommandRecord[],
    changedFiles: string[], recordedAt: string
  ) {
    this.id = id;
    this.turnId = turnId;
    this.threadId = threadId;
    this.workspaceRoot = workspaceRoot;
    this.status = status;
    this.promptTitle = promptTitle;
    this.commands = commands;
    this.changedFiles = changedFiles;
    this.recordedAt = recordedAt;
  }
}

export class AigcFileEntry {
  label: AigcLabel;
  origin: AigcOrigin;
  produceId: string;
  sourceScripts: string[];
  contentSha256: string;
  firstCreatedAt: string;
  updatedAt: string;

  constructor(
    label: AigcLabel, origin: AigcOrigin, produceId: string,
    sourceScripts: string[], contentSha256: string,
    firstCreatedAt: string, updatedAt: string
  ) {
    this.label = label;
    this.origin = origin;
    this.produceId = produceId;
    this.sourceScripts = sourceScripts;
    this.contentSha256 = contentSha256;
    this.firstCreatedAt = firstCreatedAt;
    this.updatedAt = updatedAt;
  }
}

export class AigcManifest {
  version: number;
  producer: string;
  producerId: string;
  updatedAt: string;
  files: Record<string, AigcFileEntry>;
  events: AigcEvent[];

  constructor(version: number, producer: string, producerId: string, updatedAt: string) {
    this.version = version;
    this.producer = producer;
    this.producerId = producerId;
    this.updatedAt = updatedAt;
    this.files = {};
    this.events = [];
  }
}

/** 审批 detail 解析结果。 */
export interface AigcApprovalDetail {
  command: string;
  cwd: string;
}

/** 注释语法（open/close 与是否整行前缀）。 */
export interface AigcCommentSyntax {
  open: string;
  close: string;
  prefixLine: boolean;
}

/** 归因分类结果。 */
export interface AigcTurnClassification {
  label: AigcLabel;
  origin: AigcOrigin;
  sourceScripts: string[];
}

/**
 * TC260 文本文件指南规定的 AIGC 隐式标识字段结构。
 * 注意：这是【无外层包装】的直接字段结构（OOXML/PDF/Markdown/xmind/posm 等格式一致）。
 * 附录 E 的 {"AIGC":{...}} 是通用结构示意；具体格式写入按 TC260 指南不带外层包装。
 */
export interface AigcAIGCPayload {
  Label: AigcLabel;
  ContentProducer: string;
  ProduceID: string;
  ReservedCode1: string;
  ContentPropagator: string;
  PropagateID: string;
  ReservedCode2: string;
}

/** sidecar 伴随文件的完整结构（AIGC 标识 + 溯源字段）。 */
export interface AigcSidecarPayload {
  AIGC: AigcAIGCPayload;
  sourceFile: string;
  reason: string;
}

export const DEFAULT_AIGC_PRODUCER: string = 'ArkPilot';
export const AIGC_MANIFEST_FILE_NAME: string = '.aigc_list.json';
const EVENTS_CAP: number = 500;

/** 从审批载荷的 detail JSON 字符串中解析出命令与工作目录。 */
export function parseApprovalDetail(detail: string): AigcApprovalDetail | null {
  if (detail === null || detail === undefined || detail.trim().length === 0) {
    return null;
  }
  try {
    const parsed: Object = JSON.parse(detail) as Object;
    const record: Record<string, Object> = parsed as Record<string, Object>;
    const command: string = typeof record['command'] === 'string' ? (record['command'] as string) : '';
    const cwd: string = typeof record['cwd'] === 'string' ? (record['cwd'] as string) : '';
    if (command.trim().length === 0) {
      return null;
    }
    const result: AigcApprovalDetail = {
      command: command.trim(),
      cwd: cwd.trim()
    };
    return result;
  } catch (_err) {
    return null;
  }
}

/** 计算一个文件的内容指纹；失败时退回 (size,mtime) 组合指纹。 */
export function computeContentFingerprint(contentSha256: string, size: number, mtimeMs: number): string {
  if (contentSha256.trim().length > 0) {
    return contentSha256.trim();
  }
  return `s${size}-m${Math.floor(mtimeMs)}`;
}

/** 确定性 ProduceID：同一路径 + 同一内容 + 同一应用 → 恒定 32 字符 ID。 */
export function computeProduceId(producerId: string, relativePath: string, contentSha256: string): string {
  const seed: string = `${producerId}:${relativePath}:${contentSha256}`;
  // 32 字符：两段 FNV-1a 各 16 字符，基于不同种子偏移保证低碰撞
  const first: string = fnvHex(seed, 0x811c9dc5);
  const second: string = fnvHex(seed, 0xcbf29ce4);
  const combined: string = `${first}${second}`;
  return combined.slice(0, 32);
}

/**
 * 生成 TC260 文本文件指南规定的隐式标识 JSON 文本。
 *
 * 注意：TC260《文本文件》实践指南对各格式（OOXML/PDF/Markdown/xmind/posm 等）
 * 规定的 JSON 结构是【无外层包装】的直接字段：
 *   {"Label":"1","ContentProducer":"...","ProduceID":"...","ReservedCode1":"","ContentPropagator":"...","PropagateID":"...","ReservedCode2":""}
 *
 * 附录 E 的 {"AIGC":{...}} 是通用结构示意；具体格式写入时按 TC260 指南不带外层包装。
 * 若带外层 {"AIGC":{...}}，检测平台解析顶层字段（Label/ContentProducer 等）时找不到，
 * 导致检测不出标识。
 */
export function aigcPayload(producer: string, produceId: string, label: AigcLabel): string {
  const payload: AigcAIGCPayload = {
    Label: label,
    ContentProducer: producer,
    ProduceID: produceId,
    ReservedCode1: '',
    ContentPropagator: producer,
    PropagateID: produceId,
    ReservedCode2: ''
  };
  return JSON.stringify(payload);
}

/** XML 文本节点转义：& < > 必须转义；引号在文本节点可省但为稳妥一并转义。 */
export function escapeXmlText(input: string): string {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** XML 属性值转义：追加 ' 的转义。 */
export function escapeXmlAttr(input: string): string {
  return escapeXmlText(input).replace(/'/g, '&apos;');
}

/** JSON 字符串转义为可嵌入 XML 文本节点的形式（JSON 里的 { } : " 在文本节点合法，只需转 & < >）。 */
export function escapeJsonForXml(jsonText: string): string {
  return escapeXmlText(jsonText);
}

/** OOXML custom-properties 内容类型常量。 */
export const OOXML_CUSTOM_PROPS_CONTENT_TYPE: string =
  'application/vnd.openxmlformats-officedocument.custom-properties+xml';
/** OOXML custom-properties 关系类型常量。 */
export const OOXML_CUSTOM_PROPS_RELATIONSHIP_TYPE: string =
  'http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties';
/** OOXML custom-properties 命名空间。 */
export const OOXML_CUSTOM_PROPS_NS: string =
  'http://schemas.openxmlformats.org/officeDocument/2006/custom-properties';
/** OOXML docPropsVTypes 命名空间（vt 前缀）。 */
export const OOXML_DOC_PROPS_VTYPES_NS: string =
  'http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes';
/** OOXML 自定义属性固定 fmtid。 */
export const OOXML_PROPERTY_FMTID: string =
  '{D5CDD505-2E9C-101B-9397-08002B2CF9AE}';

/**
 * 构建 OOXML custom.xml 的单个 property 元素。
 * @param pid 从 2 起递增的整数
 * @param payloadJson 无外层 JSON（已 XML 转义或在此转义）
 */
export function buildOoxmlCustomPropertyXml(pid: number, payloadJson: string): string {
  const escaped: string = escapeJsonForXml(payloadJson);
  return `<property name="AIGC" fmtid="${OOXML_PROPERTY_FMTID}" pid="${pid.toString()}"><vt:lpwstr>${escaped}</vt:lpwstr></property>`;
}

/** 构建全新的 OOXML custom.xml（无现有 custom.xml 时）。 */
export function buildOoxmlFreshCustomXml(payloadJson: string): string {
  const escaped: string = escapeJsonForXml(payloadJson);
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n` +
    `<Properties xmlns="${OOXML_CUSTOM_PROPS_NS}" xmlns:vt="${OOXML_DOC_PROPS_VTYPES_NS}">` +
    `<property name="AIGC" fmtid="${OOXML_PROPERTY_FMTID}" pid="2"><vt:lpwstr>${escaped}</vt:lpwstr></property>` +
    `</Properties>`;
}

/** 构建 OOXML [Content_Types].xml 的 custom-properties Override。 */
export function buildOoxmlContentTypesOverride(): string {
  return `<Override PartName="/docProps/custom.xml" ContentType="${OOXML_CUSTOM_PROPS_CONTENT_TYPE}"/>`;
}

/** 构建 OOXML _rels/.rels 的 custom-properties 关系。 */
export function buildOoxmlRelsRelationship(rid: string): string {
  return `<Relationship Id="${rid}" Type="${OOXML_CUSTOM_PROPS_RELATIONSHIP_TYPE}" Target="docProps/custom.xml"/>`;
}

/** 构建 OFD CustomData 元素。 */
export function buildOfdCustomDataXml(payloadJson: string): string {
  const escaped: string = escapeJsonForXml(payloadJson);
  return `<CustomData Name="AIGC">${escaped}</CustomData>`;
}

/** 构建 UOF 自定义元数据元素。 */
export function buildUofCustomMetaXml(payloadJson: string): string {
  const escaped: string = escapeJsonForXml(payloadJson);
  return `<自定义元数据_5210 名称_5211="AIGC">${escaped}</自定义元数据_5210>`;
}

/** 判断文本是否已包含 AIGC 标记，返回 true/false。 */
export function formatToInjectMode(fileName: string): AigcInjectMode {
  const lower: string = fileName.toLowerCase();
  const ext: string = lower.substring(lower.lastIndexOf('.') + 1);
  switch (ext) {
    case 'md':
    case 'markdown':
    case 'txt':
    case 'ts':
    case 'tsx':
    case 'js':
    case 'jsx':
    case 'mjs':
    case 'cjs':
    case 'java':
    case 'go':
    case 'rs':
    case 'c':
    case 'cc':
    case 'cpp':
    case 'h':
    case 'hpp':
    case 'swift':
    case 'kt':
    case 'kts':
    case 'sql':
    case 'py':
    case 'sh':
    case 'bash':
    case 'zsh':
    case 'rb':
    case 'pl':
    case 'css':
    case 'scss':
    case 'less':
    case 'html':
    case 'htm':
    case 'xml':
    case 'svg':
      return 'inline';
    // JSON/CSV 不支持注释内联，走 sidecar
    case 'json':
    case 'csv':
      return 'sidecar';
    // zip 包格式：解压→改→重打包
    case 'docx':
    case 'xlsx':
    case 'pptx':
    case 'ofd':
    case 'xmind':
    case 'posm':
    case 'posf':
      return 'container';
    // PDF：Document Information Dictionary 增量段
    case 'pdf':
      return 'pdf';
    // UOF 家族：单文件 XML
    case 'uot':
    case 'uott':
    case 'uos':
      return 'uof';
    default:
      return 'skip';
  }
}

/** 返回该扩展名文件的注释前缀。 */
export function commentPrefixForFormat(fileName: string): AigcCommentSyntax {
  const lower: string = fileName.toLowerCase();
  const ext: string = lower.substring(lower.lastIndexOf('.') + 1);
  switch (ext) {
    case 'md':
    case 'markdown':
    case 'txt':
    case 'html':
    case 'htm':
    case 'xml':
    case 'svg': {
      const result: AigcCommentSyntax = { open: '<!--', close: '-->', prefixLine: true };
      return result;
    }
    case 'css':
    case 'scss':
    case 'less': {
      const result: AigcCommentSyntax = { open: '/*', close: '*/', prefixLine: false };
      return result;
    }
    case 'py':
    case 'sh':
    case 'bash':
    case 'zsh':
    case 'rb':
    case 'pl': {
      const result: AigcCommentSyntax = { open: '#', close: '', prefixLine: false };
      return result;
    }
    default: {
      const result: AigcCommentSyntax = { open: '//', close: '', prefixLine: false };
      return result;
    }
  }
}

/** 判断文本是否已包含 AIGC 标记，返回 true/false。 */
export function hasAigcMarker(text: string): boolean {
  const head: string = text.substring(0, 8192);
  // 匹配：--- frontmatter 里的 AIGC:、行首 AIGC:、<!--AIGC:、# AIGC:、// AIGC:、/* AIGC:
  return /(?:^|\n)AIGC:|<!--AIGC:|#\s*AIGC:|\/\/\s*AIGC:|\/\*\s*AIGC:/.test(head);
}

/** 从文本首部提取已有 ProduceID（无则空串）。 */
export function extractExistingProduceId(text: string): string {
  const head: string = text.substring(0, 8192);
  const match = head.match(/ProduceID["']?\s*:\s*["']([^"']{8,64})["']/);
  if (match !== null && match.length > 1) {
    return match[1];
  }
  return '';
}

/**
 * 生成 AIGC 隐式标识块。
 *
 * - Markdown / 纯文本（md/markdown/txt）：按 TC260 文本文件指南【图1】的格式，
 *   即文件头部 YAML frontmatter（前后各 `---`）+ 多行缩进键值对：
 *     ---
 *     AIGC:
 *       Label: '1'
 *       ContentProducer: 'ArkPilot'
 *       ProduceID: '...'
 *       ReservedCode1: ''
 *       ContentPropagator: 'ArkPilot'
 *       PropagateID: '...'
 *       ReservedCode2: ''
 *     ---
 *   注意：不是 HTML 注释，也不是单行 JSON。检测平台按此 YAML frontmatter
 *   结构解析顶层字段。
 * - 其它语言（ts/js/py 等）：用对应注释语法包裹。
 */
export function buildAigcCommentLine(fileName: string, producer: string, produceId: string, label: AigcLabel): string {
  const comment: AigcCommentSyntax = commentPrefixForFormat(fileName);
  // Markdown / 纯文本：按 TC260 图1 的 YAML frontmatter 格式
  if (comment.prefixLine) {
    return buildAigcYamlBlock(producer, produceId, label);
  }
  // 其它语言：注释包裹
  const payload: string = aigcPayload(producer, produceId, label);
  if (comment.close.length > 0) {
    return `${comment.open}AIGC:${payload}${comment.close}`;
  }
  return `${comment.open} AIGC:${payload}`;
}

/** 按 TC260 图1 生成 YAML frontmatter 格式（Markdown/文本，前后 --- 包裹）。 */
export function buildAigcYamlBlock(producer: string, produceId: string, label: AigcLabel): string {
  const q: string = "'";
  const lines: string[] = [
    '---',
    'AIGC:',
    `  Label: ${q}${label}${q}`,
    `  ContentProducer: ${q}${producer}${q}`,
    `  ProduceID: ${q}${produceId}${q}`,
    `  ReservedCode1: ${q}${q}`,
    `  ContentPropagator: ${q}${producer}${q}`,
    `  PropagateID: ${q}${produceId}${q}`,
    `  ReservedCode2: ${q}${q}`,
    '---'
  ];
  return lines.join('\n');
}

/**
 * 归因规则：把 diff 出的文件 + 该 turn 执行过的命令映射为 origin/label。
 * 纯逻辑：不访问磁盘；文件是否仍在磁盘由调用方（store）处理。
 */
export function classifyTurnChanges(
  changedFilePaths: string[],
  commands: AigcCommandRecord[],
  existingEntries: Record<string, AigcFileEntry>
): Map<string, AigcTurnClassification> {
  const result: Map<string, AigcTurnClassification> = new Map<string, AigcTurnClassification>();

  // 收集命令产物：重定向输出（derived）与转换工具（transformed）
  const derivedOutputs: Map<string, string[]> = new Map<string, string[]>(); // outputPath -> scripts
  const transformedOutputs: Map<string, string[]> = new Map<string, string[]>(); // outputPath -> sources

  const TRANSFORM_TOOLS: string[] = ['pandoc', 'soffice --convert-to', '--convert-to', 'gs -sOutputFile', 'convert ', 'wkhtmltopdf', 'node -e', 'npx '];

  commands.forEach((cmd: AigcCommandRecord) => {
    const command: string = cmd.command;
    // derived：重定向 > 或 >>
    const redirectMatch = command.match(/[^&|]?\s*(?:1?>>?)\s*([^\s;|&]+)/);
    if (redirectMatch !== null && redirectMatch.length > 1) {
      const outputPath: string = redirectMatch[1].trim();
      const scripts: string[] = extractScriptCandidates(command);
      if (scripts.length > 0) {
        derivedOutputs.set(outputPath, scripts);
      } else {
        derivedOutputs.set(outputPath, []);
      }
    }
    // transformed：转换工具关键词
    for (let i: number = 0; i < TRANSFORM_TOOLS.length; i += 1) {
      if (command.indexOf(TRANSFORM_TOOLS[i]) >= 0) {
        const inputs: string[] = extractTransformSources(command);
        if (inputs.length > 0) {
          transformedOutputs.set(inputs[inputs.length - 1], inputs); // 近似：最后一个参数当输出
        }
        break;
      }
    }
  });

  changedFilePaths.forEach((relPath: string) => {
    const normalized: string = normalizeRelPath(relPath);
    if (normalized.length === 0 || normalized === AIGC_MANIFEST_FILE_NAME) {
      return;
    }
    const existing: AigcFileEntry | undefined = existingEntries[normalized];
    const existingScripts: string[] = existing !== undefined ? existing.sourceScripts : [];

    // 优先判定 derived（重定向输出命中）
    const derivedKeys: string[] = Array.from(derivedOutputs.keys());
    for (let i: number = 0; i < derivedKeys.length; i += 1) {
      const outputPath: string = derivedKeys[i];
      if (samePath(normalized, outputPath)) {
        const scripts: string[] = derivedOutputs.get(outputPath) as string[];
        const derived: AigcTurnClassification = {
          label: '1',
          origin: 'derived',
          sourceScripts: scripts.length > 0 ? scripts : existingScripts
        };
        result.set(normalized, derived);
        return;
      }
    }
    // 其次 transformed
    const transformedKeys: string[] = Array.from(transformedOutputs.keys());
    for (let i: number = 0; i < transformedKeys.length; i += 1) {
      const outputPath: string = transformedKeys[i];
      if (samePath(normalized, outputPath)) {
        const sources: string[] = transformedOutputs.get(outputPath) as string[];
        const sourceLabel: AigcLabel | null = labelOfFirstExisting(sources, existingEntries);
        const transformed: AigcTurnClassification = {
          label: sourceLabel !== null ? sourceLabel : '2',
          origin: 'transformed',
          sourceScripts: sources.length > 0 ? sources : existingScripts
        };
        result.set(normalized, transformed);
        return;
      }
    }
    // 默认 direct
    const existingLabel: AigcLabel | null = existing !== undefined ? existing.label : null;
    const direct: AigcTurnClassification = {
      label: existingLabel !== null ? existingLabel : '1',
      origin: 'direct',
      sourceScripts: existingScripts
    };
    result.set(normalized, direct);
  });

  return result;
}

function labelOfFirstExisting(sources: string[], entries: Record<string, AigcFileEntry>): AigcLabel | null {
  for (let i: number = 0; i < sources.length; i += 1) {
    const normalized: string = normalizeRelPath(sources[i]);
    const entry: AigcFileEntry | undefined = entries[normalized];
    if (entry !== undefined && entry.label === '1') {
      return '1';
    }
  }
  return null;
}

/** 从命令中提取可能的脚本/源文件路径（排除重定向目标与常见非文件参数）。 */
export function extractScriptCandidates(command: string): string[] {
  const candidates: string[] = [];
  // 匹配命令中引号包裹或裸的 .py/.sh/.ts/.js/.rs/.go 等文件参数。
  // 用 (?=$|[^a-zA-Z0-9]) 保证扩展名后是分隔符，避免 .json 误匹配成 .js。
  const tokenRegex: RegExp = /["']?([^\s"']+\.(?:py|sh|ts|js|mjs|cjs|rs|go|rb|pl|java|c|cpp|kt|swift|bash|zsh))(?=$|[^a-zA-Z0-9])["']?/gi;
  const matches = command.match(tokenRegex);
  if (matches !== null) {
    for (let i: number = 0; i < matches.length; i += 1) {
      const matchText: string = matches[i];
      const pathMatch = matchText.match(/["']?([^\s"']+\.(?:py|sh|ts|js|mjs|cjs|rs|go|rb|pl|java|c|cpp|kt|swift|bash|zsh))(?=$|[^a-zA-Z0-9])["']?/);
      if (pathMatch !== null && pathMatch.length > 1) {
        const path: string = pathMatch[1];
        // 排除重定向输出（以 > 结尾的）和明显非脚本路径
        if (path.length > 0 && !path.startsWith('>') && candidates.indexOf(path) < 0) {
          candidates.push(path);
        }
      }
    }
  }
  return candidates;
}

/** 从转换命令中提取输入/输出源文件。 */
export function extractTransformSources(command: string): string[] {
  const candidates: string[] = [];
  const tokenRegex: RegExp = /["']?([^\s"']+\.(?:md|markdown|txt|html|htm|tex|rst|docx|xlsx|pptx|pdf|png|jpg|jpeg|webp|csv|json|xml))(?=$|[^a-zA-Z0-9])["']?/gi;
  const matches = command.match(tokenRegex);
  if (matches !== null) {
    for (let i: number = 0; i < matches.length; i += 1) {
      const matchText: string = matches[i];
      const pathMatch = matchText.match(/["']?([^\s"']+\.(?:md|markdown|txt|html|htm|tex|rst|docx|xlsx|pptx|pdf|png|jpg|jpeg|webp|csv|json|xml))(?=$|[^a-zA-Z0-9])["']?/);
      if (pathMatch !== null && pathMatch.length > 1) {
        const path: string = pathMatch[1];
        if (path.length > 0 && candidates.indexOf(path) < 0) {
          candidates.push(path);
        }
      }
    }
  }
  return candidates;
}

/** 规范化相对路径：去 ./ 前缀、统一斜杠、去尾部斜杠。 */
export function normalizeRelPath(rawPath: string): string {
  let result: string = rawPath.trim().replace(/\\/g, '/');
  while (result.startsWith('./')) {
    result = result.substring(2);
  }
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

function samePath(a: string, b: string): boolean {
  return normalizeRelPath(a) === normalizeRelPath(b);
}

/** FNV-1a 确定性哈希（16 字符 hex）。用于 ProduceID 降级；内容哈希优先用 cryptoFramework。 */
function fnvHex(input: string, seed: number): string {
  let hash: number = seed >>> 0;
  for (let i: number = 0; i < input.length; i += 1) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  const positive: number = hash >>> 0;
  return positive.toString(16).padStart(16, '0');
}

/** 时间戳：yyyy-MM-ddTHH:mm:ss.sssZ（UTC）。 */
export function isoNow(): string {
  const now: Date = new Date();
  return now.toISOString();
}

/** 裁剪事件数组到 cap。 */
export function capEvents(events: AigcEvent[]): AigcEvent[] {
  if (events.length <= EVENTS_CAP) {
    return events;
  }
  return events.slice(events.length - EVENTS_CAP);
}

/** 从事件生成一个唯一 id（时间戳 + 序号）。 */
export function nextEventId(seed: string, sequence: number): string {
  const safe: string = seed.length > 0 ? seed.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 24) : 'evt';
  return `evt-${safe}-${Date.now().toString(36)}-${sequence.toString(36)}`;
}

/** 判断相对路径是否为 AIGC 清单自身。 */
export function isManifestFileName(fileName: string): boolean {
  return fileName === AIGC_MANIFEST_FILE_NAME;
}
