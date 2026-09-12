import { breakpointManager } from '../adaptive/BreakpointManager';
import { getArkPilotLayoutProfile } from '../adaptive/LayoutProfiles';
import { ArkPilotBreakpoint } from '../adaptive/BreakpointTypes';
import {
  codexBackend,
  CodexApprovalRequest,
  CodexBackendSnapshot,
  CodexConnectionState,
  CodexDiffLine,
  CodexRequestUserInput,
  CodexRequestUserInputOption,
  CodexRequestUserInputQuestion,
  CodexTurnRequest,
  CodexTurnResult
} from '../backend/CodexBackend';
import {
  CollaborationModeOption,
  CodexProviderConfig,
  WorkspaceAccessStatus,
  checkWorkspaceAccess,
  getEmbeddedCodexHostStatus,
  getEmbeddedCodexProviderCatalog,
  getEmbeddedCodexProviderConfig,
  saveEmbeddedCodexProviderConfig
} from '../backend/CodexNative';
import { providerCatalogService } from '../backend/ProviderCatalogService';
import { SessionSummary, WorkspaceAccessKind, WorkspacePermissionState, TurnTokenUsage, TokenUsageAggregate, TokenUsageBreakdown, WorkspaceItem, WorkspaceBindingDraft, WorkspaceDirectorySelection, SelectorOption, DailyTokenSnapshot, ProjectRecord, CodexContextManagementSnapshot } from '../backend/ConsoleModels';
import { StoredWorkspaceItem, workspaceBindingStore } from '../backend/WorkspaceBindingStore';
import { projectStore } from '../backend/ProjectStore';
import { AigcExportInjector } from '../backend/AigcInjector';
import { AIGC_MANIFEST_FILE_NAME } from '../backend/AigcProvenance';
import { aigcProvenanceStore } from '../backend/AigcProvenanceStore';
import { common, OpenLinkOptions, Want, wantConstant } from '@kit.AbilityKit';
import router from '@ohos.router';
import pasteboard from '@ohos.pasteboard';
import { promptAction } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileShare, fileUri, picker } from '@kit.CoreFileKit';
import fileIo from '@ohos.file.fs';
import uri from '@ohos.uri';
import taskpool from '@ohos.taskpool';
import { copyStandaloneFileChunk, deletePathTask } from '../backend/ProjectDirFileOps';
import { huaweiAccountService } from '../account/HuaweiAccountService';

const INDEX_DOMAIN = 0x0000;
const INDEX_TAG = 'IndexProviderDebug';
const WAITING_FOR_DIFF_TEXT: string = '\u7b49\u5f85 turn/diff/updated \u901a\u77e5\u3002';
const NO_DIFF_TEXT: string = '\u672c\u8f6e\u5c1a\u672a\u4ea7\u751f diff\u3002';
const NO_FILE_CHANGES_TEXT: string = '\u5c1a\u672a\u4ea7\u751f\u6587\u4ef6\u6539\u52a8';
const UNKNOWN_DIFF_FILE_TEXT: string = '\u672a\u8bc6\u522b\u6587\u4ef6';
const USER_FILE_SERVICE_SYSCAP: string = 'SystemCapability.FileManagement.UserFileService';
const FOLDER_SELECTION_SYSCAP: string = 'SystemCapability.FileManagement.UserFileService.FolderSelection';
const FOLDER_AUTHORIZATION_SYSCAP: string = 'SystemCapability.FileManagement.AppFileService.FolderAuthorization';
const LEGACY_FOLDER_AUTHORIZATION_SYSCAP: string = 'SystemCapability.FileManagement.File.Environment.FolderObtain';

// ================================================================
// TaskPool 卸载：项目目录拷贝 / 镜像 / 删除（迭代式，避免 UI 线程递归同步 I/O）
// @Concurrent 函数必须是顶层、不可捕获外部变量、参数与返回值必须可序列化；
// 被调用的辅助函数（copyStandaloneFileChunk / deletePathTask）从
// ../backend/ProjectDirFileOps 以 import 方式引入。
// ================================================================

@Concurrent
function copyProjectDirectoryTask(sourceRoot: string, targetRootPath: string): string {
  try {
    const sourceStat = fileIo.statSync(sourceRoot);
    if (!sourceStat.isDirectory()) {
      return JSON.stringify({ error: '源路径不是目录' });
    }
  } catch (err) {
    return JSON.stringify({ error: `读取源目录失败: ${sourceRoot}` });
  }
  try {
    fileIo.mkdirSync(targetRootPath, true);
  } catch (_err) {
  }
  let copiedCount: number = 0;
  const pendingSources: string[] = [];
  const pendingTargets: string[] = [];
  let headIndex: number = 0;
  pendingSources.push(sourceRoot);
  pendingTargets.push(targetRootPath);
  while (headIndex < pendingSources.length) {
    const currentSource: string = pendingSources[headIndex];
    const currentTarget: string = pendingTargets[headIndex];
    headIndex += 1;
    let entries: string[];
    try {
      entries = fileIo.listFileSync(currentSource) as string[];
    } catch (err) {
      return JSON.stringify({ error: `列出源目录失败: ${currentSource}` });
    }
    for (let index: number = 0; index < entries.length; index += 1) {
      const entry: string = entries[index];
      const sourcePath: string = `${currentSource}/${entry}`;
      const targetPath: string = `${currentTarget}/${entry}`;
      try {
        const stat = fileIo.statSync(sourcePath);
        if (stat.isDirectory()) {
          fileIo.mkdirSync(targetPath, true);
          pendingSources.push(sourcePath);
          pendingTargets.push(targetPath);
        } else if (stat.isFile()) {
          copyStandaloneFileChunk(sourcePath, targetPath);
          copiedCount += 1;
        }
      } catch (err) {
        return JSON.stringify({ error: `同步条目失败: ${sourcePath} -> ${targetPath}` });
      }
    }
  }
  return JSON.stringify({ copiedCount });
}

@Concurrent
function mirrorDirectoryTask(sourceRoot: string, targetRoot: string): string {
  try {
    const sourceStat = fileIo.statSync(sourceRoot);
    if (!sourceStat.isDirectory()) {
      return JSON.stringify({ error: '同步文件夹不是目录' });
    }
  } catch (err) {
    return JSON.stringify({ error: `读取同步文件夹失败: ${sourceRoot}` });
  }
  try {
    const targetStat = fileIo.statSync(targetRoot);
    if (!targetStat.isDirectory()) {
      const parsedDelete: string = deletePathTask(targetRoot);
      const parsedDeleteObj: Record<string, Object> = JSON.parse(parsedDelete) as Record<string, Object>;
      if (typeof parsedDeleteObj['error'] === 'string') {
        return parsedDelete;
      }
    }
  } catch (_err) {
  }
  try {
    fileIo.mkdirSync(targetRoot, true);
  } catch (err) {
    return JSON.stringify({ error: `创建项目目录失败: ${targetRoot}` });
  }
  let sourceEntries: string[];
  let targetEntries: string[];
  try {
    sourceEntries = fileIo.listFileSync(sourceRoot) as string[];
  } catch (err) {
    return JSON.stringify({ error: `列出同步文件夹失败: ${sourceRoot}` });
  }
  try {
    targetEntries = fileIo.listFileSync(targetRoot) as string[];
  } catch (err) {
    return JSON.stringify({ error: `列出项目目录失败: ${targetRoot}` });
  }
  let copiedFiles: number = 0;
  let deletedEntries: number = 0;
  for (let index: number = 0; index < targetEntries.length; index += 1) {
    const entry: string = targetEntries[index];
    if (sourceEntries.indexOf(entry) < 0) {
      const parsedDelete: string = deletePathTask(`${targetRoot}/${entry}`);
      const parsedDeleteObj: Record<string, Object> = JSON.parse(parsedDelete) as Record<string, Object>;
      if (typeof parsedDeleteObj['error'] === 'string') {
        return parsedDelete;
      }
      deletedEntries += typeof parsedDeleteObj['deletedCount'] === 'number' ? (parsedDeleteObj['deletedCount'] as number) : 0;
    }
  }
  const pendingSources: string[] = [];
  const pendingTargets: string[] = [];
  let headIndex: number = 0;
  for (let index: number = 0; index < sourceEntries.length; index += 1) {
    pendingSources.push(`${sourceRoot}/${sourceEntries[index]}`);
    pendingTargets.push(`${targetRoot}/${sourceEntries[index]}`);
  }
  while (headIndex < pendingSources.length) {
    const sourcePath: string = pendingSources[headIndex];
    const targetPath: string = pendingTargets[headIndex];
    headIndex += 1;
    try {
      const sourceStat = fileIo.statSync(sourcePath);
      if (sourceStat.isDirectory()) {
        fileIo.mkdirSync(targetPath, true);
        let childEntries: string[];
        try {
          childEntries = fileIo.listFileSync(sourcePath) as string[];
        } catch (err) {
          return JSON.stringify({ error: `列出同步文件夹失败: ${sourcePath}` });
        }
        for (let childIndex: number = 0; childIndex < childEntries.length; childIndex += 1) {
          pendingSources.push(`${sourcePath}/${childEntries[childIndex]}`);
          pendingTargets.push(`${targetPath}/${childEntries[childIndex]}`);
        }
        continue;
      }
      try {
        const targetStat = fileIo.statSync(targetPath);
        if (targetStat.isDirectory()) {
          const parsedDelete: string = deletePathTask(targetPath);
          const parsedDeleteObj: Record<string, Object> = JSON.parse(parsedDelete) as Record<string, Object>;
          if (typeof parsedDeleteObj['error'] === 'string') {
            return parsedDelete;
          }
          deletedEntries += typeof parsedDeleteObj['deletedCount'] === 'number' ? (parsedDeleteObj['deletedCount'] as number) : 0;
        }
      } catch (_err) {
      }
      copyStandaloneFileChunk(sourcePath, targetPath);
      copiedFiles += 1;
    } catch (err) {
      return JSON.stringify({ error: `导入条目失败: ${sourcePath} -> ${targetPath}` });
    }
  }
  return JSON.stringify({ copiedFiles, deletedEntries });
}

class ChatMessage {
  id: string;
  author: string;
  role: string;
  content: string;
  timestamp: string;
  itemType?: string;
  status?: string;
  metadata?: Record<string, Object>;

  constructor(id: string, author: string, role: string, content: string, timestamp: string, itemType?: string, status?: string, metadata?: Record<string, Object>) {
    this.id = id;
    this.author = author;
    this.role = role;
    this.content = content;
    this.timestamp = timestamp;
    this.itemType = itemType;
    this.status = status;
    this.metadata = metadata;
  }
}

class CodeDiffLine {
  id: string;
  lineNumber: string;
  sign: string;
  content: string;
  kind: string;
  filePath: string;

  constructor(id: string, lineNumber: string, sign: string, content: string, kind: string, filePath?: string) {
    this.id = id;
    this.lineNumber = lineNumber;
    this.sign = sign;
    this.content = content;
    this.kind = kind;
    this.filePath = filePath ?? '';
  }
}

class CodeDiffFile {
  path: string;
  label: string;
  diffStat: string;
  lines: CodeDiffLine[];

  constructor(path: string, label: string, diffStat: string, lines: CodeDiffLine[]) {
    this.path = path;
    this.label = label;
    this.diffStat = diffStat;
    this.lines = lines;
  }
}

class CompactionNotice {
  id: string;
  threadId: string;
  status: string;
  errorMessage: string;
  savedTokens: number;
  oldTotalTokens: number;
  newTotalTokens: number;
  timestamp: string;
  anchorMessageId: string;

  constructor(
    id: string,
    threadId: string,
    status: string,
    errorMessage: string,
    savedTokens: number,
    oldTotalTokens: number,
    newTotalTokens: number,
    timestamp: string,
    anchorMessageId: string = ''
  ) {
    this.id = id;
    this.threadId = threadId;
    this.status = status;
    this.errorMessage = errorMessage;
    this.savedTokens = savedTokens;
    this.oldTotalTokens = oldTotalTokens;
    this.newTotalTokens = newTotalTokens;
    this.timestamp = timestamp;
    this.anchorMessageId = anchorMessageId;
  }
}

class WorkspaceRunState {
  workspaceId: number;
  threadKey: string;
  threadId: string = '';
  turnId: string = '';
  status: string = 'inProgress';
  pendingUserPrompt: string;
  savedDraft: string;
  thinkingMessageBoundary: number;

  constructor(workspaceId: number, threadKey: string, pendingUserPrompt: string, savedDraft: string, thinkingMessageBoundary: number) {
    this.workspaceId = workspaceId;
    this.threadKey = threadKey;
    this.pendingUserPrompt = pendingUserPrompt;
    this.savedDraft = savedDraft;
    this.thinkingMessageBoundary = thinkingMessageBoundary;
  }
}

class MarkdownBlock {
  id: string;
  kind: string;
  text: string;
  rawText: string;
  level: number;
  language: string;
  rows: string[][];

  constructor(id: string, kind: string, text: string, level?: number, language?: string, rows?: string[][], rawText?: string) {
    this.id = id;
    this.kind = kind;
    this.text = text;
    this.rawText = rawText ?? text;
    this.level = level ?? 0;
    this.language = language ?? '';
    this.rows = rows ?? [];
  }
}

class MathSegment {
  id: string;
  kind: string;
  text: string;
  rawText: string;
  target: string;

  constructor(id: string, kind: string, text: string, rawText?: string, target?: string) {
    this.id = id;
    this.kind = kind;
    this.text = text;
    this.rawText = rawText ?? text;
    this.target = target ?? '';
  }
}

class InlineWebTargetMatch {
  start: number;
  end: number;
  target: string;

  constructor(start: number, end: number, target: string) {
    this.start = start;
    this.end = end;
    this.target = target;
  }
}

class LocalPathResolution {
  path: string;
  matchedExistingFile: boolean;

  constructor(path: string, matchedExistingFile?: boolean) {
    this.path = path;
    this.matchedExistingFile = matchedExistingFile ?? false;
  }
}

class MarkdownTextRun {
  id: string;
  text: string;
  blockKind: string;
  inlineKind: string;
  level: number;

  constructor(id: string, text: string, blockKind: string, inlineKind?: string, level?: number) {
    this.id = id;
    this.text = text;
    this.blockKind = blockKind;
    this.inlineKind = inlineKind ?? 'text';
    this.level = level ?? 0;
  }
}

class HtmlTextRun {
  id: string;
  text: string;
  isLink: boolean;

  constructor(id: string, text: string, isLink: boolean) {
    this.id = id;
    this.text = text;
    this.isLink = isLink;
  }
}

class CodeToken {
  id: string;
  kind: string;
  text: string;

  constructor(id: string, kind: string, text: string) {
    this.id = id;
    this.kind = kind;
    this.text = text;
  }
}

class FormulaNode {
  kind: string;
  text: string;
  variant: string;
  children: FormulaNode[];
  numerator: FormulaNode | null;
  denominator: FormulaNode | null;
  base: FormulaNode | null;
  superscript: FormulaNode | null;
  subscript: FormulaNode | null;
  radicand: FormulaNode | null;

  constructor(kind: string, text?: string, children?: FormulaNode[], variant?: string) {
    this.kind = kind;
    this.text = text ?? '';
    this.variant = variant ?? 'roman';
    this.children = children ?? [];
    this.numerator = null;
    this.denominator = null;
    this.base = null;
    this.superscript = null;
    this.subscript = null;
    this.radicand = null;
  }
}

class FormulaParseResult {
  node: FormulaNode;
  nextIndex: number;

  constructor(node: FormulaNode, nextIndex: number) {
    this.node = node;
    this.nextIndex = nextIndex;
  }
}

class MermaidScaleEntry {
  key: string;
  scale: number;

  constructor(key: string, scale: number) {
    this.key = key;
    this.scale = scale;
  }
}

class MermaidSizeBridge {
  private onSizeChange: (width: number, height: number) => void = (_width: number, _height: number): void => {};

  setOnSizeChange(callback: (width: number, height: number) => void): void {
    this.onSizeChange = callback;
  }

  reportSize(width: number, height: number): void {
    this.onSizeChange(width, height);
  }
}

@Component
struct MermaidWebDiagram {
  @Prop
  @Watch('onSourceChanged')
  source: string = '';
  @Prop
  @Watch('onDiagramHeightChanged')
  diagramHeight: number = 260;
  @Prop
  @Watch('onFontScaleChanged')
  fontScale: number = 1;
  @State private measuredDiagramHeight: number = 260;

  private controller: webview.WebviewController = new webview.WebviewController();
  private sizeBridge: MermaidSizeBridge = new MermaidSizeBridge();

  aboutToAppear(): void {
    this.sizeBridge.setOnSizeChange((width: number, height: number): void => {
      this.updateMeasuredDiagramSize(width, height);
    });
    this.resetMeasuredDiagramHeight();
  }

  aboutToDisappear(): void {
    this.sizeBridge.setOnSizeChange((_width: number, _height: number): void => {});
  }

  private mermaidDataUrl(): string {
    return `data:text/html;charset=utf-8,${encodeURIComponent(this.mermaidHtml())}`;
  }

  private mermaidHtml(): string {
    const sourceText: string = this.escapeHtml(this.source);
    return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no" />
  <style>
    html, body {
      margin: 0;
      padding: 0;
      background: #FFFFFF;
      background-color: #FFFFFF !important;
      color: #0F172A;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      overflow: auto;
      color-scheme: light;
    }
    body {
      padding: 12px;
      box-sizing: border-box;
    }
    #diagram {
      width: 100%;
      min-height: 40px;
      background: #FFFFFF !important;
      background-color: #FFFFFF !important;
      overflow: visible;
      transform-origin: 0 0;
    }
    #diagram svg {
      display: block;
      max-width: 180%;
      height: auto;
      background: #FFFFFF !important;
      background-color: #FFFFFF !important;
      transform-origin: 0 0;
    }
    .render-error {
      white-space: pre-wrap;
      word-break: break-word;
      font: 12px ui-monospace, SFMono-Regular, Consolas, monospace;
      line-height: 18px;
      color: #B91C1C;
      background: #FEF2F2;
      border: 1px solid #FECACA;
      border-radius: 8px;
      padding: 10px;
    }
  </style>
</head>
<body>
  <div id="diagram"></div>
  <pre id="source" style="display:none">${sourceText}</pre>
  <script>
    const source = document.getElementById('source').textContent || '';
    const target = document.getElementById('diagram');
    const minScale = 0.6;
    const maxScale = 1.8;
    let diagramScale = 1;
    let resizeObserver = null;
    let lastReportedWidth = 0;
    let lastReportedHeight = 0;
    const mermaidUrls = [
      'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js',
      'https://unpkg.com/mermaid@11/dist/mermaid.min.js'
    ];
    function clampScale(value) {
      if (!Number.isFinite(value)) {
        return 1;
      }
      return Math.min(maxScale, Math.max(minScale, Math.round(value * 100) / 100));
    }
    function baseSvgWidth(svg) {
      const cachedWidth = parseFloat(svg.getAttribute('data-arkpilot-base-width') || '0');
      if (Number.isFinite(cachedWidth) && cachedWidth > 0) {
        return cachedWidth;
      }
      svg.style.width = '100%';
      svg.style.minWidth = '';
      svg.style.maxWidth = 'none';
      svg.style.height = 'auto';
      const rect = svg.getBoundingClientRect();
      let width = rect.width;
      if (!Number.isFinite(width) || width <= 0) {
        const attrWidth = parseFloat(svg.getAttribute('width') || '0');
        width = Number.isFinite(attrWidth) && attrWidth > 0 ? attrWidth : 0;
      }
      if (width <= 0) {
        width = Math.max(target.clientWidth, 320);
      }
      svg.setAttribute('data-arkpilot-base-width', width.toString());
      return width;
    }
    function safeNumber(value) {
      return Number.isFinite(value) && value > 0 ? value : 0;
    }
    function currentDiagramSize() {
      const svg = target.querySelector('svg');
      const html = document.documentElement;
      const body = document.body;
      const bodyRect = body.getBoundingClientRect();
      let measuredWidth = Math.max(
        safeNumber(html.scrollWidth),
        safeNumber(body.scrollWidth),
        safeNumber(target.scrollWidth),
        safeNumber(target.getBoundingClientRect().width)
      );
      let measuredHeight = Math.max(
        safeNumber(html.scrollHeight),
        safeNumber(body.scrollHeight),
        safeNumber(target.scrollHeight),
        safeNumber(target.getBoundingClientRect().height)
      );
      if (svg) {
        const svgRect = svg.getBoundingClientRect();
        measuredWidth = Math.max(measuredWidth, safeNumber(svgRect.right - bodyRect.left + 12));
        measuredHeight = Math.max(measuredHeight, safeNumber(svgRect.bottom - bodyRect.top + 12));
      }
      return {
        width: Math.ceil(measuredWidth),
        height: Math.ceil(measuredHeight)
      };
    }
    function reportDiagramSize() {
      const size = currentDiagramSize();
      if (size.height <= 0 || size.width <= 0) {
        return;
      }
      if (Math.abs(size.width - lastReportedWidth) < 2 && Math.abs(size.height - lastReportedHeight) < 2) {
        return;
      }
      lastReportedWidth = size.width;
      lastReportedHeight = size.height;
      if (window.arkpilotMermaidBridge && window.arkpilotMermaidBridge.reportSize) {
        window.arkpilotMermaidBridge.reportSize(size.width, size.height);
      }
    }
    function scheduleDiagramSizeReport() {
      requestAnimationFrame(function() {
        reportDiagramSize();
        setTimeout(reportDiagramSize, 80);
        setTimeout(reportDiagramSize, 240);
      });
    }
    function observeDiagramSize() {
      if (resizeObserver) {
        resizeObserver.disconnect();
        resizeObserver = null;
      }
      if (window.ResizeObserver) {
        resizeObserver = new ResizeObserver(scheduleDiagramSizeReport);
        resizeObserver.observe(target);
        const svg = target.querySelector('svg');
        if (svg) {
          resizeObserver.observe(svg);
        }
      }
      window.removeEventListener('resize', scheduleDiagramSizeReport);
      window.addEventListener('resize', scheduleDiagramSizeReport);
    }
    function applyDiagramScale() {
      diagramScale = clampScale(diagramScale);
      target.style.zoom = '';
      target.style.transform = 'none';
      target.style.width = '100%';
      const svg = target.querySelector('svg');
      if (svg) {
        const nextWidth = baseSvgWidth(svg) * diagramScale;
        const nextWidthText = nextWidth.toFixed(2) + 'px';
        svg.style.display = 'block';
        svg.style.transform = 'none';
        svg.style.transformOrigin = '0 0';
        svg.style.width = nextWidthText;
        svg.style.minWidth = nextWidthText;
        svg.style.maxWidth = '180%';
        svg.style.height = 'auto';
        svg.setAttribute('width', nextWidth.toFixed(2));
        scheduleDiagramSizeReport();
        return 'applied:' + nextWidthText;
      }
      scheduleDiagramSizeReport();
      return 'pending';
    }
    window.__arkpilotApplyMermaidScale = function(value) {
      diagramScale = clampScale(value);
      return applyDiagramScale();
    };
    function showError(error) {
      const detail = error && error.message ? error.message : String(error || 'Unknown Mermaid render error');
      target.innerHTML = '<div class="render-error">Mermaid 渲染失败\\n\\n' + detail.replace(/[&<>"']/g, function(ch) {
        return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch];
      }) + '</div>';
      scheduleDiagramSizeReport();
    }
    function loadMermaid(index) {
      if (window.mermaid) {
        return Promise.resolve();
      }
      if (index >= mermaidUrls.length) {
        return Promise.reject(new Error('Mermaid.js 未加载。请确认设备可以访问 jsdelivr 或 unpkg，或后续改为内置 mermaid.min.js。'));
      }
      return new Promise(function(resolve, reject) {
        const script = document.createElement('script');
        script.src = mermaidUrls[index];
        script.onload = function() { resolve(); };
        script.onerror = function() {
          loadMermaid(index + 1).then(resolve).catch(reject);
        };
        document.head.appendChild(script);
      });
    }
    async function renderDiagram() {
      try {
        await loadMermaid(0);
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: 'loose',
          theme: 'base',
          themeVariables: {
            primaryColor: '#DBEAFE',
            primaryTextColor: '#0F172A',
            primaryBorderColor: '#93C5FD',
            lineColor: '#2563EB',
            secondaryColor: '#F8FAFC',
            tertiaryColor: '#FFFFFF',
            background: '#FFFFFF',
            mainBkg: '#DBEAFE',
            secondBkg: '#F8FAFC',
            textColor: '#0F172A',
            fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
          }
        });
        const result = await mermaid.render('arkpilot-mermaid-' + Date.now().toString(), source);
        target.innerHTML = result.svg;
        if (result.bindFunctions) {
          result.bindFunctions(target);
        }
        applyDiagramScale();
        observeDiagramSize();
        scheduleDiagramSizeReport();
      } catch (error) {
        showError(error);
      }
    }
    if (document.readyState === 'loading') {
      window.addEventListener('DOMContentLoaded', renderDiagram);
    } else {
      renderDiagram();
    }
  </script>
</body>
</html>`;
  }

  private escapeHtml(text: string): string {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  private normalizedScale(value: number): number {
    if (value !== value) {
      return 1;
    }
    return Math.min(1.8, Math.max(0.6, value));
  }

  private normalizedDiagramHeight(value: number): number {
    if (value !== value || value <= 0) {
      return 260;
    }
    return Math.min(12000, Math.max(220, Math.ceil(value)));
  }

  private resetMeasuredDiagramHeight(): void {
    this.measuredDiagramHeight = this.normalizedDiagramHeight(this.diagramHeight);
  }

  private onSourceChanged(): void {
    this.resetMeasuredDiagramHeight();
  }

  private onDiagramHeightChanged(): void {
    this.resetMeasuredDiagramHeight();
  }

  private updateMeasuredDiagramSize(_width: number, height: number): void {
    const fallbackHeight: number = this.normalizedDiagramHeight(this.diagramHeight);
    const nextHeight: number = Math.max(fallbackHeight, this.normalizedDiagramHeight(height));
    if (Math.abs(nextHeight - this.measuredDiagramHeight) >= 2) {
      this.measuredDiagramHeight = nextHeight;
    }
  }

  private onFontScaleChanged(): void {
    const scaleText: string = this.normalizedScale(this.fontScale).toFixed(2);
    try {
      void this.controller.runJavaScript(
        `window.__arkpilotApplyMermaidScale && window.__arkpilotApplyMermaidScale(${scaleText});`
      );
    } catch (_err) {
    }
  }

  build() {
    Web({ src: this.mermaidDataUrl(), controller: this.controller })
      .javaScriptAccess(true)
      .javaScriptProxy({
        object: this.sizeBridge,
        name: 'arkpilotMermaidBridge',
        methodList: new Array<string>(),
        asyncMethodList: ['reportSize'],
        controller: this.controller
      })
      .darkMode(WebDarkMode.Off)
      .forceDarkAccess(false)
      .zoomAccess(false)
      .initialScale(100)
      .textZoomRatio(100)
      .onPageEnd(() => {
        this.onFontScaleChanged();
      })
      .width('100%')
      .height(this.measuredDiagramHeight)
      .backgroundColor('#FFFFFF')
      .zIndex(0)
      .hitTestBehavior(HitTestMode.Transparent)
  }
}

@CustomDialog
struct ArkPilotProjectCreateDialog {
  controller?: CustomDialogController;
  @Link projectName: string;
  @Link sourceUri: string;
  canSelectExternalFolder: () => boolean = () => false;
  chooseFolder: () => void = () => {};
  cancel: () => void = () => {};
  confirm: () => void = () => {};
  @State private sourceInfoHovering: boolean = false;
  @State private sourceInfoPinned: boolean = false;

  private sourceFolderText(): string {
    if (this.sourceUri.length > 0) {
      return `同步文件夹：${this.sourceUri}`;
    }
    return this.canSelectExternalFolder() ? '未选择同步文件夹' : '未启用下载目录同步';
  }

  private sourceFolderColor(): ResourceColor {
    return this.sourceUri.length > 0 ? '#182431' : '#475569';
  }

  private shouldShowSourceInfo(): boolean {
    return this.sourceInfoHovering || this.sourceInfoPinned;
  }

  @Builder
  private sourceInfoPopup() {
    Column() {
      Text('同步文件夹')
        .copyOption(CopyOptions.None)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#18181B')
        .width('100%')

      Text('同步文件夹是项目和本地目录之间的交换入口。项目在应用内运行，需要时再手动与该文件夹导入或导出项目文件。')
        .copyOption(CopyOptions.None)
        .fontSize(12)
        .fontColor('#4E5969')
        .lineHeight(18)
        .width('100%')
        .margin({ top: 8 })

      Column() {
        Text('• 导出项目内容：创建项目后，可以在项目菜单中，把应用内该项目文件夹内容导出到同步文件夹。')
          .copyOption(CopyOptions.None)
          .fontSize(12)
          .fontColor('#4E5969')
          .lineHeight(18)
          .width('100%')

        Text('• 导入文件夹内容：可以在项目菜单中，把同步文件夹中的内容导入到项目文件夹内。')
          .copyOption(CopyOptions.None)
          .fontSize(12)
          .fontColor('#4E5969')
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6 })

        Text('• 未选择时：仅使用应用内项目目录，可以在项目菜单中重新关联同步文件夹。')
          .copyOption(CopyOptions.None)
          .fontSize(12)
          .fontColor('#4E5969')
          .lineHeight(18)
          .width('100%')
          .margin({ top: 6 })
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width(292)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }

  build() {
    Column() {
      Row() {
        Text('新建项目')
          .copyOption(CopyOptions.None)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
          .layoutWeight(1)
        Button('×')
          .type(ButtonType.Normal)
          .accessibilityText('关闭')
          .width(32)
          .height(32)
          .fontSize(20)
          .fontColor('#182431')
          .backgroundColor('#F2F3F5')
          .borderRadius(10)
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')

      Text('运行目录将自动创建在应用内项目目录。')
        .copyOption(CopyOptions.None)
        .fontSize(14)
        .fontColor('#475569')
        .lineHeight(20)
        .width('100%')
        .margin({ top: 8 })

      TextInput({ placeholder: '输入项目名称', text: this.projectName })
        .width('100%')
        .height(48)
        .fontSize(15)
        .fontColor('#182431')
        .placeholderColor('#64748B')
        .backgroundColor('#F7F8FA')
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .margin({ top: 22 })
        .enterKeyType(EnterKeyType.Done)
        .onChange((value: string) => {
          this.projectName = value;
        })

      Column() {
        Row() {
          Text('同步文件夹')
            .copyOption(CopyOptions.None)
            .fontSize(12)
            .fontColor('#475569')

          Blank()
            .layoutWeight(1)

          Text('i')
            .copyOption(CopyOptions.None)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.shouldShowSourceInfo() ? '#18181B' : '#4E5969')
            .textAlign(TextAlign.Center)
            .width(22)
            .height(22)
            .backgroundColor(this.shouldShowSourceInfo() ? '#E5E7EB' : '#FFFFFF')
            .border({ width: 1, color: '#D1D5DB' })
            .borderRadius(11)
            .onHover((isHover: boolean) => {
              this.sourceInfoHovering = isHover;
            })
            .onClick(() => {
              if (this.sourceInfoPinned) {
                this.sourceInfoPinned = false;
                this.sourceInfoHovering = false;
              } else {
                this.sourceInfoPinned = true;
              }
            })
            .bindPopup(this.shouldShowSourceInfo(), {
              builder: this.sourceInfoPopup,
              placement: Placement.Right,
              targetSpace: 8,
              width: 320,
              radius: 16,
              mask: false,
              autoCancel: true,
              enableArrow: true,
              popupColor: '#FFFFFF',
              shadow: { radius: 16, color: '#26000000', offsetX: 0, offsetY: 6 },
              onStateChange: (event) => {
                if (!event.isVisible) {
                  this.sourceInfoHovering = false;
                  this.sourceInfoPinned = false;
                }
              }
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.sourceFolderText())
          .copyOption(CopyOptions.None)
          .fontSize(13)
          .fontColor(this.sourceFolderColor())
          .lineHeight(18)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })

      }
      .width('100%')
      .padding(14)
      .margin({ top: 12 })
      .backgroundColor('#F7F8FA')
      .borderRadius(12)

      Button(this.canSelectExternalFolder() ? '选择同步文件夹' : '启用下载目录同步')
        .type(ButtonType.Normal)
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor('#18181B')
        .backgroundColor('#F2F3F5')
        .borderRadius(12)
        .margin({ top: 12 })
        .onClick(() => {
          this.chooseFolder();
        })

      Row() {
        Button('取消')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#182431')
          .backgroundColor('#F2F3F5')
          .borderRadius(20)
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })

        Button('创建')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#18181B')
          .borderRadius(20)
          .margin({ left: 12 })
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: 24 })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 20 })
    .backgroundColor('#FFFFFF')
    .borderRadius(24)
  }
}

@CustomDialog
struct ArkPilotNameDialog {
  controller?: CustomDialogController;
  @Link textValue: string;
  title: string = '';
  subtitle: string = '';
  placeholder: string = '';
  confirmText: string = '确认';
  cancel: () => void = () => {};
  confirm: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text(this.title)
          .copyOption(CopyOptions.None)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
          .layoutWeight(1)
        Button('×')
          .type(ButtonType.Normal)
          .accessibilityText('关闭')
          .width(32)
          .height(32)
          .fontSize(20)
          .fontColor('#182431')
          .backgroundColor('#F2F3F5')
          .borderRadius(10)
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')

      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .copyOption(CopyOptions.None)
          .fontSize(14)
          .fontColor('#475569')
          .lineHeight(20)
          .width('100%')
          .margin({ top: 8 })
      }

      TextInput({ placeholder: this.placeholder, text: this.textValue })
        .width('100%')
        .height(48)
        .fontSize(15)
        .fontColor('#182431')
        .placeholderColor('#64748B')
        .backgroundColor('#F7F8FA')
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .margin({ top: 22 })
        .enterKeyType(EnterKeyType.Done)
        .onChange((value: string) => {
          this.textValue = value;
        })

      Row() {
        Button('取消')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#182431')
          .backgroundColor('#F2F3F5')
          .borderRadius(20)
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })

        Button(this.confirmText)
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#18181B')
          .borderRadius(20)
          .margin({ left: 12 })
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: 24 })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 20 })
    .backgroundColor('#FFFFFF')
    .borderRadius(24)
  }
}

@CustomDialog
struct ArkPilotDeleteDialog {
  controller?: CustomDialogController;
  @Link targetName: string;
  title: string = '';
  targetType: string = '';
  description: string = '';
  cancel: () => void = () => {};
  confirm: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text(this.title)
          .copyOption(CopyOptions.None)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
          .layoutWeight(1)
        Button('×')
          .type(ButtonType.Normal)
          .accessibilityText('关闭')
          .width(32)
          .height(32)
          .fontSize(20)
          .fontColor('#182431')
          .backgroundColor('#F2F3F5')
          .borderRadius(10)
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')

      Text(`确认删除${this.targetType}「${this.targetName}」？`)
        .copyOption(CopyOptions.None)
        .fontSize(15)
        .fontColor('#182431')
        .lineHeight(22)
        .width('100%')
        .margin({ top: 16 })

      if (this.description.length > 0) {
        Text(this.description)
          .copyOption(CopyOptions.None)
          .fontSize(13)
          .fontColor('#475569')
          .lineHeight(19)
          .width('100%')
          .margin({ top: 8 })
      }

      Row() {
        Button('取消')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#182431')
          .backgroundColor('#F2F3F5')
          .borderRadius(20)
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })

        Button('删除')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#F97373')
          .borderRadius(20)
          .margin({ left: 12 })
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: 26 })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 20 })
    .backgroundColor('#FFFFFF')
    .borderRadius(24)
  }
}

@CustomDialog
struct ArkPilotLogoutDialog {
  controller?: CustomDialogController;
  cancel: () => void = () => {};
  confirm: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text('退出登录')
          .copyOption(CopyOptions.None)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182431')
          .layoutWeight(1)
        Button('×')
          .type(ButtonType.Circle)
          .accessibilityText('关闭')
          .width(32)
          .height(32)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#64748B')
          .backgroundColor('#F1F5F9')
          .border({ width: 1, color: '#E2E8F0' })
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')

      Text('确定要退出华为账号登录吗？')
        .copyOption(CopyOptions.None)
        .fontSize(15)
        .fontColor('#182431')
        .lineHeight(22)
        .width('100%')
        .margin({ top: 16 })

      Text('退出后需要重新使用华为账号登录。')
        .copyOption(CopyOptions.None)
        .fontSize(13)
        .fontColor('#475569')
        .lineHeight(19)
        .width('100%')
        .margin({ top: 8 })

      Row() {
        Button('取消')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#182431')
          .backgroundColor('#F2F3F5')
          .borderRadius(20)
          .onClick(() => {
            this.cancel();
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })

        Button('退出')
          .type(ButtonType.Normal)
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#F97373')
          .borderRadius(20)
          .margin({ left: 12 })
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: 26 })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 20 })
    .backgroundColor('#FFFFFF')
    .borderRadius(24)
  }
}

@Entry
@Component
struct Index {
  @StorageProp('arkPilotBreakpoint')
  @Watch('onBreakpointChanged')
  currentBreakpoint: ArkPilotBreakpoint = 'sm';
  @StorageProp('arkPilotLoggedIn')
  @Watch('onLoggedInChanged')
  accountLoggedIn: boolean = false;
  private readonly thinkingStatusPhrases: string[] = [
    '正在厘清问题',
    '正在读取上下文',
    '正在规划下一步',
    '正在组织回答'
  ];
  private readonly longThinkingStatusPhrases: string[] = [
    '摸鱼中',
    '泡咖啡中',
    '炒股中',
    '灵感加载中',
    '翻资料中',
    '灵感排队中',
    '给脑子预热中',
    '和 bug 讲道理中',
    '整理灵感碎片中'
  ];
  private readonly longThinkingPulseThreshold: number = 50;
  private readonly thinkingPhrasePulseSpan: number = 30;
  private readonly idleThinkingDelayMs: number = 3000;
  private readonly conversationFontScaleMin: number = 0.6;
  private readonly conversationFontScaleMax: number = 1.8;
  private readonly conversationFontScaleStep: number = 0.05;
  private readonly keyCodeMinus: number = 2057;
  private readonly keyCodeEquals: number = 2058;
  private readonly keyCodePlus: number = 2066;
  private readonly keyCodeNumpadSubtract: number = 2115;
  private readonly keyCodeNumpadAdd: number = 2116;
  private readonly keyCodeNumpadEquals: number = 2120;
  private readonly thinkingLogoFrames: string[] = [
    '◎>_',
    '◎>=',
    '◎>-',
    '◎>·'
  ];
  private readonly effortOptions: SelectorOption[] = [
    new SelectorOption('默认', 'default'),
    new SelectorOption('minimal', 'minimal'),
    new SelectorOption('low', 'low'),
    new SelectorOption('medium', 'medium'),
    new SelectorOption('high', 'high'),
    new SelectorOption('xhigh', 'xhigh')
  ];
  private backendSubscriptionId: number = -1;
  private reconnectTimerId: number = -1;
  private reconnectAttemptCount: number = 0;
  private thinkingTimerId: number = -1;
  private idleThinkingTimerId: number = -1;
  private lastTextOutputAt: number = 0;
  private lastTextOutputSignature: string = '';
  private readonly workspaceRoots: Map<number, string> = new Map();
  private readonly workspaceIds: Map<number, string> = new Map();
  private readonly workspaceUris: Map<number, string> = new Map();
  private readonly collaborationModeByWorkspaceId: Map<string, string> = new Map();
  private readonly requestUserInputDrafts: Map<string, string> = new Map();
  private readonly workspaceRunStates: Map<number, WorkspaceRunState> = new Map();
  private renderedWorkspaceId: number = 0;
  private renderedThreadId: string = '';
  private readonly messageScroller: Scroller = new Scroller();

  @State private workspaces: WorkspaceItem[] = [];
  @State private activeWorkspaceId: number = 1;
  @State private activeWorkspaceBindingId: string = 'session:1';
  @State private backendActiveThreadId: string = '';
  @State private runningWorkspaceVersion: number = 0;
  @State private currentWorkspaceTitle: string = '新会话 1';
  @State private currentWorkspaceDescription: string = '等待通过 app-server 创建真实会话';
  @State private activeWorkspacePermissionState: WorkspacePermissionState = 'unavailable';
  @State private activeWorkspaceAccessKind: WorkspaceAccessKind = 'unknown';
  @State private workspaceStatusText: string = 'å°šæœªæ£€æµ‹å·¥ä½œåŒºæƒé™';
  @State private selectedEffortIndex: number = 0;
  @State private showEffortOptions: boolean = false;
  @State private collaborationModes: CollaborationModeOption[] = [];
  @State private selectedCollaborationModeName: string = 'default';
  @State private collaborationModeVersion: number = 0;
  @State private showCollaborationModeOptions: boolean = false;
  @State private serverUrl: string = 'ws://127.0.0.1:7456';
  @State private workspaceRoot: string = '';
  @State private workspaceDraftText: string = '';
  @State private workspaceSelectionText: string = '使用默认工作区';
  @State private providerBaseUrl: string = '';
  @State private providerApiKey: string = '';
  @State private manualModel: string = '';
  @State private providerStatusText: string = 'Provider config not loaded yet.';
  @State private providerName: string = '未选择';
  @State private isSavingProvider: boolean = false;
  @State private apiKey: string = '';
  @State private isAuthenticating: boolean = false;
  @State private authStatusText: string = '未登录';
  @State private connectionState: CodexConnectionState = 'disconnected';
  @State private connectionText: string = '未连接';
  @State private summaryTitle: string = '';
  @State private summaryPoints: string[] = [
    '应用启动时会自动拉起内置 Rust ArkPilot host。',
    '这里通过 libhish_main.so 同步调用原生桥接层，而不是本地 mock。',
    '发送消息后会刷新对话、计划和 diff。'
  ];
  @State private changedFiles: string = '尚未产生文件改动';
  @State private diffStat: string = '+0 -0';
  @State private diffFiles: CodeDiffFile[] = [];
  @State private selectedDiffFilePath: string = '';
  @State private isRunning: boolean = false;
  @State private showLeftDrawer: boolean = true;
  @State private showRightDrawer: boolean = true;
  @State private leftPanelWidth: number = 280;
  @State private rightPanelWidth: number = 360;
  private leftScrollOffset: number = 0;
  private leftScrollController: Scroller = new Scroller();
  private readonly leftDrawerMinWidth: number = 100;
  private readonly rightDrawerMinWidth: number = 120;
  private readonly motionFastDuration: number = 160;
  private readonly motionNormalDuration: number = 240;
  private readonly motionPanelDuration: number = 280;
  private dragStartLeftW: number = 0;
  private dragStartRightW: number = 0;
  private leftHiding: boolean = false;
  private rightHiding: boolean = false;
  @State private recentWorkspaces: WorkspaceItem[] = [];
  @State private directoryFilter: string = '';
  @State private directoryFilterText: string = '使用默认工作区';
  @State private draft: string = '';
  private savedDraft: string = '';
  private backendPendingApproval: CodexApprovalRequest | null = null;
  private backendPendingRequestUserInput: CodexRequestUserInput | null = null;
  @State private pendingApproval: CodexApprovalRequest | null = null;
  @State private pendingRequestUserInput: CodexRequestUserInput | null = null;
  @State private requestUserInputVersion: number = 0;
  @State private expandedIntermediateMessageIds: string[] = [];
  @State private isTurnActivityCollapsed: boolean = true;
  @State private expandedCompactionIds: string[] = [];
  @State private selectableMessageIds: string[] = [];
  @State private hoveredMessageId: string = '';
  @State private conversationFontScale: number = 1;
  @State private mermaidScaleEntries: MermaidScaleEntry[] = [];
  @State private compactionNotices: CompactionNotice[] = [];
  @State private compactionNoticeVersion: number = 0;
  @State private currentTurnId: string = '';
  @State private currentTurnStatus: string = '';
  @State private thinkingPulseIndex: number = 0;
  @State private thinkingSessionId: number = 0;
  @State private thinkingNormalPhrase: string = '';
  @State private thinkingFunPhrase: string = '';
  @State private showIdleThinkingIndicator: boolean = false;
  @State private liveThinkingActive: boolean = false;
  @State private liveThinkingContent: string = '';
  @State private pendingUserPrompt: string = '';
  private thinkingMessageBoundary: number = -1;
  private liveThinkingReasoningSignature: string = '';
  private liveThinkingAssistantSignature: string = '';
  private thinkingNormalPhraseBucket: number = -1;
  private thinkingFunPhraseBucket: number = -1;
  @State private messageAutoFollowToBottom: boolean = true;
  private messageProgrammaticScroll: boolean = false;
  private messageProgrammaticScrollTimerId: number = -1;
  private messageScheduledScrollTimerId: number = -1;
  private messageScheduledFollowUpScrollTimerId: number = -1;
  private messageUserScrollActive: boolean = false;
  private messageUserScrollTimerId: number = -1;
  private messageZoomWheelActiveUntil: number = 0;
  private lastAppliedMessagesSignature: string = '';
  @State private messages: ChatMessage[] = [
    new ChatMessage(
      'welcome-1',
      'ArkPilot',
      'assistant',
      '前端会自动连接应用内置 app-server。必要时你仍然可以手动重连或修改工作目录。',
      '刚刚'
    )
  ];
  @State private codeLines: CodeDiffLine[] = [
    new CodeDiffLine('placeholder-1', '1', ' ', '等待 turn/diff/updated 通知。', 'context')
  ];
  @State private tokenUsage: TurnTokenUsage | null = null;
  @State private contextManagement: CodexContextManagementSnapshot = new CodexContextManagementSnapshot();
  @State private modelAutoCompactTokenLimit: number | null = null;
  @State private effectiveAutoCompactTokenLimit: number | null = null;
  @State private autoCompactCurrentTotalTokens: number | null = null;
  @State private autoCompactWillCheckBeforeNextTurn: boolean = false;
  @State private autoCompactWouldWaitForFollowUp: boolean = false;
  @State private autoCompactEnabled: boolean = false;
  @State private remainingToAutoCompact: number | null = null;
  @State private autoCompactNearThreshold: boolean = false;
  @State private tokenAggregate: TokenUsageAggregate | null = null;
  @State private tokenCardExpanded: boolean = true;
  @State private tokenCardHeight: number = 280;
  @State private tokenCardDragStartY: number = 0;
  @State private tokenCardDragStartH: number = 0;
  @State private tokenTab: number = 0;
  @State private tokenTrendRange: number = 0;
  private tokenAggregateRequestVersion: number = 0;
  @State private compacting: boolean = false;
  @State private compactError: string = '';
  private compactionClearTimerId: number = -1;
  private pendingCompactionThreadId: string = '';
  @State private projects: ProjectRecord[] = [];
  @State private newProjectName: string = '';
  @State private newProjectSourceUri: string = '';
  @State private renamingProjectId: string = '';
  @State private renameProjectText: string = '';
  @State private showAboutDialog: boolean = false;
  @State private newSessionProjectId: string = '';
  @State private newSessionName: string = '';
  @State private renamingSessionId: string = '';
  @State private renameSessionText: string = '';
  @State private hoveredProjectId: string = '';
  @State private hoveredSessionId: string = '';
  @State private hasPointerHover: boolean = false;
  @State private lastMenuTouchWindowX: number = 0;
  @State private lastMenuTouchWindowY: number = 0;
  @State private suppressProjectClickId: string = '';
  @State private suppressSessionClickId: string = '';
  @State private mouseNearRightEdge: boolean = false;
  @State private chatAreaWidth: number = 0;
  @State private showProjectMenuId: string = '';
  @State private showSessionMenuId: string = '';
  @State private floatingMenuX: number = 0;
  @State private floatingMenuY: number = 0;
  @State private floatingMenuWidth: number = 120;
  @State private renameSessionDialogText: string = '';
  @State private renameSessionDialogId: string = '';
  @State private deleteSessionDialogId: string = '';
  @State private deleteSessionDialogTitle: string = '';
  @State private renameProjectDialogText: string = '';
  @State private renameProjectDialogId: string = '';
  @State private deleteProjectDialogId: string = '';
  @State private deleteProjectDialogName: string = '';
  @State private lastAppliedBreakpoint: ArkPilotBreakpoint = 'sm';

  private createProjectDialogController: CustomDialogController | null = new CustomDialogController({
    builder: ArkPilotProjectCreateDialog({
      projectName: this.newProjectName,
      sourceUri: this.newProjectSourceUri,
      canSelectExternalFolder: () => this.canSelectExternalFolder(),
      chooseFolder: () => {
        void this.pickWorkspaceDirectoryForProject();
      },
      cancel: () => {
        this.cancelCreateProjectDialog();
      },
      confirm: () => {
        void this.createProject();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 24,
    maskColor: '#66000000',
    backgroundColor: '#FFFFFF',
    shadow: { radius: 24, color: '#26000000', offsetX: 0, offsetY: 8 },
    cancel: () => {
      this.cancelCreateProjectDialog();
    }
  });

  private newSessionDialogController: CustomDialogController | null = new CustomDialogController({
    builder: ArkPilotNameDialog({
      textValue: this.newSessionName,
      title: '新建会话',
      subtitle: '会话会创建在当前项目下。',
      placeholder: '输入会话名称',
      confirmText: '创建',
      cancel: () => {
        this.cancelNewSessionDialog();
      },
      confirm: () => {
        void this.confirmCreateSession();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 24,
    maskColor: '#66000000',
    backgroundColor: '#FFFFFF',
    shadow: { radius: 24, color: '#26000000', offsetX: 0, offsetY: 8 },
    cancel: () => {
      this.cancelNewSessionDialog();
    }
  });

  private renameProjectDialogController: CustomDialogController | null = new CustomDialogController({
    builder: ArkPilotNameDialog({
      textValue: this.renameProjectDialogText,
      title: '重命名项目',
      placeholder: '输入项目名称',
      confirmText: '确认',
      cancel: () => {
        this.cancelRenameProjectDialog();
      },
      confirm: () => {
        this.confirmRenameProjectDialog();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 24,
    maskColor: '#66000000',
    backgroundColor: '#FFFFFF',
    shadow: { radius: 24, color: '#26000000', offsetX: 0, offsetY: 8 },
    cancel: () => {
      this.cancelRenameProjectDialog();
    }
  });

  private deleteProjectDialogController: CustomDialogController | null = new CustomDialogController({
    builder: ArkPilotDeleteDialog({
      targetName: this.deleteProjectDialogName,
      title: '删除项目',
      targetType: '项目',
      description: '删除会话记录及应用内项目文件夹，\n已映射的外部同步文件夹不会被删除。',
      cancel: () => {
        this.cancelDeleteProjectDialog();
      },
      confirm: () => {
        this.confirmDeleteProjectDialog();
      }
    }),
    autoCancel: false,
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 24,
    maskColor: '#66000000',
    backgroundColor: '#FFFFFF',
    shadow: { radius: 24, color: '#26000000', offsetX: 0, offsetY: 8 },
    cancel: () => {
      this.cancelDeleteProjectDialog();
    }
  });

  private renameSessionDialogController: CustomDialogController | null = new CustomDialogController({
    builder: ArkPilotNameDialog({
      textValue: this.renameSessionDialogText,
      title: '重命名会话',
      placeholder: '输入会话名称',
      confirmText: '确认',
      cancel: () => {
        this.cancelRenameSessionDialog();
      },
      confirm: () => {
        this.confirmRenameSessionDialog();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 24,
    maskColor: '#66000000',
    backgroundColor: '#FFFFFF',
    shadow: { radius: 24, color: '#26000000', offsetX: 0, offsetY: 8 },
    cancel: () => {
      this.cancelRenameSessionDialog();
    }
  });

  private deleteSessionDialogController: CustomDialogController | null = new CustomDialogController({
    builder: ArkPilotDeleteDialog({
      targetName: this.deleteSessionDialogTitle,
      title: '删除会话',
      targetType: '会话',
      description: '删除后会话将从列表中移除。',
      cancel: () => {
        this.cancelDeleteSessionDialog();
      },
      confirm: () => {
        this.confirmDeleteSessionDialog();
      }
    }),
    autoCancel: false,
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 24,
    maskColor: '#66000000',
    backgroundColor: '#FFFFFF',
    shadow: { radius: 24, color: '#26000000', offsetX: 0, offsetY: 8 },
    cancel: () => {
      this.cancelDeleteSessionDialog();
    }
  });

  private logoutDialogController: CustomDialogController | null = new CustomDialogController({
    builder: ArkPilotLogoutDialog({
      cancel: () => {
        this.cancelLogoutDialog();
      },
      confirm: () => {
        this.confirmLogout();
      }
    }),
    autoCancel: false,
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 24,
    maskColor: '#66000000',
    backgroundColor: '#FFFFFF',
    shadow: { radius: 24, color: '#26000000', offsetX: 0, offsetY: 8 },
    cancel: () => {
      this.cancelLogoutDialog();
    }
  });

  aboutToAppear(): void {
    const loggedIn: boolean = (AppStorage.get<boolean>('arkPilotLoggedIn') ?? false);
    if (!loggedIn) {
      router.replaceUrl({ url: 'pages/AiLoginPage' });
      return;
    }
    const mediaQuery = this.getUIContext().getMediaQuery();
    breakpointManager.initialize((condition: string) => mediaQuery.matchMediaSync(condition));
    this.applyResponsiveLayoutProfile(true);

    this.backendSubscriptionId = codexBackend.subscribe((snapshot: CodexBackendSnapshot) => {
      this.applyBackendSnapshot(snapshot);
    });
    this.applyBackendSnapshot(codexBackend.snapshot());
    this.applyEmbeddedHostStatus();
    this.loadProviderConfig();
    this.restoreWorkspaceBindings();
    this.loadProjects();

    void this.restoreSessionsFromBackend();

    this.scheduleEmbeddedHostReconnect(2000);
    this.scheduleMessageScrollToBottom();
  }

  aboutToDisappear(): void {
    if (this.backendSubscriptionId >= 0) {
      codexBackend.unsubscribe(this.backendSubscriptionId);
    }
    this.clearReconnectTimer();
    this.stopThinkingAnimation();
    this.clearIdleThinkingTimer();
    this.clearCompactionClearTimer();
    this.clearMessageScheduledScrollTimers();
    this.clearMessageProgrammaticScrollTimer();
    this.clearMessageUserScrollTimer();
  }

  private applyBackendSnapshot(snapshot: CodexBackendSnapshot): void {
    hilog.info(0x0001, 'ArkPilot', `applyBackendSnapshot: conn=${snapshot.connectionState} modes=${snapshot.collaborationModes.length} selected=${this.selectedCollaborationModeName}`);
    this.serverUrl = snapshot.serverUrl;
    this.connectionState = snapshot.connectionState;
    this.connectionText = snapshot.connectionText;
    this.backendPendingApproval = snapshot.pendingApproval;
    this.backendPendingRequestUserInput = snapshot.pendingRequestUserInput;
    const previousRequestId: string = this.pendingRequestUserInput !== null ? `${this.pendingRequestUserInput.requestId}` : '';
    this.applyPendingRequestsForActiveWorkspace();
    const nextRequestId: string = this.pendingRequestUserInput !== null ? `${this.pendingRequestUserInput.requestId}` : '';
    this.collaborationModes = snapshot.collaborationModes;
    if (previousRequestId !== nextRequestId) {
      this.requestUserInputDrafts.clear();
      this.requestUserInputVersion += 1;
    }
    this.syncSelectedCollaborationMode();
    const snapshotThreadId: string = snapshot.activeThreadId.trim();
    if (this.requestBelongsToWorkspace(snapshotThreadId, this.activeWorkspaceId)) {
      this.backendActiveThreadId = snapshotThreadId;
      this.tokenUsage = snapshot.tokenUsage;
      this.contextManagement = snapshot.contextManagement;
      this.modelAutoCompactTokenLimit = snapshot.modelAutoCompactTokenLimit;
      this.effectiveAutoCompactTokenLimit = snapshot.effectiveAutoCompactTokenLimit;
      this.autoCompactCurrentTotalTokens = snapshot.autoCompactCurrentTotalTokens;
      this.autoCompactWillCheckBeforeNextTurn = snapshot.autoCompactWillCheckBeforeNextTurn;
      this.autoCompactWouldWaitForFollowUp = snapshot.autoCompactWouldWaitForFollowUp;
      this.autoCompactEnabled = snapshot.autoCompactEnabled;
      this.remainingToAutoCompact = snapshot.remainingToAutoCompact;
      this.autoCompactNearThreshold = snapshot.autoCompactNearThreshold;
    } else {
      this.backendActiveThreadId = this.activeWorkspaceBindingId.trim();
      this.modelAutoCompactTokenLimit = null;
      this.effectiveAutoCompactTokenLimit = null;
      this.autoCompactCurrentTotalTokens = null;
      this.autoCompactWillCheckBeforeNextTurn = false;
      this.autoCompactWouldWaitForFollowUp = false;
      this.autoCompactEnabled = false;
      this.remainingToAutoCompact = null;
      this.autoCompactNearThreshold = false;
    }
    this.applyCompactionSnapshot(snapshot);
  }

  private applyPendingRequestsForActiveWorkspace(): void {
    this.pendingApproval = this.backendPendingApproval !== null && this.requestBelongsToWorkspace(this.backendPendingApproval.threadId, this.activeWorkspaceId)
      ? this.backendPendingApproval
      : null;
    this.pendingRequestUserInput = this.backendPendingRequestUserInput !== null && this.requestBelongsToWorkspace(this.backendPendingRequestUserInput.threadId, this.activeWorkspaceId)
      ? this.backendPendingRequestUserInput
      : null;
  }

  private clearTokenAggregate(): void {
    this.tokenAggregateRequestVersion += 1;
    this.tokenAggregate = null;
  }

  private async refreshTokenAggregateForActiveWorkspace(expectedThreadId?: string): Promise<void> {
    const workspace: WorkspaceItem | undefined = this.activeWorkspace();
    if (workspace === undefined || !this.isRemoteThreadId(workspace.workspaceId)) {
      this.clearTokenAggregate();
      return;
    }
    const targetWorkspaceId: number = workspace.id;
    const targetThreadId: string = expectedThreadId !== undefined && expectedThreadId.trim().length > 0
      ? expectedThreadId.trim()
      : workspace.workspaceId.trim();
    const requestVersion: number = this.tokenAggregateRequestVersion + 1;
    this.tokenAggregateRequestVersion = requestVersion;
    this.tokenAggregate = null;
    await Promise.resolve();
    if (this.tokenAggregateRequestVersion !== requestVersion) {
      return;
    }
    const aggregate: TokenUsageAggregate | null = codexBackend.fetchTokenUsageAggregate();
    const activeWorkspace: WorkspaceItem | undefined = this.activeWorkspace();
    if (activeWorkspace === undefined || activeWorkspace.id !== targetWorkspaceId) {
      return;
    }
    if (!this.isRemoteThreadId(activeWorkspace.workspaceId) || activeWorkspace.workspaceId.trim() !== targetThreadId) {
      return;
    }
    this.tokenAggregate = aggregate;
  }

  private requestBelongsToWorkspace(threadId: string, workspaceId: number): boolean {
    const trimmedThreadId: string = threadId.trim();
    if (trimmedThreadId.length === 0) {
      return false;
    }
    const workspace: WorkspaceItem | undefined = this.workspaces.find((item: WorkspaceItem) => item.id === workspaceId);
    if (workspace !== undefined && workspace.workspaceId.trim() === trimmedThreadId) {
      return true;
    }
    const bindingId: string | undefined = this.workspaceIds.get(workspaceId);
    if (bindingId !== undefined && bindingId.trim() === trimmedThreadId) {
      return true;
    }
    const runState: WorkspaceRunState | undefined = this.workspaceRunStates.get(workspaceId);
    if (runState !== undefined) {
      return runState.threadId.trim() === trimmedThreadId || runState.threadKey.trim() === trimmedThreadId;
    }
    return workspaceId === this.activeWorkspaceId && this.activeWorkspaceBindingId.trim() === trimmedThreadId;
  }

  private applyCompactionSnapshot(snapshot: CodexBackendSnapshot): void {
    const compaction = snapshot.compaction;
    const hadError: boolean = this.compactError.length > 0;
    const wasCompacting: boolean = this.compacting;
    const isCurrentThread: boolean = this.isCurrentCompactionThreadId(compaction.threadId);
    const nextCompacting: boolean = isCurrentThread && (compaction.status === 'starting' || compaction.status === 'running');
    this.compacting = nextCompacting;
    if (nextCompacting && isCurrentThread) {
      this.pendingCompactionThreadId = compaction.threadId.trim();
    }
    if (compaction.status === 'idle') {
      if (!this.compacting) {
        this.pendingCompactionThreadId = '';
      }
      this.compactError = '';
      return;
    }
    if (compaction.threadId.trim().length > 0) {
      this.upsertCompactionNotice(
        compaction.threadId,
        compaction.status,
        compaction.errorMessage,
        compaction.savedTokens,
        compaction.oldTotalTokens,
        compaction.newTotalTokens
      );
    }
    if (!isCurrentThread) {
      this.compactError = '';
      return;
    }
    if (compaction.status === 'failed' || compaction.status === 'timeout') {
      this.pendingCompactionThreadId = '';
      this.compactError = compaction.errorMessage;
      return;
    }
    if (compaction.status === 'completed') {
      this.pendingCompactionThreadId = '';
      this.compactError = '';
      if (wasCompacting || hadError) {
        if (compaction.savedTokens > 0) {
          promptAction.showToast({ message: `压缩完成，释放 ${this.formatTokenCount(compaction.savedTokens)} tokens`, duration: 3000 });
        } else {
          promptAction.showToast({ message: '压缩完成', duration: 2000 });
        }
      }
      this.scheduleBackendCompactionClear(compaction.threadId);
      return;
    }
    if (!nextCompacting) {
      this.compactError = '';
    }
  }

  private upsertCompactionNotice(
    threadId: string,
    status: string,
    errorMessage: string,
    savedTokens: number,
    oldTotalTokens: number,
    newTotalTokens: number
  ): void {
    const noticeId: string = `compaction:${threadId}`;
    const previous: CompactionNotice | null = this.compactionNoticeById(noticeId);
    const isNewRun: boolean = previous === null || (this.isTerminalCompactionStatus(previous.status) && (status === 'starting' || status === 'running'));
    const effectiveOldTotal: number = oldTotalTokens > 0
      ? oldTotalTokens
      : (!isNewRun && previous !== null ? previous.oldTotalTokens : 0);
    const effectiveNewTotal: number = newTotalTokens > 0
      ? newTotalTokens
      : (!isNewRun && previous !== null ? previous.newTotalTokens : 0);
    const computedSaved: number = effectiveOldTotal > 0 && effectiveNewTotal > 0 && effectiveOldTotal > effectiveNewTotal
      ? effectiveOldTotal - effectiveNewTotal
      : 0;
    const effectiveSaved: number = savedTokens > 0
      ? savedTokens
      : (computedSaved > 0 ? computedSaved : (!isNewRun && previous !== null ? previous.savedTokens : 0));
    const anchorMessageId: string = isNewRun || previous === null ? this.currentCompactionAnchorMessageId() : previous.anchorMessageId;
    const next = new CompactionNotice(
      noticeId,
      threadId,
      status,
      errorMessage,
      effectiveSaved,
      effectiveOldTotal,
      effectiveNewTotal,
      isNewRun || previous === null ? this.currentClockLabel() : previous.timestamp,
      anchorMessageId
    );
    this.compactionNotices = [
      ...this.compactionNotices.filter((item: CompactionNotice) => item.id !== noticeId),
      next
    ];
    this.compactionNoticeVersion += 1;
    this.scheduleMessageScrollToBottom();
  }

  private isTerminalCompactionStatus(status: string): boolean {
    return status === 'completed' || status === 'failed' || status === 'timeout';
  }

  private currentCompactionThreadIds(): string[] {
    const threadIds: string[] = [];
    this.pushUniqueCompactionThreadId(threadIds, this.activeWorkspaceBindingId);
    this.pushUniqueCompactionThreadId(threadIds, this.backendActiveThreadId);
    const workspace: WorkspaceItem | undefined = this.activeWorkspace();
    if (workspace !== undefined) {
      this.pushUniqueCompactionThreadId(threadIds, workspace.workspaceId);
    }
    return threadIds;
  }

  private pushUniqueCompactionThreadId(threadIds: string[], threadId: string): void {
    const trimmedThreadId: string = threadId.trim();
    if (trimmedThreadId.length === 0 || threadIds.indexOf(trimmedThreadId) >= 0) {
      return;
    }
    threadIds.push(trimmedThreadId);
  }

  private isCurrentCompactionThreadId(threadId: string): boolean {
    const trimmedThreadId: string = threadId.trim();
    if (trimmedThreadId.length === 0) {
      return false;
    }
    return this.currentCompactionThreadIds().indexOf(trimmedThreadId) >= 0;
  }

  private scheduleBackendCompactionClear(threadId: string): void {
    this.clearCompactionClearTimer();
    this.compactionClearTimerId = setTimeout(() => {
      codexBackend.clearCompactionNotice(threadId);
      this.compactionClearTimerId = -1;
    }, 800);
  }

  private clearCompactionClearTimer(): void {
    if (this.compactionClearTimerId >= 0) {
      clearTimeout(this.compactionClearTimerId);
      this.compactionClearTimerId = -1;
    }
  }

  private compactionNoticeById(id: string): CompactionNotice | null {
    for (let index: number = 0; index < this.compactionNotices.length; index += 1) {
      if (this.compactionNotices[index].id === id) {
        return this.compactionNotices[index];
      }
    }
    return null;
  }

  private currentClockLabel(): string {
    const date: Date = new Date();
    const hours: string = date.getHours().toString().padStart(2, '0');
    const minutes: string = date.getMinutes().toString().padStart(2, '0');
    return `${hours}:${minutes}`;
  }

  private async applyEmbeddedHostStatus(): Promise<void> {
    const hostStatus = getEmbeddedCodexHostStatus();
    if (hostStatus.serverUrl.trim().length > 0) {
      this.serverUrl = hostStatus.serverUrl;
    }

    if (hostStatus.running) {
      this.summaryTitle = '应用内后端已启动';
      this.summaryPoints = [
        hostStatus.message,
        '页面会自动尝试连接本地 原生桥接 服务。',
        '如果需要调试，也可以手动断开后重新连接。'
      ];
      return;
    }

    if (hostStatus.message.trim().length > 0) {
      this.summaryTitle = '应用内后端未就绪';
      this.summaryPoints = [
        hostStatus.message,
        '可以稍后点击连接重试。',
        '如果持续失败，需要检查 native/Rust 构建产物是否被正确打包。'
      ];
    }
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimerId >= 0) {
      clearTimeout(this.reconnectTimerId);
      this.reconnectTimerId = -1;
    }
  }

  private scheduleEmbeddedHostReconnect(delayMs: number): void {
    this.clearReconnectTimer();
    this.reconnectTimerId = setTimeout(() => {
      this.reconnectTimerId = -1;
      void this.connectEmbeddedHost();
    }, delayMs);
  }

  private activeWorkspace(): WorkspaceItem | undefined {
    if (this.workspaces.length === 0) {
      return undefined;
    }
    for (let index: number = 0; index < this.workspaces.length; index += 1) {
      if (this.workspaces[index].id === this.activeWorkspaceId) {
        return this.workspaces[index];
      }
    }
    return this.workspaces[0];
  }

  private syncCurrentWorkspaceState(): void {
    const workspace: WorkspaceItem | undefined = this.activeWorkspace();
    if (workspace === undefined) {
      this.currentWorkspaceTitle = '';
      this.currentWorkspaceDescription = '';
      return;
    }
    this.currentWorkspaceTitle = workspace.title;
    this.currentWorkspaceDescription = workspace.description;
  }

  private syncRecentWorkspaces(): void {
    const filter = this.directoryFilter.trim();
    if (filter.length === 0) {
      this.recentWorkspaces = [...this.workspaces].reverse();
      return;
    }
    const filtered = this.workspaces.filter((item: WorkspaceItem) => {
      const root = this.workspaceRoots.get(item.id) ?? '';
      return root.trim().length === 0 || root.trim() === filter;
    });
    this.recentWorkspaces = [...filtered].reverse();
  }

  private ensureWorkspaceBinding(item: WorkspaceItem): string {
    const existing: string | undefined = this.workspaceIds.get(item.id);
    if (existing !== undefined && existing.trim().length > 0) {
      item.workspaceId = existing;
      return existing;
    }
    const workspaceId: string = item.workspaceId.trim().length > 0 ? item.workspaceId : `session:${item.id.toString()}`;
    item.workspaceId = workspaceId;
    this.workspaceIds.set(item.id, workspaceId);
    return workspaceId;
  }

  private refreshWorkspaceBindingState(): void {
    if (this.workspaces.length === 0) {
      this.activeWorkspaceBindingId = '';
      this.activeWorkspacePermissionState = 'unavailable';
      this.activeWorkspaceAccessKind = 'unknown';
      this.workspaceStatusText = '';
      return;
    }
    const active: WorkspaceItem = this.activeWorkspace()!;
    this.activeWorkspaceBindingId = this.ensureWorkspaceBinding(active);
    const currentWorkspaceRoot: string = this.workspaceDraftText.trim().length > 0 ? this.workspaceDraftText.trim() : this.workspaceRoot.trim();
    if (currentWorkspaceRoot.length > 0) {
      const status: WorkspaceAccessStatus = checkWorkspaceAccess(currentWorkspaceRoot);
      this.activeWorkspacePermissionState = this.mapWorkspacePermissionState(status.permissionState);
      this.activeWorkspaceAccessKind = this.mapWorkspaceAccessKind(status.accessKind);
      this.workspaceStatusText = status.message.trim().length > 0 ? status.message : 'å·¥ä½œåŒºå·²é…ç½®';
      return;
    }
    this.activeWorkspacePermissionState = 'unavailable';
    this.activeWorkspaceAccessKind = 'unknown';
    this.workspaceStatusText = 'å½“å‰æœªé…ç½®å·¥ä½œåŒº';
  }

  private nextWorkspaceId(): number {
    let nextId: number = this.activeWorkspaceId > 0 ? this.activeWorkspaceId + 1 : 1;
    for (let index: number = 0; index < this.workspaces.length; index += 1) {
      if (this.workspaces[index].id >= nextId) {
        nextId = this.workspaces[index].id + 1;
      }
    }
    this.workspaceIds.forEach((_workspaceId: string, key: number) => {
      if (key >= nextId) {
        nextId = key + 1;
      }
    });
    return nextId;
  }

  private isRemoteThreadId(workspaceId: string): boolean {
    const trimmedWorkspaceId: string = workspaceId.trim();
    return trimmedWorkspaceId.length > 0 && !trimmedWorkspaceId.startsWith('session:');
  }

  private workspaceDescriptionFromSummary(summary: SessionSummary): string {
    const changedFiles: string = summary.changedFiles.trim();
    if (changedFiles.length > 0 && changedFiles !== '尚未产生文件改动') {
      return changedFiles;
    }
    const summaryTitle: string = summary.summaryTitle.trim();
    if (summaryTitle.length > 0) {
      return summaryTitle;
    }
    return '已从 app-server 恢复的历史会话';
  }

  private resetConversationSurface(title: string, points?: string[]): void {
    this.messages = [
      new ChatMessage(
        'welcome-1',
        'ArkPilot',
        'assistant',
        '前端会自动连接应用内置 app-server。必要时你仍然可以手动重连或修改工作目录。',
        '刚刚'
      )
    ];
    this.lastAppliedMessagesSignature = '';
    this.codeLines = [
      new CodeDiffLine('placeholder-1', '1', ' ', '等待 turn/diff/updated 通知。', 'context')
    ];
    this.diffFiles = [];
    this.selectedDiffFilePath = '';
    this.summaryTitle = title;
    this.summaryPoints = points ?? ['当前会话尚未产生历史消息。'];
    this.changedFiles = '尚未产生文件改动';
    this.diffStat = '+0 -0';
    this.currentTurnId = '';
    this.renderedWorkspaceId = this.activeWorkspaceId;
    this.renderedThreadId = this.activeWorkspaceBindingId;
    this.expandedCompactionIds = [];
    this.clearLiveThinking();
    this.resumeMessageAutoFollow();
    this.scheduleMessageScrollToBottom(true);
  }

  private async restoreSessionsFromBackend(preferredThreadId?: string): Promise<void> {
    const sessions: SessionSummary[] = await codexBackend.loadPersistedSessions();
    this.applySessionSummariesToWorkspaces(sessions, preferredThreadId);
    await this.loadSelectedWorkspaceHistory();
  }

  private syncSessionSummariesFromCache(preferredThreadId?: string): void {
    const sessions: SessionSummary[] = codexBackend.sessionSummaries();
    this.applySessionSummariesToWorkspaces(sessions, preferredThreadId);
  }

  private applySessionSummariesToWorkspaces(summaries: SessionSummary[], preferredThreadId?: string): void {
    if (summaries.length === 0) {
      if (this.workspaces.length === 0) {
        this.activeWorkspaceId = 0;
        this.workspaceRoot = '';
        this.workspaceDraftText = '';
        this.currentWorkspaceTitle = '';
        this.currentWorkspaceDescription = '';
      }
      this.syncRecentWorkspaces();
      this.syncWorkspaceSelectionText();
      this.refreshWorkspaceBindingState();
      this.syncCurrentWorkspaceState();
      this.persistWorkspaceBindings();
      return;
    }

    const currentWorkspaceByThreadId: Map<string, WorkspaceItem> = new Map();
    for (let index: number = 0; index < this.workspaces.length; index += 1) {
      const workspace: WorkspaceItem = this.workspaces[index];
      if (this.isRemoteThreadId(workspace.workspaceId)) {
        currentWorkspaceByThreadId.set(workspace.workspaceId, workspace);
      }
    }

    const bindingSnapshot = workspaceBindingStore.load();
    const bindingByThreadId: Map<string, StoredWorkspaceItem> = new Map();
    for (let index: number = 0; index < bindingSnapshot.items.length; index += 1) {
      const item: StoredWorkspaceItem = bindingSnapshot.items[index];
      if (this.isRemoteThreadId(item.workspaceId)) {
        bindingByThreadId.set(item.workspaceId, item);
      }
    }

    const activeWorkspace: WorkspaceItem | undefined = this.activeWorkspace();
    const activePlaceholderId: number = activeWorkspace !== undefined && !this.isRemoteThreadId(activeWorkspace.workspaceId) ? activeWorkspace.id : 0;
    const nextWorkspaces: WorkspaceItem[] = [];
    const nextWorkspaceIds: Map<number, string> = new Map();
    const nextWorkspaceRoots: Map<number, string> = new Map();
    const nextWorkspaceUris: Map<number, string> = new Map();
    const usedIds: Set<number> = new Set();
    const newProjects: ProjectRecord[] = [];
    let nextIdSeed: number = this.nextWorkspaceId();
    let nextActiveWorkspaceId: number = 0;

    for (let index: number = 0; index < summaries.length; index += 1) {
      const summary: SessionSummary = summaries[index];
      let workspaceId: number | undefined = currentWorkspaceByThreadId.get(summary.sessionId)?.id;
      if (workspaceId === undefined) {
        workspaceId = bindingByThreadId.get(summary.sessionId)?.id;
      }
      if (workspaceId === undefined && preferredThreadId !== undefined && summary.sessionId === preferredThreadId && activePlaceholderId > 0) {
        workspaceId = activePlaceholderId;
      }
      while (workspaceId === undefined || usedIds.has(workspaceId)) {
        workspaceId = nextIdSeed;
        nextIdSeed += 1;
      }
      usedIds.add(workspaceId);

      const workspace: WorkspaceItem = new WorkspaceItem(
        workspaceId,
        summary.title,
        this.workspaceDescriptionFromSummary(summary),
        summary.sessionId
      );
      nextWorkspaces.push(workspace);
      nextWorkspaceIds.set(workspace.id, summary.sessionId);

      const existingRoot: string = this.workspaceRoots.get(workspace.id) ?? bindingByThreadId.get(summary.sessionId)?.workspaceRoot ?? '';
      const nextRoot: string = existingRoot.trim().length > 0 ? existingRoot : summary.workspaceRoot.trim();
      nextWorkspaceRoots.set(workspace.id, nextRoot);
      nextWorkspaceUris.set(workspace.id, this.workspaceUris.get(workspace.id) ?? bindingByThreadId.get(summary.sessionId)?.workspaceUri ?? '');

      // Assign project by matching session root to project path
      const sessionRoot: string = nextRoot.trim();
      if (sessionRoot.length > 0) {
        let matchedProject: ProjectRecord | undefined = undefined;
        for (let pi: number = 0; pi < this.projects.length; pi += 1) {
          if (this.projects[pi].path.trim() === sessionRoot) {
            matchedProject = this.projects[pi];
            break;
          }
        }
        if (matchedProject !== undefined) {
          workspace.projectId = matchedProject.id;
        } else if (!projectStore.isDeletedPath(sessionRoot)) {
          const projId: string = `proj_${Date.now().toString()}_${index.toString()}`;
          const projName: string = sessionRoot.substring(sessionRoot.lastIndexOf('/') + 1);
          const newProj: ProjectRecord = new ProjectRecord(projId, projName.length > 0 ? projName : sessionRoot, sessionRoot, true);
          newProjects.push(newProj);
          workspace.projectId = projId;
        }
      }

      if (summary.sessionId === preferredThreadId || (nextActiveWorkspaceId === 0 && summary.sessionId === this.activeWorkspaceBindingId)) {
        nextActiveWorkspaceId = workspace.id;
      }
    }

    // Preserve manually created workspaces that have local session IDs
    for (let index: number = 0; index < this.workspaces.length; index += 1) {
      const ws: WorkspaceItem = this.workspaces[index];
      if (!this.isRemoteThreadId(ws.workspaceId) && !usedIds.has(ws.id)) {
        usedIds.add(ws.id);
        nextWorkspaces.push(ws);
        nextWorkspaceIds.set(ws.id, ws.workspaceId);
        const preservedRoot: string = this.workspaceRoots.get(ws.id) ?? '';
        nextWorkspaceRoots.set(ws.id, preservedRoot);
        nextWorkspaceUris.set(ws.id, this.workspaceUris.get(ws.id) ?? '');
      }
    }

    if (nextActiveWorkspaceId === 0) {
      const matched: WorkspaceItem | undefined = nextWorkspaces.find((item: WorkspaceItem) => item.id === this.activeWorkspaceId);
      nextActiveWorkspaceId = matched?.id ?? nextWorkspaces[0].id;
    }

    this.workspaces = [...nextWorkspaces];
    if (newProjects.length > 0) {
      this.projects = [...this.projects, ...newProjects];
    }
    this.saveProjects();
    this.syncRecentWorkspaces();
    this.workspaceIds.clear();
    this.workspaceRoots.clear();
    this.workspaceUris.clear();
    nextWorkspaceIds.forEach((value: string, key: number) => this.workspaceIds.set(key, value));
    nextWorkspaceRoots.forEach((value: string, key: number) => this.workspaceRoots.set(key, value));
    nextWorkspaceUris.forEach((value: string, key: number) => this.workspaceUris.set(key, value));
    this.activeWorkspaceId = nextActiveWorkspaceId;
    this.syncSelectedCollaborationMode();
    this.workspaceRoot = this.workspaceRoots.get(this.activeWorkspaceId) ?? '';
    this.workspaceDraftText = this.workspaceRoot;
    this.syncWorkspaceSelectionText();
    this.refreshWorkspaceBindingState();
    this.syncCurrentWorkspaceState();
    this.persistWorkspaceBindings();
  }

  private async loadSelectedWorkspaceHistory(): Promise<void> {
    this.resumeMessageAutoFollow();
    this.clearLiveThinking();
    if (this.workspaces.length === 0) {
      codexBackend.setActiveThread('');
      this.resetConversationSurface('当前目录下暂无会话', ['请先创建一个新会话。']);
      return;
    }
    const workspace: WorkspaceItem = this.activeWorkspace()!;
    const requestedWorkspaceId: number = workspace.id;
    const requestedThreadKey: string = workspace.workspaceId;
    if (!this.isRemoteThreadId(workspace.workspaceId)) {
      codexBackend.setActiveThread('');
      this.clearTokenAggregate();
      this.resetConversationSurface('等待创建新会话', ['当前会话尚未在 app-server 中创建，发送第一条消息后会自动建立线程。']);
      this.syncActiveWorkspaceRunState();
      return;
    }
    codexBackend.setActiveThread(workspace.workspaceId);
    try {
      const cachedResult: CodexTurnResult | null = codexBackend.resultForThreadKey(workspace.workspaceId);
      if (cachedResult !== null) {
        this.applyBackendResultForWorkspace(requestedWorkspaceId, requestedThreadKey, cachedResult);
      }
      if (this.isWorkspaceRunning(requestedWorkspaceId)) {
        return;
      }
      const result: CodexTurnResult = await codexBackend.loadThreadHistory(workspace.workspaceId);
      this.applyBackendResultForWorkspace(requestedWorkspaceId, requestedThreadKey, result);
    } catch (err) {
      if (this.activeWorkspaceId !== requestedWorkspaceId) {
        return;
      }
      this.summaryTitle = '恢复会话失败';
      this.summaryPoints = [this.describeError(err)];
    }
  }

  private isWorkspaceRunning(workspaceId: number): boolean {
    this.runningWorkspaceVersion;
    const runState: WorkspaceRunState | undefined = this.workspaceRunStates.get(workspaceId);
    return runState !== undefined && runState.status === 'inProgress';
  }

  private refreshRunningWorkspaceIndicators(): void {
    this.runningWorkspaceVersion += 1;
  }

  private syncActiveWorkspaceRunState(): void {
    const runState: WorkspaceRunState | undefined = this.workspaceRunStates.get(this.activeWorkspaceId);
    this.isRunning = runState !== undefined && runState.status === 'inProgress';
    if (runState !== undefined) {
      this.currentTurnId = runState.turnId;
      this.currentTurnStatus = runState.status;
      this.pendingUserPrompt = runState.pendingUserPrompt;
      this.thinkingMessageBoundary = runState.thinkingMessageBoundary;
    } else {
      this.pendingUserPrompt = '';
      this.thinkingMessageBoundary = -1;
      this.showIdleThinkingIndicator = false;
      this.clearIdleThinkingTimer();
    }
    this.syncThinkingAnimation();
  }

  private syncWorkspaceWithRemoteThreadIdForWorkspace(workspaceId: number, remoteThreadId: string): void {
    const trimmedThreadId: string = remoteThreadId.trim();
    if (trimmedThreadId.length === 0 || this.workspaces.length === 0) {
      return;
    }
    const workspace: WorkspaceItem | undefined = this.workspaces.find((item: WorkspaceItem) => item.id === workspaceId);
    if (workspace === undefined) {
      return;
    }
    const changed: boolean = workspace.workspaceId !== trimmedThreadId;
    workspace.workspaceId = trimmedThreadId;
    this.workspaceIds.set(workspace.id, trimmedThreadId);
    if (workspaceId === this.activeWorkspaceId) {
      this.activeWorkspaceBindingId = trimmedThreadId;
      if (changed) {
        codexBackend.setActiveThread(trimmedThreadId);
        this.applyPendingRequestsForActiveWorkspace();
      }
    }
    if (changed) {
      this.persistWorkspaceBindings();
    }
  }

  private restoreWorkspaceBindings(): void {
    const snapshot = workspaceBindingStore.load();
    const restoredItems: WorkspaceBindingDraft[] = [];
    this.workspaceIds.clear();
    this.workspaceRoots.clear();
    this.workspaceUris.clear();
    this.workspaces = [];
    for (let index: number = 0; index < snapshot.items.length; index += 1) {
      const item = snapshot.items[index];
      if (item.id <= 0) {
        continue;
      }
      restoredItems.push(new WorkspaceBindingDraft(
        item.id,
        item.title.trim().length > 0 ? item.title : `ä¼šè¯ ${item.id}`,
        item.description,
        item.workspaceId.trim().length > 0 ? item.workspaceId : `session:${item.id.toString()}`,
        item.workspaceRoot,
        item.workspaceUri,
        item.projectId
      ));
    }

    if (restoredItems.length === 0) {
      this.workspaces = [];
      this.activeWorkspaceId = 0;
      this.workspaceRoot = '';
      this.workspaceDraftText = '';
      this.currentWorkspaceTitle = '';
      this.currentWorkspaceDescription = '';
      this.syncWorkspaceSelectionText();
      this.syncCurrentWorkspaceState();
      this.persistWorkspaceBindings();
      return;
    }

    const restoredWorkspaces: WorkspaceItem[] = [];
    for (let index: number = 0; index < restoredItems.length; index += 1) {
      const restored: WorkspaceBindingDraft = restoredItems[index];
      const workspace: WorkspaceItem = new WorkspaceItem(restored.id, restored.title, restored.description, restored.workspaceId, restored.projectId);
      restoredWorkspaces.push(workspace);
      this.workspaceIds.set(restored.id, restored.workspaceId);
      this.workspaceRoots.set(restored.id, restored.workspaceRoot);
      this.workspaceUris.set(restored.id, restored.workspaceUri);
    }
    this.workspaces = restoredWorkspaces;
    this.syncRecentWorkspaces();

    const preferredActiveId: number = snapshot.activeWorkspaceId > 0 ? snapshot.activeWorkspaceId : restoredItems[0].id;
    const matched: WorkspaceItem | undefined = this.workspaces.find((item: WorkspaceItem) => item.id === preferredActiveId);
    this.activeWorkspaceId = matched?.id ?? this.workspaces[0].id;
    this.syncSelectedCollaborationMode();
    this.workspaceRoot = this.workspaceRoots.get(this.activeWorkspaceId) ?? '';
    this.workspaceDraftText = this.workspaceRoot;
    this.syncWorkspaceSelectionText();
    this.refreshWorkspaceBindingState();
    this.syncCurrentWorkspaceState();
  }

  private persistWorkspaceBindings(): void {
    const items: StoredWorkspaceItem[] = [];
    for (let index: number = 0; index < this.workspaces.length; index += 1) {
      const workspace: WorkspaceItem = this.workspaces[index];
      const item: StoredWorkspaceItem = new StoredWorkspaceItem();
      item.id = workspace.id;
      item.title = workspace.title;
      item.description = workspace.description;
      item.workspaceId = this.ensureWorkspaceBinding(workspace);
      item.workspaceRoot = this.workspaceRoots.get(workspace.id) ?? '';
      item.workspaceUri = this.workspaceUris.get(workspace.id) ?? '';
      item.projectId = workspace.projectId;
      items.push(item);
    }
    workspaceBindingStore.saveBindings(this.activeWorkspaceId, items);
  }

  // ── Project management ──────────────────────────────────────────

  private loadProjects(): void {
    this.projects = projectStore.load();
  }

  private saveProjects(): void {
    projectStore.save(this.projects);
  }

  private openCreateProjectDialog(): void {
    this.newProjectName = '';
    this.newProjectSourceUri = '';
    this.showProjectMenuId = '';
    this.showSessionMenuId = '';
    if (this.createProjectDialogController !== null) {
      this.createProjectDialogController.open();
    }
  }

  private cancelCreateProjectDialog(): void {
    this.newProjectSourceUri = '';
  }

  private closeCreateProjectDialog(): void {
    if (this.createProjectDialogController !== null) {
      this.createProjectDialogController.close();
    }
  }

  private cancelNewSessionDialog(): void {
    this.newSessionProjectId = '';
    this.newSessionName = '';
  }

  private closeNewSessionDialog(): void {
    if (this.newSessionDialogController !== null) {
      this.newSessionDialogController.close();
    }
  }

  private openRenameProjectDialog(proj: ProjectRecord): void {
    this.renameProjectDialogId = proj.id;
    this.renameProjectDialogText = proj.name;
    if (this.renameProjectDialogController !== null) {
      this.renameProjectDialogController.open();
    }
  }

  private cancelRenameProjectDialog(): void {
    this.renameProjectDialogId = '';
    this.renameProjectDialogText = '';
  }

  private confirmRenameProjectDialog(): void {
    const name: string = this.renameProjectDialogText.trim();
    if (name.length === 0 || this.renameProjectDialogId.length === 0) {
      promptAction.showToast({ message: '请输入项目名称', duration: 2000 });
      return;
    }
    const targetId: string = this.renameProjectDialogId;
    const next: ProjectRecord[] = [];
    for (let i: number = 0; i < this.projects.length; i += 1) {
      const p: ProjectRecord = this.projects[i];
      if (p.id === targetId) {
        next.push(new ProjectRecord(p.id, name, p.path, p.expanded, p.sourceUri));
      } else {
        next.push(new ProjectRecord(p.id, p.name, p.path, p.expanded, p.sourceUri));
      }
    }
    this.projects = next;
    this.saveProjects();
    this.cancelRenameProjectDialog();
    if (this.renameProjectDialogController !== null) {
      this.renameProjectDialogController.close();
    }
  }

  private openDeleteProjectDialog(proj: ProjectRecord): void {
    this.deleteProjectDialogId = proj.id;
    this.deleteProjectDialogName = proj.name;
    if (this.deleteProjectDialogController !== null) {
      this.deleteProjectDialogController.open();
    }
  }

  private cancelDeleteProjectDialog(): void {
    this.deleteProjectDialogId = '';
    this.deleteProjectDialogName = '';
  }

  private confirmDeleteProjectDialog(): void {
    const targetId: string = this.deleteProjectDialogId;
    if (targetId.length === 0) {
      return;
    }
    this.cancelDeleteProjectDialog();
    if (this.deleteProjectDialogController !== null) {
      this.deleteProjectDialogController.close();
    }
    void this.deleteProject(targetId);
  }

  private openRenameSessionDialog(item: WorkspaceItem): void {
    this.renameSessionDialogId = this.ensureWorkspaceBinding(item);
    this.renameSessionDialogText = item.title;
    if (this.renameSessionDialogController !== null) {
      this.renameSessionDialogController.open();
    }
  }

  private cancelRenameSessionDialog(): void {
    this.renameSessionDialogId = '';
    this.renameSessionDialogText = '';
  }

  private confirmRenameSessionDialog(): void {
    const name: string = this.renameSessionDialogText.trim();
    if (name.length === 0 || this.renameSessionDialogId.length === 0) {
      promptAction.showToast({ message: '请输入会话名称', duration: 2000 });
      return;
    }
    const targetId: string = this.renameSessionDialogId;
    const next: WorkspaceItem[] = [];
    for (let i: number = 0; i < this.workspaces.length; i += 1) {
      const w: WorkspaceItem = this.workspaces[i];
      if (this.ensureWorkspaceBinding(w) === targetId) {
        next.push(new WorkspaceItem(w.id, name, w.description, w.workspaceId, w.projectId));
      } else {
        next.push(new WorkspaceItem(w.id, w.title, w.description, w.workspaceId, w.projectId));
      }
    }
    this.workspaces = next;
    this.syncRecentWorkspaces();
    this.syncCurrentWorkspaceState();
    this.persistWorkspaceBindings();
    this.cancelRenameSessionDialog();
    if (this.renameSessionDialogController !== null) {
      this.renameSessionDialogController.close();
    }
    void codexBackend.renameSession(targetId, name);
  }

  private openDeleteSessionDialog(item: WorkspaceItem): void {
    this.deleteSessionDialogId = this.ensureWorkspaceBinding(item);
    this.deleteSessionDialogTitle = item.title;
    if (this.deleteSessionDialogController !== null) {
      this.deleteSessionDialogController.open();
    }
  }

  private cancelDeleteSessionDialog(): void {
    this.deleteSessionDialogId = '';
    this.deleteSessionDialogTitle = '';
  }

  private confirmDeleteSessionDialog(): void {
    const targetId: string = this.deleteSessionDialogId;
    if (targetId.length === 0) {
      return;
    }
    this.cancelDeleteSessionDialog();
    if (this.deleteSessionDialogController !== null) {
      this.deleteSessionDialogController.close();
    }
    void this.deleteSession(targetId);
  }

  private sessionsForProject(projectId: string): WorkspaceItem[] {
    const result: WorkspaceItem[] = [];
    for (let i: number = 0; i < this.workspaces.length; i += 1) {
      if (this.workspaces[i].projectId === projectId) {
        result.push(this.workspaces[i]);
      }
    }
    return result;
  }

  private async createProject(): Promise<void> {
    const name: string = this.newProjectName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '请输入项目名称', duration: 2000 });
      return;
    }
    const path: string = this.sandboxProjectPath();
    const sourceUri: string = this.newProjectSourceUri.trim();
    const id: string = `proj_${Date.now().toString()}`;
    const next: ProjectRecord[] = [...this.projects, new ProjectRecord(id, name, path, true, sourceUri)];
    this.projects = next;
    this.saveProjects();
    this.closeCreateProjectDialog();
    this.newProjectName = '';
    this.newProjectSourceUri = '';
    promptAction.showToast({ message: sourceUri.length > 0 ? `项目"${name}"已创建，外部同步文件夹已记录` : `项目"${name}"已创建`, duration: 2000 });
  }

  private startRenameProject(projectId: string): void {
    const proj: ProjectRecord | undefined = this.projects.find((p: ProjectRecord) => p.id === projectId);
    if (proj !== undefined) {
      this.renamingProjectId = projectId;
      this.renameProjectText = proj.name;
    }
  }

  private confirmRenameProject(): void {
    const name: string = this.renameProjectText.trim();
    if (name.length === 0 || this.renamingProjectId.length === 0) {
      return;
    }
    const next: ProjectRecord[] = [];
    for (let i: number = 0; i < this.projects.length; i += 1) {
      const p: ProjectRecord = this.projects[i];
      if (p.id === this.renamingProjectId) {
        next.push(new ProjectRecord(p.id, name, p.path, p.expanded, p.sourceUri));
      } else {
        next.push(new ProjectRecord(p.id, p.name, p.path, p.expanded, p.sourceUri));
      }
    }
    this.projects = next;
    this.saveProjects();
    this.renamingProjectId = '';
    this.renameProjectText = '';
  }

  private cancelRenameProject(): void {
    this.renamingProjectId = '';
    this.renameProjectText = '';
  }

  private runMotion(action: () => void, duration: number = this.motionNormalDuration): void {
    this.getUIContext().animateTo({ duration: duration, curve: Curve.FastOutSlowIn }, action);
  }

  private runPanelMotion(action: () => void): void {
    this.runMotion(action, this.motionPanelDuration);
  }

  private runFastMotion(action: () => void): void {
    this.runMotion(action, this.motionFastDuration);
  }

  private themeRootBackground(): string {
    return '#EEF2F7';
  }

  private themePanelBackground(): string {
    return '#FAFAFA';
  }

  private themeElevatedBackground(): string {
    return '#FFFFFF';
  }

  private themeInputBackground(): string {
    return '#FFFFFF';
  }

  private themeSubtleBackground(): string {
    return '#F4F4F5';
  }

  private themeTextPrimary(): string {
    return '#18181B';
  }

  private themeTextStrong(): string {
    return '#0F172A';
  }

  private themeTextSecondary(): string {
    return '#71717A';
  }

  private themeTextMuted(): string {
    return '#64748B';
  }

  private themeBorder(): string {
    return '#E4E4E7';
  }

  private themeStrongBorder(): string {
    return '#D4D4D8';
  }

  private themeBackdrop(): string {
    return '#66000000';
  }

  private toggleProjectExpanded(projectId: string): void {
    const savedOffset: number = this.leftScrollController.currentOffset().yOffset;
    const next: ProjectRecord[] = [];
    for (let i: number = 0; i < this.projects.length; i += 1) {
      const p: ProjectRecord = this.projects[i];
      if (p.id === projectId) {
        next.push(new ProjectRecord(p.id, p.name, p.path, !p.expanded, p.sourceUri));
      } else {
        next.push(new ProjectRecord(p.id, p.name, p.path, p.expanded, p.sourceUri));
      }
    }
    this.runFastMotion(() => {
      this.projects = next;
    });
    this.saveProjects();
    setTimeout(() => {
      this.leftScrollController.scrollTo({ yOffset: savedOffset, xOffset: 0 });
    }, 50);
  }

  private openNewSessionDialog(projectId: string): void {
    this.newSessionProjectId = projectId;
    this.newSessionName = '';
    this.showProjectMenuId = '';
    this.showSessionMenuId = '';
    if (this.newSessionDialogController !== null) {
      this.newSessionDialogController.open();
    }
  }

  private async confirmCreateSession(): Promise<void> {
    const name: string = this.newSessionName.trim();
    if (name.length === 0 || this.newSessionProjectId.length === 0) {
      promptAction.showToast({ message: '请输入会话名称', duration: 2000 });
      return;
    }
    const proj: ProjectRecord | undefined = this.projects.find((p: ProjectRecord) => p.id === this.newSessionProjectId);
    if (proj === undefined) {
      return;
    }
    const nextId: number = this.nextWorkspaceId();
    const workspace: WorkspaceItem = new WorkspaceItem(nextId, name, '', `session:${nextId.toString()}`, proj.id);
    this.workspaces.push(workspace);
    this.workspaceRoots.set(nextId, proj.path);
    this.workspaceIds.set(nextId, `session:${nextId.toString()}`);
    this.closeNewSessionDialog();
    this.newSessionProjectId = '';
    this.newSessionName = '';
    this.syncRecentWorkspaces();
    this.persistWorkspaceBindings();
    await this.selectWorkspace(workspace);
  }

  private startRenameSession(sessionId: string): void {
    const ws: WorkspaceItem | undefined = this.workspaces.find((w: WorkspaceItem) => this.ensureWorkspaceBinding(w) === sessionId);
    if (ws !== undefined) {
      this.renamingSessionId = sessionId;
      this.renameSessionText = ws.title;
    }
  }

  private confirmRenameSession(): void {
    const name: string = this.renameSessionText.trim();
    if (name.length === 0 || this.renamingSessionId.length === 0) {
      return;
    }
    const next: WorkspaceItem[] = [];
    for (let i: number = 0; i < this.workspaces.length; i += 1) {
      const w: WorkspaceItem = this.workspaces[i];
      if (this.ensureWorkspaceBinding(w) === this.renamingSessionId) {
        next.push(new WorkspaceItem(w.id, name, w.description, w.workspaceId, w.projectId));
      } else {
        next.push(new WorkspaceItem(w.id, w.title, w.description, w.workspaceId, w.projectId));
      }
    }
    this.workspaces = next;
    this.syncRecentWorkspaces();
    this.syncCurrentWorkspaceState();
    this.persistWorkspaceBindings();
    void codexBackend.renameSession(this.renamingSessionId, name);
    this.renamingSessionId = '';
    this.renameSessionText = '';
  }

  private cancelRenameSession(): void {
    this.renamingSessionId = '';
    this.renameSessionText = '';
  }

  private async deleteSession(sessionId: string): Promise<void> {
    let targetIndex: number = -1;
    for (let i: number = 0; i < this.workspaces.length; i += 1) {
      if (this.ensureWorkspaceBinding(this.workspaces[i]) === sessionId) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex < 0) {
      return;
    }
    let archiveFailed: boolean = false;
    try {
      await codexBackend.archiveSession(sessionId);
    } catch (_err) {
      archiveFailed = true;
    }
    this.workspaces.splice(targetIndex, 1);
    if (this.workspaces.length === 0) {
      this.activeWorkspaceId = 0;
    } else if (targetIndex <= this.workspaces.length) {
      const newIndex: number = targetIndex < this.workspaces.length ? targetIndex : this.workspaces.length - 1;
      await this.selectWorkspace(this.workspaces[newIndex]);
    }
    this.syncRecentWorkspaces();
    this.persistWorkspaceBindings();
    if (archiveFailed) {
      promptAction.showToast({ message: '会话已从列表移除，但后台归档未完成。', duration: 2800 });
    }
  }

  private async deleteProjectFolder(projectPath: string): Promise<void> {
    const trimmedPath: string = projectPath.trim();
    const context: common.UIAbilityContext | null = this.currentAbilityContext();
    if (trimmedPath.length === 0 || context === null) {
      return;
    }
    const projectsRoot: string = `${context.filesDir}/projects`;
    if (!trimmedPath.startsWith(`${projectsRoot}/`)) {
      return;
    }
    try {
      const task = new taskpool.Task(deletePathTask, trimmedPath);
      const rawResult: string = await taskpool.execute(task) as string;
      const parsed: Record<string, Object> = JSON.parse(rawResult) as Record<string, Object>;
      if (typeof parsed['error'] === 'string') {
        hilog.warn(INDEX_DOMAIN, INDEX_TAG, 'delete project folder failed: %{public}s', parsed['error'] as string);
      }
    } catch (err) {
      hilog.warn(INDEX_DOMAIN, INDEX_TAG, 'delete project folder failed: %{public}s', this.describeError(err));
    }
  }

  private async deleteProject(projectId: string): Promise<void> {
    let targetIndex: number = -1;
    for (let i: number = 0; i < this.projects.length; i += 1) {
      if (this.projects[i].id === projectId) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex < 0) {
      return;
    }
    const projectPath: string = this.projects[targetIndex].path;
    projectStore.addDeletedPath(projectPath);

    let archiveFailed: boolean = false;
    for (let i: number = this.workspaces.length - 1; i >= 0; i -= 1) {
      if (this.workspaces[i].projectId === projectId) {
        const sessionId: string = this.ensureWorkspaceBinding(this.workspaces[i]);
        try {
          await codexBackend.archiveSession(sessionId);
        } catch (_err) {
          archiveFailed = true;
        }
      }
    }

    const next: ProjectRecord[] = [];
    for (let i: number = 0; i < this.projects.length; i += 1) {
      if (this.projects[i].id !== projectId) {
        next.push(this.projects[i]);
      }
    }
    this.projects = next;
    this.saveProjects();
    await this.deleteProjectFolder(projectPath);
    for (let i: number = this.workspaces.length - 1; i >= 0; i -= 1) {
      if (this.workspaces[i].projectId === projectId) {
        this.workspaces.splice(i, 1);
      }
    }
    this.syncRecentWorkspaces();
    this.persistWorkspaceBindings();
    if (archiveFailed) {
      promptAction.showToast({ message: '项目已删除，但部分会话后台归档未完成。', duration: 3200 });
    }
  }

  private relativeTime(updatedAt: string): string {
    const parsed: number = Date.parse(updatedAt);
    if (isNaN(parsed)) {
      return '';
    }
    const diffMs: number = Date.now() - parsed;
    if (diffMs < 0) {
      return '刚刚';
    }
    const minutes: number = Math.floor(diffMs / 60000);
    if (minutes < 1) {
      return '刚刚';
    }
    if (minutes < 60) {
      return `${minutes.toString()} 分`;
    }
    const hours: number = Math.floor(minutes / 60);
    if (hours < 24) {
      return `${hours.toString()} 时`;
    }
    const days: number = Math.floor(hours / 24);
    return `${days.toString()} 天`;
  }

  private applyWorkspaceRootBinding(): void {
    const trimmedWorkspaceRoot: string = this.workspaceDraftText.trim();
    this.workspaceRoot = trimmedWorkspaceRoot;
    this.workspaceRoots.set(this.activeWorkspaceId, trimmedWorkspaceRoot);
    this.workspaceUris.set(this.activeWorkspaceId, '');
    this.syncWorkspaceSelectionText();
    this.refreshWorkspaceBindingState();
    this.persistWorkspaceBindings();
  }

  private applyWorkspaceDirectorySelection(workspaceRoot: string, workspaceUri: string): void {
    const trimmedWorkspaceRoot: string = workspaceRoot.trim();
    this.directoryFilter = trimmedWorkspaceRoot;
    this.directoryFilterText = trimmedWorkspaceRoot.length > 0 ? trimmedWorkspaceRoot : '使用默认工作区';
    this.syncRecentWorkspaces();
  }

  private syncWorkspaceSelectionText(): void {
    const workspaceUri: string = this.workspaceUris.get(this.activeWorkspaceId) ?? '';
    if (workspaceUri.trim().length > 0) {
      this.workspaceSelectionText = `已选择目录: ${workspaceUri}`;
      return;
    }
    if (this.workspaceRoot.trim().length > 0) {
      this.workspaceSelectionText = `当前工作目录: ${this.workspaceRoot}`;
      return;
    }
    this.workspaceSelectionText = '使用默认工作区';
  }

  private canSelectExternalFolder(): boolean {
    try {
      return canIUse(FOLDER_SELECTION_SYSCAP);
    } catch (_err) {
      return false;
    }
  }

  private canUseUserFileService(): boolean {
    try {
      return canIUse(USER_FILE_SERVICE_SYSCAP);
    } catch (_err) {
      return false;
    }
  }

  private canPersistExternalFolderPermission(): boolean {
    try {
      return canIUse(FOLDER_AUTHORIZATION_SYSCAP) || canIUse(LEGACY_FOLDER_AUTHORIZATION_SYSCAP);
    } catch (_err) {
      return false;
    }
  }

  private projectSourcePermissionMode(): number {
    return fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE;
  }

  private async persistProjectSourcePermission(sourceUri: string): Promise<boolean> {
    if (sourceUri.trim().length === 0 || !this.canPersistExternalFolderPermission()) {
      return false;
    }
    try {
      await fileShare.persistPermission([{ uri: sourceUri, operationMode: this.projectSourcePermissionMode() }]);
      return true;
    } catch (err) {
      hilog.warn(INDEX_DOMAIN, INDEX_TAG, 'persist source permission failed: %{public}s', this.describeError(err));
      return false;
    }
  }

  private async activateProjectSourcePermission(sourceUri: string): Promise<void> {
    if (sourceUri.trim().length === 0) {
      throw new Error('项目没有同步文件夹。');
    }
    if (!this.canPersistExternalFolderPermission()) {
      return;
    }
    await fileShare.activatePermission([{ uri: sourceUri, operationMode: this.projectSourcePermissionMode() }]);
  }

  private sanitizeProjectDirectoryName(projectName: string): string {
    const sanitized: string = projectName.trim().replace(/[\/\\:*?"<>|]/g, '_');
    if (sanitized.length === 0 || sanitized === '.' || sanitized === '..') {
      return `proj_${Date.now().toString()}`;
    }
    return sanitized;
  }

  private isProjectPathUsed(projectPath: string): boolean {
    const trimmedPath: string = projectPath.trim();
    for (let index: number = 0; index < this.projects.length; index += 1) {
      if (this.projects[index].path.trim() === trimmedPath) {
        return true;
      }
    }
    return false;
  }

  private sandboxProjectPath(): string {
    const context: common.UIAbilityContext | null = this.currentAbilityContext();
    if (context === null) {
      throw new Error('当前页面上下文不可用，无法创建应用内项目目录。');
    }
    const basePath: string = `${context.filesDir}/projects`;
    const directoryName: string = this.sanitizeProjectDirectoryName(this.newProjectName);
    let candidatePath: string = `${basePath}/${directoryName}`;
    let suffix: number = 2;
    while (this.isProjectPathUsed(candidatePath)) {
      candidatePath = `${basePath}/${directoryName}_${suffix.toString()}`;
      suffix += 1;
    }
    fileIo.mkdirSync(candidatePath, true);
    return candidatePath;
  }

  private async pickDirectorySelection(): Promise<WorkspaceDirectorySelection | null> {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      throw new Error('当前页面上下文不可用，无法打开目录选择器。');
    }
    if (!this.canSelectExternalFolder()) {
      throw new Error('当前设备不支持选择外部目录。');
    }
    const documentPicker = new picker.DocumentViewPicker(hostContext);
    const selectedUris: Array<string> = await documentPicker.select({
      selectMode: picker.DocumentSelectMode.FOLDER
    });
    if (selectedUris.length === 0) {
      return null;
    }
    const selectedUri: string = selectedUris[0];
    const parsedUri = new uri.URI(selectedUri);
    const candidatePath: string = decodeURIComponent(parsedUri.path ?? '');
    if (candidatePath.trim().length === 0) {
      throw new Error(`目录已选择，但暂时无法解析路径: ${selectedUri}`);
    }
    return new WorkspaceDirectorySelection(candidatePath, selectedUri);
  }

  private async pickDownloadDirectorySelection(projectDirectoryName?: string): Promise<WorkspaceDirectorySelection | null> {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      throw new Error('当前页面上下文不可用，无法打开下载目录授权。');
    }
    if (!this.canUseUserFileService()) {
      throw new Error('当前设备不支持下载目录授权。');
    }
    const documentSaveOptions = new picker.DocumentSaveOptions();
    documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const documentPicker = new picker.DocumentViewPicker(hostContext);
    const selectedUris: Array<string> = await documentPicker.save(documentSaveOptions);
    if (selectedUris.length === 0) {
      return null;
    }
    let selectedUri: string = selectedUris[0];
    if (projectDirectoryName !== undefined && projectDirectoryName.trim().length > 0) {
      selectedUri = this.childUri(this.childUri(selectedUri, 'projects'), projectDirectoryName.trim());
    }
    const candidatePath: string = this.fileUriToFsPath(selectedUri);
    return new WorkspaceDirectorySelection(candidatePath, selectedUri);
  }

  private async pickWorkspaceDirectory(): Promise<void> {
    try {
      const selection: WorkspaceDirectorySelection | null = await this.pickDirectorySelection();
      if (selection === null) {
        this.workspaceStatusText = '未选择目录，继续使用当前工作区。';
        return;
      }
      this.applyWorkspaceDirectorySelection(selection.rootPath, selection.sourceUri);
    } catch (err) {
      this.workspaceStatusText = `选择目录失败: ${this.describeError(err)}`;
    }
  }

  private async pickWorkspaceDirectoryForProject(): Promise<void> {
    try {
      if (!this.canSelectExternalFolder()) {
        if (this.newProjectName.trim().length === 0) {
          promptAction.showToast({ message: '请先输入项目名称，再启用下载目录同步', duration: 2500 });
          return;
        }
        const downloadSelection: WorkspaceDirectorySelection | null = await this.pickDownloadDirectorySelection(this.sanitizeProjectDirectoryName(this.newProjectName));
        if (downloadSelection !== null) {
          this.newProjectSourceUri = downloadSelection.sourceUri;
          promptAction.showToast({ message: '已启用下载目录同步，项目将使用应用内目录', duration: 3000 });
        }
        return;
      }
      const selection: WorkspaceDirectorySelection | null = await this.pickDirectorySelection();
      if (selection !== null) {
        this.newProjectSourceUri = selection.sourceUri;
        const persisted: boolean = await this.persistProjectSourcePermission(selection.sourceUri);
        promptAction.showToast({
          message: persisted
            ? '外部目录已记录为同步文件夹，读写授权已持久化'
            : '外部目录已记录为同步文件夹；授权未持久化，重启后同步可能需要重新选择',
          duration: 3000
        });
      }
    } catch (err) {
      promptAction.showToast({ message: `选择同步文件夹失败: ${this.describeError(err)}`, duration: 3000 });
    }
  }

  private async reselectProjectImportSource(projectId: string): Promise<void> {
    try {
      let selection: WorkspaceDirectorySelection | null = null;
      let persisted: boolean = false;
      let downloadMode: boolean = false;
      if (this.canSelectExternalFolder()) {
        selection = await this.pickDirectorySelection();
        if (selection !== null) {
          persisted = await this.persistProjectSourcePermission(selection.sourceUri);
        }
      } else {
        let projectDirectoryName: string = '';
        for (let i: number = 0; i < this.projects.length; i += 1) {
          if (this.projects[i].id === projectId) {
            projectDirectoryName = this.sanitizeProjectDirectoryName(this.projects[i].name);
            break;
          }
        }
        selection = await this.pickDownloadDirectorySelection(projectDirectoryName);
        downloadMode = true;
      }
      if (selection === null) {
        return;
      }
      const next: ProjectRecord[] = [];
      for (let i: number = 0; i < this.projects.length; i += 1) {
        const p: ProjectRecord = this.projects[i];
        if (p.id === projectId) {
          next.push(new ProjectRecord(p.id, p.name, p.path, p.expanded, selection.sourceUri));
        } else {
          next.push(new ProjectRecord(p.id, p.name, p.path, p.expanded, p.sourceUri));
        }
      }
      this.projects = next;
      this.saveProjects();
      promptAction.showToast({
        message: downloadMode
          ? '下载目录同步文件夹已更新'
          : (persisted ? '同步文件夹已更新，读写授权已持久化' : '同步文件夹已更新；授权未持久化，重启后同步可能需要重新选择'),
        duration: 3000
      });
    } catch (err) {
      promptAction.showToast({ message: `更新同步文件夹失败: ${this.describeError(err)}`, duration: 3000 });
    }
  }

  private mapWorkspacePermissionState(value: string): WorkspacePermissionState {
    if (value === 'writable' || value === 'readonly' || value === 'revoked') {
      return value;
    }
    return 'unavailable';
  }

  private mapWorkspaceAccessKind(value: string): WorkspaceAccessKind {
    if (value === 'sandbox' || value === 'user_granted' || value === 'readonly') {
      return value;
    }
    return 'unknown';
  }

  private currentModelLabel(): string {
    return this.currentModelValue();
  }

  private currentModelValue(): string {
    const mode: CollaborationModeOption | null = this.selectedCollaborationMode();
    const modeModel: string = mode?.model?.trim() ?? '';
    if (modeModel.length > 0) {
      return modeModel;
    }
    const model: string = this.manualModel.trim();
    if (model.length === 0) {
      return '未配置 API';
    }
    return model;
  }

  private currentEffortLabel(): string {
    const currentValue: string = this.currentEffortValue();
    const matched: SelectorOption | undefined = this.effortOptions.find((item: SelectorOption) => item.value === currentValue);
    return matched?.label ?? currentValue;
  }

  private currentEffortValue(): string {
    const mode: CollaborationModeOption | null = this.selectedCollaborationMode();
    const modeEffort: string | null | undefined = mode?.reasoningEffort;
    // If the collaboration mode explicitly sets an effort (non-null string), use it.
    if (typeof modeEffort === 'string' && modeEffort.trim().length > 0) {
      return modeEffort.trim();
    }
    // Otherwise fall back to the user-selected effort from the UI picker.
    return this.effortOptions[this.selectedEffortIndex].value;
  }

  private collaborationModeKey(): string {
    return this.activeWorkspaceBindingId;
  }

  private syncSelectedCollaborationMode(): void {
    if (this.collaborationModes.length === 0) {
      hilog.info(0x0001, 'ArkPilot', `syncSelectedCollaborationMode: modes empty, resetting to default`);
      this.selectedCollaborationModeName = 'default';
      return;
    }
    const modeKey: string = this.collaborationModeKey();
    const mappedName: string | undefined = this.collaborationModeByWorkspaceId.get(modeKey);
    const currentName: string = mappedName ?? this.selectedCollaborationModeName;
    hilog.info(0x0001, 'ArkPilot', `syncSelectedCollaborationMode: key=${modeKey} mappedName=${mappedName} currentName=${currentName} modes=${this.collaborationModes.map((m: CollaborationModeOption) => m.name).join(',')}`);
    const matched: CollaborationModeOption | undefined = this.collaborationModes.find((item: CollaborationModeOption) => item.name === currentName);
    if (matched !== undefined) {
      hilog.info(0x0001, 'ArkPilot', `syncSelectedCollaborationMode: matched=${matched.name}`);
      this.selectedCollaborationModeName = matched.name;
      this.collaborationModeByWorkspaceId.set(modeKey, matched.name);
      this.collaborationModeVersion += 1;
      return;
    }
    const defaultMode: CollaborationModeOption | undefined = this.collaborationModes.find((item: CollaborationModeOption) => item.mode === 'default');
    const fallback: CollaborationModeOption = defaultMode ?? this.collaborationModes[0];
    hilog.info(0x0001, 'ArkPilot', `syncSelectedCollaborationMode: fallback=${fallback.name}`);
    this.selectedCollaborationModeName = fallback.name;
    this.collaborationModeByWorkspaceId.set(modeKey, fallback.name);
    this.collaborationModeVersion += 1;
  }

  private selectedCollaborationMode(): CollaborationModeOption | null {
    const matched: CollaborationModeOption | undefined = this.collaborationModes.find((item: CollaborationModeOption) => item.name === this.selectedCollaborationModeName);
    if (this.selectedCollaborationModeName !== 'default') {
      hilog.info(0x0001, 'ArkPilot', `selectedCollaborationMode: searching=${this.selectedCollaborationModeName} found=${matched !== undefined} modes=[${this.collaborationModes.map((m: CollaborationModeOption) => `"${m.name}"`).join(',')}]`);
    }
    return matched ?? null;
  }

  private currentCollaborationModeLabel(): string {
    this.collaborationModeVersion; // touch to register as dependency
    const mode: CollaborationModeOption | null = this.selectedCollaborationMode();
    const label: string = mode !== null ? mode.name : 'Default';
    hilog.info(0x0001, 'ArkPilot', `currentCollaborationModeLabel: selected=${this.selectedCollaborationModeName} modes=${this.collaborationModes.length} label=${label}`);
    return label;
  }

  private chooseCollaborationMode(mode: CollaborationModeOption): void {
    hilog.info(0x0001, 'ArkPilot', `chooseCollaborationMode: name=${mode.name} mode=${mode.mode} key=${this.collaborationModeKey()}`);
    this.selectedCollaborationModeName = mode.name;
    this.collaborationModeByWorkspaceId.set(this.collaborationModeKey(), mode.name);
    this.showCollaborationModeOptions = false;
    this.collaborationModeVersion += 1;
    hilog.info(0x0001, 'ArkPilot', `chooseCollaborationMode done: selectedCollaborationModeName=${this.selectedCollaborationModeName} version=${this.collaborationModeVersion}`);
  }

  private visibleMessages(): ChatMessage[] {
    const hasPendingTailMessage: boolean = (this.isRunning && this.pendingUserPrompt.trim().length > 0) ||
      this.pendingRequestUserInput !== null;
    const renderableAfter: boolean[] = this.precomputeRenderableAfterFlags(hasPendingTailMessage);
    let visible: ChatMessage[] = [];
    for (let index: number = 0; index < this.messages.length; index += 1) {
      if (this.shouldRenderMessageAt(index, hasPendingTailMessage, renderableAfter)) {
        visible.push(this.messages[index]);
      }
    }
    if (this.isRunning && this.pendingUserPrompt.trim().length > 0) {
      visible = [...visible, this.pendingUserMessage()];
    }
    if (this.pendingRequestUserInput !== null) {
      const request: CodexRequestUserInput = this.pendingRequestUserInput;
      const promptMessage = new ChatMessage(
        `request-user-input:${request.requestId}`,
        'ArkPilot',
        'plan',
        request.detail.trim().length > 0 ? request.detail : request.title,
        '刚刚',
        'plan'
      );
      visible = [...visible, promptMessage];
    }
    return visible;
  }

  private chatMessagesSignature(messages: ChatMessage[]): string {
    const count: number = messages.length;
    let signature: string = `${count}`;
    for (let index: number = 0; index < count; index += 1) {
      const message: ChatMessage = messages[index];
      signature += `|${message.id}|${message.content.length}|${message.status ?? ''}`;
    }
    return signature;
  }

  private precomputeRenderableAfterFlags(hasPendingTailMessage: boolean): boolean[] {
    const flags: boolean[] = new Array<boolean>(this.messages.length);
    let seenRenderableAfter: boolean = hasPendingTailMessage;
    for (let index: number = this.messages.length - 1; index >= 0; index -= 1) {
      flags[index] = seenRenderableAfter;
      if (this.shouldRenderMessage(this.messages[index])) {
        seenRenderableAfter = true;
      }
    }
    return flags;
  }

  private shouldRenderMessageAt(index: number, hasPendingTailMessage: boolean, renderableAfter: boolean[]): boolean {
    const item: ChatMessage = this.messages[index];
    if (!this.shouldRenderMessage(item)) {
      return false;
    }
    if (this.isReasoningMessage(item)) {
      return !this.hasRenderableMessageAfter(index, hasPendingTailMessage, renderableAfter);
    }
    return true;
  }

  private shouldRenderMessage(item: ChatMessage): boolean {
    if (this.isCompactionSystemMessage(item)) {
      return false;
    }
    return !this.isEmptyReasoningMessage(item);
  }

  private hasRenderableMessageAfter(index: number, hasPendingTailMessage: boolean, renderableAfter: boolean[]): boolean {
    if (hasPendingTailMessage) {
      return true;
    }
    if (index + 1 < renderableAfter.length) {
      return renderableAfter[index + 1];
    }
    return false;
  }

  private isEmptyReasoningMessage(item: ChatMessage): boolean {
    const type: string = item.itemType ?? item.role;
    return type === 'reasoning' && item.content.trim().length === 0;
  }

  private isCompactionSystemMessage(item: ChatMessage): boolean {
    const type: string = item.itemType ?? item.role;
    if (type !== 'system' && item.role !== 'system') {
      return false;
    }
    const content: string = item.content.trim();
    return content.indexOf('上下文已压缩') >= 0 ||
      content.toLowerCase().indexOf('context has been compacted') >= 0;
  }

  private shouldShowTurnActivityLine(): boolean {
    if (!this.shouldTrackIdleThinking()) {
      return false;
    }
    if (this.pendingApproval !== null || this.pendingRequestUserInput !== null) {
      return false;
    }
    return this.liveThinkingActive || this.currentTurnHasIntermediateOutput();
  }

  private toggleTurnActivityExpanded(): void {
    this.isTurnActivityCollapsed = !this.isTurnActivityCollapsed;
  }

  private latestCurrentTurnThoughtStage(messages: ChatMessage[]): string {
    const startIndex: number = this.currentTurnMessageStartIndex();
    let latestStage: string = '';
    for (let index: number = startIndex; index < messages.length; index += 1) {
      const item: ChatMessage = messages[index];
      if (this.isReasoningMessage(item)) {
        latestStage = 'reasoning';
      } else if (this.isAssistantOutputMessage(item)) {
        latestStage = 'assistant';
      } else if (this.isActivityMessage(item)) {
        latestStage = 'activity';
      }
    }
    return latestStage;
  }

  private currentTurnAssistantOutputSignature(messages: ChatMessage[]): string {
    const parts: string[] = [];
    const startIndex: number = this.currentTurnMessageStartIndex();
    for (let index: number = startIndex; index < messages.length; index += 1) {
      const item: ChatMessage = messages[index];
      if (this.isAssistantOutputMessage(item)) {
        parts.push(`${item.id}:${item.content.length}`);
      }
    }
    return parts.join('|');
  }

  private currentTurnReasoningSignature(messages: ChatMessage[]): string {
    const parts: string[] = [];
    const startIndex: number = this.currentTurnMessageStartIndex();
    for (let index: number = startIndex; index < messages.length; index += 1) {
      const item: ChatMessage = messages[index];
      if (this.isReasoningMessage(item)) {
        parts.push(`${item.id}:${item.content.length}`);
      }
    }
    return parts.join('|');
  }

  private currentTurnTextOutputSignature(): string {
    const parts: string[] = [];
    const startIndex: number = this.currentTurnMessageStartIndex();
    for (let index: number = startIndex; index < this.messages.length; index += 1) {
      const item: ChatMessage = this.messages[index];
      if (this.isTextOutputMessage(item)) {
        parts.push(`${item.id}:${item.role}:${item.itemType ?? ''}:${item.content.length}`);
      }
    }
    return parts.join('|');
  }

  private isTextOutputMessage(item: ChatMessage): boolean {
    if (item.content.trim().length === 0) {
      return false;
    }
    const type: string = item.itemType ?? item.role;
    if (type === 'system' || item.role === 'system' || item.role === 'user') {
      return false;
    }
    return true;
  }

  private isAssistantOutputMessage(item: ChatMessage): boolean {
    if (item.content.trim().length === 0) {
      return false;
    }
    const type: string = item.itemType ?? item.role;
    if (this.isIntermediateMessageType(type)) {
      return false;
    }
    return item.role === 'assistant' || item.role === 'agent';
  }

  private isCurrentTurnAssistantOutput(item: ChatMessage, index: number): boolean {
    if (!this.isAssistantOutputMessage(item)) {
      return false;
    }
    if (this.currentTurnId.trim().length > 0 && item.id.startsWith(`${this.currentTurnId}:`)) {
      return true;
    }
    return index >= this.currentTurnMessageStartIndex();
  }

  private isStreamingAssistantMessage(item: ChatMessage): boolean {
    if (this.currentTurnStatus !== 'inProgress') {
      return false;
    }
    const index: number = this.messages.findIndex((message: ChatMessage) => message.id === item.id);
    return this.isCurrentTurnAssistantOutput(item, index);
  }

  private isActivityMessage(item: ChatMessage): boolean {
    const type: string = item.itemType ?? item.role;
    if (this.isIntermediateMessageType(type)) {
      return true;
    }
    return item.role !== 'user' &&
      item.role !== 'system' &&
      item.role !== 'assistant' &&
      item.role !== 'agent';
  }

  private currentTurnHasIntermediateOutput(): boolean {
    const startIndex: number = this.currentTurnMessageStartIndex();
    for (let index: number = startIndex; index < this.messages.length; index += 1) {
      const item: ChatMessage = this.messages[index];
      if (this.isActivityMessage(item) && !this.isEmptyReasoningMessage(item)) {
        return true;
      }
    }
    return false;
  }

  private isIntermediateMessageType(type: string): boolean {
    return type === 'reasoning' ||
      type === 'command' ||
      type === 'tool' ||
      type === 'file' ||
      type === 'search' ||
      type === 'plan' ||
      type === 'image' ||
      type === 'hook' ||
      type === 'review';
  }

  private currentTurnMessageStartIndex(): number {
    return this.thinkingMessageBoundary >= 0 ? this.thinkingMessageBoundary : this.messages.length;
  }

  private thinkingStatusPhraseText(): string {
    const isLongThinking: boolean = this.thinkingPulseIndex >= this.longThinkingPulseThreshold;
    if (isLongThinking) {
      const phrase: string = this.thinkingFunPhrase.length > 0 ? this.thinkingFunPhrase : '思考中';
      return `${phrase}${this.thinkingDots()}`;
    }
    const phrase: string = this.thinkingNormalPhrase.length > 0 ? this.thinkingNormalPhrase : this.thinkingStatusPhrases[0];
    return `${phrase}${this.thinkingDots()}`;
  }

  private pendingUserMessage(): ChatMessage {
    return new ChatMessage(
      `pending-user:${this.thinkingSessionId}`,
      '你',
      'user',
      this.pendingUserPrompt,
      '刚刚'
    );
  }

  private startThinkingAnimation(): void {
    if (this.thinkingTimerId >= 0) {
      return;
    }
    this.thinkingTimerId = setInterval(() => {
      this.thinkingPulseIndex = (this.thinkingPulseIndex + 1) % 144;
      this.refreshThinkingNormalPhrase();
      this.refreshThinkingFunPhrase();
    }, 1000);
  }

  private shouldTrackIdleThinking(): boolean {
    return this.isRunning && this.currentTurnStatus === 'inProgress';
  }

  private resetIdleThinkingTimer(): void {
    this.lastTextOutputAt = Date.now();
    this.showIdleThinkingIndicator = false;
    this.clearIdleThinkingTimer();
    if (!this.shouldTrackIdleThinking()) {
      return;
    }
    this.idleThinkingTimerId = setTimeout(() => {
      this.idleThinkingTimerId = -1;
      this.updateIdleThinkingIndicator();
    }, this.idleThinkingDelayMs);
  }

  private clearIdleThinkingTimer(): void {
    if (this.idleThinkingTimerId >= 0) {
      clearTimeout(this.idleThinkingTimerId);
      this.idleThinkingTimerId = -1;
    }
  }

  private updateIdleThinkingIndicator(): void {
    if (!this.shouldTrackIdleThinking()) {
      this.showIdleThinkingIndicator = false;
      this.clearIdleThinkingTimer();
      return;
    }
    const elapsedMs: number = Date.now() - this.lastTextOutputAt;
    if (elapsedMs >= this.idleThinkingDelayMs) {
      if (!this.showIdleThinkingIndicator) {
        this.showIdleThinkingIndicator = true;
        this.scheduleMessageScrollToBottom();
      }
      if (this.idleThinkingTimerId < 0) {
        this.idleThinkingTimerId = setTimeout(() => {
          this.idleThinkingTimerId = -1;
          this.updateIdleThinkingIndicator();
        }, 500);
      }
      return;
    }
    this.clearIdleThinkingTimer();
    this.idleThinkingTimerId = setTimeout(() => {
      this.idleThinkingTimerId = -1;
      this.updateIdleThinkingIndicator();
    }, this.idleThinkingDelayMs - elapsedMs);
  }

  private syncTextOutputIdleState(): void {
    if (!this.shouldTrackIdleThinking()) {
      this.lastTextOutputSignature = '';
      this.showIdleThinkingIndicator = false;
      this.clearIdleThinkingTimer();
      return;
    }
    const signature: string = this.currentTurnTextOutputSignature();
    if (signature !== this.lastTextOutputSignature) {
      this.lastTextOutputSignature = signature;
      this.resetIdleThinkingTimer();
      return;
    }
    this.updateIdleThinkingIndicator();
  }

  private stopThinkingAnimation(): void {
    if (this.thinkingTimerId >= 0) {
      clearInterval(this.thinkingTimerId);
      this.thinkingTimerId = -1;
    }
  }

  private clearLiveThinking(): void {
    this.liveThinkingActive = false;
    this.liveThinkingContent = '';
    this.liveThinkingReasoningSignature = '';
    this.liveThinkingAssistantSignature = '';
    this.isTurnActivityCollapsed = true;
  }

  private isReasoningPlaceholderText(content: string): boolean {
    return content.trim() === '正在思考...';
  }

  private updateLiveThinking(result: CodexTurnResult, rawMessages: ChatMessage[]): void {
    if (result.status !== 'inProgress') {
      this.clearLiveThinking();
      return;
    }
    const latestStage: string = this.latestCurrentTurnThoughtStage(rawMessages);
    const assistantSignature: string = this.currentTurnAssistantOutputSignature(rawMessages);
    const reasoningSignature: string = this.currentTurnReasoningSignature(rawMessages);
    if (assistantSignature !== this.liveThinkingAssistantSignature) {
      this.liveThinkingAssistantSignature = assistantSignature;
      this.liveThinkingActive = false;
      this.liveThinkingContent = '';
    }
    if (latestStage === 'assistant' && reasoningSignature === this.liveThinkingReasoningSignature) {
      this.clearLiveThinking();
      this.liveThinkingReasoningSignature = reasoningSignature;
      this.liveThinkingAssistantSignature = assistantSignature;
      return;
    }
    if (latestStage === '' || latestStage === 'activity') {
      this.liveThinkingActive = true;
      this.liveThinkingContent = '';
      this.liveThinkingReasoningSignature = reasoningSignature;
      this.liveThinkingAssistantSignature = assistantSignature;
      return;
    }
    const startIndex: number = this.currentTurnMessageStartIndex();
    let latestReasoning: ChatMessage | null = null;
    for (let index: number = startIndex; index < rawMessages.length; index += 1) {
      const item: ChatMessage = rawMessages[index];
      if (this.isReasoningMessage(item)) {
        latestReasoning = item;
      }
    }
    if (latestReasoning === null || this.isReasoningPlaceholderText(latestReasoning.content)) {
      this.liveThinkingActive = true;
      this.liveThinkingContent = '';
      this.liveThinkingReasoningSignature = reasoningSignature;
      this.liveThinkingAssistantSignature = assistantSignature;
      return;
    }
    this.liveThinkingActive = true;
    this.liveThinkingContent = latestReasoning.content;
    this.liveThinkingReasoningSignature = reasoningSignature;
    this.liveThinkingAssistantSignature = assistantSignature;
  }

  private syncThinkingAnimation(): void {
    if (this.isRunning) {
      this.startThinkingAnimation();
      return;
    }
    this.stopThinkingAnimation();
  }

  private thinkingStatusText(): string {
    return `${this.thinkingLogoText()} ${this.thinkingStatusPhraseText()}`;
  }

  private displayBrandText(text: string): string {
    return text.replace(/Codex/g, 'ArkPilot');
  }

  private turnActivityDetailLines(): string[] {
    const reasoningText: string = this.liveThinkingContent.trim();
    if (reasoningText.length === 0) {
      return ['正在等待可展示的思考内容。'];
    }
    const lines: string[] = reasoningText
      .replace(/\r\n/g, '\n')
      .replace(/\r/g, '\n')
      .split('\n')
      .map((line: string) => this.displayBrandText(line).trim())
      .filter((line: string) => line.length > 0);
    if (lines.length === 0) {
      lines.push('正在等待可展示的思考内容。');
    }
    return lines;
  }

  private refreshThinkingNormalPhrase(): void {
    if (this.thinkingPulseIndex >= this.longThinkingPulseThreshold) {
      this.thinkingNormalPhraseBucket = -1;
      return;
    }
    const bucket: number = Math.floor(this.thinkingPulseIndex / this.thinkingPhrasePulseSpan);
    if (bucket === this.thinkingNormalPhraseBucket && this.thinkingNormalPhrase.length > 0) {
      return;
    }
    this.thinkingNormalPhraseBucket = bucket;
    this.thinkingNormalPhrase = this.randomThinkingPhrase(this.thinkingStatusPhrases, this.thinkingNormalPhrase, '');
  }

  private refreshThinkingFunPhrase(): void {
    if (this.thinkingPulseIndex < this.longThinkingPulseThreshold) {
      if (this.thinkingFunPhrase.length > 0) {
        this.thinkingFunPhrase = '';
      }
      this.thinkingFunPhraseBucket = -1;
      return;
    }
    const bucket: number = Math.floor((this.thinkingPulseIndex - this.longThinkingPulseThreshold) / this.thinkingPhrasePulseSpan);
    if (bucket === this.thinkingFunPhraseBucket && this.thinkingFunPhrase.length > 0) {
      return;
    }
    this.thinkingFunPhraseBucket = bucket;
    this.thinkingFunPhrase = this.randomThinkingLongPhrase(this.thinkingFunPhrase);
  }

  private randomThinkingPhrase(phrases: string[], previousPhrase: string, fallbackPhrase: string): string {
    if (phrases.length === 0) {
      return fallbackPhrase;
    }
    if (phrases.length === 1) {
      return phrases[0];
    }
    let phraseIndex: number = Math.floor(Math.random() * phrases.length);
    if (phrases[phraseIndex] === previousPhrase) {
      phraseIndex = (phraseIndex + 1 + Math.floor(Math.random() * (phrases.length - 1))) % phrases.length;
    }
    return phrases[phraseIndex];
  }

  private randomThinkingLongPhrase(previousPhrase: string): string {
    const defaultPhrase: string = '思考中';
    if (Math.random() < 0.75) {
      return defaultPhrase;
    }
    const phrases: string[] = this.longThinkingStatusPhrases;
    if (phrases.length === 1) {
      return phrases[0];
    }
    return this.randomThinkingPhrase(phrases, previousPhrase !== defaultPhrase ? previousPhrase : '', defaultPhrase);
  }

  private thinkingLogoText(): string {
    const frameIndex: number = Math.floor(this.thinkingPulseIndex / 2) % this.thinkingLogoFrames.length;
    return this.thinkingLogoFrames[frameIndex];
  }

  private thinkingDots(): string {
    switch (Math.floor(this.thinkingPulseIndex / 2) % 4) {
      case 0:
        return '…';
      case 1:
        return '.';
      case 2:
        return '..';
      default:
        return '...';
    }
  }

  private requestUserInputAnswer(questionId: string): string {
    this.requestUserInputVersion;
    return this.requestUserInputDrafts.get(questionId) ?? '';
  }

  private setRequestUserInputAnswer(questionId: string, value: string): void {
    this.requestUserInputDrafts.set(questionId, value);
    this.requestUserInputVersion += 1;
  }

  private async submitRequestUserInput(): Promise<void> {
    const request: CodexRequestUserInput | null = this.pendingRequestUserInput;
    if (request === null) {
      return;
    }
    const answers: Record<string, string[]> = {};
    for (let index: number = 0; index < request.questions.length; index += 1) {
      const question = request.questions[index];
      const value: string = this.requestUserInputAnswer(question.id).trim();
      if (value.length === 0) {
        this.summaryTitle = '需要补充信息';
        this.summaryPoints = [`请先回答“${question.header}”再继续。`];
        return;
      }
      answers[question.id] = [value];
    }
    await codexBackend.submitPendingUserInput(answers);
    this.requestUserInputDrafts.clear();
    this.requestUserInputVersion += 1;
  }

  private async declineRequestUserInput(): Promise<void> {
    await codexBackend.declinePendingUserInput();
    this.requestUserInputDrafts.clear();
    this.requestUserInputVersion += 1;
  }

  private sendMessage(): void {
    const prompt: string = this.draft.trim();
    if (prompt.length === 0 || this.isWorkspaceRunning(this.activeWorkspaceId)) {
      return;
    }
    if (this.providerApiKey.trim().length === 0) {
      promptAction.showToast({ message: '尚未配置 API，请到设置界面进行配置', duration: 3000 });
      return;
    }
    this.resumeMessageAutoFollow();
    this.scheduleMessageScrollToBottom(true);
    this.savedDraft = this.draft;
    this.draft = '';
    void this.runTurn(prompt);
  }

  private stopTurn(): void {
    const runState: WorkspaceRunState | undefined = this.workspaceRunStates.get(this.activeWorkspaceId);
    const threadKey: string = runState !== undefined
      ? (runState.threadId.trim().length > 0 ? runState.threadId : runState.threadKey)
      : this.activeWorkspaceBindingId;
    codexBackend.interruptTurnForThreadKey(threadKey);
  }

  private async runTurn(prompt: string): Promise<void> {
    if (this.workspaces.length === 0) {
      return;
    }
    const workspace: WorkspaceItem | undefined = this.activeWorkspace();
    if (workspace === undefined) {
      return;
    }
    const runWorkspaceId: number = workspace.id;
    if (this.isWorkspaceRunning(runWorkspaceId)) {
      return;
    }
    if (this.workspaceDraftText.trim() !== this.workspaceRoot.trim()) {
      this.applyWorkspaceRootBinding();
    }
    const trimmedWorkspaceRoot: string = this.workspaceRoot.trim();
    const threadKey: string = workspace.workspaceId.trim().length > 0 ? workspace.workspaceId : this.activeWorkspaceBindingId;
    const runBindingId: string = this.activeWorkspaceBindingId;
    const runPermissionState: WorkspacePermissionState = this.activeWorkspacePermissionState;
    const runAccessKind: WorkspaceAccessKind = this.activeWorkspaceAccessKind;
    const runModel: string = this.currentModelValue();
    const runEffort: string = this.currentEffortValue();
    const runCollaborationMode: CollaborationModeOption | null = this.selectedCollaborationMode();
    const runSavedDraft: string = this.savedDraft;
    const runBoundary: number = this.messages.length;
    this.workspaceRunStates.set(runWorkspaceId, new WorkspaceRunState(runWorkspaceId, threadKey, prompt, runSavedDraft, runBoundary));
    this.refreshRunningWorkspaceIndicators();
    this.isRunning = true;
    this.currentTurnStatus = 'inProgress';
    this.pendingUserPrompt = prompt;
    this.thinkingMessageBoundary = runBoundary;
    this.thinkingPulseIndex = 0;
    this.thinkingNormalPhrase = '';
    this.thinkingNormalPhraseBucket = -1;
    this.thinkingFunPhrase = '';
    this.thinkingFunPhraseBucket = -1;
    this.liveThinkingActive = true;
    this.liveThinkingContent = '';
    this.liveThinkingReasoningSignature = '';
    this.liveThinkingAssistantSignature = '';
    this.showIdleThinkingIndicator = false;
    this.lastTextOutputAt = Date.now();
    this.lastTextOutputSignature = '';
    this.clearIdleThinkingTimer();
    this.thinkingSessionId += 1;
    this.refreshThinkingNormalPhrase();
    this.startThinkingAnimation();
    this.resetIdleThinkingTimer();
    this.workspaceRoots.set(runWorkspaceId, this.workspaceRoot);
    this.refreshWorkspaceBindingState();

    try {
      await this.applyEmbeddedHostStatus();
      codexBackend.configureServerUrl(this.serverUrl);
      const result: CodexTurnResult = await codexBackend.startTurn(
        new CodexTurnRequest(
          threadKey,
          workspace.title,
          runBindingId,
          trimmedWorkspaceRoot,
          runPermissionState,
          runAccessKind,
          trimmedWorkspaceRoot.length > 0 ? [trimmedWorkspaceRoot] : [],
          runModel,
          runEffort,
          runCollaborationMode,
          prompt
        ),
        (update: CodexTurnResult) => {
          this.applyBackendResultForWorkspace(runWorkspaceId, threadKey, update);
        }
      );
      this.applyBackendResultForWorkspace(runWorkspaceId, threadKey, result);
      if ((result.status === 'interrupted' || result.status === 'failed') && this.activeWorkspaceId === runWorkspaceId) {
        this.draft = runSavedDraft;
      }
      if (this.activeWorkspaceId === runWorkspaceId) {
        this.savedDraft = '';
      }
    } catch (err) {
      this.workspaceRunStates.delete(runWorkspaceId);
      this.refreshRunningWorkspaceIndicators();
      if (this.activeWorkspaceId === runWorkspaceId) {
        this.currentTurnStatus = 'failed';
        this.summaryTitle = '调用失败';
        this.summaryPoints = [this.describeError(err)];
        this.draft = runSavedDraft;
        this.savedDraft = '';
      }
    } finally {
      this.workspaceRunStates.delete(runWorkspaceId);
      this.refreshRunningWorkspaceIndicators();
      if (this.activeWorkspaceId === runWorkspaceId) {
        this.isRunning = false;
        this.pendingUserPrompt = '';
        this.thinkingMessageBoundary = -1;
        this.showIdleThinkingIndicator = false;
        this.lastTextOutputSignature = '';
        this.clearLiveThinking();
        this.clearIdleThinkingTimer();
        this.syncThinkingAnimation();
      }
    }
  }

  private applyBackendResultForWorkspace(workspaceId: number, threadKey: string, result: CodexTurnResult): void {
    this.syncWorkspaceWithRemoteThreadIdForWorkspace(workspaceId, result.threadId);
    const runState: WorkspaceRunState | undefined = this.workspaceRunStates.get(workspaceId);
    if (runState !== undefined) {
      runState.threadKey = threadKey;
      runState.threadId = result.threadId;
      runState.turnId = result.turnId;
      runState.status = result.status;
      if (this.backendResultContainsPendingPrompt(result)) {
        runState.pendingUserPrompt = '';
      }
      if (result.status !== 'inProgress') {
        this.workspaceRunStates.delete(workspaceId);
        this.refreshRunningWorkspaceIndicators();
      }
    }
    if (workspaceId !== this.activeWorkspaceId) {
      return;
    }
    const resultThreadId: string = result.threadId.trim();
    const isSameRenderedConversation: boolean = this.renderedWorkspaceId === workspaceId &&
      (resultThreadId.length === 0 || this.renderedThreadId.length === 0 || this.renderedThreadId === resultThreadId);
    this.applyBackendResult(result, isSameRenderedConversation);
    this.renderedWorkspaceId = workspaceId;
    this.renderedThreadId = resultThreadId.length > 0 ? resultThreadId : threadKey;
    this.syncActiveWorkspaceRunState();
  }

  private applyBackendResult(result: CodexTurnResult, preserveDisplayState: boolean = true): void {
    this.currentTurnId = result.turnId;
    this.currentTurnStatus = result.status;
    this.syncThinkingAnimation();
    if (this.backendResultContainsPendingPrompt(result)) {
      this.pendingUserPrompt = '';
    }
    const rawMessages: ChatMessage[] = result.messages.map((item) => {
      return new ChatMessage(item.messageId, this.displayBrandText(item.author), item.role, this.displayBrandText(item.content), item.timestamp, item.itemType, item.status, item.metadata);
    });
    const displayMessages: ChatMessage[] = preserveDisplayState
      ? this.mergeDisplayMessagesLinear(rawMessages, result)
      : rawMessages;
    this.updateLiveThinking(result, displayMessages);
    const nextMessages: ChatMessage[] = displayMessages.filter((item: ChatMessage) => {
      return !this.isReasoningMessage(item);
    });
    const messagesSignature: string = this.chatMessagesSignature(nextMessages);
    if (messagesSignature !== this.lastAppliedMessagesSignature) {
      this.messages = nextMessages;
      this.lastAppliedMessagesSignature = messagesSignature;
    }
    this.codeLines = result.diffLines.length > 0
      ? result.diffLines.map((line: CodexDiffLine) => {
          return new CodeDiffLine(line.lineId, line.lineNumber, line.sign, line.content, line.kind, line.filePath);
        })
      : [new CodeDiffLine('placeholder-2', '1', ' ', '本轮尚未产生 diff。', 'context')];
    if (result.diffLines.length > 0) {
      this.applyDiffFiles(this.buildDiffFiles(this.codeLines));
    } else {
      this.diffFiles = [];
      this.selectedDiffFilePath = '';
    }
    this.summaryTitle = this.displayBrandText(result.summaryTitle);
    this.summaryPoints = result.summaryPoints.length > 0 ? result.summaryPoints.map((point: string) => this.displayBrandText(point)) : ['没有可展示的摘要信息。'];
    this.changedFiles = result.changedFiles;
    this.diffStat = result.diffStat;
    if (result.tokenUsage !== null) {
      this.tokenUsage = result.tokenUsage;
    }
    if (result.contextManagement !== null) {
      this.contextManagement = result.contextManagement;
    }
    this.modelAutoCompactTokenLimit = result.modelAutoCompactTokenLimit;
    this.effectiveAutoCompactTokenLimit = result.effectiveAutoCompactTokenLimit;
    this.autoCompactCurrentTotalTokens = result.autoCompactCurrentTotalTokens;
    this.autoCompactWillCheckBeforeNextTurn = result.autoCompactWillCheckBeforeNextTurn;
    this.autoCompactWouldWaitForFollowUp = result.autoCompactWouldWaitForFollowUp;
    this.autoCompactEnabled = result.autoCompactEnabled;
    this.remainingToAutoCompact = result.remainingToAutoCompact;
    this.autoCompactNearThreshold = result.autoCompactNearThreshold;
    if (result.status !== 'inProgress') {
      void this.refreshTokenAggregateForActiveWorkspace(result.threadId);
    }
    this.syncTextOutputIdleState();
    this.scheduleMessageScrollToBottom();
  }

  /**
   * O(N) 单遍重建显示消息（替代旧的 O(N²) mergeStreamingDisplayMessages + preserveStableMessageTimestamps）：
   * 一次构建现有消息 id 索引，保留历史稳定 timestamp，仅对当前轮流式输出做内容合并。
   */
  private mergeDisplayMessagesLinear(rawMessages: ChatMessage[], result: CodexTurnResult): ChatMessage[] {
    const existingById: Map<string, ChatMessage> = new Map<string, ChatMessage>();
    for (let index: number = 0; index < this.messages.length; index += 1) {
      const message: ChatMessage = this.messages[index];
      if (!existingById.has(message.id)) {
        existingById.set(message.id, message);
      }
    }
    const display: ChatMessage[] = [];
    for (let index: number = 0; index < rawMessages.length; index += 1) {
      const item: ChatMessage = rawMessages[index];
      const existing: ChatMessage | undefined = existingById.get(item.id);
      if (existing === undefined) {
        display.push(item);
        continue;
      }
      const mergedContent: string = (result.status === 'inProgress' && this.isCurrentTurnAssistantOutput(item, index) && existing.content !== item.content)
        ? this.mergeStreamingMessageContent(existing.content, item.content)
        : item.content;
      display.push(new ChatMessage(
        item.id,
        item.author,
        item.role,
        mergedContent,
        existing.timestamp.trim().length > 0 ? existing.timestamp : item.timestamp,
        item.itemType,
        item.status,
        item.metadata
      ));
      existingById.delete(item.id);
    }
    // 兜底：native 快照暂未包含的当前轮流式消息，按原顺序补插（增量协议下应罕见）。
    let insertAt: number = this.messages.length;
    for (let index: number = this.messages.length - 1; index >= 0; index -= 1) {
      const existing: ChatMessage = this.messages[index];
      if (!existingById.has(existing.id)) {
        continue;
      }
      if (!this.isCurrentTurnAssistantOutput(existing, index)) {
        continue;
      }
      insertAt = Math.min(index, display.length);
      display.splice(insertAt, 0, existing);
      existingById.delete(existing.id);
    }
    return display;
  }

  private mergeStreamingMessageContent(existingContent: string, incomingContent: string): string {
    if (existingContent.length === 0 || incomingContent.startsWith(existingContent)) {
      return incomingContent;
    }
    if (incomingContent.length === 0 || existingContent.indexOf(incomingContent) >= 0) {
      return existingContent;
    }
    const overlapSize: number = this.streamingMessageContentOverlapSize(existingContent, incomingContent);
    if (overlapSize > 0) {
      return `${existingContent}${incomingContent.substring(overlapSize)}`;
    }
    return incomingContent.length >= existingContent.length ? incomingContent : existingContent;
  }

  private streamingMessageContentOverlapSize(left: string, right: string): number {
    const maxOverlap: number = Math.min(left.length, right.length);
    for (let size: number = maxOverlap; size > 0; size -= 1) {
      if (left.endsWith(right.substring(0, size))) {
        return size;
      }
    }
    return 0;
  }

  private backendResultContainsPendingPrompt(result: CodexTurnResult): boolean {
    const prompt: string = this.pendingUserPrompt.trim();
    if (prompt.length === 0) {
      return false;
    }
    for (let index: number = result.messages.length - 1; index >= 0; index -= 1) {
      const item = result.messages[index];
      if (item.role === 'user' && item.content.trim() === prompt) {
        return true;
      }
    }
    return false;
  }

  private clampConversationFontScale(value: number): number {
    const clamped: number = Math.min(this.conversationFontScaleMax, Math.max(this.conversationFontScaleMin, value));
    return Math.round(clamped * 100) / 100;
  }

  private setConversationFontScale(value: number): void {
    const nextScale: number = this.clampConversationFontScale(value);
    if (nextScale === this.conversationFontScale) {
      return;
    }
    this.conversationFontScale = nextScale;
    this.scheduleMessageScrollToBottom();
  }

  private adjustConversationFontScale(steps: number): void {
    if (steps === 0) {
      return;
    }
    this.setConversationFontScale(this.conversationFontScale + (this.conversationFontScaleStep * steps));
  }

  private adjustConversationFontScaleFromWheel(steps: number): void {
    this.messageZoomWheelActiveUntil = Date.now() + 120;
    this.adjustConversationFontScale(steps);
  }

  private conversationFontSize(base: number): number {
    return Math.round(base * this.conversationFontScale * 10) / 10;
  }

  private conversationLineHeight(base: number): number {
    return Math.round(base * this.conversationFontScale * 10) / 10;
  }

  private conversationZoomLabel(): string {
    return `${Math.round(this.conversationFontScale * 100).toString()}%`;
  }

  private isConversationFontAtMin(): boolean {
    return this.conversationFontScale <= this.conversationFontScaleMin;
  }

  private isConversationFontAtMax(): boolean {
    return this.conversationFontScale >= this.conversationFontScaleMax;
  }

  private mermaidScaleKey(messageId: string, block: MarkdownBlock): string {
    return `${messageId}:${block.id}`;
  }

  private mermaidScale(key: string): number {
    for (let index: number = 0; index < this.mermaidScaleEntries.length; index += 1) {
      if (this.mermaidScaleEntries[index].key === key) {
        return this.mermaidScaleEntries[index].scale;
      }
    }
    return 1;
  }

  private setMermaidScale(key: string, value: number): void {
    const nextScale: number = this.clampConversationFontScale(value);
    const nextEntries: MermaidScaleEntry[] = [];
    let updated: boolean = false;
    for (let index: number = 0; index < this.mermaidScaleEntries.length; index += 1) {
      const entry: MermaidScaleEntry = this.mermaidScaleEntries[index];
      if (entry.key === key) {
        updated = true;
        if (nextScale !== 1) {
          nextEntries.push(new MermaidScaleEntry(key, nextScale));
        }
      } else {
        nextEntries.push(entry);
      }
    }
    if (!updated && nextScale !== 1) {
      nextEntries.push(new MermaidScaleEntry(key, nextScale));
    }
    this.mermaidScaleEntries = nextEntries;
  }

  private adjustMermaidScale(key: string, steps: number): void {
    if (steps === 0) {
      return;
    }
    this.setMermaidScale(key, this.mermaidScale(key) + (this.conversationFontScaleStep * steps));
  }

  private isMermaidScaleAtMin(key: string): boolean {
    return this.mermaidScale(key) <= this.conversationFontScaleMin;
  }

  private isMermaidScaleAtMax(key: string): boolean {
    return this.mermaidScale(key) >= this.conversationFontScaleMax;
  }

  private isModifierPressed(event: KeyEvent | AxisEvent, primary: string): boolean {
    if (event.getModifierKeyState === undefined) {
      return false;
    }
    try {
      if (event.getModifierKeyState([primary])) {
        return true;
      }
    } catch (_err) {
    }
    try {
      return event.getModifierKeyState([primary.toLowerCase()]);
    } catch (_err) {
      return false;
    }
  }

  private isConversationZoomInKey(event: KeyEvent): boolean {
    return event.keyText === '+' ||
      event.keyText === '=' ||
      event.keyCode === this.keyCodePlus ||
      event.keyCode === this.keyCodeEquals ||
      event.keyCode === this.keyCodeNumpadAdd ||
      event.keyCode === this.keyCodeNumpadEquals;
  }

  private isConversationZoomOutKey(event: KeyEvent): boolean {
    return event.keyText === '-' ||
      event.keyCode === this.keyCodeMinus ||
      event.keyCode === this.keyCodeNumpadSubtract;
  }

  private handleConversationKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down || !this.isModifierPressed(event, 'Ctrl')) {
      return false;
    }
    if (this.isConversationZoomInKey(event)) {
      this.adjustConversationFontScale(1);
      event.stopPropagation();
      return true;
    }
    if (this.isConversationZoomOutKey(event)) {
      this.adjustConversationFontScale(-1);
      event.stopPropagation();
      return true;
    }
    return false;
  }

  private axisVerticalValue(event: AxisEvent): number {
    let value: number = event.getVerticalAxisValue();
    if (value === 0 && event.axisVertical !== undefined) {
      value = event.axisVertical;
    }
    return value;
  }

  private handleConversationAxisZoom(event: AxisEvent): void {
    if (!this.isModifierPressed(event, 'Ctrl')) {
      return;
    }
    const vertical: number = this.axisVerticalValue(event);
    if (vertical === 0 || vertical !== vertical) {
      return;
    }
    this.adjustConversationFontScaleFromWheel(vertical < 0 ? 1 : -1);
  }

  private scheduleMessageScrollToBottom(force: boolean = false): void {
    if (!force && !this.messageAutoFollowToBottom) {
      return;
    }
    if (force) {
      this.clearMessageScheduledScrollTimers();
    }
    if (this.messageScheduledScrollTimerId < 0) {
      this.messageScheduledScrollTimerId = setTimeout(() => {
        this.messageScheduledScrollTimerId = -1;
        this.scrollMessagesToBottom(force);
      }, 0);
    }
    if (this.messageScheduledFollowUpScrollTimerId < 0) {
      this.messageScheduledFollowUpScrollTimerId = setTimeout(() => {
        this.messageScheduledFollowUpScrollTimerId = -1;
        this.scrollMessagesToBottom(force);
      }, 48);
    }
  }

  private scrollMessagesToBottom(force: boolean = false): void {
    if (!force && !this.messageAutoFollowToBottom) {
      return;
    }
    this.beginMessageProgrammaticScroll();
    try {
      this.messageScroller.scrollEdge(Edge.Bottom);
      this.messageAutoFollowToBottom = true;
    } catch (_err) {
    }
  }

  private clearMessageProgrammaticScrollTimer(): void {
    if (this.messageProgrammaticScrollTimerId >= 0) {
      clearTimeout(this.messageProgrammaticScrollTimerId);
      this.messageProgrammaticScrollTimerId = -1;
    }
  }

  private clearMessageScheduledScrollTimers(): void {
    if (this.messageScheduledScrollTimerId >= 0) {
      clearTimeout(this.messageScheduledScrollTimerId);
      this.messageScheduledScrollTimerId = -1;
    }
    if (this.messageScheduledFollowUpScrollTimerId >= 0) {
      clearTimeout(this.messageScheduledFollowUpScrollTimerId);
      this.messageScheduledFollowUpScrollTimerId = -1;
    }
  }

  private clearMessageUserScrollTimer(): void {
    if (this.messageUserScrollTimerId >= 0) {
      clearTimeout(this.messageUserScrollTimerId);
      this.messageUserScrollTimerId = -1;
    }
  }

  private beginMessageProgrammaticScroll(): void {
    this.clearMessageProgrammaticScrollTimer();
    this.messageProgrammaticScroll = true;
    this.messageProgrammaticScrollTimerId = setTimeout(() => {
      this.messageProgrammaticScroll = false;
      this.messageProgrammaticScrollTimerId = -1;
    }, 120);
  }

  private resumeMessageAutoFollow(): void {
    this.messageUserScrollActive = false;
    this.clearMessageUserScrollTimer();
    this.messageAutoFollowToBottom = true;
  }

  private beginMessageUserScroll(): void {
    this.clearMessageUserScrollTimer();
    this.messageUserScrollActive = true;
    this.messageUserScrollTimerId = setTimeout(() => {
      this.messageUserScrollActive = false;
      this.messageUserScrollTimerId = -1;
    }, 240);
  }

  private isUserMessageScrollSource(source: ScrollSource): boolean {
    return source === ScrollSource.DRAG ||
      source === ScrollSource.FLING ||
      source === ScrollSource.OTHER_USER_INPUT ||
      source === ScrollSource.SCROLL_BAR ||
      source === ScrollSource.SCROLL_BAR_FLING;
  }

  private isMessageScrollerAtEnd(): boolean {
    try {
      return this.messageScroller.isAtEnd();
    } catch (_err) {
      return true;
    }
  }

  private handleMessageWillScroll(_xOffset: number, yOffset: number, _scrollState: ScrollState, scrollSource: ScrollSource): OffsetResult | void {
    if (this.messageZoomWheelActiveUntil > Date.now() && scrollSource === ScrollSource.OTHER_USER_INPUT) {
      return { xOffset: 0, yOffset: 0 };
    }
    if (!this.isUserMessageScrollSource(scrollSource)) {
      return;
    }
    this.beginMessageUserScroll();
    this.messageProgrammaticScroll = false;
    if (yOffset < 0 || !this.isMessageScrollerAtEnd()) {
      this.messageAutoFollowToBottom = false;
    }
  }

  private handleMessageDidScroll(_xOffset: number, _yOffset: number, _scrollState: ScrollState): void {
    const atEnd: boolean = this.isMessageScrollerAtEnd();
    if (this.messageProgrammaticScroll) {
      if (atEnd) {
        this.messageAutoFollowToBottom = true;
      }
      return;
    }
    if (atEnd) {
      this.resumeMessageAutoFollow();
      return;
    }
    if (this.messageUserScrollActive) {
      this.messageAutoFollowToBottom = false;
    }
  }

  private handleMessageScrollEdge(side: Edge): void {
    if (side === Edge.Bottom) {
      this.messageAutoFollowToBottom = true;
      return;
    }
    if (side === Edge.Top) {
      this.messageAutoFollowToBottom = false;
    }
  }

  private jumpToLatestMessage(): void {
    this.resumeMessageAutoFollow();
    this.scrollMessagesToBottom(true);
  }

  private handleMessageScrollStop(): void {
    if (this.isMessageScrollerAtEnd()) {
      this.resumeMessageAutoFollow();
      return;
    }
    this.messageUserScrollActive = false;
    this.clearMessageUserScrollTimer();
  }

  private messageRenderKey(item: ChatMessage): string {
    const type: string = item.itemType ?? item.role;
    const status: string = item.status ?? '';
    const metadataText: string = this.cachedMetadataSignature(item.id, item.metadata);
    return `${item.id}:${type}:${status}:${metadataText.length}:${this.messageContentRenderSignature(item.content)}`;
  }

  private metadataSignatureCache: Map<string, string> = new Map();

  private cachedMetadataSignature(messageId: string, metadata?: Record<string, Object>): string {
    if (metadata === undefined) {
      this.metadataSignatureCache.delete(messageId);
      return '';
    }
    const cached: string | undefined = this.metadataSignatureCache.get(messageId);
    if (cached !== undefined) {
      return cached;
    }
    const signature: string = JSON.stringify(metadata);
    if (this.metadataSignatureCache.size >= 256) {
      this.metadataSignatureCache.clear();
    }
    this.metadataSignatureCache.set(messageId, signature);
    return signature;
  }

  private messageContentRenderSignature(content: string): string {
    const length: number = content.length;
    if (length === 0) {
      return '0';
    }
    const first: number = content.charCodeAt(0);
    const middle: number = content.charCodeAt(Math.floor(length / 2));
    const last: number = content.charCodeAt(length - 1);
    return `${length}:${first}:${middle}:${last}`;
  }

  private async connectOrDisconnect(): Promise<void> {
    codexBackend.configureServerUrl(this.serverUrl);
    if (this.connectionState === 'connected' || this.connectionState === 'connecting') {
      await codexBackend.disconnect();
      return;
    }

    try {
      await codexBackend.connect();
      this.loadProviderConfig();
      await this.restoreSessionsFromBackend();
      this.reconnectAttemptCount = 0;
      this.clearReconnectTimer();
      this.summaryTitle = '连接成功';
      this.summaryPoints = [
        'initialize / initialized 握手已经完成。',
        '现在可以直接发送 turn/start 请求。',
        '如需针对项目操作，请填写真实工作目录。'
      ];
    } catch (err) {
      this.summaryTitle = '连接失败';
      this.summaryPoints = [this.describeError(err)];
    }
  }

  private async connectEmbeddedHost(): Promise<void> {
    if (this.connectionState === 'connected' || this.connectionState === 'connecting') {
      return;
    }

    try {
      codexBackend.configureServerUrl(this.serverUrl);
      await codexBackend.connect();
      this.loadProviderConfig();
      await this.restoreSessionsFromBackend();
      this.summaryTitle = '应用内后端连接成功';
      this.summaryPoints = [
        'initialize / initialized 握手已经完成。',
        '当前页面连接的是应用内自启动的 Rust app-server。',
        '现在可以直接发送 turn/start 请求。'
      ];
    } catch (err) {
      this.reconnectAttemptCount += 1;
      const hostStatus = getEmbeddedCodexHostStatus();
      const retryDelayMs: number = Math.min(1500 * this.reconnectAttemptCount, 6000);
      this.summaryTitle = '应用内后端连接失败';
      this.summaryPoints = [
        hostStatus.message.length > 0 ? hostStatus.message : 'embedded host status unavailable',
        this.describeError(err),
        `系统将在 ${retryDelayMs} ms 后自动重试连接。`,
        '可以点击连接按钮重试，或者检查 native 日志。'
      ];
      this.scheduleEmbeddedHostReconnect(retryDelayMs);
    }
  }

  private async loginWithApiKey(): Promise<void> {
    if (this.isAuthenticating) {
      return;
    }

    const apiKey: string = this.apiKey.trim();
    if (apiKey.length === 0) {
      this.summaryTitle = '登录失败';
      this.summaryPoints = ['请先输入 OpenAI API Key。'];
      return;
    }

    this.isAuthenticating = true;
    try {
      await codexBackend.loginWithApiKey(apiKey);
      this.summaryTitle = 'OpenAI 认证已就绪';
      this.summaryPoints = [
        '已经通过 account/login/start 完成 API Key 登录。',
        '现在可以重新发送你的问题。',
        this.authStatusText
      ];
    } catch (err) {
      this.summaryTitle = '登录失败';
      this.summaryPoints = [this.describeError(err)];
    } finally {
      this.isAuthenticating = false;
    }
  }

  private loadProviderConfig(): void {
    const config: CodexProviderConfig = getEmbeddedCodexProviderConfig();
    const catalog = getEmbeddedCodexProviderCatalog();
    this.providerBaseUrl = config.baseUrl;
    this.providerApiKey = config.apiKey;
    this.manualModel = config.model;
    this.providerStatusText = this.describeProviderConfig(config);
    // 从 catalog 中获取当前激活的 provider 名称
    let activeName: string = '未选择';
    for (let i = 0; i < catalog.providers.length; i++) {
      if (catalog.providers[i].isActive) {
        activeName = catalog.providers[i].name;
        break;
      }
    }
    if (activeName === '未选择' && catalog.providers.length > 0) {
      activeName = catalog.providers[0].name;
    }
    this.providerName = activeName;
    hilog.info(
      INDEX_DOMAIN,
      INDEX_TAG,
      'loadProviderConfig baseUrl=%{public}s model=%{public}s apiKeyLen=%{public}d catalogProviders=%{public}d',
      config.baseUrl,
      config.model,
      config.apiKey.length,
      catalog.providers.length
    );
  }

  private async saveProviderConfig(): Promise<void> {
    if (this.isSavingProvider) {
      return;
    }

    this.isSavingProvider = true;
    try {
      hilog.info(
        INDEX_DOMAIN,
        INDEX_TAG,
        'saveProviderConfig input baseUrl=%{public}s model=%{public}s apiKeyLen=%{public}d',
        this.providerBaseUrl.trim(),
        this.manualModel.trim(),
        this.providerApiKey.trim().length
      );
      const config: CodexProviderConfig = saveEmbeddedCodexProviderConfig(
        this.providerBaseUrl.trim(),
        this.providerApiKey.trim(),
        this.manualModel.trim()
      );
      hilog.info(
        INDEX_DOMAIN,
        INDEX_TAG,
        'saveProviderConfig native returned baseUrl=%{public}s model=%{public}s apiKeyLen=%{public}d',
        config.baseUrl,
        config.model,
        config.apiKey.length
      );
      this.providerBaseUrl = config.baseUrl;
      this.providerApiKey = config.apiKey;
      this.manualModel = config.model;
      const importedCatalog = providerCatalogService.importCurrentProvider();
      hilog.info(
        INDEX_DOMAIN,
        INDEX_TAG,
        'saveProviderConfig imported catalog activeProviderId=%{public}s providers=%{public}d',
        importedCatalog.activeProviderId,
        importedCatalog.providers.length
      );
      this.providerStatusText = this.describeProviderConfig(config);
      this.summaryTitle = 'Provider config saved';
      this.summaryPoints = [
        'base_url, api_key, and default model were written to CODEX_HOME and synced to the active provider catalog.',
        'Restart the app to apply provider changes to the embedded app-server runtime.',
        this.providerStatusText
      ];
    } catch (err) {
      hilog.error(
        INDEX_DOMAIN,
        INDEX_TAG,
        'saveProviderConfig failed: %{public}s',
        this.describeError(err)
      );
      hilog.error(
        INDEX_DOMAIN,
        INDEX_TAG,
        'saveProviderConfig error details: %{public}s',
        JSON.stringify(err)
      );
      if (err instanceof Error && err.stack !== undefined) {
        hilog.error(
          INDEX_DOMAIN,
          INDEX_TAG,
          'saveProviderConfig stack: %{public}s',
          err.stack
        );
      }
      this.summaryTitle = 'Provider config failed';
      this.summaryPoints = [this.describeError(err)];
    } finally {
      this.isSavingProvider = false;
    }
  }

  private async approvePending(): Promise<void> {
    await codexBackend.approvePendingRequest();
  }

  private async declinePending(): Promise<void> {
    await codexBackend.declinePendingRequest();
  }

  private async selectWorkspace(item: WorkspaceItem): Promise<void> {
    this.activeWorkspaceId = item.id;
    this.syncSelectedCollaborationMode();
    this.workspaceRoot = this.workspaceRoots.get(item.id) ?? '';
    this.workspaceDraftText = this.workspaceRoot;
    this.directoryFilter = this.workspaceRoot;
    this.directoryFilterText = this.workspaceRoot.length > 0 ? this.workspaceRoot : '使用默认工作区';
    this.syncRecentWorkspaces();
    this.refreshWorkspaceBindingState();
    this.syncCurrentWorkspaceState();
    this.syncActiveWorkspaceRunState();
    this.applyPendingRequestsForActiveWorkspace();
    this.persistWorkspaceBindings();
    await this.loadSelectedWorkspaceHistory();
    this.syncActiveWorkspaceRunState();
  }

  private lastConversationMessage(): ChatMessage | null {
    for (let index = this.messages.length - 1; index >= 0; index -= 1) {
      const item: ChatMessage = this.messages[index];
      const content: string = item.content.trim();
      if (content.length === 0 || item.id === 'welcome-1') {
        continue;
      }
      if (item.role === 'user' || item.role === 'assistant' || item.role === 'agent') {
        return item;
      }
    }
    return null;
  }

  private hasFailureSignal(text: string): boolean {
    const lowerText: string = text.toLowerCase();
    return lowerText.indexOf('失败') >= 0 ||
      lowerText.indexOf('错误') >= 0 ||
      lowerText.indexOf('异常') >= 0 ||
      lowerText.indexOf('error') >= 0 ||
      lowerText.indexOf('failed') >= 0 ||
      lowerText.indexOf('exception') >= 0;
  }


  private hasDiffSignal(): boolean {
    return this.diffFiles.length > 0 ||
      (this.changedFiles.trim().length > 0 && this.changedFiles !== NO_FILE_CHANGES_TEXT) ||
      this.diffStat.trim() !== '+0 -0';
  }

  private currentCompactionAnchorMessageId(): string {
    const lastMessage: ChatMessage | null = this.lastConversationMessage();
    return lastMessage !== null ? lastMessage.id : '';
  }

  private currentCompactionNotices(): CompactionNotice[] {
    this.compactionNoticeVersion;
    const threadIds: string[] = this.currentCompactionThreadIds();
    if (threadIds.length === 0) {
      return [...this.compactionNotices];
    }
    return this.compactionNotices.filter((notice: CompactionNotice) => {
      return threadIds.indexOf(notice.threadId) >= 0;
    });
  }

  private compactionNoticesBeforeMessages(): CompactionNotice[] {
    return this.currentCompactionNotices().filter((notice: CompactionNotice) => {
      const anchorMessageId: string = notice.anchorMessageId.trim();
      return anchorMessageId.length === 0;
    });
  }

  private compactionNoticesAfterMessage(messageId: string): CompactionNotice[] {
    return this.currentCompactionNotices().filter((notice: CompactionNotice) => {
      return notice.anchorMessageId === messageId;
    });
  }

  private compactionNoticeRenderKey(notice: CompactionNotice): string {
    return `${notice.id}:${notice.status}:${notice.savedTokens}:${notice.oldTotalTokens}:${notice.newTotalTokens}:${notice.anchorMessageId}:${this.compactionNoticeVersion}`;
  }

  private isCompactionNoticeExpanded(noticeId: string): boolean {
    return this.expandedCompactionIds.indexOf(noticeId) >= 0;
  }

  private toggleCompactionNoticeExpanded(noticeId: string): void {
    if (this.isCompactionNoticeExpanded(noticeId)) {
      this.expandedCompactionIds = this.expandedCompactionIds.filter((id: string) => id !== noticeId);
      return;
    }
    this.expandedCompactionIds = [...this.expandedCompactionIds, noticeId];
  }

  private retryCurrentCompaction(threadId: string = ''): void {
    const preferredThreadId: string = threadId.trim();
    const targetThreadId: string = preferredThreadId.length > 0
      ? preferredThreadId
      : (this.backendActiveThreadId.trim().length > 0 ? this.backendActiveThreadId.trim() : this.activeWorkspaceBindingId.trim());
    if (targetThreadId.length === 0 || this.compacting || this.pendingCompactionThreadId === targetThreadId) {
      return;
    }
    this.pendingCompactionThreadId = targetThreadId;
    this.resumeMessageAutoFollow();
    this.compactError = '';
    codexBackend.clearCompactionNotice(targetThreadId);
    void codexBackend.compactThread(targetThreadId).catch((err: Error) => {
      this.pendingCompactionThreadId = '';
      this.compactError = err.message.trim().length > 0 ? err.message : codexBackend.getLastCompactError();
    });
  }

  private accentBorderColor(role: string): string {
    switch (role) {
      case 'reasoning': return '#F59E0B';
      case 'command': return '#10B981';
      case 'tool': return '#3B82F6';
      case 'file': return '#A855F7';
      case 'search': return '#14B8A6';
      case 'plan': return '#F97316';
      case 'image': return '#EC4899';
      case 'hook': return '#EAB308';
      case 'review': return '#FACC15';
      case 'user': return '#3B82F6';
      default: return '#D4D4D8';
    }
  }

  private operationLabel(role: string): string {
    switch (role) {
      case 'reasoning': return '思考';
      case 'command': return '命令';
      case 'tool': return '工具';
      case 'file': return '文件';
      case 'search': return '搜索';
      case 'plan': return '计划';
      case 'image': return '图片';
      case 'hook': return '钩子';
      case 'review': return '审查';
      default: return role;
    }
  }


  private dynamicInputPlaceholder(): string {
    if (this.pendingRequestUserInput !== null) {
      return '上方有待补充问题，也可以输入追加说明...';
    }
    if (this.pendingApproval !== null) {
      return '上方有待确认操作，也可以输入替代指令...';
    }
    if (this.isRunning) {
      return '任务执行中，输入下一步想法会先保留为草稿...';
    }
    if (this.connectionState !== 'connected') {
      return '连接后输入要发送给 ArkPilot 的指令...';
    }

    const lastMessage: ChatMessage | null = this.lastConversationMessage();
    if (lastMessage === null) {
      return '输入要发送给 ArkPilot 的指令...';
    }
    if (this.hasFailureSignal(`${this.summaryTitle}\n${lastMessage.content}`)) {
      return '描述期望结果，或要求继续修复最新错误...';
    }
    if (this.hasDiffSignal()) {
      return '围绕当前 diff 提问、要求检查或继续修改...';
    }
    if (lastMessage.role === 'user') {
      return '补充上条需求的背景、路径或验收条件...';
    }
    return '基于最新回复继续追问...';
  }

  private connectionButtonLabel(): string {
    if (this.connectionState === 'connected') {
      return '断开';
    }
    if (this.connectionState === 'connecting') {
      return '连接中';
    }
    return '连接';
  }

  private authButtonLabel(): string {
    return 'Log in';
  }

  private providerButtonLabel(): string {
    if (this.isSavingProvider) {
      return 'Saving...';
    }
    return 'Save provider';
  }

  private describeProviderConfig(config: CodexProviderConfig): string {
    const baseUrl: string = config.baseUrl.trim().length > 0 ? config.baseUrl.trim() : '未配置';
    const model: string = config.model.trim().length > 0 ? config.model.trim() : '未配置';
    const auth: string = config.apiKey.trim().length > 0 ? 'API key set' : 'No API key';
    return `base_url: ${baseUrl} | model: ${model} | ${auth}`;
  }

  private connectionChipBackground(): string {
    if (this.connectionState === 'connected') {
      return '#DCFCE7';
    }
    if (this.connectionState === 'connecting') {
      return '#fffefbc7';
    }
    if (this.connectionState === 'error') {
      return '#FEE2E2';
    }
    return '#E2E8F0';
  }

  private connectionChipColor(): string {
    if (this.connectionState === 'connected') {
      return '#166534';
    }
    if (this.connectionState === 'connecting') {
      return '#92400E';
    }
    if (this.connectionState === 'error') {
      return '#B91C1C';
    }
    return '#475569';
  }

  private messageBackground(role: string): string {
    switch (role) {
      case 'assistant':
      case 'agent':
        return '#00000000';
      case 'user':
        return '#EFF6FF';
      default:
        return this.themeElevatedBackground();
    }
  }

  private authorColor(role: string): string {
    switch (role) {
      case 'assistant':
      case 'agent':
        return '#3B82F6';
      case 'system':
        return '#71717A';
      case 'reasoning':
        return '#D97706';
      case 'command':
        return '#059669';
      case 'tool':
        return '#2563EB';
      case 'file':
        return '#9333EA';
      case 'search':
        return '#10B981';
      case 'plan':
        return '#EA580C';
      case 'image':
        return '#DB2777';
      case 'hook':
        return '#B45309';
      case 'review':
        return '#A16207';
      case 'user':
        return '#2563EB';
      default:
        return '#7C3AED';
    }
  }

  private diffBackground(kind: string): string {
    if (kind === 'add') {
      return '#ECFDF3';
    }
    if (kind === 'delete') {
      return '#FEF2F2';
    }
    return '#F8FAFC';
  }

  private diffColor(kind: string): string {
    if (kind === 'add') {
      return '#15803D';
    }
    if (kind === 'delete') {
      return '#DC2626';
    }
    return '#475569';
  }

  private isWorkspaceActive(item: WorkspaceItem): boolean {
    return this.activeWorkspaceId === item.id;
  }

  private toggleLeftDrawer(): void {
    this.runPanelMotion(() => {
      this.showLeftDrawer = !this.showLeftDrawer;
    });
  }

  private toggleRightDrawer(): void {
    this.runPanelMotion(() => {
      this.showRightDrawer = !this.showRightDrawer;
    });
  }

  private applyResponsiveLayoutProfile(force: boolean = false): void {
    if (!force && this.lastAppliedBreakpoint === this.currentBreakpoint) {
      return;
    }
    const profile = getArkPilotLayoutProfile(this.currentBreakpoint);
    if (profile.leftPanelWidth > 0) {
      this.leftPanelWidth = profile.leftPanelWidth;
    }
    if (profile.rightPanelWidth > 0) {
      this.rightPanelWidth = profile.rightPanelWidth;
    }
    this.showLeftDrawer = profile.leftPanelPersistent;
    this.showRightDrawer = profile.rightPanelPersistent;
    this.lastAppliedBreakpoint = this.currentBreakpoint;
  }

  private onBreakpointChanged(): void {
    this.applyResponsiveLayoutProfile();
  }

  private onLoggedInChanged(): void {
    const loggedIn: boolean = (AppStorage.get<boolean>('arkPilotLoggedIn') ?? false);
    if (!loggedIn) {
      this.cancelLogoutDialog();
      router.replaceUrl({ url: 'pages/AiLoginPage' });
    }
  }

  private accountDisplayName(): string {
    const masked: string = huaweiAccountService.maskedUnionID();
    return masked.length > 0 ? masked : '已登录';
  }

  private openSwitchAccountPage(): void {
    // 切换账号 = 彻底退出本地登录态并撤销系统级授权，
    // 回到登录页重新授权（可在授权页重新选择账号/输入密码）。
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext !== undefined) {
      void huaweiAccountService.logout(hostContext);
    } else {
      void huaweiAccountService.logout();
    }
  }

  private openLogoutDialog(): void {
    if (this.logoutDialogController !== null) {
      this.logoutDialogController.open();
    }
  }

  private confirmLogout(): void {
    if (this.logoutDialogController !== null) {
      this.logoutDialogController.close();
    }
    // logout() 会触发 onLoggedInChanged，自动跳转回 LoginPage
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext !== undefined) {
      void huaweiAccountService.logout(hostContext);
    } else {
      void huaweiAccountService.logout();
    }
  }

  private cancelLogoutDialog(): void {
    if (this.logoutDialogController !== null) {
      this.logoutDialogController.close();
    }
  }

  private isPhoneBreakpoint(): boolean {
    return this.currentBreakpoint === 'xs' || this.currentBreakpoint === 'sm';
  }

  private describeError(err: Object): string {
    if (err instanceof Error) {
      return err.message.trim().length > 0 ? err.message : '操作失败，请稍后重试。';
    }
    return '操作失败，请稍后重试。';
  }

  private normalizedDirectoryUri(rawUri: string): string {
    let result: string = rawUri.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  private fileUriToFsPath(rawUri: string): string {
    try {
      return new fileUri.FileUri(rawUri).path;
    } catch (_err) {
      return rawUri;
    }
  }

  private encodeUriPathSegment(segment: string): string {
    return encodeURIComponent(segment).replace(/%2F/g, '/');
  }

  private childUri(parentUri: string, childName: string): string {
    return `${this.normalizedDirectoryUri(parentUri)}/${this.encodeUriPathSegment(childName)}`;
  }

  /**
   * AIGC provenance：taskpool 复制完成后，主线程对清单命中的文件补注入隐式标识。
   * 命中清单且可注入的文件由注入器写导出副本（覆盖 taskpool 已复制的未注入副本）；
   * .aigc_list.json 自身由 taskpool 原样导出（injectIfNeeded 对其返回 false）。
   */
  private async reinjectAigcForMirror(sourceRoot: string, targetRootUri: string, injector: AigcExportInjector): Promise<number> {
    let injectedCount: number = 0;
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(sourceRoot) as string[];
    } catch (err) {
      throw new Error(`列出源目录失败: ${sourceRoot}; ${this.describeError(err)}`);
    }
    for (let index: number = 0; index < entries.length; index += 1) {
      const entry: string = entries[index];
      const sourcePath: string = `${sourceRoot}/${entry}`;
      const targetUri: string = this.childUri(targetRootUri, entry);
      try {
        const stat = fileIo.statSync(sourcePath);
        if (stat.isDirectory()) {
          injectedCount += await this.reinjectAigcForMirror(sourcePath, targetUri, injector);
        } else if (stat.isFile()) {
          const injected: boolean = await injector.injectIfNeeded(sourcePath, targetUri);
          if (injected) {
            injectedCount += 1;
          }
        }
      } catch (err) {
        throw new Error(`注入条目失败: ${sourcePath} -> ${targetUri}; ${this.describeError(err)}`);
      }
    }
    return injectedCount;
  }

  private async syncProjectToImportSource(proj: ProjectRecord): Promise<void> {
    const sourceUri: string = proj.sourceUri.trim();
    if (sourceUri.length === 0) {
      promptAction.showToast({ message: '该项目没有同步文件夹', duration: 2000 });
      return;
    }
    const projectPath: string = proj.path.trim();
    if (projectPath.length === 0) {
      promptAction.showToast({ message: '项目运行目录为空，无法同步', duration: 2000 });
      return;
    }
    const targetLabel: string = this.canSelectExternalFolder() ? '同步文件夹' : '下载目录';
    promptAction.showToast({ message: `开始同步到${targetLabel}...`, duration: 1200 });
    try {
      try {
        await this.activateProjectSourcePermission(sourceUri);
      } catch (activationErr) {
        hilog.warn(INDEX_DOMAIN, INDEX_TAG, 'activate source permission failed: %{public}s', this.describeError(activationErr));
      }
      // AIGC provenance：构造导出注入器，对清单命中的文件在导出副本上注入隐式标识。
      // .aigc_list.json 自身由 taskpool 原样导出（injectIfNeeded 对其返回 false）
      const codexHome: string = (AppStorage.get('codexHome') as string) ?? '';
      const injector: AigcExportInjector | null = AigcExportInjector.fromSourceRoot(projectPath, codexHome);
      const targetRootPath: string = this.fileUriToFsPath(sourceUri);
      const task = new taskpool.Task(copyProjectDirectoryTask, projectPath, targetRootPath);
      const rawResult: string = await taskpool.execute(task) as string;
      const parsed: Record<string, Object> = JSON.parse(rawResult) as Record<string, Object>;
      if (typeof parsed['error'] === 'string') {
        throw new Error(parsed['error'] as string);
      }
      const copiedCount: number = typeof parsed['copiedCount'] === 'number' ? (parsed['copiedCount'] as number) : 0;
      // AIGC provenance：taskpool 复制完成后，主线程对清单命中的文件补注入隐式标识
      if (injector !== null) {
        await this.reinjectAigcForMirror(projectPath, sourceUri, injector);
      }
      promptAction.showToast({ message: `已同步 ${copiedCount.toString()} 个文件到${targetLabel}`, duration: 2600 });
    } catch (err) {
      hilog.error(INDEX_DOMAIN, INDEX_TAG, 'sync project to import source failed: %{public}s', this.describeError(err));
      promptAction.showToast({ message: `同步失败: ${this.describeError(err)}；同步文件夹可能已被删除或授权失效，请重新选择同步文件夹`, duration: 3200 });
    }
  }

  private async importProjectFromSyncFolder(proj: ProjectRecord): Promise<void> {
    const sourceUri: string = proj.sourceUri.trim();
    if (sourceUri.length === 0) {
      promptAction.showToast({ message: '该项目没有同步文件夹', duration: 2000 });
      return;
    }
    const projectPath: string = proj.path.trim();
    if (projectPath.length === 0) {
      promptAction.showToast({ message: '项目运行目录为空，无法导入', duration: 2000 });
      return;
    }
    promptAction.showToast({ message: '开始导入同步文件夹内容...', duration: 1200 });
    try {
      try {
        await this.activateProjectSourcePermission(sourceUri);
      } catch (activationErr) {
        hilog.warn(INDEX_DOMAIN, INDEX_TAG, 'activate source permission failed: %{public}s', this.describeError(activationErr));
      }
      const sourcePath: string = this.fileUriToFsPath(sourceUri);
      const task = new taskpool.Task(mirrorDirectoryTask, sourcePath, projectPath);
      const rawResult: string = await taskpool.execute(task) as string;
      const parsed: Record<string, Object> = JSON.parse(rawResult) as Record<string, Object>;
      if (typeof parsed['error'] === 'string') {
        throw new Error(parsed['error'] as string);
      }
      const copiedFiles: number = typeof parsed['copiedFiles'] === 'number' ? (parsed['copiedFiles'] as number) : 0;
      const deletedEntries: number = typeof parsed['deletedEntries'] === 'number' ? (parsed['deletedEntries'] as number) : 0;
      promptAction.showToast({ message: `已导入 ${copiedFiles.toString()} 个文件，删除 ${deletedEntries.toString()} 个多余条目`, duration: 3000 });
      // AIGC provenance：导入回流时合并外部清单，保留已标注文件的标识记录
      this.mergeAigcManifestFromImport(sourcePath, projectPath);
    } catch (err) {
      hilog.error(INDEX_DOMAIN, INDEX_TAG, 'import project from sync folder failed: %{public}s', this.describeError(err));
      promptAction.showToast({ message: `导入失败: ${this.describeError(err)}；同步文件夹可能已被删除或授权失效，请重新选择同步文件夹`, duration: 3600 });
    }
  }

  /** AIGC provenance：导入后合并外部清单进项目目录清单。 */
  private mergeAigcManifestFromImport(sourceRootPath: string, projectPath: string): void {
    try {
      const importedManifestPath: string = `${sourceRootPath}/${AIGC_MANIFEST_FILE_NAME}`;
      let rawText: string = '';
      try {
        fileIo.statSync(importedManifestPath);
        rawText = fileIo.readTextSync(importedManifestPath);
      } catch (_err) {
      }
      if (rawText.trim().length === 0) {
        return;
      }
      aigcProvenanceStore.mergeImportedManifest(projectPath, rawText);
    } catch (err) {
      hilog.warn(INDEX_DOMAIN, INDEX_TAG, 'mergeAigcManifestFromImport failed: %{public}s', this.describeError(err));
    }
  }

  private openWebTarget(rawTarget: string, label: string, sourceMessageId?: string): void {
    const target: string = this.cleanMarkdownLinkTarget(rawTarget);
    if (target.length === 0) {
      promptAction.showToast({ message: '链接地址为空', duration: 1600 });
      return;
    }
    if (this.isHttpUrl(target)) {
      this.openHttpTarget(target, label);
      return;
    }
    const title: string = label.length > 0 ? label : this.fileNameFromTarget(target);
    if (this.isFileUri(target)) {
      this.openSystemFileUri(target, title);
      return;
    }
    const localUri: string = this.localTargetToSystemUri(target, sourceMessageId);
    if (localUri.length > 0) {
      this.openSystemFileUri(localUri, title);
      return;
    }
    promptAction.showToast({ message: '无法定位链接或文件，已交由系统处理的目标需要是有效 URL 或本地路径', duration: 2400 });
  }

  private openHttpTarget(target: string, label: string): void {
    const context: common.UIAbilityContext | null = this.currentAbilityContext();
    if (context === null) {
      promptAction.showToast({ message: '当前页面上下文不可用，无法打开浏览器', duration: 2200 });
      return;
    }
    const options: OpenLinkOptions = {
      appLinkingOnly: false
    };
    try {
      context.openLink(target, options)
        .then(() => {
          promptAction.showToast({ message: '已在浏览器中打开', duration: 1400 });
        })
        .catch((_err: Object) => {
          this.openViewDataTarget(target, 'text/html', label.length > 0 ? label : target, false);
        });
    } catch (_err) {
      this.openViewDataTarget(target, 'text/html', label.length > 0 ? label : target, false);
    }
  }

  private openViewDataTarget(targetUri: string, mimeType: string, title: string, grantRead: boolean): void {
    const context: common.UIAbilityContext | null = this.currentAbilityContext();
    if (context === null) {
      promptAction.showToast({ message: '当前页面上下文不可用，无法打开链接', duration: 2200 });
      return;
    }
    const params: Record<string, Object> = {};
    params[wantConstant.Params.CONTENT_TITLE_KEY] = title;
    if (grantRead) {
      params[wantConstant.Params.PARAMS_STREAM] = [targetUri];
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: targetUri,
      type: mimeType,
      parameters: params,
      flags: grantRead ? wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION : 0
    };
    try {
      context.startAbility(want)
        .then(() => {
          promptAction.showToast({ message: '已打开链接', duration: 1400 });
        })
        .catch((err: Object) => {
          promptAction.showToast({ message: `打开失败: ${this.describeError(err)}`, duration: 2600 });
        });
    } catch (err) {
      promptAction.showToast({ message: `打开失败: ${this.describeError(err)}`, duration: 2600 });
    }
  }

  private openDiffFileWithSystem(file: CodeDiffFile): void {
    const rawPath: string = file.path.trim();
    if (rawPath.length === 0 || rawPath === UNKNOWN_DIFF_FILE_TEXT) {
      promptAction.showToast({ message: '无法定位文件，请确认工作目录或文件是否存在', duration: 2400 });
      return;
    }
    const resolved: LocalPathResolution = this.resolveLocalFileTarget(rawPath);
    if (resolved.path.length === 0) {
      promptAction.showToast({ message: '无法定位文件，请确认工作目录', duration: 2400 });
      return;
    }
    const targetUri: string = this.pathToFileUri(resolved.path);
    if (targetUri.length === 0) {
      promptAction.showToast({ message: '无法生成文件 URI，无法打开文件', duration: 2400 });
      return;
    }
    this.openSystemFileUri(targetUri, file.label.length > 0 ? file.label : this.fileNameFromTarget(rawPath));
  }

  private openSystemFileUri(targetUri: string, title: string): void {
    const context: common.UIAbilityContext | null = this.currentAbilityContext();
    if (context === null) {
      promptAction.showToast({ message: '当前页面上下文不可用，无法打开文件', duration: 2200 });
      return;
    }
    const params: Record<string, Object> = {};
    params[wantConstant.Params.CONTENT_TITLE_KEY] = title;
    params[wantConstant.Params.PARAMS_STREAM] = [targetUri];
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: targetUri,
      type: this.mimeTypeForTarget(targetUri),
      parameters: params,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    try {
      context.startAbility(want)
        .then(() => {
          promptAction.showToast({ message: '已尝试用系统默认应用打开', duration: 1400 });
        })
        .catch((err: Object) => {
          promptAction.showToast({ message: `系统打开失败: ${this.describeError(err)}`, duration: 2600 });
        });
    } catch (err) {
      promptAction.showToast({ message: `系统打开失败: ${this.describeError(err)}`, duration: 2600 });
    }
  }

  private currentAbilityContext(): common.UIAbilityContext | null {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined || hostContext === null) {
      return null;
    }
    return hostContext as common.UIAbilityContext;
  }

  private isHttpUrl(target: string): boolean {
    const lower: string = target.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  private isFileUri(target: string): boolean {
    return target.trim().toLowerCase().startsWith('file://');
  }

  private isOpenableWebTarget(target: string): boolean {
    const cleanTarget: string = this.cleanMarkdownLinkTarget(target);
    return this.isHttpUrl(cleanTarget) ||
      this.isFileUri(cleanTarget) ||
      this.isAbsoluteLocalPath(this.localFileTargetPath(cleanTarget)) ||
      this.hasOpenableFileExtension(cleanTarget);
  }

  private isHtmlFileTarget(target: string): boolean {
    const pathPart: string = this.localFilePathPart(target);
    return pathPart.endsWith('.html') || pathPart.endsWith('.htm');
  }

  private hasOpenableFileExtension(target: string): boolean {
    const pathPart: string = this.localFilePathPart(target);
    const slashIndex: number = pathPart.lastIndexOf('/');
    const dotIndex: number = pathPart.lastIndexOf('.');
    if (dotIndex <= slashIndex || dotIndex >= pathPart.length - 1) {
      return false;
    }
    const extension: string = pathPart.substring(dotIndex + 1);
    if (extension.length > 16) {
      return false;
    }
    let hasLetter: boolean = false;
    for (let index: number = 0; index < extension.length; index += 1) {
      const ch: string = extension[index];
      if (ch >= 'a' && ch <= 'z') {
        hasLetter = true;
      }
      if (!((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9'))) {
        return false;
      }
    }
    return hasLetter;
  }

  private localFilePathPart(target: string): string {
    return this.localFileTargetPath(target).toLowerCase();
  }

  private localFileTargetPath(target: string): string {
    const cleanTarget: string = target.trim();
    let end: number = cleanTarget.length;
    const queryIndex: number = cleanTarget.indexOf('?');
    if (queryIndex >= 0 && queryIndex < end) {
      end = queryIndex;
    }
    const hashIndex: number = cleanTarget.indexOf('#');
    if (hashIndex >= 0 && hashIndex < end) {
      end = hashIndex;
    }
    return cleanTarget.substring(0, end);
  }

  private localFileTargetSuffix(target: string): string {
    const cleanTarget: string = target.trim();
    const pathPart: string = this.localFileTargetPath(cleanTarget);
    return cleanTarget.substring(pathPart.length);
  }

  private localTargetToSystemUri(target: string, sourceMessageId?: string): string {
    const cleanTarget: string = target.trim();
    if (this.isFileUri(cleanTarget)) {
      return cleanTarget;
    }
    const resolved: LocalPathResolution = this.resolveLocalFileTarget(this.localFileTargetPath(cleanTarget), sourceMessageId);
    if (resolved.path.length === 0) {
      return '';
    }
    const resolvedUri: string = this.pathToFileUri(resolved.path);
    return resolvedUri.length > 0 ? `${resolvedUri}${this.localFileTargetSuffix(cleanTarget)}` : '';
  }

  private resolveLocalFileTarget(target: string, sourceMessageId?: string): LocalPathResolution {
    const normalizedTarget: string = this.collapseLocalPathSegments(target.replace(/\\/g, '/'));
    if (this.isAbsoluteLocalPath(normalizedTarget)) {
      return new LocalPathResolution(normalizedTarget, this.localFileExists(normalizedTarget));
    }

    const roots: string[] = this.localFileResolutionRoots(sourceMessageId);
    if (roots.length === 0) {
      return new LocalPathResolution('');
    }

    const candidates: string[] = [];
    for (let index: number = 0; index < roots.length; index += 1) {
      const candidate: string = this.joinLocalPath(roots[index], normalizedTarget);
      candidates.push(candidate);
      if (this.localFileExists(candidate)) {
        return new LocalPathResolution(candidate, true);
      }
    }

    return new LocalPathResolution(candidates[0] ?? '');
  }

  private localFileResolutionRoots(sourceMessageId?: string): string[] {
    const roots: string[] = [];
    const sourceIndex: number = this.messageIndexById(sourceMessageId ?? '');
    if (sourceIndex >= 0) {
      this.addMessageLocalPathRoots(roots, this.messages[sourceIndex]);
      for (let index: number = sourceIndex - 1; index >= 0; index -= 1) {
        this.addMessageLocalPathRoots(roots, this.messages[index]);
      }
    } else {
      for (let index: number = this.messages.length - 1; index >= 0; index -= 1) {
        this.addMessageLocalPathRoots(roots, this.messages[index]);
      }
    }

    this.addLocalPathRoot(roots, this.workspaceRoot);
    this.workspaceRoots.forEach((root: string) => {
      this.addLocalPathRoot(roots, root);
    });
    for (let index: number = 0; index < this.projects.length; index += 1) {
      this.addLocalPathRoot(roots, this.projects[index].path);
    }
    return roots;
  }

  private messageIndexById(messageId: string): number {
    if (messageId.trim().length === 0) {
      return -1;
    }
    for (let index: number = 0; index < this.messages.length; index += 1) {
      if (this.messages[index].id === messageId) {
        return index;
      }
    }
    return -1;
  }

  private addMessageLocalPathRoots(roots: string[], message: ChatMessage): void {
    const metadata: Record<string, Object> | undefined = message.metadata;
    if (metadata === undefined || metadata === null) {
      return;
    }

    const cwdValue: Object | undefined = metadata['cwd'];
    if (typeof cwdValue === 'string') {
      this.addLocalPathRoot(roots, cwdValue as string);
    }

    this.addMetadataPathParentRoot(roots, metadata['path']);
    this.addMetadataPathParentRoot(roots, metadata['savedPath']);

    const filesValue: Object | undefined = metadata['files'];
    if (Array.isArray(filesValue)) {
      const files: Object[] = filesValue as Object[];
      for (let index: number = 0; index < files.length; index += 1) {
        this.addMetadataPathParentRoot(roots, files[index]);
      }
    }
  }

  private addMetadataPathParentRoot(roots: string[], rawValue: Object | undefined): void {
    if (typeof rawValue !== 'string') {
      return;
    }
    const normalizedPath: string = this.collapseLocalPathSegments((rawValue as string).trim().replace(/\\/g, '/'));
    if (!this.isAbsoluteLocalPath(normalizedPath)) {
      return;
    }
    this.addLocalPathRoot(roots, this.parentLocalPath(normalizedPath));
  }

  private addLocalPathRoot(roots: string[], rawRoot: string): void {
    let normalizedRoot: string = this.collapseLocalPathSegments(rawRoot.trim().replace(/\\/g, '/'));
    if (normalizedRoot.length > 1) {
      normalizedRoot = normalizedRoot.replace(/\/+$/g, '');
    }
    if (normalizedRoot.length === 0) {
      return;
    }
    for (let index: number = 0; index < roots.length; index += 1) {
      if (roots[index].toLowerCase() === normalizedRoot.toLowerCase()) {
        return;
      }
    }
    roots.push(normalizedRoot);
  }

  private joinLocalPath(base: string, target: string): string {
    return this.collapseLocalPathSegments(`${base.replace(/\/+$/g, '')}/${target.replace(/^\/+/g, '')}`);
  }

  private parentLocalPath(path: string): string {
    const normalizedPath: string = path.replace(/\\/g, '/');
    const slashIndex: number = normalizedPath.lastIndexOf('/');
    if (slashIndex <= 0) {
      return '';
    }
    return normalizedPath.substring(0, slashIndex);
  }

  private localFileExists(path: string): boolean {
    try {
      const stat = fileIo.statSync(path);
      return stat !== undefined && stat.isFile();
    } catch (_err) {
      return false;
    }
  }

  private collapseLocalPathSegments(path: string): string {
    const normalizedPath: string = path.trim().replace(/\\/g, '/');
    if (normalizedPath.length === 0) {
      return '';
    }

    let prefix: string = '';
    let rest: string = normalizedPath;
    if (/^[A-Za-z]:\//.test(normalizedPath)) {
      prefix = normalizedPath.substring(0, 3);
      rest = normalizedPath.substring(3);
    } else if (normalizedPath.startsWith('/')) {
      prefix = '/';
      rest = normalizedPath.replace(/^\/+/g, '');
    }

    const parts: string[] = [];
    const rawParts: string[] = rest.split('/');
    for (let index: number = 0; index < rawParts.length; index += 1) {
      const part: string = rawParts[index];
      if (part.length === 0 || part === '.') {
        continue;
      }
      if (part === '..') {
        if (parts.length > 0 && parts[parts.length - 1] !== '..') {
          parts.pop();
        } else if (prefix.length === 0) {
          parts.push(part);
        }
        continue;
      }
      parts.push(part);
    }

    if (prefix.length > 0) {
      return `${prefix}${parts.join('/')}`;
    }
    return parts.join('/');
  }

  private isAbsoluteLocalPath(path: string): boolean {
    const normalizedPath: string = path.replace(/\\/g, '/');
    return normalizedPath.startsWith('/') || /^[A-Za-z]:\//.test(normalizedPath);
  }

  private pathToFileUri(path: string): string {
    const normalizedPath: string = path.replace(/\\/g, '/');
    const publicDocsUri: string = this.publicDocsFileUriFromPath(normalizedPath);
    if (publicDocsUri.length > 0) {
      return publicDocsUri;
    }
    try {
      return fileUri.getUriFromPath(normalizedPath);
    } catch (_err) {
      return this.fallbackFileUriFromPath(normalizedPath);
    }
  }

  private publicDocsFileUriFromPath(path: string): string {
    const normalizedPath: string = path.replace(/\\/g, '/');
    const pathWithoutLeadingSlash: string = normalizedPath.replace(/^\/+/g, '');
    if (pathWithoutLeadingSlash.toLowerCase().startsWith('storage/users/currentuser/')) {
      return `file://docs/${this.encodeFileUriPath(pathWithoutLeadingSlash)}`;
    }
    return '';
  }

  private fallbackFileUriFromPath(path: string): string {
    const normalizedPath: string = path.replace(/\\/g, '/');
    const encodedPath: string = this.encodeFileUriPath(normalizedPath);
    if (/^[A-Za-z]:\//.test(normalizedPath)) {
      return `file:///${encodedPath}`;
    }
    if (normalizedPath.startsWith('/')) {
      return `file://${encodedPath}`;
    }
    return `file://${encodedPath}`;
  }

  private encodeFileUriPath(path: string): string {
    return encodeURI(path).replace(/#/g, '%23').replace(/\?/g, '%3F');
  }

  private fileNameFromTarget(target: string): string {
    const pathPart: string = target.split('?')[0].split('#')[0].replace(/\\/g, '/');
    const slashIndex: number = pathPart.lastIndexOf('/');
    return slashIndex >= 0 ? pathPart.substring(slashIndex + 1) : pathPart;
  }

  private mimeTypeForTarget(target: string): string {
    const extension: string = this.extensionFromTarget(target);
    switch (extension) {
      case 'html':
      case 'htm':
        return 'text/html';
      case 'md':
      case 'markdown':
        return 'text/markdown';
      case 'txt':
      case 'log':
      case 'ets':
      case 'ts':
      case 'tsx':
      case 'js':
      case 'jsx':
      case 'json':
      case 'json5':
      case 'xml':
      case 'yaml':
      case 'yml':
      case 'toml':
      case 'rs':
      case 'py':
      case 'java':
      case 'kt':
      case 'c':
      case 'cc':
      case 'cpp':
      case 'h':
      case 'hpp':
      case 'css':
      case 'csv':
        return 'text/plain';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'pdf':
        return 'application/pdf';
      case 'zip':
        return 'application/zip';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      default:
        return 'application/octet-stream';
    }
  }

  private extensionFromTarget(target: string): string {
    const pathPart: string = target.split('?')[0].split('#')[0].replace(/\\/g, '/').toLowerCase();
    const slashIndex: number = pathPart.lastIndexOf('/');
    const dotIndex: number = pathPart.lastIndexOf('.');
    if (dotIndex <= slashIndex || dotIndex >= pathPart.length - 1) {
      return '';
    }
    return pathPart.substring(dotIndex + 1);
  }

  private copyPlainText(text: string, successMessage: string): void {
    if (text.length === 0) {
      promptAction.showToast({ message: '没有可复制内容', duration: 1600 });
      return;
    }
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      void systemPasteboard.setData(pasteData);
      promptAction.showToast({ message: successMessage, duration: 1600 });
    } catch (_err) {
      promptAction.showToast({ message: '复制失败', duration: 2000 });
    }
  }

  private messageCopyText(item: ChatMessage): string {
    return this.messageOriginalText(item.content);
  }

  private copyMessage(item: ChatMessage): void {
    this.copyPlainText(this.messageCopyText(item), '消息已复制');
  }

  private messageOriginalText(content: string): string {
    return content.trimEnd();
  }

  private placeholderDiffLine(id: string, content: string): CodeDiffLine {
    return new CodeDiffLine(id, '1', ' ', content, 'context');
  }

  private diffFileKey(filePath: string): string {
    const trimmedFilePath: string = filePath.trim();
    return trimmedFilePath.length > 0 ? trimmedFilePath : UNKNOWN_DIFF_FILE_TEXT;
  }

  private diffFileDisplayName(filePath: string): string {
    const normalizedPath: string = this.diffFileKey(filePath).replace(/\\/g, '/');
    const slashIndex: number = normalizedPath.lastIndexOf('/');
    return slashIndex >= 0 ? normalizedPath.substring(slashIndex + 1) : normalizedPath;
  }

  private buildDiffFiles(lines: CodeDiffLine[]): CodeDiffFile[] {
    const orderedPaths: string[] = [];
    const groupedLines: Map<string, CodeDiffLine[]> = new Map();
    const addCounts: Map<string, number> = new Map();
    const deleteCounts: Map<string, number> = new Map();

    for (let index: number = 0; index < lines.length; index += 1) {
      const line: CodeDiffLine = lines[index];
      const filePath: string = this.diffFileKey(line.filePath);
      if (!groupedLines.has(filePath)) {
        groupedLines.set(filePath, []);
        addCounts.set(filePath, 0);
        deleteCounts.set(filePath, 0);
        orderedPaths.push(filePath);
      }
      (groupedLines.get(filePath) as CodeDiffLine[]).push(line);
      if (line.kind === 'add') {
        addCounts.set(filePath, (addCounts.get(filePath) ?? 0) + 1);
      } else if (line.kind === 'delete') {
        deleteCounts.set(filePath, (deleteCounts.get(filePath) ?? 0) + 1);
      }
    }

    const files: CodeDiffFile[] = [];
    for (let index: number = 0; index < orderedPaths.length; index += 1) {
      const filePath: string = orderedPaths[index];
      files.push(
        new CodeDiffFile(
          filePath,
          this.diffFileDisplayName(filePath),
          `+${addCounts.get(filePath) ?? 0} -${deleteCounts.get(filePath) ?? 0}`,
          groupedLines.get(filePath) ?? []
        )
      );
    }
    return files;
  }

  private diffFileByPath(path: string, files?: CodeDiffFile[]): CodeDiffFile | null {
    const sourceFiles: CodeDiffFile[] = files ?? this.diffFiles;
    for (let index: number = 0; index < sourceFiles.length; index += 1) {
      if (sourceFiles[index].path === path) {
        return sourceFiles[index];
      }
    }
    return null;
  }

  private applyDiffFiles(files: CodeDiffFile[]): void {
    this.diffFiles = files;
    if (files.length === 0) {
      this.selectedDiffFilePath = '';
      this.codeLines = [this.placeholderDiffLine('placeholder-2', NO_DIFF_TEXT)];
      return;
    }

    let selectedFile: CodeDiffFile | null = this.diffFileByPath(this.selectedDiffFilePath, files);
    if (selectedFile === null) {
      selectedFile = files[0];
    }
    this.selectedDiffFilePath = selectedFile.path;
    this.codeLines = selectedFile.lines.length > 0
      ? selectedFile.lines
      : [this.placeholderDiffLine('placeholder-empty-file', NO_DIFF_TEXT)];
  }

  private selectDiffFile(path: string): void {
    const selectedFile: CodeDiffFile | null = this.diffFileByPath(path);
    if (selectedFile === null) {
      return;
    }
    this.selectedDiffFilePath = selectedFile.path;
    this.codeLines = selectedFile.lines.length > 0
      ? selectedFile.lines
      : [this.placeholderDiffLine('placeholder-empty-file', NO_DIFF_TEXT)];
  }

  private selectedDiffFile(): CodeDiffFile | null {
    return this.diffFileByPath(this.selectedDiffFilePath);
  }

  private currentDiffFilePath(): string {
    const selectedFile: CodeDiffFile | null = this.selectedDiffFile();
    return selectedFile !== null ? selectedFile.path : NO_FILE_CHANGES_TEXT;
  }

  private currentDiffFileStat(): string {
    const selectedFile: CodeDiffFile | null = this.selectedDiffFile();
    return selectedFile !== null ? selectedFile.diffStat : this.diffStat;
  }

  private openSelectedDiffFileWithSystem(): void {
    const selectedFile: CodeDiffFile | null = this.selectedDiffFile();
    if (selectedFile === null) {
      promptAction.showToast({ message: '当前没有可打开的修改文件', duration: 1800 });
      return;
    }
    this.openDiffFileWithSystem(selectedFile);
  }

  private isDiffFileSelected(file: CodeDiffFile): boolean {
    return this.selectedDiffFilePath === file.path;
  }

  @Builder
  private chip(label: string, background: string, color: string) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(10)
      .fontColor(color)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor(background)
      .borderRadius(6)
  }

  @Builder
  private panelTitle(title: string, subtitle: string) {
    Column() {
      Text(title)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.themeTextPrimary())

      Text(subtitle)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(10)
        .fontColor(this.themeTextMuted())
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private selectorButton(label: string, value: string, active: boolean, onPress: () => void) {
    Row() {
      Text(label)
        .copyOption(CopyOptions.None)
        .fontSize(10)
        .fontColor(this.themeTextSecondary())

      Text(value)
        .copyOption(CopyOptions.None)
        .fontSize(10)
        .fontColor(this.themeTextPrimary())
        .margin({ left: 6 })

      Text('▾')
        .copyOption(CopyOptions.None)
        .fontSize(10)
        .fontColor(this.themeTextMuted())
        .margin({ left: 6 })
    }
    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .backgroundColor(active ? this.themeSubtleBackground() : this.themePanelBackground())
    .border({ width: 0.5, color: active ? this.themeStrongBorder() : this.themeBorder() })
    .borderRadius(8)
    .scale({ x: active ? 1.02 : 1, y: active ? 1.02 : 1 })
    .animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn })
    .onClick(() => {
      onPress();
    })
  }

  @Builder
  private optionChip(option: SelectorOption, selected: boolean, onPress: () => void) {
    Text(option.label)
      .copyOption(CopyOptions.None)
      .fontSize(10)
      .fontColor(selected ? this.themeTextStrong() : this.themeTextSecondary())
      .fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 11, right: 11, top: 6, bottom: 6 })
      .backgroundColor(selected ? '#EEF6FF' : this.themeElevatedBackground())
      .border({ width: 0.5, color: selected ? '#93C5FD' : this.themeBorder() })
      .borderRadius(10)
      .shadow(selected ? { radius: 8, color: '#143B82F6', offsetY: 2 } : { radius: 0, color: '#00000000', offsetY: 0 })
      .scale({ x: selected ? 1.03 : 1, y: selected ? 1.03 : 1 })
      .animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn })
      .margin({ right: 7, bottom: 7 })
      .onClick(() => {
        onPress();
      })
  }

  @Builder
  private zoomStepButton(label: string, disabled: boolean, onPress: () => void) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(12)
      .fontColor(disabled ? this.themeTextMuted() : this.themeTextStrong())
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .width(24)
      .height(24)
      .backgroundColor(disabled ? this.themeSubtleBackground() : this.themeElevatedBackground())
      .border({ width: 0.5, color: disabled ? this.themeBorder() : this.themeStrongBorder() })
      .borderRadius(6)
      .opacity(disabled ? 0.55 : 1)
      .scale({ x: disabled ? 0.96 : 1, y: disabled ? 0.96 : 1 })
      .animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn })
      .onClick(() => {
        if (!disabled) {
          onPress();
        }
      })
  }

  @Builder
  private conversationZoomControl() {
    Row() {
      this.zoomStepButton('-', this.isConversationFontAtMin(), () => {
        this.adjustConversationFontScale(-1);
      })

      Text(this.conversationZoomLabel())
        .copyOption(CopyOptions.None)
        .fontSize(10)
        .fontColor(this.themeTextSecondary())
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .width(42)

      this.zoomStepButton('+', this.isConversationFontAtMax(), () => {
        this.adjustConversationFontScale(1);
      })
    }
    .height(28)
    .padding({ left: 2, right: 2 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.themeBorder() })
    .borderRadius(8)
  }

  @Builder
  private magnifierZoomIcon(kind: string, color: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      Circle()
        .width(11)
        .height(11)
        .fill('#00000000')
        .stroke(color)
        .strokeWidth(1.4)
        .position({ x: 2, y: 2 })

      Column()
        .width(6)
        .height(1.4)
        .backgroundColor(color)
        .borderRadius(1)
        .rotate({ angle: 45 })
        .position({ x: 11.2, y: 12.2 })

      Column()
        .width(6)
        .height(1.3)
        .backgroundColor(color)
        .borderRadius(1)
        .position({ x: 4.5, y: 6.8 })

      if (kind === 'in') {
        Column()
          .width(1.3)
          .height(6)
          .backgroundColor(color)
          .borderRadius(1)
          .position({ x: 6.85, y: 4.45 })
      }
    }
    .width(19)
    .height(19)
  }

  @Builder
  private mermaidZoomIconButton(kind: string, disabled: boolean, onPress: () => void) {
    Row() {
      this.magnifierZoomIcon(kind, disabled ? '#A1A1AA' : '#2563EB')
    }
    .width(26)
    .height(24)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(6)
    .backgroundColor(disabled ? this.themeSubtleBackground() : this.themeElevatedBackground())
    .border({ width: 0.5, color: disabled ? this.themeBorder() : '#BFDBFE' })
    .opacity(disabled ? 0.55 : 1)
    .scale({ x: disabled ? 0.96 : 1, y: disabled ? 0.96 : 1 })
    .animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn })
    .onClick(() => {
      if (!disabled) {
        onPress();
      }
    })
  }

  @Builder
  private copyIcon(color: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width(10)
        .height(12)
        .border({ width: 1.2, color: color })
        .borderRadius(2)
        .backgroundColor('#00000000')
        .position({ x: 4, y: 1 })

      Column()
        .width(10)
        .height(12)
        .border({ width: 1.2, color: color })
        .borderRadius(2)
        .backgroundColor('#00000000')
        .position({ x: 1, y: 4 })
    }
    .width(16)
    .height(18)
  }

  @Builder
  private iconCopyButton(onPress: () => void) {
    Row() {
      this.copyIcon('#64748B')
    }
    .width(26)
    .height(26)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(6)
    .backgroundColor('#00000000')
    .onClick(() => {
      onPress();
    })
  }

  @Builder
  private selectTextIcon(color: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Column().width(12).height(1.3).backgroundColor(color).borderRadius(1)
        Column().width(12).height(1.3).backgroundColor(color).borderRadius(1).margin({ top: 4 })
        Column().width(8).height(1.3).backgroundColor(color).borderRadius(1).margin({ top: 4 })
      }
      .position({ x: 1, y: 3 })

      Column()
        .width(1.4)
        .height(15)
        .backgroundColor(color)
        .borderRadius(1)
        .position({ x: 17, y: 2 })

      Column()
        .width(5)
        .height(1.2)
        .backgroundColor(color)
        .borderRadius(1)
        .position({ x: 15, y: 1 })

      Column()
        .width(5)
        .height(1.2)
        .backgroundColor(color)
        .borderRadius(1)
        .position({ x: 15, y: 17 })
    }
    .width(22)
    .height(20)
  }

  @Builder
  private iconSelectTextButton(active: boolean, onPress: () => void) {
    Row() {
      this.selectTextIcon(active ? '#2563EB' : this.themeTextSecondary())
    }
    .width(30)
    .height(26)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(6)
    .backgroundColor(active ? this.eventSoftBackground('tool') : '#00000000')
    .onClick(() => {
      onPress();
    })
  }

  private floatingMenuWidthForMaxLabelLength(maxLabelLength: number): number {
    return Math.min(180, Math.max(96, maxLabelLength * 13 + 28));
  }

  private projectSyncMenuLabel(): string {
    return this.canSelectExternalFolder() ? '导出到同步文件夹' : '导出到下载目录';
  }

  private projectSourceMenuLabel(proj: ProjectRecord): string {
    if (this.canSelectExternalFolder()) {
      return proj.sourceUri.trim().length > 0 ? '重新选择同步文件夹' : '选择同步文件夹';
    }
    return proj.sourceUri.trim().length > 0 ? '重新启用下载目录同步' : '启用下载目录同步';
  }

  private projectFloatingMenuWidth(proj: ProjectRecord): number {
    let maxLabelLength: number = '重命名项目'.length;
    maxLabelLength = Math.max(maxLabelLength, '删除项目'.length);
    if (proj.sourceUri.trim().length > 0) {
      maxLabelLength = Math.max(maxLabelLength, this.projectSyncMenuLabel().length);
      maxLabelLength = Math.max(maxLabelLength, '导入同步文件夹内容'.length);
    }
    maxLabelLength = Math.max(maxLabelLength, this.projectSourceMenuLabel(proj).length);
    maxLabelLength = Math.max(maxLabelLength, '复制路径'.length);
    return this.floatingMenuWidthForMaxLabelLength(maxLabelLength);
  }

  private sessionFloatingMenuWidth(): number {
    let maxLabelLength: number = '重命名会话'.length;
    maxLabelLength = Math.max(maxLabelLength, '删除会话'.length);
    return this.floatingMenuWidthForMaxLabelLength(maxLabelLength);
  }

  private placeFloatingMenu(windowX: number, windowY: number, menuWidth: number): void {
    this.floatingMenuWidth = menuWidth;
    this.floatingMenuX = Math.max(8, windowX - menuWidth + 2);
    this.floatingMenuY = Math.max(8, windowY - 20);
  }

  private rememberMenuTouchPosition(event: TouchEvent): void {
    if (event.touches.length > 0) {
      const touch: TouchObject = event.touches[0];
      this.lastMenuTouchWindowX = touch.windowX;
      this.lastMenuTouchWindowY = touch.windowY;
    }
  }

  private showProjectFloatingMenu(proj: ProjectRecord, windowX: number, windowY: number): void {
    this.placeFloatingMenu(windowX, windowY, this.projectFloatingMenuWidth(proj));
    this.showSessionMenuId = '';
    this.showProjectMenuId = this.showProjectMenuId === proj.id ? '' : proj.id;
  }

  private showProjectFloatingMenuFromTouch(proj: ProjectRecord): void {
    const menuWidth: number = this.projectFloatingMenuWidth(proj);
    const windowX: number = this.lastMenuTouchWindowX > 0 ? this.lastMenuTouchWindowX : menuWidth + 8;
    const windowY: number = this.lastMenuTouchWindowY > 0 ? this.lastMenuTouchWindowY : 48;
    this.showProjectFloatingMenu(proj, windowX, windowY);
    this.suppressProjectClickId = proj.id;
  }

  private showProjectFloatingMenuFromMouse(proj: ProjectRecord, event: MouseEvent): void {
    if (event.button !== MouseButton.Right || event.action !== MouseAction.Press) {
      return;
    }
    if (event.stopPropagation !== undefined) {
      event.stopPropagation();
    }
    this.showProjectFloatingMenu(proj, event.windowX, event.windowY);
    this.suppressProjectClickId = proj.id;
  }

  private showSessionFloatingMenu(item: WorkspaceItem, windowX: number, windowY: number): void {
    const sid: string = this.ensureWorkspaceBinding(item);
    this.placeFloatingMenu(windowX, windowY, this.sessionFloatingMenuWidth());
    this.showProjectMenuId = '';
    this.showSessionMenuId = this.showSessionMenuId === sid ? '' : sid;
  }

  private showSessionFloatingMenuFromTouch(item: WorkspaceItem): void {
    const menuWidth: number = this.sessionFloatingMenuWidth();
    const windowX: number = this.lastMenuTouchWindowX > 0 ? this.lastMenuTouchWindowX : menuWidth + 8;
    const windowY: number = this.lastMenuTouchWindowY > 0 ? this.lastMenuTouchWindowY : 48;
    this.showSessionFloatingMenu(item, windowX, windowY);
    this.suppressSessionClickId = this.ensureWorkspaceBinding(item);
  }

  private showSessionFloatingMenuFromMouse(item: WorkspaceItem, event: MouseEvent): void {
    if (event.button !== MouseButton.Right || event.action !== MouseAction.Press) {
      return;
    }
    if (event.stopPropagation !== undefined) {
      event.stopPropagation();
    }
    this.showSessionFloatingMenu(item, event.windowX, event.windowY);
    this.suppressSessionClickId = this.ensureWorkspaceBinding(item);
  }

  private closeFloatingMenus(): void {
    this.showProjectMenuId = '';
    this.showSessionMenuId = '';
  }

  @Builder
  private topLevelFloatingMenus() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#00000000')
        .onClick(() => {
          this.closeFloatingMenus();
        })

      if (this.showProjectMenuId.length > 0) {
        ForEach(this.projects, (proj: ProjectRecord) => {
          if (proj.id === this.showProjectMenuId) {
            this.projectFloatingMenu(proj)
          }
        }, (proj: ProjectRecord) => proj.id)
      }

      if (this.showSessionMenuId.length > 0) {
        ForEach(this.workspaces, (item: WorkspaceItem) => {
          if (this.ensureWorkspaceBinding(item) === this.showSessionMenuId) {
            this.sessionFloatingMenu(item)
          }
        }, (item: WorkspaceItem) => this.ensureWorkspaceBinding(item))
      }
    }
    .width('100%')
    .height('100%')
    .zIndex(1000)
  }

  @Builder
  private projectGroup(proj: ProjectRecord) {
      Column() {
        // Project header row
        Row() {
          Text(proj.expanded ? '▾' : '▸')
            .fontSize(13)
            .fontColor(this.themeTextSecondary())
            .width(16)

          Stack({ alignContent: Alignment.TopStart }) {
            Column()
              .width(14)
              .height(10)
              .border({ width: 1, color: '#A1A1AA' })
              .borderRadius({ bottomLeft: 2, bottomRight: 2, topLeft: 0, topRight: 2 })
            Column()
              .width(7)
              .height(3)
              .border({ width: 1, color: '#A1A1AA' })
              .borderRadius({ topLeft: 2, topRight: 2 })
              .backgroundColor(this.themePanelBackground())
              .position({ x: 0, y: -1 })
          }
          .width(14)
          .height(12)
          .margin({ right: 6 })

          Text(proj.name)
            .copyOption(CopyOptions.None)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.themeTextPrimary())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // Floating menu button (hover-visible)
          Text('···')
            .fontSize(16)
            .fontColor(this.themeTextSecondary())
            .padding({ left: 6, right: 6, top: 0, bottom: 0 })
            .height(20)
            .visibility(this.hasPointerHover && this.hoveredProjectId === proj.id ? Visibility.Visible : Visibility.Hidden)
            .onClick((event: ClickEvent) => {
              this.showProjectFloatingMenu(proj, event.windowX, event.windowY);
            })

          // New session button (plus)
          Text('+')
            .fontSize(18)
            .fontColor(this.themeTextSecondary())
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .onClick(() => {
              this.openNewSessionDialog(proj.id);
            })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(6)
        .backgroundColor(this.hoveredProjectId === proj.id ? this.themeSubtleBackground() : 'transparent')
        .scale({ x: this.hoveredProjectId === proj.id ? 1.01 : 1, y: this.hoveredProjectId === proj.id ? 1.01 : 1 })
        .animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn })
        .onHover((isHover: boolean) => {
          if (isHover) {
            this.hasPointerHover = true;
          }
          if (this.showProjectMenuId.length === 0) {
            this.hoveredProjectId = isHover ? proj.id : '';
          }
        })
        .onTouch((event: TouchEvent) => {
          this.rememberMenuTouchPosition(event);
        })
        .onMouse((event: MouseEvent) => {
          this.showProjectFloatingMenuFromMouse(proj, event);
        })
        .gesture(
          LongPressGesture({ repeat: false, duration: 500 })
            .onAction(() => {
              this.showProjectFloatingMenuFromTouch(proj);
            })
        )
        .onClick(() => {
          if (this.suppressProjectClickId === proj.id) {
            this.suppressProjectClickId = '';
            return;
          }
          this.toggleProjectExpanded(proj.id);
        })

        // Inline rename input
        if (this.renamingProjectId === proj.id) {
          Row() {
            TextInput({ text: this.renameProjectText })
              .layoutWeight(1)
              .height(28)
              .fontSize(12)
              .backgroundColor(this.themeInputBackground())
              .border({ width: 0.5, color: this.themeStrongBorder() })
              .borderRadius(6)
              .padding({ left: 8, right: 8 })
              .onChange((value: string) => {
                this.renameProjectText = value;
              })

            Button('✓')
              .type(ButtonType.Normal)
              .width(28).height(28)
              .fontSize(14).fontColor('#15803D')
              .backgroundColor('#DCFCE7').borderRadius(8)
              .margin({ left: 6 })
              .onClick(() => { this.confirmRenameProject(); })

            Button('×')
              .type(ButtonType.Normal)
              .width(28).height(28)
              .fontSize(18).fontColor('#B91C1C')
              .backgroundColor('#FEE2E2').borderRadius(8)
              .margin({ left: 4 })
              .onClick(() => { this.cancelRenameProject(); })
          }
          .width('100%')
          .padding({ left: 24, right: 8, bottom: 6 })
        }

        // Sessions under this project
        if (proj.expanded) {
          Column() {
            if (this.sessionsForProject(proj.id).length === 0) {
              Text('暂无会话')
                .fontSize(10)
                .fontColor(this.themeTextMuted())
                .padding({ left: 24, top: 4, bottom: 4 })
            } else {
              ForEach(this.sessionsForProject(proj.id), (session: WorkspaceItem) => {
                this.sessionItem(session)
              }, (session: WorkspaceItem) => `${session.id.toString()}:${session.title}`)
            }
          }
          .width('100%')
          .padding({ left: 16 })
          .transition(TransitionEffect.OPACITY.animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn }))
        }
      }
      .width('100%')
      .margin({ bottom: 4 })
  }

  @Builder
  private projectFloatingMenu(proj: ProjectRecord) {
    Column() {
        this.floatingMenuItem('重命名项目', () => {
          this.showProjectMenuId = '';
          this.openRenameProjectDialog(proj);
        })

        this.floatingMenuItem('删除项目', () => {
          this.showProjectMenuId = '';
          this.openDeleteProjectDialog(proj);
        })

        this.floatingMenuItem('复制路径', () => {
          this.showProjectMenuId = '';
          let targetPath: string = '';
          for (let i: number = 0; i < this.projects.length; i += 1) {
            if (this.projects[i].id === proj.id) {
              targetPath = this.projects[i].path;
              break;
            }
          }
          if (targetPath.length > 0) {
            this.copyPlainText(targetPath, '路径已复制');
          }
        })

        this.floatingMenuSeparator()
        this.floatingMenuSectionTitle('同步文件夹')

        if (proj.sourceUri.trim().length > 0) {
          this.floatingMenuItem(this.projectSyncMenuLabel(), () => {
            this.showProjectMenuId = '';
            void this.syncProjectToImportSource(proj);
          })

          this.floatingMenuItem('导入同步文件夹内容', () => {
            this.showProjectMenuId = '';
            void this.importProjectFromSyncFolder(proj);
          })
        }

        this.floatingMenuItem(this.projectSourceMenuLabel(proj), () => {
          this.showProjectMenuId = '';
          void this.reselectProjectImportSource(proj.id);
        })
    }
    .width(this.floatingMenuWidth)
    .padding({ top: 4, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(this.themeElevatedBackground())
    .border({ width: 0.5, color: this.themeBorder() })
    .shadow({ radius: 12, color: '#1A000000', offsetX: 0, offsetY: 4 })
    .position({ x: this.floatingMenuX, y: this.floatingMenuY })
    .zIndex(1000)
  }

  @Builder
  private floatingMenuItem(label: string, onPress: () => void) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(12)
      .fontColor(this.themeTextPrimary())
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        onPress();
      })
  }

  @Builder
  private floatingMenuSeparator() {
    Divider()
      .width('100%')
      .color(this.themeBorder())
      .strokeWidth(0.5)
      .margin({ top: 4, bottom: 4 })
  }

  @Builder
  private floatingMenuSectionTitle(label: string) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(10)
      .fontColor(this.themeTextMuted())
      .width('100%')
      .padding({ left: 12, right: 12, top: 2, bottom: 2 })
  }


  @Builder
  private sessionItem(item: WorkspaceItem) {
      Column() {
        if (this.renamingSessionId === this.ensureWorkspaceBinding(item)) {
          // Inline rename mode
          Row() {
            TextInput({ text: this.renameSessionText })
              .layoutWeight(1)
              .height(24)
              .fontSize(11)
              .backgroundColor(this.themeInputBackground())
              .border({ width: 0.5, color: this.themeStrongBorder() })
              .borderRadius(4)
              .padding({ left: 6, right: 6 })
              .onChange((value: string) => {
                this.renameSessionText = value;
              })

            Button('✓')
              .type(ButtonType.Normal)
              .width(26).height(26)
              .fontSize(13).fontColor('#15803D')
              .backgroundColor('#DCFCE7').borderRadius(7)
              .margin({ left: 4 })
              .onClick(() => { this.confirmRenameSession(); })

            Button('×')
              .type(ButtonType.Normal)
              .width(26).height(26)
              .fontSize(17).fontColor('#B91C1C')
              .backgroundColor('#FEE2E2').borderRadius(7)
              .margin({ left: 4 })
              .onClick(() => { this.cancelRenameSession(); })
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        } else {
          // Normal session display
          Row() {
            Text(item.title)
              .copyOption(CopyOptions.None)
              .fontSize(11)
              .fontWeight(this.isWorkspaceActive(item) ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.isWorkspaceActive(item) ? this.themeTextPrimary() : this.themeTextSecondary())
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (this.isWorkspaceRunning(item.id)) {
              Row() {
                Circle({ width: 5, height: 5 })
                  .fill('#22C55E')

                Text('运行中')
                  .copyOption(CopyOptions.None)
                  .fontSize(10)
                  .fontColor('#15803D')
                  .margin({ left: 4 })
              }
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor('#DCFCE7')
              .borderRadius(8)
              .margin({ right: 4 })
            }

            Text(this.relativeTime(this.findSessionUpdatedAt(item)))
              .fontSize(10)
              .fontColor(this.themeTextMuted())
              .margin({ right: 4 })

            Text('···')
              .fontSize(16)
              .fontColor(this.themeTextSecondary())
              .padding({ left: 2, right: 2 })
              .visibility(this.hasPointerHover && this.hoveredSessionId === this.ensureWorkspaceBinding(item) ? Visibility.Visible : Visibility.Hidden)
              .onClick((event: ClickEvent) => {
                this.showSessionFloatingMenu(item, event.windowX, event.windowY);
              })
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .borderRadius(6)
          .backgroundColor(this.isWorkspaceActive(item) ? this.themeSubtleBackground() : (this.hoveredSessionId === this.ensureWorkspaceBinding(item) ? this.themePanelBackground() : 'transparent'))
          .scale({ x: this.isWorkspaceActive(item) || this.hoveredSessionId === this.ensureWorkspaceBinding(item) ? 1.01 : 1, y: this.isWorkspaceActive(item) || this.hoveredSessionId === this.ensureWorkspaceBinding(item) ? 1.01 : 1 })
          .animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn })
          .onTouch((event: TouchEvent) => {
            this.rememberMenuTouchPosition(event);
          })
          .onMouse((event: MouseEvent) => {
            this.showSessionFloatingMenuFromMouse(item, event);
          })
          .gesture(
            LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => {
                this.showSessionFloatingMenuFromTouch(item);
              })
          )
          .onClick(() => {
            const sid: string = this.ensureWorkspaceBinding(item);
            if (this.suppressSessionClickId === sid) {
              this.suppressSessionClickId = '';
              return;
            }
            void this.selectWorkspace(item);
          })
        }
      }
        .width('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .onHover((isHover: boolean) => {
          if (isHover) {
            this.hasPointerHover = true;
          }
          if (this.showSessionMenuId.length === 0) {
            this.hoveredSessionId = isHover ? this.ensureWorkspaceBinding(item) : '';
          }
        })
  }

  @Builder
  private sessionFloatingMenu(item: WorkspaceItem) {
    Column() {
        this.floatingMenuItem('重命名会话', () => {
          this.showSessionMenuId = '';
          this.openRenameSessionDialog(item);
        })

        this.floatingMenuItem('删除会话', () => {
          this.showSessionMenuId = '';
          this.openDeleteSessionDialog(item);
        })
    }
    .width(this.floatingMenuWidth)
    .padding({ top: 4, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(this.themeElevatedBackground())
    .border({ width: 0.5, color: this.themeBorder() })
    .shadow({ radius: 12, color: '#1A000000', offsetX: 0, offsetY: 4 })
    .position({ x: this.floatingMenuX, y: this.floatingMenuY })
    .zIndex(1000)
  }

  private findSessionUpdatedAt(item: WorkspaceItem): string {
    const summaries: SessionSummary[] = codexBackend.sessionSummaries();
    const sessionId: string = this.ensureWorkspaceBinding(item);
    for (let i: number = 0; i < summaries.length; i += 1) {
      if (summaries[i].sessionId === sessionId) {
        return summaries[i].lastUpdatedAt;
      }
    }
    return '';
  }


  @Builder
  private infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(10)
        .fontColor(this.themeTextMuted())
        .width(78)

      Text(value)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(11)
        .fontColor(this.themeTextStrong())
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ top: 8 })
  }



  @Builder
  private markdownModeChip(label: string) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(9)
      .fontColor(this.themeTextSecondary())
      .padding({ left: 7, right: 7, top: 3, bottom: 3 })
      .backgroundColor(this.themeSubtleBackground())
      .border({ width: 0.5, color: this.themeBorder() })
      .borderRadius(6)
  }

  @Builder
  private messageBody(item: ChatMessage) {
    if (item.status === 'inProgress' && item.content.trim().length === 0) {
      Text(this.emptyMessageBodyText(item))
        .copyOption(CopyOptions.None)
        .fontSize(this.conversationFontSize(12))
        .lineHeight(this.conversationLineHeight(19))
        .fontColor(this.messageContentColor(item.itemType ?? item.role))
        .fontWeight(FontWeight.Medium)
        .margin({ top: 6 })
    } else if (this.isMessageCollapsed(item)) {
      if (this.hasHtmlFileLinkContent(this.collapsedMessagePreview(item))) {
        Column() {
          Text() {
            ForEach(this.htmlTextRuns(this.collapsedMessagePreview(item), `${item.id}:collapsed-html-runs`), (run: HtmlTextRun) => {
              Span(run.text)
                .fontSize(this.conversationFontSize(12))
                .fontColor(run.isLink ? '#2563EB' : this.messageContentColor(item.itemType ?? item.role))
                .fontWeight(run.isLink ? FontWeight.Medium : FontWeight.Regular)
                .decoration(run.isLink ? { type: TextDecorationType.Underline, color: '#93C5FD' } : { type: TextDecorationType.None, color: 'transparent' })
            }, (run: HtmlTextRun) => run.id)
          }
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(this.conversationFontSize(12))
            .lineHeight(this.conversationLineHeight(19))
            .fontColor(this.messageContentColor(item.itemType ?? item.role))
            .wordBreak(WordBreak.BREAK_WORD)
            .margin({ top: 6 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => {
              this.toggleMessageExpanded(item.id);
            })
          Text('点击展开完整输出')
            .copyOption(CopyOptions.None)
            .fontSize(this.conversationFontSize(10))
            .fontColor(this.accentBorderColor(item.itemType ?? item.role))
            .margin({ top: 4 })
            .onClick(() => {
              this.toggleMessageExpanded(item.id);
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      } else {
        Text(this.collapsedMessagePreview(item))
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(this.conversationFontSize(12))
          .lineHeight(this.conversationLineHeight(19))
          .fontColor(this.messageContentColor(item.itemType ?? item.role))
          .wordBreak(WordBreak.BREAK_WORD)
          .margin({ top: 6 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => {
            this.toggleMessageExpanded(item.id);
          })
      }
    } else if (item.content.trim().length === 0) {
      Text(this.emptyMessageBodyText(item))
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.conversationFontSize(12))
        .lineHeight(this.conversationLineHeight(19))
        .fontColor(this.messageContentColor(item.itemType ?? item.role))
        .wordBreak(WordBreak.BREAK_WORD)
        .margin({ top: 6 })
    } else if (this.isMessageSelectableMode(item.id) && this.shouldShowMessageSelectableAction(item)) {
      Text(this.messageOriginalText(item.content))
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.conversationFontSize(12))
        .lineHeight(this.conversationLineHeight(19))
        .fontColor(this.messageContentColor(item.itemType ?? item.role))
        .width('100%')
        .wordBreak(WordBreak.BREAK_WORD)
        .padding({ left: 10, right: 10, top: 9, bottom: 9 })
        .margin({ top: 6 })
        .backgroundColor(this.themePanelBackground())
        .border({ width: 0.5, color: this.themeStrongBorder() })
        .borderRadius(8)
    } else if (this.isStreamingAssistantMessage(item)) {
      Text(item.content)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.conversationFontSize(12))
        .lineHeight(this.conversationLineHeight(19))
        .fontColor(this.messageContentColor(item.itemType ?? item.role))
        .wordBreak(WordBreak.BREAK_WORD)
        .margin({ top: 6 })
    } else if (this.hasHtmlFileLinkContent(item.content)) {
      this.htmlFileMessageBody(item)
    } else if (!this.shouldRenderMarkdown(item.content)) {
      Text(item.content)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.conversationFontSize(12))
        .lineHeight(this.conversationLineHeight(19))
        .fontColor(this.messageContentColor(item.itemType ?? item.role))
        .wordBreak(WordBreak.BREAK_WORD)
        .margin({ top: 6 })
    } else if (!this.hasRenderedOrCodeMarkdownSurface(item.content)) {
      this.plainMarkdownTextBody(item)
    } else if (this.shouldRenderInlineOnlyMarkdown(item.content)) {
      this.inlineMessageMarkdownBody(item)
    } else {
      this.markdownRenderedBody(item)
    }
  }

  @Builder
  private plainMarkdownTextBody(item: ChatMessage) {
    Text() {
      ForEach(this.plainMarkdownTextRuns(item.content, item.id), (run: MarkdownTextRun) => {
        Span(run.text)
          .fontColor(this.plainMarkdownRunColor(run, item.itemType ?? item.role))
          .fontSize(this.plainMarkdownRunFontSize(run))
          .fontWeight(this.plainMarkdownRunWeight(run))
      }, (run: MarkdownTextRun) => run.id)
    }
    .copyOption(CopyOptions.LocalDevice)
    .fontSize(this.conversationFontSize(12))
    .lineHeight(this.conversationLineHeight(19))
    .fontColor(this.messageContentColor(item.itemType ?? item.role))
    .width('100%')
    .wordBreak(WordBreak.BREAK_WORD)
    .margin({ top: 6 })
  }

  @Builder
  private inlineMessageMarkdownBody(item: ChatMessage) {
    this.inlineMarkdownLine(`${item.id}:inline`, item.content.trim(), this.messageContentColor(item.itemType ?? item.role), this.conversationFontSize(12), this.conversationLineHeight(19), undefined, 6, item.id)
  }

  @Builder
  private htmlFileMessageBody(item: ChatMessage) {
    Column() {
      Text() {
        ForEach(this.htmlTextRuns(item.content, `${item.id}:html-runs`), (run: HtmlTextRun) => {
          Span(run.text)
            .fontSize(this.conversationFontSize(12))
            .fontColor(run.isLink ? '#2563EB' : this.messageContentColor(item.itemType ?? item.role))
            .fontWeight(run.isLink ? FontWeight.Medium : FontWeight.Regular)
            .decoration(run.isLink ? { type: TextDecorationType.Underline, color: '#93C5FD' } : { type: TextDecorationType.None, color: 'transparent' })
        }, (run: HtmlTextRun) => run.id)
      }
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.conversationFontSize(12))
        .lineHeight(this.conversationLineHeight(19))
        .fontColor(this.messageContentColor(item.itemType ?? item.role))
        .wordBreak(WordBreak.BREAK_WORD)
        .margin({ top: 6 })
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.openFirstHtmlFileLinkContent(item.content, item.id);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private markdownRenderedBody(item: ChatMessage) {
    Column() {
      ForEach(this.markdownBlocks(item.content), (block: MarkdownBlock) => {
        this.markdownBlock(item.id, block)
      }, (block: MarkdownBlock) => block.id)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 6 })
  }

  @Builder
  private markdownBlock(messageId: string, block: MarkdownBlock) {
    if (block.kind === 'heading') {
      Column() {
        this.inlineMarkdownContent(
          messageId,
          block.id,
          block.text,
          this.themeTextStrong(),
          this.markdownHeadingFontSize(block.level),
          this.markdownHeadingLineHeight(block.level),
          FontWeight.Medium
        )
      }
      .width('100%')
      .margin({ top: 6, bottom: 4 })
    } else if (block.kind === 'quote') {
      Row() {
        Column()
          .width(3)
          .height('100%')
          .backgroundColor(this.themeStrongBorder())
          .borderRadius(2)
          .margin({ right: 9 })
        this.inlineMarkdownContent(messageId, block.id, block.text, this.themeTextSecondary())
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ top: 7, bottom: 7, right: 8 })
      .backgroundColor(this.themePanelBackground())
      .borderRadius(8)
      .margin({ top: 5, bottom: 5 })
    } else if (block.kind === 'list') {
      Column() {
        ForEach(block.text.split('\n'), (line: string, index: number) => {
          Row() {
            Text(this.markdownListMarker(line))
              .copyOption(CopyOptions.None)
              .fontSize(this.conversationFontSize(12))
              .fontColor(this.themeTextSecondary())
              .width(24)
            Column() {
              this.inlineMarkdownContent(messageId, `${block.id}-${index}`, this.markdownListText(line), this.themeTextPrimary())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ top: index === 0 ? 0 : 3 })
        })
      }
      .width('100%')
      .margin({ top: 4, bottom: 4 })
    } else if (block.kind === 'code') {
      this.codeBlock(block)
    } else if (block.kind === 'math') {
      this.mathBlock(block)
    } else if (block.kind === 'mermaid') {
      this.mermaidBlock(messageId, block)
    } else if (block.kind === 'table') {
      this.markdownTable(messageId, block)
    } else if (block.kind === 'divider') {
      Column()
        .width('100%')
        .height(1)
        .backgroundColor(this.themeBorder())
        .margin({ top: 8, bottom: 8 })
    } else {
      this.inlineMarkdownContent(messageId, block.id, block.text, this.themeTextPrimary())
    }
  }

  @Builder
  private markdownTable(messageId: string, block: MarkdownBlock) {
    Column() {
      ForEach(block.rows, (row: string[], rowIndex: number) => {
        Row() {
          ForEach(row, (cell: string, cellIndex?: number) => {
            Column() {
              this.inlineMarkdownContent(
                messageId,
                `${block.id}:r${rowIndex}:c${cellIndex ?? 0}`,
                cell,
                rowIndex === 0 ? this.themeTextStrong() : this.themeTextPrimary(),
                this.conversationFontSize(10),
                this.conversationLineHeight(16),
                rowIndex === 0 ? FontWeight.Medium : FontWeight.Regular
              )
            }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .padding({ left: 7, right: 7, top: 6, bottom: 6 })
          }, (cell: string, cellIndex?: number) => `${rowIndex}:${cellIndex ?? 0}`)
        }
        .width('100%')
        .backgroundColor(rowIndex === 0 ? this.themeSubtleBackground() : this.themeElevatedBackground())
        .border({ width: 0.5, color: this.themeBorder() })
      })
    }
    .width('100%')
    .borderRadius(8)
    .margin({ top: 5, bottom: 5 })
  }

  @Builder
  private codeBlock(block: MarkdownBlock) {
    Column() {
      Row() {
        Text(block.language.length > 0 ? block.language : 'text')
          .copyOption(CopyOptions.None)
          .fontSize(9)
          .fontColor('#0369A1')
          .fontWeight(FontWeight.Medium)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor('#E0F2FE')
          .borderRadius(6)
        Blank()
          .layoutWeight(1)
        this.iconCopyButton(() => {
          this.copyPlainText(block.text, '代码已复制');
        })
      }
      .width('100%')
      .margin({ bottom: 6 })

      Column() {
        this.highlightedCodeLines(block.text, block.language, `${block.id}:code`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .backgroundColor(this.themeInputBackground())
    .border({ width: 0.5, color: this.themeStrongBorder() })
    .borderRadius(8)
    .margin({ top: 5, bottom: 5 })
  }

  @Builder
  private highlightedCodeLines(text: string, language: string, baseId: string) {
    Text() {
      ForEach(this.codeBlockLines(text), (line: string, lineIndex: number) => {
        ForEach(this.codeLineTokens(line, language, `${baseId}:${lineIndex}`), (token: CodeToken) => {
          Span(token.text)
            .fontColor(this.codeTokenColor(token.kind))
            .fontWeight(this.codeTokenWeight(token.kind))
        }, (token: CodeToken) => token.id)
        if (lineIndex < this.codeBlockLines(text).length - 1) {
          Span('\n')
            .fontColor(this.themeTextStrong())
        }
      }, (line: string, lineIndex: number) => `${lineIndex}:${line}`)
    }
    .copyOption(CopyOptions.LocalDevice)
    .fontSize(this.conversationFontSize(11))
    .lineHeight(this.conversationLineHeight(18))
    .fontFamily('monospace')
    .width('100%')
  }

  @Builder
  private inlineMarkdownContent(messageId: string, blockId: string, text: string, color: string, fontSize?: number, lineHeight?: number, weight?: FontWeight) {
    Column() {
      ForEach(text.split('\n'), (line: string, lineIndex: number) => {
        if (line.length === 0) {
          Blank()
            .width('100%')
            .height(8)
        } else {
          this.inlineMarkdownLine(
            `${messageId}:${blockId}:${lineIndex}`,
            line,
            color,
            fontSize ?? this.conversationFontSize(12),
            lineHeight ?? this.conversationLineHeight(19),
            weight,
            lineIndex === 0 ? 0 : 2,
            messageId
          )
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private inlineMathFlowSegment(segment: MathSegment, color: string, fontSize: number, lineHeight: number, weight?: FontWeight) {
    if (segment.kind === 'code') {
      Text(segment.text)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(Math.max(fontSize - this.conversationFontSize(1), this.conversationFontSize(10)))
        .lineHeight(lineHeight)
        .fontFamily('monospace')
        .fontColor(this.themeTextStrong())
        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
        .margin({ left: 2, right: 2, bottom: 2 })
        .backgroundColor(this.themeSubtleBackground())
        .border({ width: 0.5, color: this.themeBorder() })
        .borderRadius(4)
    } else {
      Text(segment.text)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(fontSize)
        .lineHeight(lineHeight)
        .fontColor(segment.kind === 'link' ? '#2563EB' : color)
        .fontWeight(segment.kind === 'strong' ? FontWeight.Medium : (weight ?? FontWeight.Regular))
        .margin({ bottom: 2 })
    }
  }

  @Builder
  private inlineMarkdownLine(baseId: string, text: string, color: string, fontSize: number, lineHeight: number, weight: FontWeight | undefined, topMargin: number, sourceMessageId?: string) {
    if (this.hasInlineMathText(text)) {
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
        ForEach(this.inlineMarkdownSegments(text, baseId), (segment: MathSegment) => {
          if (segment.kind === 'math') {
            this.inlineMathSegment(segment, fontSize, lineHeight)
          } else {
            this.inlineMathFlowSegment(segment, color, fontSize, lineHeight, weight)
          }
        }, (segment: MathSegment) => segment.id)
      }
      .width('100%')
      .margin({ top: topMargin })
    } else {
      this.inlineMarkdownTextLine(this.inlineMarkdownSegments(text, baseId), color, fontSize, lineHeight, weight, topMargin, sourceMessageId)
    }
  }

  @Builder
  private inlineMarkdownTextLine(segments: MathSegment[], color: string, fontSize: number, lineHeight: number, weight: FontWeight | undefined, topMargin: number, sourceMessageId?: string) {
    if (this.hasInlineLinkSegment(segments)) {
      Text() {
        ForEach(segments, (segment: MathSegment) => {
          if (segment.kind === 'code') {
            Span(this.inlineCodeSpanText(segment.text))
              .fontSize(Math.max(fontSize - this.conversationFontSize(1), this.conversationFontSize(10)))
              .fontColor(this.themeTextStrong())
              .fontWeight(FontWeight.Medium)
          } else {
            Span(segment.text)
              .fontSize(fontSize)
              .fontColor(segment.kind === 'link' ? '#2563EB' : color)
              .fontWeight(segment.kind === 'strong' || segment.kind === 'link' ? FontWeight.Medium : (weight ?? FontWeight.Regular))
          }
        }, (segment: MathSegment) => segment.id)
      }
      .copyOption(CopyOptions.LocalDevice)
      .fontSize(fontSize)
      .lineHeight(lineHeight)
      .width('100%')
      .wordBreak(WordBreak.BREAK_WORD)
      .margin({ top: topMargin })
      .onClick(() => {
        this.openFirstInlineLinkSegment(segments, sourceMessageId);
      })
    } else {
      Text() {
        ForEach(segments, (segment: MathSegment) => {
          if (segment.kind === 'code') {
            Span(this.inlineCodeSpanText(segment.text))
              .fontSize(Math.max(fontSize - this.conversationFontSize(1), this.conversationFontSize(10)))
              .fontColor(this.themeTextStrong())
              .fontWeight(FontWeight.Medium)
          } else {
            Span(segment.text)
              .fontSize(fontSize)
              .fontColor(color)
              .fontWeight(segment.kind === 'strong' ? FontWeight.Medium : (weight ?? FontWeight.Regular))
          }
        }, (segment: MathSegment) => segment.id)
      }
      .copyOption(CopyOptions.LocalDevice)
      .fontSize(fontSize)
      .lineHeight(lineHeight)
      .width('100%')
      .wordBreak(WordBreak.BREAK_WORD)
      .margin({ top: topMargin })
    }
  }

  private hasInlineMathSegment(segments: MathSegment[]): boolean {
    for (let index: number = 0; index < segments.length; index += 1) {
      if (segments[index].kind === 'math') {
        return true;
      }
    }
    return false;
  }

  private hasInlineMathText(text: string): boolean {
    return this.hasInlineMathSegment(this.inlineMarkdownSegments(text, 'inline-math-probe'));
  }

  private hasInlineLinkSegment(segments: MathSegment[]): boolean {
    for (let index: number = 0; index < segments.length; index += 1) {
      if (segments[index].kind === 'link') {
        return true;
      }
    }
    return false;
  }

  private hasHtmlFileLinkContent(content: string): boolean {
    return this.htmlFileLinkSegments(content, 'html-probe').length > 0;
  }

  private htmlFileLinkSegments(content: string, baseId: string): MathSegment[] {
    const sourceSegments: MathSegment[] = this.inlineMarkdownSegments(content, `${baseId}:source`);
    const result: MathSegment[] = [];
    for (let index: number = 0; index < sourceSegments.length; index += 1) {
      const segment: MathSegment = sourceSegments[index];
      if (segment.kind === 'link' && this.isHtmlFileTarget(segment.target)) {
        result.push(new MathSegment(`${baseId}:html:${result.length.toString()}`, 'link', segment.text, segment.rawText, segment.target));
      }
    }
    return result;
  }

  private htmlTextRuns(content: string, baseId: string): HtmlTextRun[] {
    const sourceSegments: MathSegment[] = this.inlineMarkdownSegments(content, `${baseId}:source`);
    const result: HtmlTextRun[] = [];
    let serial: number = 0;
    for (let index: number = 0; index < sourceSegments.length; index += 1) {
      const segment: MathSegment = sourceSegments[index];
      const isHtmlLink: boolean = segment.kind === 'link' && this.isHtmlFileTarget(segment.target);
      result.push(new HtmlTextRun(`${baseId}:run:${serial.toString()}`, segment.text, isHtmlLink));
      serial += 1;
    }
    if (result.length === 0) {
      result.push(new HtmlTextRun(`${baseId}:run:0`, content, false));
    }
    return result;
  }

  private openFirstHtmlFileLinkContent(content: string, sourceMessageId?: string): void {
    const segments: MathSegment[] = this.htmlFileLinkSegments(content, 'html-open');
    if (segments.length > 0) {
      this.openWebTarget(segments[0].target, segments[0].text, sourceMessageId);
    }
  }

  private firstInlineLinkSegment(segments: MathSegment[]): MathSegment | null {
    for (let index: number = 0; index < segments.length; index += 1) {
      if (segments[index].kind === 'link') {
        return segments[index];
      }
    }
    return null;
  }

  private openFirstInlineLinkSegment(segments: MathSegment[], sourceMessageId?: string): void {
    const linkSegment: MathSegment | null = this.firstInlineLinkSegment(segments);
    if (linkSegment !== null) {
      this.openWebTarget(linkSegment.target, linkSegment.text, sourceMessageId);
    }
  }

  private inlineCodeSpanText(text: string): string {
    return ` ${text} `;
  }

  @Builder
  private inlineMathSegment(segment: MathSegment, fontSize: number, lineHeight: number) {
    Row() {
      this.formulaInlineContent(segment.rawText, fontSize)
    }
    .padding({ left: 5, right: 5, top: 2, bottom: 2 })
    .margin({ right: 4, bottom: 2 })
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.themeStrongBorder() })
    .borderRadius(6)
  }

  @Builder
  private formulaInlineContent(source: string, fontSize: number) {
    Row() {
      this.formulaNode(this.parseFormula(source), Math.max(fontSize + this.conversationFontSize(1), this.conversationFontSize(13)), this.themeTextStrong(), false)
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private formulaBlockContent(source: string) {
    Column() {
      ForEach(this.mathBlockLines(source), (line: string, lineIndex?: number) => {
        Row() {
          this.formulaNode(this.parseFormula(line), this.conversationFontSize(19), this.themeTextStrong(), true)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: (lineIndex ?? 0) === 0 ? 0 : 6 })
      }, (line: string, lineIndex?: number) => `${lineIndex ?? 0}:${line}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private formulaNode(node: FormulaNode, fontSize: number, color: string, displayStyle: boolean = false) {
    if (node.kind === 'sequence') {
      Row() {
        ForEach(node.children, (child: FormulaNode, childIndex?: number) => {
          this.formulaNode(child, fontSize, color, displayStyle)
        }, (child: FormulaNode, childIndex?: number) => `${child.kind}:${childIndex ?? 0}:${child.text}`)
      }
      .alignItems(VerticalAlign.Center)
    } else if (node.kind === 'group' && node.children.length > 0) {
      Row() {
        Text(node.text.length > 0 ? node.text.charAt(0) : '(')
          .copyOption(CopyOptions.None)
          .fontSize(this.formulaGroupDelimiterFontSize(node, fontSize))
          .lineHeight(this.formulaGroupDelimiterFontSize(node, fontSize) + 6)
          .fontColor(color)
          .fontWeight(FontWeight.Medium)

        this.formulaNode(node.children[0], fontSize, color, displayStyle)

        Text(node.text.length > 1 ? node.text.charAt(1) : ')')
          .copyOption(CopyOptions.None)
          .fontSize(this.formulaGroupDelimiterFontSize(node, fontSize))
          .lineHeight(this.formulaGroupDelimiterFontSize(node, fontSize) + 6)
          .fontColor(color)
          .fontWeight(FontWeight.Medium)
      }
      .alignItems(VerticalAlign.Center)
    } else if (node.kind === 'fraction' && node.numerator !== null && node.denominator !== null) {
      Column() {
        Row() {
          this.formulaNode(node.numerator, Math.max(fontSize - 2, 11), color, displayStyle)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 2 })

        Column()
          .width('100%')
          .height(1)
          .backgroundColor(color)

        Row() {
          this.formulaNode(node.denominator, Math.max(fontSize - 2, 11), color, displayStyle)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 2 })
      }
      .width(this.formulaFractionWidth(node, fontSize))
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 3, right: 3 })
    } else if (node.kind === 'sqrt' && node.radicand !== null) {
      Row() {
        Text('√')
          .copyOption(CopyOptions.None)
          .fontSize(fontSize + 2)
          .lineHeight(fontSize + 6)
          .fontColor(color)
          .fontWeight(FontWeight.Medium)

        Column() {
          Column()
            .width('100%')
            .height(1)
            .backgroundColor(color)
            .margin({ bottom: 1 })

          this.formulaNode(node.radicand, Math.max(fontSize - 1, 11), color, displayStyle)
        }
        .width(this.formulaRadicandWidth(node, fontSize))
        .padding({ left: 3, right: 3, top: 2 })
      }
      .alignItems(VerticalAlign.Bottom)
    } else if (node.kind === 'script' && node.base !== null) {
      if (displayStyle && this.isFormulaLimitOperatorNode(node.base)) {
        Column() {
          if (node.superscript !== null) {
            Row() {
              this.formulaNode(node.superscript, this.formulaLimitFontSize(fontSize), color, false)
            }
            .justifyContent(FlexAlign.Center)
            .margin({ bottom: 1 })
          }

          Row() {
            this.formulaNode(node.base, this.formulaLimitOperatorFontSize(fontSize), color, false)
          }
          .justifyContent(FlexAlign.Center)

          if (node.subscript !== null) {
            Row() {
              this.formulaNode(node.subscript, this.formulaLimitFontSize(fontSize), color, false)
            }
            .justifyContent(FlexAlign.Center)
            .margin({ top: 1 })
          }
        }
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 2, right: 2 })
      } else {
        Row() {
          this.formulaNode(node.base, fontSize, color, displayStyle)

          Column() {
            if (node.superscript !== null) {
              this.formulaNode(node.superscript, Math.max(fontSize - 5, 9), color, false)
            }
            if (node.subscript !== null) {
              this.formulaNode(node.subscript, Math.max(fontSize - 5, 9), color, false)
            }
          }
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(VerticalAlign.Top)
      }
    } else if (node.kind === 'space') {
      Blank()
        .width(this.formulaSpacingWidth(node.text, fontSize))
        .height(1)
    } else {
      Text(node.text)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(fontSize)
        .lineHeight(fontSize + 6)
        .fontColor(color)
        .fontStyle(this.formulaFontStyle(node))
        .fontWeight(FontWeight.Regular)
    }
  }

  @Builder
  private mathBlock(block: MarkdownBlock) {
    Column() {
      this.formulaBlockContent(block.rawText)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 9, bottom: 10 })
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.eventBorderColor('tool') })
    .borderRadius(8)
    .margin({ top: 5, bottom: 5 })
  }

  private formulaFractionWidth(node: FormulaNode, fontSize: number): number {
    if (node.numerator === null || node.denominator === null) {
      return Math.max(fontSize * 2, 26);
    }
    const numeratorWidth: number = this.formulaNodeApproxWidth(node.numerator, Math.max(fontSize - 2, 11));
    const denominatorWidth: number = this.formulaNodeApproxWidth(node.denominator, Math.max(fontSize - 2, 11));
    return Math.min(Math.max(Math.max(numeratorWidth, denominatorWidth) + 12, fontSize * 1.8), 360);
  }

  private formulaRadicandWidth(node: FormulaNode, fontSize: number): number {
    if (node.radicand === null) {
      return Math.max(fontSize * 2, 26);
    }
    return Math.min(Math.max(this.formulaNodeApproxWidth(node.radicand, Math.max(fontSize - 1, 11)) + 8, fontSize * 1.8), 340);
  }

  private formulaGroupDelimiterFontSize(node: FormulaNode, fontSize: number): number {
    if (node.children.length === 0) {
      return fontSize;
    }
    return this.formulaNeedsTallDelimiter(node.children[0]) ? fontSize + 4 : fontSize;
  }

  private formulaLimitFontSize(fontSize: number): number {
    return Math.max(fontSize - 6, 10);
  }

  private formulaLimitOperatorFontSize(fontSize: number): number {
    return fontSize + 3;
  }

  private formulaNodeApproxWidth(node: FormulaNode, fontSize: number): number {
    if (node.kind === 'sequence') {
      let width: number = 0;
      for (let i = 0; i < node.children.length; i++) {
        width += this.formulaNodeApproxWidth(node.children[i], fontSize);
      }
      return Math.max(width, fontSize);
    }
    if (node.kind === 'group' && node.children.length > 0) {
      return this.formulaNodeApproxWidth(node.children[0], fontSize) + fontSize;
    }
    if (node.kind === 'fraction' && node.numerator !== null && node.denominator !== null) {
      return this.formulaFractionWidth(node, fontSize);
    }
    if (node.kind === 'sqrt' && node.radicand !== null) {
      return this.formulaRadicandWidth(node, fontSize) + fontSize;
    }
    if (node.kind === 'script' && node.base !== null) {
      if (this.isFormulaLimitOperatorNode(node.base)) {
        const operatorWidth: number = this.formulaNodeApproxWidth(node.base, fontSize + 3);
        const supWidth: number = node.superscript === null ? 0 : this.formulaNodeApproxWidth(node.superscript, Math.max(fontSize - 6, 10));
        const subWidth: number = node.subscript === null ? 0 : this.formulaNodeApproxWidth(node.subscript, Math.max(fontSize - 6, 10));
        return Math.max(operatorWidth, Math.max(supWidth, subWidth)) + 4;
      }
      const baseWidth: number = this.formulaNodeApproxWidth(node.base, fontSize);
      const supWidth: number = node.superscript === null ? 0 : this.formulaNodeApproxWidth(node.superscript, Math.max(fontSize - 5, 9));
      const subWidth: number = node.subscript === null ? 0 : this.formulaNodeApproxWidth(node.subscript, Math.max(fontSize - 5, 9));
      return baseWidth + Math.max(supWidth, subWidth);
    }
    if (node.kind === 'space') {
      return this.formulaSpacingWidth(node.text, fontSize);
    }
    return this.formulaTextApproxWidth(node.text, fontSize);
  }

  private formulaNeedsTallDelimiter(node: FormulaNode): boolean {
    if (node.kind === 'fraction' || node.kind === 'sqrt') {
      return true;
    }
    if (node.kind === 'script' && node.base !== null && this.isFormulaLimitOperatorNode(node.base)) {
      return true;
    }
    if (node.kind === 'group' && node.children.length > 0) {
      return this.formulaNeedsTallDelimiter(node.children[0]);
    }
    if (node.kind === 'sequence') {
      for (let i = 0; i < node.children.length; i++) {
        if (this.formulaNeedsTallDelimiter(node.children[i])) {
          return true;
        }
      }
    }
    return false;
  }

  private isFormulaLimitOperatorNode(node: FormulaNode): boolean {
    return node.kind === 'operator' &&
      (node.text === '∑' ||
        node.text === '∏' ||
        node.text === '∫' ||
        node.text === '∮' ||
        node.text === 'lim' ||
        node.text === 'limsup' ||
        node.text === 'liminf' ||
        node.text === 'sup' ||
        node.text === 'inf' ||
        node.text === 'argmax' ||
        node.text === 'argmin');
  }

  private formulaSpacingWidth(command: string, fontSize: number): number {
    switch (command) {
      case 'qquad': return fontSize * 2;
      case 'quad': return fontSize;
      case ';': return fontSize * 0.35;
      case ':': return fontSize * 0.28;
      case ',': return fontSize * 0.18;
      default: return fontSize * 0.35;
    }
  }

  private formulaTextApproxWidth(text: string, fontSize: number): number {
    let width: number = 0;
    for (let i = 0; i < text.length; i++) {
      width += text[i] === ' ' ? fontSize * 0.35 : fontSize * 0.58;
    }
    return Math.max(width, fontSize * 0.6);
  }

  private formulaFontStyle(node: FormulaNode): FontStyle {
    return node.variant === 'italic' ? FontStyle.Italic : FontStyle.Normal;
  }

  @Builder
  private mermaidBlock(messageId: string, block: MarkdownBlock) {
    Column() {
      Row() {
        Text('Mermaid')
          .copyOption(CopyOptions.None)
          .fontSize(9)
          .fontColor('#2563EB')
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor(this.eventSoftBackground('tool'))
          .borderRadius(6)

        Blank()
          .layoutWeight(1)

        this.mermaidZoomIconButton('out', this.isMermaidScaleAtMin(this.mermaidScaleKey(messageId, block)), () => {
          this.adjustMermaidScale(this.mermaidScaleKey(messageId, block), -1);
        })

        Blank()
          .width(4)

        this.mermaidZoomIconButton('in', this.isMermaidScaleAtMax(this.mermaidScaleKey(messageId, block)), () => {
          this.adjustMermaidScale(this.mermaidScaleKey(messageId, block), 1);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 7 })

      MermaidWebDiagram({
        source: block.text,
        diagramHeight: this.mermaidDiagramHeight(block.text, this.mermaidScale(this.mermaidScaleKey(messageId, block))),
        fontScale: this.mermaidScale(this.mermaidScaleKey(messageId, block))
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 9, bottom: 10 })
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.eventBorderColor('tool') })
    .borderRadius(8)
    .margin({ top: 5, bottom: 5 })
  }

  @Builder
  private turnActivityLine() {
    Row() {
      this.turnActivityBlock()
      Blank()
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 8 })
  }

  @Builder
  private turnActivityBlock() {
    Column() {
      Row() {
        Row() {
          Text(this.isTurnActivityCollapsed ? '\u203A' : '\u2304')
            .copyOption(CopyOptions.None)
            .fontSize(16)
            .fontColor(this.accentBorderColor('reasoning'))
        }
        .width(20)
        .height(20)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.eventSoftBackground('reasoning'))
        .border({ width: 0.5, color: this.eventBorderColor('reasoning') })
          .borderRadius(6)
          .margin({ right: 8 })

        Text(this.messageIcon('reasoning'))
          .copyOption(CopyOptions.None)
          .fontSize(this.conversationFontSize(12))
          .fontColor(this.accentBorderColor('reasoning'))
          .fontWeight(FontWeight.Medium)
          .width(22)

        Text('思考')
          .copyOption(CopyOptions.None)
          .fontSize(this.conversationFontSize(12))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentBorderColor('reasoning'))

        Text('刚刚')
          .copyOption(CopyOptions.None)
          .fontSize(10)
          .fontColor(this.themeTextMuted())
          .margin({ left: 8 })

        Text('进行中')
          .copyOption(CopyOptions.None)
          .fontSize(10)
          .fontColor(this.statusColor('inProgress'))
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(this.statusBgColor('inProgress'))
          .borderRadius(6)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => {
        this.toggleTurnActivityExpanded();
      })

      if (this.isTurnActivityCollapsed) {
        Text(this.thinkingStatusText())
          .copyOption(CopyOptions.None)
          .fontSize(this.conversationFontSize(11))
          .fontColor(this.accentBorderColor('reasoning'))
          .lineHeight(this.conversationLineHeight(17))
          .width('100%')
          .margin({ top: 6, left: 28 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => {
            this.toggleTurnActivityExpanded();
          })
      } else {
        Column() {
          Text(this.thinkingStatusText())
            .copyOption(CopyOptions.None)
            .fontSize(this.conversationFontSize(12))
            .fontColor(this.messageContentColor('reasoning'))
            .lineHeight(this.conversationLineHeight(19))
            .fontWeight(FontWeight.Medium)
            .margin({ top: 6 })

          ForEach(this.turnActivityDetailLines(), (line: string, index?: number) => {
            Text(line)
              .copyOption(CopyOptions.LocalDevice)
              .fontSize(this.conversationFontSize(12))
              .fontColor(this.messageContentColor('reasoning'))
              .lineHeight(this.conversationLineHeight(19))
              .wordBreak(WordBreak.BREAK_WORD)
              .margin({ top: index === 0 ? 6 : 4 })
          }, (line: string, index?: number) => `turn-activity:${index ?? 0}:${line}`)

          Text('收起思考内容')
            .copyOption(CopyOptions.None)
            .fontSize(this.conversationFontSize(10))
            .fontColor(this.accentBorderColor('reasoning'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ top: 6 })
            .backgroundColor(this.eventSoftBackground('reasoning'))
            .border({ width: 0.5, color: this.eventBorderColor('reasoning') })
            .borderRadius(6)
            .onClick(() => {
              this.toggleTurnActivityExpanded();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 28 })
      }
    }
    .width('92%')
    .constraintSize({ maxWidth: '92%' })
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.themeBorder() })
    .borderRadius(8)
  }

  @Builder
  private compactionNoticeLine(notice: CompactionNotice) {
    Row() {
      this.compactionNoticeBlock(notice)
      Blank()
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 8 })
  }

  @Builder
  private compactionNoticeBlock(notice: CompactionNotice) {
    Column() {
      Row() {
        Row() {
          Text(this.isCompactionNoticeExpanded(notice.id) ? '\u2304' : '\u203A')
            .copyOption(CopyOptions.None)
            .fontSize(16)
            .fontColor(this.compactionNoticeColor(notice.status))
        }
        .width(20)
        .height(20)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.compactionNoticeSoftBackground(notice.status))
        .border({ width: 0.5, color: this.compactionNoticeBorderColor(notice.status) })
        .borderRadius(6)
        .margin({ right: 8 })

        Text('上下文压缩')
          .copyOption(CopyOptions.None)
          .fontSize(this.conversationFontSize(12))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.compactionNoticeColor(notice.status))

        Text(this.compactionNoticeStatusLabel(notice.status))
          .copyOption(CopyOptions.None)
          .fontSize(this.conversationFontSize(10))
          .fontColor(this.compactionNoticeColor(notice.status))
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(this.compactionNoticeSoftBackground(notice.status))
          .borderRadius(6)
          .margin({ left: 8 })

        Text(notice.timestamp)
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(this.conversationFontSize(10))
          .fontColor(this.themeTextMuted())
          .margin({ left: 10 })
      }
      .alignItems(VerticalAlign.Center)
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => {
        this.toggleCompactionNoticeExpanded(notice.id);
      })

      Text(this.compactionNoticeSummary(notice))
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.conversationFontSize(11))
        .fontColor(this.compactionNoticeColor(notice.status))
        .lineHeight(this.conversationLineHeight(17))
        .constraintSize({ maxWidth: '100%' })
        .wordBreak(WordBreak.BREAK_WORD)
        .margin({ top: 6, left: 28 })
        .maxLines(this.isCompactionNoticeExpanded(notice.id) ? 3 : 1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.isCompactionNoticeExpanded(notice.id)) {
        Column() {
          this.compactionMetricRow('压缩前', notice.oldTotalTokens > 0 ? `${this.formatTokenCount(notice.oldTotalTokens)} tokens` : '未知')
          this.compactionMetricRow('压缩后', notice.newTotalTokens > 0 ? `${this.formatTokenCount(notice.newTotalTokens)} tokens` : '未知')
          this.compactionMetricRow('释放', this.compactionSavedText(notice))
          if (notice.errorMessage.trim().length > 0) {
            Text(notice.errorMessage)
              .copyOption(CopyOptions.LocalDevice)
              .fontSize(this.conversationFontSize(10))
              .fontColor('#DC2626')
              .lineHeight(this.conversationLineHeight(16))
              .margin({ top: 6 })
          }
          if (notice.status === 'failed' || notice.status === 'timeout') {
            Text('重试压缩')
              .copyOption(CopyOptions.None)
              .fontSize(this.conversationFontSize(10))
              .fontColor('#4338CA')
              .fontWeight(FontWeight.Medium)
              .padding({ left: 8, right: 8, top: 5, bottom: 5 })
              .backgroundColor(this.compactionNoticeSoftBackground('completed'))
              .borderRadius(6)
              .margin({ top: 8 })
              .onClick(() => {
                this.retryCurrentCompaction(notice.threadId);
              })
          }
        }
        .constraintSize({ maxWidth: '100%' })
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8, left: 28 })
      }
    }
    .constraintSize({ maxWidth: '72%' })
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.themeBorder() })
    .borderRadius(8)
  }

  @Builder
  private compactionMetricRow(label: string, value: string) {
    Row() {
      Text(label)
        .copyOption(CopyOptions.None)
        .fontSize(this.conversationFontSize(10))
        .fontColor(this.themeTextSecondary())
        .width(56)

      Text(value)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.conversationFontSize(10))
        .fontColor(this.themeTextStrong())
        .fontFamily('monospace')
    }
    .width('100%')
    .margin({ top: 3 })
  }

  @Builder
  private messageEventBlock(item: ChatMessage) {
    Column() {
      Row() {
        Row() {
          Text(this.isMessageCollapsed(item) ? '\u203A' : '\u2304')
            .copyOption(CopyOptions.None)
            .fontSize(16)
            .fontColor(this.accentBorderColor(item.itemType ?? item.role))
        }
        .width(20)
        .height(20)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.eventSoftBackground(item.itemType ?? item.role))
        .border({ width: 0.5, color: this.eventBorderColor(item.itemType ?? item.role) })
        .borderRadius(6)
        .margin({ right: 8 })

        Text(this.messageIcon(item.itemType ?? item.role))
          .copyOption(CopyOptions.None)
          .fontSize(this.conversationFontSize(12))
          .fontColor(this.accentBorderColor(item.itemType ?? item.role))
          .fontWeight(FontWeight.Medium)
          .width(22)

        Text(this.operationLabel(item.itemType ?? item.role))
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(this.conversationFontSize(12))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentBorderColor(item.itemType ?? item.role))

        Text(item.timestamp)
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(10)
          .fontColor(this.themeTextMuted())
          .margin({ left: 8 })

        if (item.status && item.status !== 'completed') {
          Text(this.statusLabel(item.status))
            .fontSize(9)
            .fontColor(this.statusColor(item.status))
            .backgroundColor(this.statusBgColor(item.status))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(6)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => {
        this.toggleMessageExpanded(item.id);
      })

      if (this.isMessageCollapsed(item)) {
        Row() {
          Text(this.collapsedMessagePreview(item))
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(this.conversationFontSize(11))
            .fontColor(this.accentBorderColor(item.itemType ?? item.role))
            .lineHeight(this.conversationLineHeight(17))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
          .width('100%')
          .padding({ left: 46 })
          .margin({ top: 5 })
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => {
            this.toggleMessageExpanded(item.id);
          })
      } else {
        Column() {
          this.messageBody(item)
          if (this.isReasoningMessage(item)) {
            this.reasoningToggleText(item)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 28 })
      }
    }
    .width('92%')
    .constraintSize({ maxWidth: '92%' })
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.themeBorder() })
    .borderRadius(8)
  }

  @Builder
  private reasoningToggleText(item: ChatMessage) {
    Text(this.isMessageCollapsed(item) ? '展开思考内容' : '收起思考内容')
      .copyOption(CopyOptions.None)
      .fontSize(this.conversationFontSize(10))
      .fontColor(this.accentBorderColor(item.itemType ?? item.role))
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ top: 6 })
      .backgroundColor(this.eventSoftBackground(item.itemType ?? item.role))
      .border({ width: 0.5, color: this.eventBorderColor(item.itemType ?? item.role) })
      .borderRadius(6)
      .onClick(() => {
        this.toggleMessageExpanded(item.id);
      })
  }

  @Builder
  private messageHeader(item: ChatMessage) {
    Row() {
      Text(this.displayBrandText(item.author))
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.conversationFontSize(12))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.authorColor(item.itemType ?? item.role))

      Text(item.timestamp)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(10)
        .fontColor(this.themeTextMuted())
        .margin({ left: 8 })
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private messageHeaderRow(item: ChatMessage) {
    if (this.isUserMessage(item)) {
      this.messageHeader(item)
    } else {
      Row() {
        this.messageHeader(item)
      }
      .width('100%')
      .constraintSize({ maxWidth: '100%' })
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  private messageCard(item: ChatMessage) {
    Column() {
      this.messageHeaderRow(item)
      this.messageBody(item)
    }
    .alignItems(HorizontalAlign.Start)
    .constraintSize({ maxWidth: this.messageCardMaxWidth(item) })
    .padding({
      left: this.isUserMessage(item) ? 12 : 4,
      right: this.isUserMessage(item) ? 12 : 4,
      top: this.isUserMessage(item) ? 9 : 4,
      bottom: this.isUserMessage(item) ? 9 : 4
    })
    .backgroundColor(this.messageBackground(item.itemType ?? item.role))
    .border({ width: this.isUserMessage(item) ? 0.5 : 0, color: this.isUserMessage(item) ? '#BFDBFE' : 'transparent' })
    .borderRadius(this.isUserMessage(item) ? 10 : 0)
  }

  @Builder
  private messageActionRow(item: ChatMessage) {
    if (this.shouldShowMessageActions(item) && this.hoveredMessageId === item.id) {
      Row() {
        this.iconCopyButton(() => {
          this.copyMessage(item);
        })
        if (this.shouldShowMessageSelectableAction(item)) {
          Blank()
            .width(4)
          this.iconSelectTextButton(this.isMessageSelectableMode(item.id), () => {
            this.toggleMessageSelectableMode(item.id);
          })
        }
      }
      .height(26)
      .margin({
        top: 3,
        left: this.isUserMessage(item) ? 0 : 2,
        right: this.isUserMessage(item) ? 2 : 0
      })
    }
  }

  @Builder
  private messageCluster(item: ChatMessage) {
    Column() {
      this.messageCard(item)
      this.messageActionRow(item)
    }
    .alignItems(this.isUserMessage(item) ? HorizontalAlign.End : HorizontalAlign.Start)
  }

  @Builder
  private messageLine(item: ChatMessage) {
    Row() {
      if (this.isUserMessage(item)) {
        Blank()
          .layoutWeight(1)
        this.messageCluster(item)
      } else if (this.isCollapsibleMessage(item)) {
        this.messageEventBlock(item)
        Blank()
          .layoutWeight(1)
      } else {
        this.messageCluster(item)
        Blank()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: this.isCollapsibleMessage(item) ? 6 : 10 })
    .onHover((isHover: boolean) => {
      if (!this.shouldShowMessageActions(item)) {
        return;
      }
      if (isHover) {
        this.hoveredMessageId = item.id;
        return;
      }
      if (this.hoveredMessageId === item.id) {
        this.hoveredMessageId = '';
      }
    })
  }

  private isUserMessage(item: ChatMessage): boolean {
    return item.role === 'user';
  }

  private mermaidDiagramHeight(source: string, scale?: number): number {
    const lineCount: number = source.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n').length;
    const baseHeight: number = Math.min(Math.max(220, lineCount * 28 + 120), 640);
    return Math.min(Math.max(220, Math.round(baseHeight * this.clampConversationFontScale(scale ?? 1))), 1152);
  }

  private shouldShowMessageActions(item: ChatMessage): boolean {
    const type: string = item.itemType ?? item.role;
    return item.content.trim().length > 0 &&
      item.role !== 'system' &&
      type !== 'system' &&
      !this.isIntermediateMessageType(type);
  }

  private shouldShowMessageSelectableAction(item: ChatMessage): boolean {
    return this.shouldShowMessageActions(item) && this.hasRenderedOrCodeMarkdownSurface(item.content);
  }

  private hasRenderedOrCodeMarkdownSurface(content: string): boolean {
    const text: string = content.trim();
    if (text.length === 0 || !this.shouldRenderMarkdown(text)) {
      return false;
    }
    if (this.hasInlineLinkSegment(this.inlineMarkdownSegments(text, 'inline-link-probe'))) {
      return true;
    }
    if (this.hasInlineMathText(text)) {
      return true;
    }
    const blocks: MarkdownBlock[] = this.markdownBlocks(text);
    for (let index: number = 0; index < blocks.length; index += 1) {
      const kind: string = blocks[index].kind;
      if (kind === 'code' || kind === 'math' || kind === 'mermaid' || kind === 'table') {
        return true;
      }
    }
    return false;
  }

  private plainMarkdownTextRuns(content: string, baseId: string): MarkdownTextRun[] {
    const blocks: MarkdownBlock[] = this.markdownBlocks(content);
    const runs: MarkdownTextRun[] = [];
    let serial: number = 0;
    for (let index: number = 0; index < blocks.length; index += 1) {
      if (index > 0) {
        serial = this.pushPlainMarkdownRun(runs, serial, '\n', 'newline');
      }
      serial = this.appendPlainMarkdownBlockRuns(runs, serial, blocks[index], `${baseId}:plain:${index}`);
    }
    if (runs.length === 0) {
      runs.push(new MarkdownTextRun(`${baseId}:plain:empty`, content.trim(), 'paragraph'));
    }
    return runs;
  }

  private appendPlainMarkdownBlockRuns(runs: MarkdownTextRun[], serial: number, block: MarkdownBlock, baseId: string): number {
    switch (block.kind) {
      case 'heading':
        return this.appendPlainMarkdownInlineRuns(runs, serial, block.text, 'heading', block.level, baseId);
      case 'quote':
        return this.appendPlainMarkdownQuoteRuns(runs, serial, block, baseId);
      case 'list':
        return this.appendPlainMarkdownListRuns(runs, serial, block, baseId);
      case 'divider':
        return this.pushPlainMarkdownRun(runs, serial, '────────────', 'divider');
      default:
        return this.appendPlainMarkdownInlineRuns(runs, serial, block.text, 'paragraph', 0, baseId);
    }
  }

  private appendPlainMarkdownQuoteRuns(runs: MarkdownTextRun[], serial: number, block: MarkdownBlock, baseId: string): number {
    const lines: string[] = block.text.split('\n');
    for (let index: number = 0; index < lines.length; index += 1) {
      if (index > 0) {
        serial = this.pushPlainMarkdownRun(runs, serial, '\n', 'newline');
      }
      serial = this.pushPlainMarkdownRun(runs, serial, '> ', 'quoteMarker');
      serial = this.appendPlainMarkdownInlineRuns(runs, serial, lines[index], 'quote', 0, `${baseId}:q${index}`);
    }
    return serial;
  }

  private appendPlainMarkdownListRuns(runs: MarkdownTextRun[], serial: number, block: MarkdownBlock, baseId: string): number {
    const lines: string[] = block.text.split('\n');
    for (let index: number = 0; index < lines.length; index += 1) {
      if (index > 0) {
        serial = this.pushPlainMarkdownRun(runs, serial, '\n', 'newline');
      }
      serial = this.pushPlainMarkdownRun(runs, serial, `${this.markdownListMarker(lines[index])} `, 'listMarker');
      serial = this.appendPlainMarkdownInlineRuns(runs, serial, this.markdownListText(lines[index]), 'list', 0, `${baseId}:li${index}`);
    }
    return serial;
  }

  private appendPlainMarkdownInlineRuns(runs: MarkdownTextRun[], serial: number, text: string, blockKind: string, level: number, baseId: string): number {
    const lines: string[] = text.split('\n');
    for (let lineIndex: number = 0; lineIndex < lines.length; lineIndex += 1) {
      if (lineIndex > 0) {
        serial = this.pushPlainMarkdownRun(runs, serial, '\n', 'newline');
      }
      const segments: MathSegment[] = this.inlineMarkdownSegments(lines[lineIndex], `${baseId}:line${lineIndex}`);
      for (let segmentIndex: number = 0; segmentIndex < segments.length; segmentIndex += 1) {
        const segment: MathSegment = segments[segmentIndex];
        const displayText: string = segment.kind === 'math' ? segment.rawText : segment.text;
        serial = this.pushPlainMarkdownRun(runs, serial, displayText, blockKind, segment.kind, level);
      }
    }
    return serial;
  }

  private pushPlainMarkdownRun(
    runs: MarkdownTextRun[],
    serial: number,
    text: string,
    blockKind: string,
    inlineKind?: string,
    level?: number
  ): number {
    if (text.length === 0) {
      return serial;
    }
    runs.push(new MarkdownTextRun(`plain-run-${serial}`, text, blockKind, inlineKind, level));
    return serial + 1;
  }

  private plainMarkdownRunColor(run: MarkdownTextRun, itemType?: string): string {
    if (run.inlineKind === 'link') {
      return '#2563EB';
    }
    if (run.inlineKind === 'code') {
      return this.themeTextStrong();
    }
    if (run.blockKind === 'heading') {
      return this.themeTextStrong();
    }
    if (run.blockKind === 'quote' || run.blockKind === 'quoteMarker') {
      return this.themeTextSecondary();
    }
    if (run.blockKind === 'listMarker') {
      return this.themeTextSecondary();
    }
    if (run.blockKind === 'divider') {
      return this.themeTextMuted();
    }
    return this.messageContentColor(itemType);
  }

  private plainMarkdownRunFontSize(run: MarkdownTextRun): number {
    if (run.blockKind === 'heading') {
      return this.markdownHeadingFontSize(run.level);
    }
    return this.conversationFontSize(12);
  }

  private plainMarkdownRunWeight(run: MarkdownTextRun): FontWeight {
    if (run.blockKind === 'heading' || run.inlineKind === 'strong' || run.inlineKind === 'code' ||
      run.blockKind === 'listMarker' || run.blockKind === 'quoteMarker') {
      return FontWeight.Medium;
    }
    return FontWeight.Regular;
  }

  private shouldRenderMarkdown(content: string): boolean {
    const text: string = content.trim();
    if (text.length === 0) {
      return false;
    }
    return this.hasBlockMarkdownContent(text) || this.hasInlineMarkdownContent(text);
  }

  private shouldRenderInlineOnlyMarkdown(content: string): boolean {
    const text: string = content.trim();
    return text.length > 0 && !this.hasBlockMarkdownContent(text) && this.hasInlineMarkdownContent(text);
  }

  private hasBlockMarkdownContent(text: string): boolean {
    return text.indexOf('```') >= 0 ||
      text.indexOf('$$') >= 0 ||
      text.indexOf('\\[') >= 0 ||
      text.match(/(^|\n)#{1,6}\s+\S/) !== null ||
      text.match(/(^|\n)\s*>\s+\S/) !== null ||
      text.match(/(^|\n)\s*([-*+]|\d+\.)\s+\S/) !== null ||
      text.match(/\n\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?/) !== null ||
      text.match(/(^|\n)\s*(---|\*\*\*|___)\s*($|\n)/) !== null;
  }

  private hasInlineMarkdownContent(text: string): boolean {
    const dollarStart: number = this.findInlineDollarStart(text, 0);
    return text.indexOf('\\(') >= 0 ||
      (dollarStart >= 0 && this.findInlineDollarEnd(text, dollarStart + 1) >= 0) ||
      text.match(/\*\*[^*]+\*\*/) !== null ||
      text.match(/__[^_]+__/) !== null ||
      text.match(/`[^`]+`/) !== null ||
      text.match(/!\[[^\]]*\]\([^)]+\)/) !== null ||
      text.match(/\[[^\]]+\]\([^)]+\)/) !== null ||
      this.findInlineWebTarget(text, 0) !== null;
  }

  private messageCardMaxWidth(item: ChatMessage): string {
    if (this.isCollapsibleMessage(item)) {
      return '82%';
    }
    if (this.isUserMessage(item)) {
      return this.hasWideMarkdownContent(item.content) ? '82%' : '72%';
    }
    return this.hasWideMarkdownContent(item.content) ? '94%' : '90%';
  }

  private hasWideMarkdownContent(content: string): boolean {
    const text: string = content.trim();
    return text.indexOf('```') >= 0 ||
      text.indexOf('$$') >= 0 ||
      text.indexOf('\\[') >= 0 ||
      text.match(/\n\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?/) !== null ||
      text.length > 180;
  }

  private isCollapsibleMessage(item: ChatMessage): boolean {
    const type: string = item.itemType ?? item.role;
    return this.isIntermediateMessageType(type);
  }

  private isReasoningMessage(item: ChatMessage): boolean {
    const type: string = item.itemType ?? item.role;
    return type === 'reasoning';
  }

  private isMessageCollapsed(item: ChatMessage): boolean {
    return this.isCollapsibleMessage(item) && !this.isMessageExpanded(item.id);
  }

  private isMessageExpanded(messageId: string): boolean {
    return this.expandedIntermediateMessageIds.indexOf(messageId) >= 0;
  }

  private toggleMessageExpanded(messageId: string): void {
    if (this.isMessageExpanded(messageId)) {
      this.expandedIntermediateMessageIds = this.expandedIntermediateMessageIds.filter((id: string) => id !== messageId);
      return;
    }
    this.expandedIntermediateMessageIds = [...this.expandedIntermediateMessageIds, messageId];
  }

  private isMessageSelectableMode(messageId: string): boolean {
    return this.selectableMessageIds.indexOf(messageId) >= 0;
  }

  private toggleMessageSelectableMode(messageId: string): void {
    if (this.isMessageSelectableMode(messageId)) {
      this.selectableMessageIds = this.selectableMessageIds.filter((id: string) => id !== messageId);
      return;
    }
    this.selectableMessageIds = [...this.selectableMessageIds, messageId];
  }

  private markdownBlocksCache: Map<string, MarkdownBlock[]> = new Map();

  private markdownBlocks(content: string): MarkdownBlock[] {
    const cached: MarkdownBlock[] | undefined = this.markdownBlocksCache.get(content);
    if (cached !== undefined) {
      return cached;
    }
    const lines: string[] = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    const blocks: MarkdownBlock[] = [];
    let i = 0;
    let serial = 0;

    while (i < lines.length) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (trimmed.length === 0) {
        i++;
        continue;
      }

      if (trimmed.startsWith('```')) {
        const language: string = trimmed.substring(3).trim().toLowerCase();
        const body: string[] = [];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          body.push(lines[i]);
          i++;
        }
        if (i < lines.length) {
          i++;
        }
        const code: string = body.join('\n');
        const kind: string = this.isMermaidCodeBlock(language, code) ? 'mermaid' : 'code';
        const rawLanguage: string = kind === 'mermaid' ? (language.length > 0 ? language : 'mermaid') : language;
        blocks.push(new MarkdownBlock(
          `md-${serial++}`,
          kind,
          code,
          0,
          language,
          [],
          this.fencedCodeSource(rawLanguage, code)
        ));
        continue;
      }

      if (trimmed.startsWith('$$')) {
        const body: string[] = [];
        const firstBody: string = trimmed.substring(2);
        if (firstBody.endsWith('$$') && firstBody.length > 2) {
          body.push(firstBody.substring(0, firstBody.length - 2));
          i++;
        } else {
          if (firstBody.trim().length > 0) {
            body.push(firstBody);
          }
          i++;
          while (i < lines.length && !lines[i].trim().endsWith('$$')) {
            body.push(lines[i]);
            i++;
          }
          if (i < lines.length) {
            const lastLine: string = lines[i].trim();
            const lastBody: string = lastLine.substring(0, Math.max(lastLine.length - 2, 0));
            if (lastBody.trim().length > 0) {
              body.push(lastBody);
            }
            i++;
          }
        }
        const mathBody: string = body.join('\n');
        blocks.push(new MarkdownBlock(`md-${serial++}`, 'math', mathBody, 0, '', [], this.wrappedMathSource('$$', '$$', mathBody)));
        continue;
      }

      if (trimmed.startsWith('\\[')) {
        const body: string[] = [];
        const firstBody: string = trimmed.substring(2);
        if (firstBody.endsWith('\\]') && firstBody.length > 2) {
          body.push(firstBody.substring(0, firstBody.length - 2));
          i++;
        } else {
          if (firstBody.trim().length > 0) {
            body.push(firstBody);
          }
          i++;
          while (i < lines.length && !lines[i].trim().endsWith('\\]')) {
            body.push(lines[i]);
            i++;
          }
          if (i < lines.length) {
            const lastLine: string = lines[i].trim();
            const lastBody: string = lastLine.substring(0, Math.max(lastLine.length - 2, 0));
            if (lastBody.trim().length > 0) {
              body.push(lastBody);
            }
            i++;
          }
        }
        const mathBody: string = body.join('\n');
        blocks.push(new MarkdownBlock(`md-${serial++}`, 'math', mathBody, 0, '', [], this.wrappedMathSource('\\[', '\\]', mathBody)));
        continue;
      }

      const headingMatch: RegExpMatchArray | null = line.match(/^(#{1,6})\s+(.+)$/);
      if (headingMatch !== null) {
        blocks.push(new MarkdownBlock(`md-${serial++}`, 'heading', headingMatch[2], headingMatch[1].length));
        i++;
        continue;
      }

      if (this.isDividerLine(trimmed)) {
        blocks.push(new MarkdownBlock(`md-${serial++}`, 'divider', ''));
        i++;
        continue;
      }

      if (this.isTableStart(lines, i)) {
        const rows: string[][] = [];
        rows.push(this.parseTableRow(lines[i]));
        i += 2;
        while (i < lines.length && lines[i].indexOf('|') >= 0 && lines[i].trim().length > 0) {
          rows.push(this.parseTableRow(lines[i]));
          i++;
        }
        blocks.push(new MarkdownBlock(`md-${serial++}`, 'table', '', 0, '', rows));
        continue;
      }

      if (this.isQuoteLine(trimmed)) {
        const body: string[] = [];
        while (i < lines.length && this.isQuoteLine(lines[i].trim())) {
          body.push(lines[i].trim().replace(/^>\s?/, ''));
          i++;
        }
        blocks.push(new MarkdownBlock(`md-${serial++}`, 'quote', body.join('\n')));
        continue;
      }

      if (this.isListLine(trimmed)) {
        const body: string[] = [];
        while (i < lines.length && this.isListLine(lines[i].trim())) {
          body.push(lines[i].trim());
          i++;
        }
        blocks.push(new MarkdownBlock(`md-${serial++}`, 'list', body.join('\n')));
        continue;
      }

      const body: string[] = [];
      while (i < lines.length && lines[i].trim().length > 0 && !this.isMarkdownBoundary(lines, i)) {
        body.push(lines[i].trim());
        i++;
      }
      if (body.length === 0) {
        body.push(line);
        i++;
      }
      blocks.push(new MarkdownBlock(`md-${serial++}`, 'paragraph', body.join('\n')));
    }

    if (blocks.length === 0) {
      blocks.push(new MarkdownBlock('md-empty', 'paragraph', content));
    }
    if (this.markdownBlocksCache.size >= 64) {
      this.markdownBlocksCache.clear();
    }
    this.markdownBlocksCache.set(content, blocks);
    return blocks;
  }

  private isMarkdownBoundary(lines: string[], index: number): boolean {
    const trimmed: string = lines[index].trim();
    return trimmed.startsWith('```') ||
      trimmed.startsWith('$$') ||
      trimmed.startsWith('\\[') ||
      trimmed.match(/^(#{1,6})\s+(.+)$/) !== null ||
      this.isDividerLine(trimmed) ||
      this.isQuoteLine(trimmed) ||
      this.isListLine(trimmed) ||
      this.isTableStart(lines, index);
  }

  private isDividerLine(trimmed: string): boolean {
    return trimmed === '---' || trimmed === '***' || trimmed === '___';
  }

  private isMermaidCodeBlock(language: string, code: string): boolean {
    const lang: string = language.trim().toLowerCase();
    if (lang === 'mermaid' || lang === 'mmd') {
      return true;
    }
    const firstMeaningfulLine: string = this.firstMeaningfulMermaidLine(code).toLowerCase();
    if (firstMeaningfulLine.length === 0) {
      return false;
    }
    const starters: string[] = [
      'flowchart ',
      'graph ',
      'sequencediagram',
      'classdiagram',
      'statediagram',
      'statediagram-v2',
      'erdiagram',
      'journey',
      'gantt',
      'pie',
      'mindmap',
      'timeline',
      'quadrantchart',
      'requirementdiagram',
      'gitgraph',
      'c4context',
      'c4container',
      'c4component',
      'c4dynamic',
      'zenuml',
      'sankey',
      'sankey-beta',
      'xychart-beta',
      'block-beta',
      'packet-beta',
      'architecture-beta',
      'kanban',
      'radar-beta',
      'treemap-beta'
    ];
    for (let index: number = 0; index < starters.length; index += 1) {
      if (firstMeaningfulLine.startsWith(starters[index])) {
        return true;
      }
    }
    return false;
  }

  private firstMeaningfulMermaidLine(code: string): string {
    const lines: string[] = code.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    let skippingFrontmatter: boolean = false;
    for (let index: number = 0; index < lines.length; index += 1) {
      const line: string = lines[index].trim();
      if (line.length === 0 || line.startsWith('%%')) {
        continue;
      }
      if (line === '---') {
        skippingFrontmatter = !skippingFrontmatter;
        continue;
      }
      if (!skippingFrontmatter) {
        return line;
      }
    }
    return '';
  }

  private isQuoteLine(trimmed: string): boolean {
    return trimmed.startsWith('>');
  }

  private isListLine(trimmed: string): boolean {
    return trimmed.match(/^([-*+])\s+.+$/) !== null || trimmed.match(/^\d+\.\s+.+$/) !== null;
  }

  private isTableStart(lines: string[], index: number): boolean {
    if (index + 1 >= lines.length) {
      return false;
    }
    const current: string = lines[index].trim();
    const separator: string = lines[index + 1].trim();
    return current.indexOf('|') >= 0 && separator.match(/^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$/) !== null;
  }

  private parseTableRow(line: string): string[] {
    let text: string = line.trim();
    if (text.startsWith('|')) {
      text = text.substring(1);
    }
    if (text.endsWith('|')) {
      text = text.substring(0, text.length - 1);
    }
    return text.split('|').map((cell: string): string => cell.trim());
  }

  private codeBlockLinesCache: Map<string, string[]> = new Map();

  private codeBlockLines(text: string): string[] {
    const cached: string[] | undefined = this.codeBlockLinesCache.get(text);
    if (cached !== undefined) {
      return cached;
    }
    const lines: string[] = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\t/g, '    ').split('\n');
    const result: string[] = lines.length > 0 ? lines : [''];
    if (this.codeBlockLinesCache.size >= 64) {
      this.codeBlockLinesCache.clear();
    }
    this.codeBlockLinesCache.set(text, result);
    return result;
  }

  private codeLineTokens(line: string, language: string, baseId: string): CodeToken[] {
    const tokens: CodeToken[] = [];
    const lang: string = this.normalizeCodeLanguage(language);
    let cursor: number = 0;
    let serial: number = 0;

    while (cursor < line.length) {
      const current: string = line[cursor];
      if (current === ' ') {
        let end: number = cursor + 1;
        while (end < line.length && line[end] === ' ') {
          end += 1;
        }
        tokens.push(new CodeToken(`${baseId}:${serial++}`, 'plain', line.substring(cursor, end)));
        cursor = end;
        continue;
      }

      if (this.isCodeLineCommentStart(line, cursor, lang)) {
        tokens.push(new CodeToken(`${baseId}:${serial++}`, 'comment', line.substring(cursor)));
        break;
      }

      if (line.startsWith('/*', cursor)) {
        const closing: number = line.indexOf('*/', cursor + 2);
        const end: number = closing >= 0 ? closing + 2 : line.length;
        tokens.push(new CodeToken(`${baseId}:${serial++}`, 'comment', line.substring(cursor, end)));
        cursor = end;
        continue;
      }

      if (current === '"' || current === '\'' || current === '`') {
        const end: number = this.findCodeStringEnd(line, cursor, current);
        tokens.push(new CodeToken(`${baseId}:${serial++}`, 'string', line.substring(cursor, end)));
        cursor = end;
        continue;
      }

      if (this.isCodeDigit(current)) {
        const end: number = this.findCodeNumberEnd(line, cursor);
        tokens.push(new CodeToken(`${baseId}:${serial++}`, 'number', line.substring(cursor, end)));
        cursor = end;
        continue;
      }

      if (this.isCodeIdentifierStart(current)) {
        const end: number = this.findCodeIdentifierEnd(line, cursor);
        const word: string = line.substring(cursor, end);
        tokens.push(new CodeToken(`${baseId}:${serial++}`, this.codeIdentifierKind(word, lang), word));
        cursor = end;
        continue;
      }

      if (this.isCodeOperator(current)) {
        let end: number = cursor + 1;
        while (end < line.length && this.isCodeOperator(line[end])) {
          end += 1;
        }
        tokens.push(new CodeToken(`${baseId}:${serial++}`, 'operator', line.substring(cursor, end)));
        cursor = end;
        continue;
      }

      tokens.push(new CodeToken(`${baseId}:${serial++}`, 'plain', current));
      cursor += 1;
    }

    if (tokens.length === 0) {
      tokens.push(new CodeToken(`${baseId}:empty`, 'plain', ' '));
    }
    return tokens;
  }

  private normalizeCodeLanguage(language: string): string {
    const lang: string = language.trim().toLowerCase();
    if (lang === 'c++' || lang === 'cpp' || lang === 'cc' || lang === 'cxx') {
      return 'cpp';
    }
    if (lang === 'ts' || lang === 'tsx' || lang === 'typescript') {
      return 'typescript';
    }
    if (lang === 'js' || lang === 'jsx' || lang === 'javascript') {
      return 'javascript';
    }
    if (lang === 'py' || lang === 'python3') {
      return 'python';
    }
    if (lang === 'sh' || lang === 'bash' || lang === 'zsh' || lang === 'powershell' || lang === 'ps1') {
      return 'shell';
    }
    return lang;
  }

  private isCodeLineCommentStart(line: string, index: number, lang: string): boolean {
    if (line.startsWith('//', index)) {
      return lang !== 'python' && lang !== 'shell';
    }
    if (line.startsWith('%%', index)) {
      return lang === 'mermaid';
    }
    if (line.startsWith('#', index)) {
      return lang === 'python' || lang === 'shell' || lang === 'ruby' || lang === 'toml' || lang === 'yaml';
    }
    if (line.startsWith('--', index)) {
      return lang === 'sql' || lang === 'lua';
    }
    return false;
  }

  private findCodeStringEnd(line: string, start: number, quote: string): number {
    let cursor: number = start + 1;
    while (cursor < line.length) {
      if (line[cursor] === '\\') {
        cursor += 2;
        continue;
      }
      if (line[cursor] === quote) {
        return cursor + 1;
      }
      cursor += 1;
    }
    return line.length;
  }

  private findCodeNumberEnd(line: string, start: number): number {
    let cursor: number = start + 1;
    while (cursor < line.length && /[A-Za-z0-9_.]/.test(line[cursor])) {
      cursor += 1;
    }
    return cursor;
  }

  private findCodeIdentifierEnd(line: string, start: number): number {
    let cursor: number = start + 1;
    while (cursor < line.length && this.isCodeIdentifierPart(line[cursor])) {
      cursor += 1;
    }
    return cursor;
  }

  private isCodeIdentifierStart(ch: string): boolean {
    return /[A-Za-z_$]/.test(ch);
  }

  private isCodeIdentifierPart(ch: string): boolean {
    return /[A-Za-z0-9_$]/.test(ch);
  }

  private isCodeDigit(ch: string): boolean {
    return /[0-9]/.test(ch);
  }

  private isCodeOperator(ch: string): boolean {
    return '+-*/%=!<>&|^~?:.'.indexOf(ch) >= 0;
  }

  private codeIdentifierKind(word: string, lang: string): string {
    if (word === 'true' || word === 'false' || word === 'null' || word === 'undefined' || word === 'None' ||
      word === 'nil' || word === 'nullptr') {
      return 'literal';
    }
    if (this.isCodeKeyword(word, lang)) {
      return 'keyword';
    }
    if (this.isCodeBuiltin(word, lang)) {
      return 'builtin';
    }
    return 'plain';
  }

  private isCodeKeyword(word: string, lang: string): boolean {
    const common: string = '|if|else|for|while|do|switch|case|break|continue|return|try|catch|finally|throw|new|class|struct|enum|interface|extends|implements|public|private|protected|static|const|let|var|void|async|await|import|export|from|as|in|of|';
    if (common.indexOf(`|${word}|`) >= 0) {
      return true;
    }
    if (lang === 'c' || lang === 'cpp') {
      return '|auto|char|double|float|int|long|short|signed|unsigned|sizeof|typedef|union|volatile|extern|register|inline|namespace|template|typename|using|virtual|override|include|define|'.indexOf(`|${word}|`) >= 0;
    }
    if (lang === 'python') {
      return '|def|lambda|yield|with|pass|elif|global|nonlocal|assert|del|is|not|and|or|except|raise|'.indexOf(`|${word}|`) >= 0;
    }
    if (lang === 'rust') {
      return '|fn|let|mut|impl|trait|pub|crate|mod|use|match|where|loop|move|ref|self|Self|super|unsafe|'.indexOf(`|${word}|`) >= 0;
    }
    if (lang === 'java' || lang === 'kotlin') {
      return '|abstract|boolean|byte|char|double|final|float|int|long|native|package|short|strictfp|super|synchronized|this|throws|transient|volatile|'.indexOf(`|${word}|`) >= 0;
    }
    if (lang === 'css') {
      return '|display|position|absolute|relative|fixed|flex|grid|block|inline|none|color|background|border|margin|padding|width|height|'.indexOf(`|${word}|`) >= 0;
    }
    if (lang === 'mermaid') {
      return '|graph|flowchart|sequenceDiagram|classDiagram|stateDiagram|stateDiagram-v2|erDiagram|journey|gantt|pie|mindmap|timeline|subgraph|end|participant|actor|as|title|section|TD|TB|BT|LR|RL|'.indexOf(`|${word}|`) >= 0;
    }
    return false;
  }

  private isCodeBuiltin(word: string, lang: string): boolean {
    const common: string = '|String|Number|Boolean|Array|Object|Map|Set|Promise|Error|Date|Math|JSON|console|print|printf|scanf|main|';
    if (common.indexOf(`|${word}|`) >= 0) {
      return true;
    }
    if (lang === 'python') {
      return '|str|int|float|bool|list|dict|set|tuple|len|range|open|enumerate|zip|sum|min|max|'.indexOf(`|${word}|`) >= 0;
    }
    if (lang === 'rust') {
      return '|String|Vec|Option|Result|Some|None|Ok|Err|println|format|'.indexOf(`|${word}|`) >= 0;
    }
    return false;
  }

  private codeTokenColor(kind: string): string {
    switch (kind) {
      case 'keyword': return '#7C3AED';
      case 'builtin': return '#0369A1';
      case 'string': return '#15803D';
      case 'number':
      case 'literal': return '#B45309';
      case 'comment': return '#64748B';
      case 'operator': return '#BE123C';
      default: return this.themeTextStrong();
    }
  }

  private codeTokenWeight(kind: string): FontWeight {
    return kind === 'keyword' || kind === 'builtin' ? FontWeight.Medium : FontWeight.Regular;
  }

  private normalizeInlineMarkdownText(text: string): string {
    let result: string = text;
    result = result.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, '图片: $1');
    result = result.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '$1 ($2)');
    result = result.replace(/\*\*([^*]+)\*\*/g, '$1');
    result = result.replace(/__([^_]+)__/g, '$1');
    result = result.replace(/`([^`]+)`/g, '$1');
    return result;
  }

  private inlineMarkdownSegmentsCache: Map<string, MathSegment[]> = new Map();

  private inlineMarkdownSegments(text: string, baseId: string): MathSegment[] {
    const cacheKey: string = `${baseId}\u0000${text}`;
    const cached: MathSegment[] | undefined = this.inlineMarkdownSegmentsCache.get(cacheKey);
    if (cached !== undefined) {
      return cached;
    }
    const segments: MathSegment[] = [];
    let cursor: number = 0;
    let serial: number = 0;

    while (cursor < text.length) {
      const dollarStart: number = this.findInlineDollarStart(text, cursor);
      const parenStart: number = text.indexOf('\\(', cursor);
      let start: number = -1;
      let kind: string = '';

      if (dollarStart >= 0 && (parenStart < 0 || dollarStart < parenStart)) {
        start = dollarStart;
        kind = 'dollar';
      } else if (parenStart >= 0) {
        start = parenStart;
        kind = 'paren';
      }

      if (start < 0) {
        serial = this.pushInlineMarkdownTextSegments(segments, text.substring(cursor), baseId, serial);
        break;
      }

      if (start > cursor) {
        serial = this.pushInlineMarkdownTextSegments(segments, text.substring(cursor, start), baseId, serial);
      }

      if (kind === 'dollar') {
        const end: number = this.findInlineDollarEnd(text, start + 1);
        if (end < 0) {
          serial = this.pushInlineMarkdownTextSegments(segments, text.substring(start), baseId, serial);
          break;
        }
        const expr: string = text.substring(start + 1, end);
        const raw: string = text.substring(start, end + 1);
        if (expr.indexOf('\n') >= 0 || expr.trim().length === 0) {
          serial = this.pushInlineMarkdownTextSegments(segments, raw, baseId, serial);
        } else {
          this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:math:${serial++}`, 'math', expr.trim(), raw));
        }
        cursor = end + 1;
        continue;
      }

      const parenEnd: number = text.indexOf('\\)', start + 2);
      if (parenEnd < 0) {
        serial = this.pushInlineMarkdownTextSegments(segments, text.substring(start), baseId, serial);
        break;
      }
      const expr: string = text.substring(start + 2, parenEnd);
      const raw: string = text.substring(start, parenEnd + 2);
      if (expr.indexOf('\n') >= 0 || expr.trim().length === 0) {
        serial = this.pushInlineMarkdownTextSegments(segments, raw, baseId, serial);
      } else {
        this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:math:${serial++}`, 'math', expr.trim(), raw));
      }
      cursor = parenEnd + 2;
    }

    if (segments.length === 0) {
      segments.push(new MathSegment(`${baseId}:text:0`, 'text', this.normalizeInlineMarkdownText(text)));
    }
    if (this.inlineMarkdownSegmentsCache.size >= 128) {
      this.inlineMarkdownSegmentsCache.clear();
    }
    this.inlineMarkdownSegmentsCache.set(cacheKey, segments);
    return segments;
  }

  private pushInlineMarkdownTextSegments(segments: MathSegment[], text: string, baseId: string, serial: number): number {
    let cursor: number = 0;
    while (cursor < text.length) {
      let next: number = text.length;
      let kind: string = '';
      const webTargetMatch: InlineWebTargetMatch | null = this.findInlineWebTarget(text, cursor);
      if (webTargetMatch !== null && webTargetMatch.start < next) {
        next = webTargetMatch.start;
        kind = 'web-target';
      }
      const codeStart: number = text.indexOf('`', cursor);
      if (codeStart >= 0 && codeStart < next) {
        next = codeStart;
        kind = 'code';
      }
      const strongStarStart: number = text.indexOf('**', cursor);
      if (strongStarStart >= 0 && strongStarStart < next) {
        next = strongStarStart;
        kind = 'strong-star';
      }
      const strongUnderlineStart: number = text.indexOf('__', cursor);
      if (strongUnderlineStart >= 0 && strongUnderlineStart < next) {
        next = strongUnderlineStart;
        kind = 'strong-underline';
      }
      const imageStart: number = text.indexOf('![', cursor);
      if (imageStart >= 0 && imageStart < next) {
        next = imageStart;
        kind = 'image';
      }
      const linkStart: number = text.indexOf('[', cursor);
      if (linkStart >= 0 && linkStart < next) {
        next = linkStart;
        kind = 'link';
      }

      if (next > cursor) {
        this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:text:${serial++}`, 'text', text.substring(cursor, next)));
      }
      if (kind.length === 0) {
        break;
      }

      if (kind === 'code') {
        const end: number = text.indexOf('`', next + 1);
        if (end > next + 1) {
          const codeText: string = text.substring(next + 1, end);
          if (this.isOpenableWebTarget(codeText)) {
            this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:link:${serial++}`, 'link', codeText, text.substring(next, end + 1), codeText));
          } else {
            this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:code:${serial++}`, 'code', codeText, text.substring(next, end + 1)));
          }
          cursor = end + 1;
          continue;
        }
      } else if (kind === 'web-target') {
        const match: InlineWebTargetMatch | null = this.findInlineWebTarget(text, next);
        if (match !== null && match.start === next && match.end > next) {
          const display: string = text.substring(match.start, match.end);
          this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:link:${serial++}`, 'link', display, display, match.target));
          cursor = match.end;
          continue;
        }
      } else if (kind === 'strong-star') {
        const end: number = text.indexOf('**', next + 2);
        if (end > next + 2) {
          this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:strong:${serial++}`, 'strong', text.substring(next + 2, end), text.substring(next, end + 2)));
          cursor = end + 2;
          continue;
        }
      } else if (kind === 'strong-underline') {
        const end: number = text.indexOf('__', next + 2);
        if (end > next + 2) {
          this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:strong:${serial++}`, 'strong', text.substring(next + 2, end), text.substring(next, end + 2)));
          cursor = end + 2;
          continue;
        }
      } else if (kind === 'image' || kind === 'link') {
        const parsedEnd: number = this.pushInlineMarkdownLinkSegment(segments, text, next, baseId, serial, kind === 'image');
        if (parsedEnd > next) {
          serial += 1;
          cursor = parsedEnd;
          continue;
        }
      }

      this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:text:${serial++}`, 'text', text[next]));
      cursor = next + 1;
    }
    return serial;
  }

  private pushInlineMarkdownLinkSegment(segments: MathSegment[], text: string, start: number, baseId: string, serial: number, image: boolean): number {
    const labelStart: number = image ? start + 2 : start + 1;
    const labelEnd: number = text.indexOf(']', labelStart);
    if (labelEnd <= labelStart || labelEnd + 1 >= text.length || text[labelEnd + 1] !== '(') {
      return -1;
    }
    const urlEnd: number = text.indexOf(')', labelEnd + 2);
    if (urlEnd <= labelEnd + 2) {
      return -1;
    }
    const label: string = text.substring(labelStart, labelEnd).trim();
    const url: string = text.substring(labelEnd + 2, urlEnd).trim();
    const target: string = this.cleanMarkdownLinkTarget(url);
    const display: string = image ? (label.length > 0 ? `图片: ${label}` : '图片') : (label.length > 0 ? label : url);
    this.pushInlineMarkdownSegment(segments, new MathSegment(`${baseId}:link:${serial}`, 'link', display, text.substring(start, urlEnd + 1), target));
    return urlEnd + 1;
  }

  private findInlineWebTarget(text: string, cursor: number): InlineWebTargetMatch | null {
    const httpMatch: InlineWebTargetMatch | null = this.findInlineHttpTarget(text, cursor);
    const localFileMatch: InlineWebTargetMatch | null = this.findInlineLocalWebFileTarget(text, cursor);
    if (httpMatch === null) {
      return localFileMatch;
    }
    if (localFileMatch === null) {
      return httpMatch;
    }
    return httpMatch.start <= localFileMatch.start ? httpMatch : localFileMatch;
  }

  private findInlineHttpTarget(text: string, cursor: number): InlineWebTargetMatch | null {
    const lower: string = text.toLowerCase();
    const httpIndex: number = lower.indexOf('http://', cursor);
    const httpsIndex: number = lower.indexOf('https://', cursor);
    let start: number = -1;
    if (httpIndex >= 0 && httpsIndex >= 0) {
      start = Math.min(httpIndex, httpsIndex);
    } else if (httpIndex >= 0) {
      start = httpIndex;
    } else if (httpsIndex >= 0) {
      start = httpsIndex;
    }
    if (start < 0) {
      return null;
    }
    let end: number = start;
    while (end < text.length && !this.isHttpTargetDelimiter(text[end])) {
      end += 1;
    }
    const trimmedEnd: number = this.trimAutoTargetEnd(text, start, end);
    if (trimmedEnd <= start) {
      return null;
    }
    const target: string = text.substring(start, trimmedEnd);
    return new InlineWebTargetMatch(start, trimmedEnd, target);
  }

  private findInlineLocalWebFileTarget(text: string, cursor: number): InlineWebTargetMatch | null {
    const lower: string = text.toLowerCase();
    let extensionIndex: number = this.nextOpenableFileExtensionIndex(lower, cursor);
    while (extensionIndex >= 0) {
      const extensionEnd: number = this.openableFileExtensionEnd(lower, extensionIndex);
      if (extensionEnd > extensionIndex) {
        let start: number = extensionIndex - 1;
        while (start >= 0 && !this.isLocalFileTargetDelimiter(text[start])) {
          start -= 1;
        }
        start += 1;
        let end: number = extensionEnd;
        if (end < text.length && (text[end] === '?' || text[end] === '#')) {
          end += 1;
          while (end < text.length && !this.isLocalFileTargetDelimiter(text[end])) {
            end += 1;
          }
        }
        end = this.trimAutoTargetEnd(text, start, end);
        if (start < end) {
          const rawTarget: string = text.substring(start, end);
          const target: string = this.normalizeInlineLocalWebFileTarget(rawTarget);
          if (this.isOpenableWebTarget(target)) {
            return new InlineWebTargetMatch(end - target.length, end, target);
          }
        }
      }
      extensionIndex = this.nextOpenableFileExtensionIndex(lower, extensionIndex + 1);
    }
    return null;
  }

  private nextOpenableFileExtensionIndex(lowerText: string, cursor: number): number {
    return lowerText.indexOf('.', cursor);
  }

  private normalizeInlineLocalWebFileTarget(target: string): string {
    const cleanTarget: string = target.trim();
    if (this.isFileUri(cleanTarget) || this.isAbsoluteLocalPath(cleanTarget)) {
      return cleanTarget;
    }
    for (let index: number = 0; index < cleanTarget.length; index += 1) {
      if (!this.isAsciiLocalFileStart(cleanTarget[index])) {
        continue;
      }
      const candidate: string = cleanTarget.substring(index);
      if (this.hasOpenableFileExtension(candidate)) {
        return candidate;
      }
    }
    return cleanTarget;
  }

  private isAsciiLocalFileStart(ch: string): boolean {
    return (ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch === '_' ||
      ch === '-' ||
      ch === '.';
  }

  private openableFileExtensionEnd(lowerText: string, extensionIndex: number): number {
    if (extensionIndex < 0 || extensionIndex + 1 >= lowerText.length) {
      return -1;
    }
    let end: number = extensionIndex + 1;
    while (end < lowerText.length) {
      const ch: string = lowerText[end];
      if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) {
        end += 1;
        continue;
      }
      break;
    }
    const extensionLength: number = end - extensionIndex - 1;
    if (extensionLength <= 0 || extensionLength > 16) {
      return -1;
    }
    let hasLetter: boolean = false;
    for (let index: number = extensionIndex + 1; index < end; index += 1) {
      const ch: string = lowerText[index];
      if (ch >= 'a' && ch <= 'z') {
        hasLetter = true;
        break;
      }
    }
    if (!hasLetter) {
      return -1;
    }
    if (end >= lowerText.length) {
      return end;
    }
    const next: string = lowerText[end];
    return next === '?' || next === '#' || this.isLocalFileTargetDelimiter(next) ? end : -1;
  }

  private isHttpTargetDelimiter(ch: string): boolean {
    return ch === ' ' || ch === '\n' || ch === '\r' || ch === '\t' ||
      ch === '<' || ch === '>' || ch === '"' || ch === '\'' || ch === '`';
  }

  private isLocalFileTargetDelimiter(ch: string): boolean {
    return this.isHttpTargetDelimiter(ch) ||
      ch === '[' || ch === ']' || ch === '(' || ch === ')' ||
      ch === '{' || ch === '}' || ch === ',' || ch === ';' || ch === '!' || ch === '?';
  }

  private trimAutoTargetEnd(text: string, start: number, end: number): number {
    let nextEnd: number = end;
    while (nextEnd > start) {
      const ch: string = text[nextEnd - 1];
      if (ch === '.' || ch === ',' || ch === ';' || ch === ':' || ch === '!' || ch === '?') {
        nextEnd -= 1;
        continue;
      }
      if ((ch === ')' || ch === ']') && this.hasUnbalancedClosingTargetChar(text.substring(start, nextEnd), ch)) {
        nextEnd -= 1;
        continue;
      }
      break;
    }
    return nextEnd;
  }

  private hasUnbalancedClosingTargetChar(value: string, closing: string): boolean {
    const opening: string = closing === ')' ? '(' : '[';
    let openCount: number = 0;
    let closeCount: number = 0;
    for (let index: number = 0; index < value.length; index += 1) {
      if (value[index] === opening) {
        openCount += 1;
      } else if (value[index] === closing) {
        closeCount += 1;
      }
    }
    return closeCount > openCount;
  }

  private cleanMarkdownLinkTarget(target: string): string {
    let result: string = target.trim();
    if (result.length >= 2 && result[0] === '<') {
      const closeIndex: number = result.indexOf('>');
      if (closeIndex > 0) {
        result = result.substring(1, closeIndex).trim();
      }
    }
    return result;
  }

  private pushInlineMarkdownSegment(segments: MathSegment[], segment: MathSegment): void {
    if (segment.text.length === 0) {
      return;
    }
    if (segment.kind === 'text' && segments.length > 0 && segments[segments.length - 1].kind === 'text') {
      const previous: MathSegment = segments[segments.length - 1];
      previous.text += segment.text;
      previous.rawText += segment.rawText;
      return;
    }
    segments.push(segment);
  }

  private findInlineDollarStart(text: string, cursor: number): number {
    for (let i = cursor; i < text.length; i++) {
      if (text[i] !== '$') {
        continue;
      }
      if (i > 0 && text[i - 1] === '\\') {
        continue;
      }
      if (i + 1 < text.length && text[i + 1] === '$') {
        continue;
      }
      return i;
    }
    return -1;
  }

  private findInlineDollarEnd(text: string, cursor: number): number {
    for (let i = cursor; i < text.length; i++) {
      if (text[i] !== '$') {
        continue;
      }
      if (i > 0 && text[i - 1] === '\\') {
        continue;
      }
      if (i + 1 < text.length && text[i + 1] === '$') {
        continue;
      }
      return i;
    }
    return -1;
  }

  private mathBlockLines(text: string): string[] {
    const normalized: string = this.normalizeFormulaSource(text).replace(/\\\\/g, '\n');
    const rawLines: string[] = normalized.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    const lines: string[] = [];
    for (let i = 0; i < rawLines.length; i++) {
      const line: string = rawLines[i].replace(/&/g, ' ').trim();
      if (line.length > 0) {
        lines.push(line);
      }
    }
    if (lines.length > 0) {
      return lines;
    }
    const fallback: string = normalized.trim();
    return fallback.length > 0 ? [fallback] : ['0'];
  }

  private normalizeFormulaSource(text: string): string {
    let result: string = text.trim();
    if (result.startsWith('$$') && result.endsWith('$$') && result.length > 4) {
      result = result.substring(2, result.length - 2).trim();
    } else if (result.startsWith('\\[') && result.endsWith('\\]') && result.length > 4) {
      result = result.substring(2, result.length - 2).trim();
    } else if (result.startsWith('\\(') && result.endsWith('\\)') && result.length > 4) {
      result = result.substring(2, result.length - 2).trim();
    } else if (result.startsWith('$') && result.endsWith('$') && result.length > 2) {
      result = result.substring(1, result.length - 1).trim();
    }
    result = result.replace(/\\begin\{[^{}]+\}/g, '');
    result = result.replace(/\\end\{[^{}]+\}/g, '');
    result = result.replace(/\\left/g, '');
    result = result.replace(/\\right/g, '');
    result = result.replace(/\\,/g, ' ');
    result = result.replace(/\\;/g, ' ');
    result = result.replace(/\\:/g, ' ');
    result = result.replace(/\\!/g, '');
    return result.trim();
  }

  private parseFormula(text: string): FormulaNode {
    const parsed: FormulaParseResult = this.parseFormulaSequence(this.normalizeFormulaSource(text), 0, '');
    return parsed.node;
  }

  private parseFormulaSequence(source: string, index: number, stopChar: string): FormulaParseResult {
    const children: FormulaNode[] = [];
    let cursor: number = index;

    while (cursor < source.length) {
      if (stopChar.length > 0 && source[cursor] === stopChar) {
        cursor += 1;
        break;
      }
      if (source[cursor] === '}') {
        break;
      }
      if (source[cursor] === ' ' || source[cursor] === '\t') {
        this.pushFormulaChild(children, new FormulaNode('text', ' '));
        cursor += 1;
        continue;
      }
      if (source[cursor] === '/') {
        const numeratorIndex: number = this.findFormulaFractionNumeratorIndex(children);
        if (numeratorIndex >= 0) {
          const denominatorCursor: number = this.skipFormulaWhitespace(source, cursor + 1);
          const denominator: FormulaParseResult = this.parseFormulaOperand(source, denominatorCursor);
          if (!(denominator.node.kind === 'text' && denominator.node.text.length === 0 && denominator.nextIndex === denominatorCursor)) {
            const numeratorNodes: FormulaNode[] = children.splice(numeratorIndex, children.length - numeratorIndex);
            const fraction: FormulaNode = new FormulaNode('fraction');
            fraction.numerator = numeratorNodes[0];
            fraction.denominator = denominator.node;
            this.pushFormulaChild(children, fraction);
            cursor = denominator.nextIndex;
            continue;
          }
        }
      }
      const operand: FormulaParseResult = this.parseFormulaOperand(source, cursor);
      this.pushFormulaChild(children, operand.node);
      cursor = operand.nextIndex;
    }

    if (children.length === 0) {
      return new FormulaParseResult(new FormulaNode('text', ''), cursor);
    }
    if (children.length === 1) {
      return new FormulaParseResult(children[0], cursor);
    }
    return new FormulaParseResult(new FormulaNode('sequence', '', children), cursor);
  }

  private parseFormulaOperand(source: string, index: number): FormulaParseResult {
    const atom: FormulaParseResult = this.parseFormulaAtom(source, index);
    let node: FormulaNode = atom.node;
    let cursor: number = atom.nextIndex;
    let superscript: FormulaNode | null = null;
    let subscript: FormulaNode | null = null;

    while (cursor < source.length && (source[cursor] === '^' || source[cursor] === '_')) {
      const operator: string = source[cursor];
      const operand: FormulaParseResult = this.parseFormulaScriptOperand(source, cursor + 1);
      cursor = operand.nextIndex;
      if (operator === '^') {
        superscript = operand.node;
      } else {
        subscript = operand.node;
      }
    }

    if (superscript !== null || subscript !== null) {
      const scriptNode: FormulaNode = new FormulaNode('script');
      scriptNode.base = node;
      scriptNode.superscript = superscript;
      scriptNode.subscript = subscript;
      node = scriptNode;
    }

    return new FormulaParseResult(node, cursor);
  }

  private parseFormulaScriptOperand(source: string, index: number): FormulaParseResult {
    if (index >= source.length) {
      return new FormulaParseResult(new FormulaNode('text', ''), index);
    }
    if (source[index] === '{') {
      return this.parseFormulaSequence(source, index + 1, '}');
    }
    return this.parseFormulaAtom(source, index);
  }

  private parseFormulaAtom(source: string, index: number): FormulaParseResult {
    if (index >= source.length) {
      return new FormulaParseResult(new FormulaNode('text', ''), index);
    }

    const current: string = source[index];
    if (current === '{') {
      return this.parseFormulaSequence(source, index + 1, '}');
    }
    if (current === '(') {
      return this.parseFormulaDelimitedGroup(source, index, ')', '()');
    }
    if (current === '[') {
      return this.parseFormulaDelimitedGroup(source, index, ']', '[]');
    }

    if (current === '\\') {
      if (index + 1 >= source.length) {
        return new FormulaParseResult(new FormulaNode('text', '\\'), index + 1);
      }

      if (source[index + 1] === '\\') {
        return new FormulaParseResult(new FormulaNode('text', ' '), index + 2);
      }

      let cursor: number = index + 1;
      while (cursor < source.length && this.isFormulaLetter(source[cursor])) {
        cursor += 1;
      }

      if (cursor === index + 1) {
        return new FormulaParseResult(new FormulaNode('text', source[index + 1]), index + 2);
      }

      const command: string = source.substring(index + 1, cursor);
      if (command === 'frac' || command === 'dfrac' || command === 'tfrac') {
        const numerator: FormulaParseResult = this.parseFormulaScriptOperand(source, cursor);
        const denominator: FormulaParseResult = this.parseFormulaScriptOperand(source, numerator.nextIndex);
        const fraction: FormulaNode = new FormulaNode('fraction');
        fraction.numerator = numerator.node;
        fraction.denominator = denominator.node;
        return new FormulaParseResult(fraction, denominator.nextIndex);
      }

      if (command === 'sqrt') {
        let nextIndex: number = cursor;
        if (nextIndex < source.length && source[nextIndex] === '[') {
          nextIndex += 1;
          while (nextIndex < source.length && source[nextIndex] !== ']') {
            nextIndex += 1;
          }
          if (nextIndex < source.length) {
            nextIndex += 1;
          }
        }
        const radicand: FormulaParseResult = this.parseFormulaScriptOperand(source, nextIndex);
        const sqrtNode: FormulaNode = new FormulaNode('sqrt');
        sqrtNode.radicand = radicand.node;
        return new FormulaParseResult(sqrtNode, radicand.nextIndex);
      }

      if (command === 'operatorname' && cursor < source.length && source[cursor] === '*') {
        cursor += 1;
      }

      if (command === 'text' || command === 'mathrm' || command === 'operatorname' || command === 'mathbf' ||
        command === 'mathit' || command === 'mathbb' || command === 'mathcal' || command === 'mathsf' || command === 'mathtt') {
        return this.parseFormulaTextGroup(source, cursor, command === 'mathit' ? 'italic' : 'roman');
      }

      if (command === 'displaystyle' || command === 'textstyle' || command === 'limits' || command === 'nolimits') {
        return new FormulaParseResult(new FormulaNode('text', ''), cursor);
      }

      if (this.isFormulaSpacingCommand(command)) {
        return new FormulaParseResult(new FormulaNode('space', command), cursor);
      }

      const mapped: string = this.formulaCommandText(command);
      if (mapped.length > 0) {
        return new FormulaParseResult(
          new FormulaNode(this.isFormulaOperatorCommand(command) ? 'operator' : 'text', mapped, [], this.isFormulaOperatorCommand(command) ? 'roman' : 'italic'),
          cursor
        );
      }

      return new FormulaParseResult(new FormulaNode('text', command), cursor);
    }

    if (this.isFormulaLetter(current)) {
      let cursor: number = index + 1;
      while (cursor < source.length && this.isFormulaLetter(source[cursor])) {
        cursor += 1;
      }
      return new FormulaParseResult(new FormulaNode('text', source.substring(index, cursor), [], 'italic'), cursor);
    }

    if (this.isFormulaDigit(current)) {
      let cursor: number = index + 1;
      while (cursor < source.length && this.isFormulaDigit(source[cursor])) {
        cursor += 1;
      }
      return new FormulaParseResult(new FormulaNode('number', source.substring(index, cursor), [], 'roman'), cursor);
    }

    return new FormulaParseResult(
      new FormulaNode(this.isFormulaOperatorChar(current) || this.isFormulaPunctuationChar(current) ? 'operator' : 'text', current, [], 'roman'),
      index + 1
    );
  }

  private pushFormulaChild(children: FormulaNode[], node: FormulaNode): void {
    if (node.kind === 'text' && node.text.length === 0) {
      return;
    }
    if (children.length > 0 && children[children.length - 1].kind === node.kind && children[children.length - 1].variant === node.variant &&
      (node.kind === 'text' || node.kind === 'number' || node.kind === 'operator')) {
      children[children.length - 1].text += node.text;
      return;
    }
    children.push(node);
  }

  private parseFormulaTextGroup(source: string, index: number, variant: string): FormulaParseResult {
    if (index >= source.length || source[index] !== '{') {
      return this.parseFormulaScriptOperand(source, index);
    }
    let cursor: number = index + 1;
    let depth: number = 1;
    let result: string = '';
    while (cursor < source.length && depth > 0) {
      if (source[cursor] === '{') {
        depth += 1;
        result += source[cursor];
        cursor += 1;
        continue;
      }
      if (source[cursor] === '}') {
        depth -= 1;
        if (depth === 0) {
          cursor += 1;
          break;
        }
        result += source[cursor];
        cursor += 1;
        continue;
      }
      result += source[cursor];
      cursor += 1;
    }
    return new FormulaParseResult(new FormulaNode('text', result, [], variant), cursor);
  }

  private parseFormulaDelimitedGroup(source: string, index: number, closingChar: string, delimiter: string): FormulaParseResult {
    const inner: FormulaParseResult = this.parseFormulaSequence(source, index + 1, closingChar);
    return new FormulaParseResult(new FormulaNode('group', delimiter, [inner.node]), inner.nextIndex);
  }

  private skipFormulaWhitespace(source: string, index: number): number {
    let cursor: number = index;
    while (cursor < source.length && (source[cursor] === ' ' || source[cursor] === '\t')) {
      cursor += 1;
    }
    return cursor;
  }

  private findFormulaFractionNumeratorIndex(children: FormulaNode[]): number {
    let index: number = children.length - 1;
    while (index >= 0 && this.isFormulaSpaceNode(children[index])) {
      index -= 1;
    }
    if (index < 0) {
      return -1;
    }
    return this.isFormulaFractionCandidate(children[index]) ? index : -1;
  }

  private isFormulaSpaceNode(node: FormulaNode): boolean {
    return node.kind === 'text' && node.text === ' ';
  }

  private isFormulaFractionCandidate(node: FormulaNode): boolean {
    if (node.kind === 'text' || node.kind === 'number' || node.kind === 'sequence' || node.kind === 'group' ||
      node.kind === 'fraction' || node.kind === 'sqrt' || node.kind === 'script') {
      return true;
    }
    if (node.kind === 'operator') {
      return node.text.length > 1 || '+-=<>*/'.indexOf(node.text) < 0;
    }
    return false;
  }

  private isFormulaLetter(ch: string): boolean {
    return /[A-Za-z]/.test(ch);
  }

  private isFormulaDigit(ch: string): boolean {
    return /[0-9]/.test(ch);
  }

  private isFormulaOperatorChar(ch: string): boolean {
    return '+-=<>*/'.indexOf(ch) >= 0;
  }

  private isFormulaPunctuationChar(ch: string): boolean {
    return '()[]{}|,.;:!'.indexOf(ch) >= 0;
  }

  private isFormulaSpacingCommand(command: string): boolean {
    return command === 'quad' || command === 'qquad';
  }

  private isFormulaOperatorCommand(command: string): boolean {
    return command === 'sum' ||
      command === 'prod' ||
      command === 'int' ||
      command === 'oint' ||
      command === 'times' ||
      command === 'cdot' ||
      command === 'pm' ||
      command === 'mp' ||
      command === 'leq' ||
      command === 'le' ||
      command === 'geq' ||
      command === 'ge' ||
      command === 'neq' ||
      command === 'approx' ||
      command === 'mid' ||
      command === 'cap' ||
      command === 'cup' ||
      command === 'in' ||
      command === 'notin' ||
      command === 'to' ||
      command === 'rightarrow' ||
      command === 'leftarrow' ||
      command === 'mapsto' ||
      command === 'sin' ||
      command === 'cos' ||
      command === 'tan' ||
      command === 'log' ||
      command === 'ln' ||
      command === 'lim' ||
      command === 'limsup' ||
      command === 'liminf' ||
      command === 'sup' ||
      command === 'inf' ||
      command === 'argmax' ||
      command === 'argmin' ||
      command === 'max' ||
      command === 'min' ||
      command === 'exp';
  }

  private formulaCommandText(command: string): string {
    switch (command) {
      case 'alpha': return 'α';
      case 'beta': return 'β';
      case 'gamma': return 'γ';
      case 'delta': return 'δ';
      case 'epsilon':
      case 'varepsilon': return 'ε';
      case 'theta':
      case 'vartheta': return 'θ';
      case 'lambda': return 'λ';
      case 'mu': return 'μ';
      case 'pi': return 'π';
      case 'sigma': return 'σ';
      case 'phi':
      case 'varphi': return 'φ';
      case 'omega': return 'ω';
      case 'Gamma': return 'Γ';
      case 'Delta': return 'Δ';
      case 'Theta': return 'Θ';
      case 'Lambda': return 'Λ';
      case 'Pi': return 'Π';
      case 'Sigma': return 'Σ';
      case 'Phi': return 'Φ';
      case 'Omega': return 'Ω';
      case 'sum': return '∑';
      case 'prod': return '∏';
      case 'int': return '∫';
      case 'oint': return '∮';
      case 'infty': return '∞';
      case 'times': return '×';
      case 'cdot': return '·';
      case 'pm': return '±';
      case 'mp': return '∓';
      case 'neq': return '≠';
      case 'approx': return '≈';
      case 'mid': return '|';
      case 'cap': return '∩';
      case 'cup': return '∪';
      case 'in': return '∈';
      case 'notin': return '∉';
      case 'le':
      case 'leq': return '≤';
      case 'ge':
      case 'geq': return '≥';
      case 'to':
      case 'rightarrow': return '→';
      case 'leftarrow': return '←';
      case 'mapsto': return '↦';
      case 'cdots': return '⋯';
      case 'ldots': return '…';
      case 'sin':
      case 'cos':
      case 'tan':
      case 'log':
      case 'ln':
      case 'lim':
      case 'limsup':
      case 'liminf':
      case 'sup':
      case 'inf':
      case 'argmax':
      case 'argmin':
      case 'max':
      case 'min':
      case 'exp': return command;
      default: return '';
    }
  }

  private renderInlineMath(text: string): string {
    let result: string = '';
    let cursor: number = 0;
    while (cursor < text.length) {
      const start: number = this.findInlineDollarStart(text, cursor);
      if (start < 0) {
        result += text.substring(cursor);
        break;
      }
      const end: number = this.findInlineDollarEnd(text, start + 1);
      if (end < 0) {
        result += text.substring(cursor);
        break;
      }
      const expr: string = text.substring(start + 1, end);
      if (expr.indexOf('\n') >= 0 || expr.trim().length === 0) {
        result += text.substring(cursor, end + 1);
      } else {
        result += text.substring(cursor, start) + this.renderMathText(expr);
      }
      cursor = end + 1;
    }
    return result;
  }

  private renderInlineParenMath(text: string): string {
    let result: string = '';
    let cursor: number = 0;
    while (cursor < text.length) {
      const start: number = text.indexOf('\\(', cursor);
      if (start < 0) {
        result += text.substring(cursor);
        break;
      }
      const end: number = text.indexOf('\\)', start + 2);
      if (end < 0) {
        result += text.substring(cursor);
        break;
      }
      const expr: string = text.substring(start + 2, end);
      if (expr.indexOf('\n') >= 0 || expr.trim().length === 0) {
        result += text.substring(cursor, end + 2);
      } else {
        result += text.substring(cursor, start) + this.renderMathText(expr);
      }
      cursor = end + 2;
    }
    return result;
  }

  private renderMathText(text: string): string {
    let result: string = text.trim();
    let previous: string = '';
    while (previous !== result) {
      previous = result;
      result = result.replace(/\\begin\{[^{}]+\}/g, '');
      result = result.replace(/\\end\{[^{}]+\}/g, '');
      result = result.replace(/\\operatorname\{([^{}]+)\}/g, '$1');
      result = result.replace(/\\mathrm\{([^{}]+)\}/g, '$1');
      result = result.replace(/\\text\{([^{}]+)\}/g, '$1');
      result = result.replace(/\\left/g, '');
      result = result.replace(/\\right/g, '');
      result = result.replace(/\\frac\{([^{}]+)\}\{([^{}]+)\}/g, '($1)/($2)');
      result = result.replace(/\\sqrt\{([^{}]+)\}/g, '√($1)');
    }
    result = result.replace(/\\\\/g, '\n');
    result = result.replace(/\s*&\s*/g, '  ');
    result = result.replace(/\\qquad/g, '    ');
    result = result.replace(/\\quad/g, '  ');
    result = result.replace(/\\,/g, ' ');
    result = result.replace(/\\;/g, ' ');
    result = result.replace(/\\:/g, ' ');
    result = result.replace(/\\!/g, '');
    result = result.replace(/\\sum/g, 'Σ');
    result = result.replace(/\\int/g, '∫');
    result = result.replace(/\\prod/g, 'Π');
    result = result.replace(/\\to/g, '→');
    result = result.replace(/\\mapsto/g, '↦');
    result = result.replace(/\\cdots/g, '⋯');
    result = result.replace(/\\ldots/g, '…');
    result = result.replace(/\\times/g, '×');
    result = result.replace(/\\cdot/g, '·');
    result = result.replace(/\\leq?/g, '≤');
    result = result.replace(/\\geq?/g, '≥');
    result = result.replace(/\\neq/g, '≠');
    result = result.replace(/\\approx/g, '≈');
    result = result.replace(/\\rightarrow/g, '→');
    result = result.replace(/\\leftarrow/g, '←');
    result = result.replace(/\\alpha/g, 'α');
    result = result.replace(/\\beta/g, 'β');
    result = result.replace(/\\gamma/g, 'γ');
    result = result.replace(/\\delta/g, 'δ');
    result = result.replace(/\\lambda/g, 'λ');
    result = result.replace(/\\mu/g, 'μ');
    result = result.replace(/\\pi/g, 'π');
    result = result.replace(/\\sigma/g, 'σ');
    result = result.replace(/\\theta/g, 'θ');
    result = result.replace(/\\infty/g, '∞');
    result = result.replace(/\^\{([^{}]+)\}/g, (_match: string, expr: string): string => this.renderMathSuperscript(expr));
    result = result.replace(/\^([A-Za-z0-9+\-=()])/g, (_match: string, expr: string): string => this.renderMathSuperscript(expr));
    result = result.replace(/_\{([^{}]+)\}/g, (_match: string, expr: string): string => this.renderMathSubscript(expr));
    result = result.replace(/_([A-Za-z0-9+\-=()])/g, (_match: string, expr: string): string => this.renderMathSubscript(expr));
    result = result.replace(/[ \t]+\n/g, '\n');
    result = result.replace(/\n[ \t]+/g, '\n');
    return result;
  }

  private renderMathSuperscript(text: string): string {
    const map: Record<string, string> = {
      '0': '⁰',
      '1': '¹',
      '2': '²',
      '3': '³',
      '4': '⁴',
      '5': '⁵',
      '6': '⁶',
      '7': '⁷',
      '8': '⁸',
      '9': '⁹',
      '+': '⁺',
      '-': '⁻',
      '=': '⁼',
      '(': '⁽',
      ')': '⁾',
      'n': 'ⁿ',
      'i': 'ⁱ'
    };
    let result: string = '';
    const source: string = text.trim();
    for (let i = 0; i < source.length; i++) {
      const mapped: string | undefined = map[source[i]];
      if (mapped === undefined) {
        return `^(${source})`;
      }
      result += mapped;
    }
    return result;
  }

  private renderMathSubscript(text: string): string {
    const map: Record<string, string> = {
      '0': '₀',
      '1': '₁',
      '2': '₂',
      '3': '₃',
      '4': '₄',
      '5': '₅',
      '6': '₆',
      '7': '₇',
      '8': '₈',
      '9': '₉',
      '+': '₊',
      '-': '₋',
      '=': '₌',
      '(': '₍',
      ')': '₎',
      'a': 'ₐ',
      'e': 'ₑ',
      'h': 'ₕ',
      'i': 'ᵢ',
      'j': 'ⱼ',
      'k': 'ₖ',
      'l': 'ₗ',
      'm': 'ₘ',
      'n': 'ₙ',
      'o': 'ₒ',
      'p': 'ₚ',
      'r': 'ᵣ',
      's': 'ₛ',
      't': 'ₜ',
      'u': 'ᵤ',
      'v': 'ᵥ',
      'x': 'ₓ'
    };
    let result: string = '';
    const source: string = text.trim();
    for (let i = 0; i < source.length; i++) {
      const mapped: string | undefined = map[source[i]];
      if (mapped === undefined) {
        return `_(${source})`;
      }
      result += mapped;
    }
    return result;
  }

  private mathDisplayLines(text: string): string[] {
    const lines: string[] = this.renderMathText(text)
      .split('\n')
      .map((line: string): string => line.trim())
      .filter((line: string): boolean => line.length > 0);
    if (lines.length > 0) {
      return lines;
    }
    const fallback: string = this.renderMathText(text).trim();
    return fallback.length > 0 ? [fallback] : ['0'];
  }

  private fencedCodeSource(language: string, code: string): string {
    const info: string = language.trim();
    if (info.length > 0) {
      return `\`\`\`${info}\n${code}\n\`\`\``;
    }
    return `\`\`\`\n${code}\n\`\`\``;
  }

  private wrappedMathSource(opening: string, closing: string, body: string): string {
    if (body.indexOf('\n') >= 0) {
      return `${opening}\n${body}\n${closing}`;
    }
    return `${opening}${body}${closing}`;
  }

  private markdownHeadingFontSize(level: number): number {
    if (level <= 1) {
      return this.conversationFontSize(18);
    }
    if (level === 2) {
      return this.conversationFontSize(16);
    }
    if (level === 3) {
      return this.conversationFontSize(14);
    }
    return this.conversationFontSize(13);
  }

  private markdownHeadingLineHeight(level: number): number {
    if (level <= 1) {
      return this.conversationLineHeight(26);
    }
    if (level === 2) {
      return this.conversationLineHeight(24);
    }
    return this.conversationLineHeight(21);
  }

  private markdownListMarker(line: string): string {
    const ordered: RegExpMatchArray | null = line.match(/^(\d+)\.\s+.+$/);
    if (ordered !== null) {
      return `${ordered[1]}.`;
    }
    return '•';
  }

  private markdownListText(line: string): string {
    return line.replace(/^([-*+])\s+/, '').replace(/^\d+\.\s+/, '');
  }

  private messageIcon(itemType?: string): string {
    switch (itemType) {
      case 'reasoning':
        return '🧠';
      case 'command':
        return '⚡';
      case 'tool':
        return '🔧';
      case 'file':
        return '📄';
      case 'search':
        return '🔍';
      case 'plan':
        return '📋';
      case 'image':
        return '🖼️';
      case 'hook':
        return '🪝';
      case 'review':
        return '👁️';
      default:
        return '';
    }
  }

  private eventSoftBackground(role: string): string {
    switch (role) {
      case 'reasoning': return '#FFFBEB';
      case 'command': return '#ECFDF5';
      case 'tool': return '#EFF6FF';
      case 'file': return '#F5F3FF';
      case 'search': return '#F0FDFA';
      case 'plan': return '#FFF7ED';
      case 'image': return '#FDF2F8';
      case 'hook': return '#FEFCE8';
      case 'review': return '#FEF9C3';
      default: return '#F8FAFC';
    }
  }

  private eventBorderColor(role: string): string {
    switch (role) {
      case 'reasoning': return '#FDE68A';
      case 'command': return '#A7F3D0';
      case 'tool': return '#BFDBFE';
      case 'file': return '#DDD6FE';
      case 'search': return '#99F6E4';
      case 'plan': return '#FED7AA';
      case 'image': return '#FBCFE8';
      case 'hook': return '#FDE68A';
      case 'review': return '#FACC15';
      default: return this.themeBorder();
    }
  }

  private emptyMessageBodyText(item: ChatMessage): string {
    const type: string = item.itemType ?? item.role;
    if (type === 'reasoning') {
      return item.status === 'inProgress' ? '等待可展示的思考内容。' : '本次没有返回可展示的思考内容。';
    }
    if (item.status === 'inProgress') {
      return this.thinkingStatusText();
    }
    return '没有可展示的输出。';
  }

  private collapsedMessagePreview(item: ChatMessage): string {
    const text: string = item.content.replace(/\s+/g, ' ').trim();
    if (this.isReasoningMessage(item)) {
      if (text.length > 0) {
        return text;
      }
      return item.status === 'inProgress' ? this.thinkingStatusPhraseText() : '点击展开查看思考内容。';
    }
    if (text.length > 0) {
      return text;
    }
    return this.emptyMessageBodyText(item);
  }

  private compactionNoticeStatusLabel(status: string): string {
    switch (status) {
      case 'starting':
        return '启动中';
      case 'running':
        return '压缩中';
      case 'completed':
        return '已完成';
      case 'failed':
        return '失败';
      case 'timeout':
        return '超时';
      default:
        return status;
    }
  }

  private compactionNoticeColor(status: string): string {
    switch (status) {
      case 'failed':
      case 'timeout':
        return '#DC2626';
      case 'starting':
      case 'running':
        return '#2563EB';
      case 'completed':
        return '#4338CA';
      default:
        return '#64748B';
    }
  }

  private compactionNoticeSoftBackground(status: string): string {
    switch (status) {
      case 'failed':
      case 'timeout':
        return '#FEF2F2';
      case 'starting':
      case 'running':
        return '#EFF6FF';
      case 'completed':
        return '#EEF2FF';
      default:
        return this.themeSubtleBackground();
    }
  }

  private compactionNoticeBorderColor(status: string): string {
    switch (status) {
      case 'failed':
      case 'timeout':
        return '#FECACA';
      case 'starting':
      case 'running':
        return '#BFDBFE';
      case 'completed':
        return '#C7D2FE';
      default:
        return this.themeStrongBorder();
    }
  }

  private compactionNoticeSummary(notice: CompactionNotice): string {
    if (notice.status === 'starting' || notice.status === 'running') {
      if (notice.savedTokens > 0) {
        return `已释放 ${this.formatTokenCount(notice.savedTokens)} tokens，正在同步最终结果。`;
      }
      return '正在压缩当前线程上下文。';
    }
    if (notice.errorMessage.trim().length > 0) {
      return notice.errorMessage.trim();
    }
    if (notice.savedTokens > 0) {
      return `释放 ${this.formatTokenCount(notice.savedTokens)} tokens。`;
    }
    return '压缩完成，token 用量暂无明显变化。';
  }

  private compactionSavedText(notice: CompactionNotice): string {
    if (notice.savedTokens > 0) {
      return `${this.formatTokenCount(notice.savedTokens)} tokens`;
    }
    if (notice.status === 'starting' || notice.status === 'running') {
      return '计算中';
    }
    return '0 tokens';
  }

  private statusLabel(status: string): string {
    switch (status) {
      case 'inProgress':
        return '进行中';
      case 'failed':
        return '失败';
      case 'declined':
        return '已拒绝';
      default:
        return status;
    }
  }

  private statusColor(status: string): string {
    switch (status) {
      case 'inProgress':
        return '#0369A1';
      case 'failed':
        return '#DC2626';
      case 'declined':
        return '#D97706';
      default:
        return '#71717A';
    }
  }

  private statusBgColor(status: string): string {
    switch (status) {
      case 'inProgress':
        return '#E0F2FE';
      case 'failed':
        return '#FEE2E2';
      case 'declined':
        return '#FEF3C7';
      default:
        return this.themeSubtleBackground();
    }
  }

  private messageContentColor(itemType?: string): string {
    switch (itemType) {
      case 'reasoning':
        return this.themeTextSecondary();
      case 'command':
      case 'tool':
        return '#1E40AF';
      default:
        return '#27272A';
    }
  }

  @Builder
  private diffRow(line: CodeDiffLine) {
    Row() {
      Text(line.lineNumber)
        .copyOption(CopyOptions.LocalDevice)
        .width(28)
        .fontSize(10)
        .fontColor(this.themeTextMuted())
        .fontFamily('monospace')

      Text(line.sign)
        .copyOption(CopyOptions.LocalDevice)
        .width(12)
        .fontSize(11)
        .fontColor(this.diffColor(line.kind))
        .fontFamily('monospace')

      Text(line.content)
        .copyOption(CopyOptions.LocalDevice)
        .layoutWeight(1)
        .fontSize(10)
        .fontColor(this.diffColor(line.kind))
        .fontFamily('monospace')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 7, bottom: 7 })
    .backgroundColor(this.diffBackground(line.kind))
    .borderRadius(8)
  }

  @Builder
  private diffFileRow(file: CodeDiffFile) {
    Row() {
      Column() {
        Text(file.label)
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(11)
          .fontWeight(this.isDiffFileSelected(file) ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.themeTextPrimary())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(file.path)
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(9)
          .fontColor(this.themeTextMuted())
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(file.diffStat)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(10)
        .fontColor(this.isDiffFileSelected(file) ? '#2563EB' : '#16A34A')
        .margin({ left: 8 })

      Text('↗')
        .copyOption(CopyOptions.None)
        .fontSize(12)
        .fontColor(this.themeTextSecondary())
        .textAlign(TextAlign.Center)
        .width(26)
        .height(26)
        .margin({ left: 8 })
        .backgroundColor(this.themeElevatedBackground())
        .border({ width: 0.5, color: this.themeBorder() })
        .borderRadius(7)
        .onClick(() => {
          this.selectDiffFile(file.path);
          this.openDiffFileWithSystem(file);
        })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(this.isDiffFileSelected(file) ? '#EFF6FF' : this.themeElevatedBackground())
    .border({ width: 0.5, color: this.isDiffFileSelected(file) ? '#93C5FD' : this.themeBorder() })
    .borderRadius(8)
    .gesture(
      TapGesture({ count: 2 })
        .onAction(() => {
          this.selectDiffFile(file.path);
          this.openDiffFileWithSystem(file);
        })
    )
    .gesture(
      TapGesture({ count: 1 })
        .onAction(() => {
          this.selectDiffFile(file.path);
        })
    )
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => {
          this.selectDiffFile(file.path);
          this.openDiffFileWithSystem(file);
        })
    )
  }


  @Builder
  private approvalCard(approval: CodexApprovalRequest) {
    Column() {
      Row() {
        this.panelTitle(approval.title, 'app-server 正在等待前端响应')

        Blank()
          .layoutWeight(1)

        this.chip('需要确认', '#FEF3C7', '#92400E')
      }
      .width('100%')

      Text(approval.detail)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(this.conversationFontSize(12))
        .fontColor(this.themeTextStrong())
        .lineHeight(this.conversationLineHeight(19))
        .margin({ top: 10 })

      Row() {
        Button('允许')
          .height(34)
          .fontSize(12)
          .backgroundColor('#27272A')
          .fontColor('#FFFFFF')
          .borderRadius(8)
          .onClick(() => {
            void this.approvePending();
          })

        Button('拒绝')
          .height(34)
          .margin({ left: 8 })
          .fontSize(12)
          .backgroundColor(this.themePanelBackground())
          .fontColor(this.themeTextStrong())
          .borderRadius(8)
          .border({ width: 0.5, color: this.themeBorder() })
          .onClick(() => {
            void this.declinePending();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 12 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .backgroundColor(this.eventSoftBackground('reasoning'))
    .border({ width: 0.5, color: this.eventBorderColor('reasoning') })
    .borderRadius(10)
    .margin({ top: 10 })
  }

  @Builder
  private requestUserInputCard(request: CodexRequestUserInput) {
    Column() {
      Row() {
        this.panelTitle(request.title, '继续执行当前计划前，需要你补充信息')

        Blank()
          .layoutWeight(1)

        this.chip('Plan', '#FFF7ED', '#C2410C')
      }
      .width('100%')

      if (request.detail.trim().length > 0) {
        Text(request.detail)
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(this.conversationFontSize(12))
          .fontColor(this.themeTextStrong())
          .lineHeight(this.conversationLineHeight(19))
          .margin({ top: 10 })
      }

      Column() {
        ForEach(request.questions, (question: CodexRequestUserInputQuestion) => {
          Column() {
            Text(question.header)
              .fontSize(this.conversationFontSize(11))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.themeTextPrimary())

            Text(question.question)
              .fontSize(this.conversationFontSize(11))
              .fontColor(this.themeTextSecondary())
              .lineHeight(this.conversationLineHeight(18))
              .margin({ top: 4 })

            if (question.options.length > 0) {
              Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
                ForEach(question.options, (option: CodexRequestUserInputOption) => {
                  Column() {
                    this.optionChip(
                      new SelectorOption(option.label, option.label),
                      this.requestUserInputAnswer(question.id) === option.label,
                      () => {
                        this.setRequestUserInputAnswer(question.id, option.label);
                      }
                    )
                    if (option.description.trim().length > 0) {
                      Text(option.description)
                        .fontSize(this.conversationFontSize(10))
                        .fontColor(this.themeTextMuted())
                        .lineHeight(this.conversationLineHeight(16))
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .margin({ right: 8, bottom: 8 })
                }, (option: CodexRequestUserInputOption) => `${question.id}:${option.label}`)
              }
              .width('100%')
              .margin({ top: 8 })
            }

            if (question.isOther || question.options.length === 0) {
              TextInput({
                text: this.requestUserInputAnswer(question.id),
                placeholder: question.isSecret ? '输入不会展示在会话流里的私密内容' : '输入你的回答'
              })
                .width('100%')
                .height(40)
                .margin({ top: 8 })
                .fontSize(this.conversationFontSize(11))
                .backgroundColor(this.themePanelBackground())
                .borderRadius(8)
                .border({ width: 0.5, color: this.themeBorder() })
                .padding({ left: 12, right: 12 })
                .onChange((value: string) => {
                  this.setRequestUserInputAnswer(question.id, value);
                })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 12 })
        }, (question: CodexRequestUserInputQuestion) => question.id)
      }
      .width('100%')

      Row() {
        Button('继续')
          .height(34)
          .fontSize(12)
          .backgroundColor('#27272A')
          .fontColor('#FFFFFF')
          .borderRadius(8)
          .onClick(() => {
            void this.submitRequestUserInput();
          })

        Button('取消')
          .height(34)
          .margin({ left: 8 })
          .fontSize(12)
          .backgroundColor(this.themePanelBackground())
          .fontColor(this.themeTextStrong())
          .borderRadius(8)
          .border({ width: 0.5, color: this.themeBorder() })
          .onClick(() => {
            void this.declineRequestUserInput();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 14 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .backgroundColor(this.eventSoftBackground('plan'))
    .border({ width: 0.5, color: this.eventBorderColor('plan') })
    .borderRadius(10)
    .margin({ top: 10 })
  }

  @Builder
  private leftPanel() {
    Column() {
      // Header
      Row() {
        Text('ArkPilot')
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.themeTextPrimary())
          .layoutWeight(1)
          .onClick(() => { this.showAboutDialog = true; })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider()
        .width('100%')
        .color(this.themeStrongBorder())
        .strokeWidth(0.5)
        .margin({ top: 12, bottom: 4 })

      // Title row with + button
      Row() {
        Text('项目')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themeTextPrimary())

        Blank()
          .layoutWeight(1)

        Text('+')
          .fontSize(18)
          .fontColor(this.themeTextSecondary())
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .onClick(() => {
            this.openCreateProjectDialog();
          })
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 8, bottom: 8 })

      // Scrollable project list — takes all remaining space
      List({ scroller: this.leftScrollController }) {
        if (this.projects.length === 0) {
          ListItem() {
            Text('暂无项目，点击右上角 + 创建')
              .fontSize(10)
              .fontColor(this.themeTextMuted())
              .margin({ top: 4 })
          }
        } else {
          ForEach(this.projects, (proj: ProjectRecord) => {
            ListItem() {
              this.projectGroup(proj)
            }
            .hitTestBehavior(HitTestMode.Transparent)
          }, (proj: ProjectRecord) => `${proj.id}_${proj.expanded.toString()}`)
        }
      }
      .listDirection(Axis.Vertical)
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(6)

      // Account status row — always above settings
      if (this.accountLoggedIn) {
        Row() {
          Column() {
            Text('Huawei 账号')
              .copyOption(CopyOptions.None)
              .fontSize(10)
              .fontColor(this.themeTextMuted())

            Text(this.accountDisplayName())
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.themeTextPrimary())
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button('切换账号')
            .height(28)
            .padding({ left: 10, right: 10 })
            .fontSize(10)
            .fontColor(this.themeTextSecondary())
            .backgroundColor(this.themeSubtleBackground())
            .borderRadius(14)
            .border({ width: 0.5, color: this.themeBorder() })
            .onClick(() => {
              this.openSwitchAccountPage();
            })

          Button('退出登录')
            .height(28)
            .padding({ left: 10, right: 10 })
            .fontSize(10)
            .fontColor(this.themeTextSecondary())
            .backgroundColor(this.themeSubtleBackground())
            .borderRadius(14)
            .border({ width: 0.5, color: this.themeBorder() })
            .margin({ left: 6 })
            .onClick(() => {
              this.openLogoutDialog();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 8, top: 8, bottom: 8 })
        .backgroundColor(this.themeElevatedBackground())
        .borderRadius(16)
        .border({ width: 0.5, color: this.themeBorder() })
        .margin({ top: 8 })
      } else {
        Button('未登录 · 点击登录')
          .height(38)
          .width('100%')
          .fontSize(12)
          .fontColor(this.themeTextSecondary())
          .backgroundColor(this.themeElevatedBackground())
          .borderRadius(16)
          .border({ width: 0.5, color: this.themeBorder() })
          .margin({ top: 8 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/AiLoginPage' });
          })
      }

      // Settings button — always at bottom
      Button() {
        Row() {
          Text('⚙')
            .fontSize(14)
            .fontColor(this.themeTextSecondary())

          Text('设置')
            .fontSize(12)
            .fontColor(this.themeTextSecondary())
            .margin({ left: 6 })
        }
      }
      .height(38)
      .width('100%')
      .margin({ top: 8 })
      .backgroundColor(this.themeElevatedBackground())
      .borderRadius(16)
      .border({ width: 0.5, color: this.themeBorder() })
      .onClick(() => {
        router.pushUrl({ url: 'pages/AiSettingsPage' });
      })

    }
    .height('100%')
    .width(this.leftPanelWidth)
    .padding(12)
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.themeBorder() })
    .borderRadius(20)
    .onClick(() => {
      this.showProjectMenuId = '';
      this.showSessionMenuId = '';
    })
  }

  @Builder
  private chatCenterView() {
    Column() {
      Column() {
        Row() {
          Button() {
            Stack() {
              Column()
                .width(16)
                .height(12)
                .borderRadius(3)
                .border({ width: 1.5, color: this.themeTextSecondary() })
                .backgroundColor(this.showLeftDrawer ? this.themeSubtleBackground() : this.themeElevatedBackground())
              Column()
                .width(1.5)
                .height(8)
                .backgroundColor(this.themeTextSecondary())
                .position({ x: 4, y: 2 })
            }
            .width(16)
            .height(12)
          }
          .type(ButtonType.Normal)
          .width(32)
          .height(28)
          .backgroundColor(this.themePanelBackground())
          .borderRadius(8)
          .border({ width: 0.5, color: this.themeBorder() })
          .onClick(() => {
            this.toggleLeftDrawer();
          })

          Blank()
            .width(6)

          Column() {
            Text(this.currentWorkspaceTitle)
              .copyOption(CopyOptions.LocalDevice)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.themeTextPrimary())

            Text(this.currentWorkspaceDescription)
              .copyOption(CopyOptions.LocalDevice)
              .fontSize(10)
              .fontColor(this.themeTextMuted())
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)

          Blank()
            .layoutWeight(1)

          if (!this.isPhoneBreakpoint()) {
            Row() {
              Text(this.currentCollaborationModeLabel())
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontColor('#C2410C')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(this.eventSoftBackground('plan'))
                .borderRadius(6)
              Blank()
                .width(6)
              Text(this.currentModelLabel())
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontColor('#2563EB')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(this.eventSoftBackground('tool'))
                .borderRadius(6)
              Blank()
                .width(6)
              Text(this.currentEffortLabel())
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontColor(this.themeTextSecondary())
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(this.themeSubtleBackground())
                .borderRadius(6)
              Blank()
                .width(6)
            }
            .alignItems(VerticalAlign.Center)
          }

          this.conversationZoomControl()

          Blank()
            .width(6)

          Button() {
            Stack() {
              Column()
                .width(16)
                .height(12)
                .borderRadius(3)
                .border({ width: 1.5, color: this.themeTextSecondary() })
                .backgroundColor(this.showRightDrawer ? this.themeSubtleBackground() : this.themeElevatedBackground())
              Column()
                .width(1.5)
                .height(8)
                .backgroundColor(this.themeTextSecondary())
                .position({ x: 10.5, y: 2 })
            }
            .width(16)
            .height(12)
          }
          .type(ButtonType.Normal)
          .width(32)
          .height(28)
          .backgroundColor(this.themePanelBackground())
          .borderRadius(8)
          .border({ width: 0.5, color: this.themeBorder() })
          .onClick(() => {
            this.toggleRightDrawer();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.isPhoneBreakpoint()) {
          Row() {
            Text(this.currentCollaborationModeLabel())
              .copyOption(CopyOptions.None)
              .fontSize(10)
              .fontColor('#C2410C')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.eventSoftBackground('plan'))
              .borderRadius(6)
            Blank()
              .width(6)
            Text(this.currentModelLabel())
              .copyOption(CopyOptions.None)
              .fontSize(10)
              .fontColor('#2563EB')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.eventSoftBackground('tool'))
              .borderRadius(6)
            Blank()
              .width(6)
            Text(this.currentEffortLabel())
              .copyOption(CopyOptions.None)
              .fontSize(10)
              .fontColor(this.themeTextSecondary())
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.themeSubtleBackground())
              .borderRadius(6)
          }
          .width('100%')
          .margin({ top: 8 })
        }
      }
      .width('100%')

      if (!this.isPhoneBreakpoint() && this.pendingApproval !== null) {
        this.approvalCard(this.pendingApproval!)
      }

      if (!this.isPhoneBreakpoint() && this.pendingRequestUserInput !== null) {
        this.requestUserInputCard(this.pendingRequestUserInput!)
      }

      Column() {
        Scroll(this.messageScroller) {
          Column() {
            ForEach(this.compactionNoticesBeforeMessages(), (notice: CompactionNotice) => {
              this.compactionNoticeLine(notice)
            }, (notice: CompactionNotice) => this.compactionNoticeRenderKey(notice))
            ForEach(this.visibleMessages(), (item: ChatMessage) => {
              this.messageLine(item)
              ForEach(this.compactionNoticesAfterMessage(item.id), (notice: CompactionNotice) => {
                this.compactionNoticeLine(notice)
              }, (notice: CompactionNotice) => this.compactionNoticeRenderKey(notice))
            }, (item: ChatMessage) => this.messageRenderKey(item))
            if (this.shouldShowTurnActivityLine()) {
              this.turnActivityLine()
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .margin({ top: 10 })
        .scrollBar(this.mouseNearRightEdge ? BarState.On : BarState.Auto)
        .onWillScroll((xOffset: number, yOffset: number, scrollState: ScrollState, scrollSource: ScrollSource) => {
          return this.handleMessageWillScroll(xOffset, yOffset, scrollState, scrollSource);
        })
        .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState) => {
          this.handleMessageDidScroll(xOffset, yOffset, scrollState);
        })
        .onScrollEdge((side: Edge) => {
          this.handleMessageScrollEdge(side);
        })
        .onScrollStop(() => {
          this.handleMessageScrollStop();
        })
        .onReachEnd(() => {
          this.resumeMessageAutoFollow();
        })
        .onAxisEvent((event: AxisEvent) => {
          this.handleConversationAxisZoom(event);
        })
      }
      .layoutWeight(1)
      .width('100%')
      .onAreaChange((_old: Area, newArea: Area) => {
        this.chatAreaWidth = newArea.width as number;
      })
      .onTouch((event: TouchEvent) => {
        if (event.touches.length > 0) {
          const touch: TouchObject = event.touches[0];
          const near: boolean = this.chatAreaWidth - touch.windowX < 20;
          if (near !== this.mouseNearRightEdge) {
            this.mouseNearRightEdge = near;
          }
        }
      })
      .onHover((isHover: boolean) => {
        if (!isHover) {
          this.mouseNearRightEdge = false;
        }
      })

      Column() {
          Row() {
            Row() {
              Text('模式')
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontColor(this.themeTextSecondary())
              Text(this.currentCollaborationModeLabel())
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.themeTextStrong())
                .margin({ left: 6 })
              Text('▾')
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontColor(this.themeTextMuted())
                .margin({ left: 6 })
            }
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.showCollaborationModeOptions ? '#EEF6FF' : this.themeElevatedBackground())
            .border({ width: 0.5, color: this.showCollaborationModeOptions ? '#93C5FD' : this.themeBorder() })
            .borderRadius(12)
            .scale({ x: this.showCollaborationModeOptions ? 1.02 : 1, y: this.showCollaborationModeOptions ? 1.02 : 1 })
            .animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn })
            .onClick(() => {
              this.runFastMotion(() => {
                this.showCollaborationModeOptions = !this.showCollaborationModeOptions;
                if (this.showCollaborationModeOptions) {
                  this.showEffortOptions = false;
                }
              });
            })

            Blank()
              .width(8)
            Row() {
              Text('推理')
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontColor(this.themeTextSecondary())

              Text(this.currentEffortLabel())
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontColor(this.themeTextStrong())
                .margin({ left: 6 })

              Text('▾')
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontColor(this.themeTextMuted())
                .margin({ left: 6 })
            }
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.showEffortOptions ? '#EEF6FF' : this.themeElevatedBackground())
            .border({ width: 0.5, color: this.showEffortOptions ? '#93C5FD' : this.themeBorder() })
            .borderRadius(12)
            .scale({ x: this.showEffortOptions ? 1.02 : 1, y: this.showEffortOptions ? 1.02 : 1 })
            .animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn })
            .onClick(() => {
              this.runFastMotion(() => {
                this.showEffortOptions = !this.showEffortOptions;
                if (this.showEffortOptions) {
                  this.showCollaborationModeOptions = false;
                }
              });
            })
          }
          .width('100%')
          .margin({ top: 0 })
          .transition(TransitionEffect.OPACITY.animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn }))

          if (this.showCollaborationModeOptions) {
            Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
              ForEach(this.collaborationModes, (item: CollaborationModeOption) => {
                this.optionChip(
                  new SelectorOption(item.name, item.name),
                  this.selectedCollaborationModeName === item.name,
                  () => {
                    this.chooseCollaborationMode(item);
                  }
                )
              }, (item: CollaborationModeOption) => item.name)
            }
            .width('100%')
            .margin({ top: 8 })
            .transition(TransitionEffect.OPACITY.animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn }))
          }

          if (this.showEffortOptions) {
            Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
              ForEach(this.effortOptions, (item: SelectorOption, index: number) => {
                this.optionChip(item, this.selectedEffortIndex === index, () => {
                  this.runFastMotion(() => {
                    this.selectedEffortIndex = index;
                    this.showEffortOptions = false;
                  });
                })
              })
            }
            .width('100%')
            .margin({ top: 8 })
            .transition(TransitionEffect.OPACITY.animation({ duration: this.motionFastDuration, curve: Curve.FastOutSlowIn }))
          }

        Row() {
          TextArea({ text: this.draft, placeholder: this.dynamicInputPlaceholder() })
            .layoutWeight(1)
            .constraintSize({ minHeight: 42, maxHeight: 136 })
            .minLines(1)
            .maxLines(5, { overflowMode: MaxLinesMode.SCROLL })
            .fontSize(this.conversationFontSize(13))
            .lineHeight(this.conversationLineHeight(20))
            .fontColor(this.themeTextStrong())
            .wordBreak(WordBreak.BREAK_WORD)
            .placeholderColor(this.themeTextMuted())
            .backgroundColor(this.themeInputBackground())
            .borderRadius(14)
            .border({ width: 0.5, color: this.themeStrongBorder() })
            .padding({ left: 14, right: 14 })
            .enterKeyType(EnterKeyType.Send)
            .onChange((value: string) => {
              this.draft = value;
            })
            .onSubmit((_enterKey: EnterKeyType) => {
              this.sendMessage();
            })
            .onKeyEvent((event: KeyEvent) => {
              if (this.handleConversationKeyEvent(event)) {
                return true;
              }
              if (event.type === KeyType.Down && event.keyCode === 27 && this.isRunning) {
                this.stopTurn();
                return true;
              }
              return false;
            })

          Button() {
            Text(this.isRunning ? '■' : '发送')
              .fontSize(this.isRunning ? 14 : 12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .copyOption(CopyOptions.None)
          }
            .accessibilityText(this.isRunning ? '停止生成' : '发送消息')
            .width(66)
            .height(42)
            .margin({ left: 9 })
            .backgroundColor(this.isRunning ? '#27272A' : '#111827')
            .borderRadius(14)
            .shadow({ radius: 12, color: this.isRunning ? '#22DC2626' : '#24111827', offsetY: 4 })
            .opacity(1)
            .onClick(() => {
              if (this.isRunning) {
                this.stopTurn();
              } else {
                this.sendMessage();
              }
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 8 })

        Row() {
          Text('⚠ 回答由 AI 生成，可能存在错误，请注意甄别')
            .fontSize(10)
            .fontColor(this.themeTextMuted())
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 2, bottom: 2 })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 10 })
      .margin({ top: 10 })
      .backgroundColor(this.themePanelBackground())
      .border({ width: 0.5, color: this.themeBorder() })
      .borderRadius(18)
      .shadow({ radius: 18, color: '#120F172A', offsetY: 6 })
    }
    .height('100%')
    .width('100%')
    .focusable(true)
    .onKeyEvent((event: KeyEvent) => {
      return this.handleConversationKeyEvent(event);
    })
  }

  @Builder
  private centerPanel() {
    Column() {
      if (this.workspaces.length === 0) {
        Row() {
          Button() {
          Stack() {
            Column()
              .width(16)
              .height(12)
              .borderRadius(3)
              .border({ width: 1.5, color: this.themeTextSecondary() })
              .backgroundColor(this.showLeftDrawer ? this.themeSubtleBackground() : this.themeElevatedBackground())
            Column()
              .width(1.5)
              .height(8)
              .backgroundColor(this.themeTextSecondary())
              .position({ x: 4, y: 2 })
          }
          .width(16)
          .height(12)
        }
        .type(ButtonType.Normal)
        .width(32)
        .height(28)
        .backgroundColor(this.themePanelBackground())
        .borderRadius(8)
        .border({ width: 0.5, color: this.themeBorder() })
        .onClick(() => {
          this.toggleLeftDrawer();
        })
          Blank()
            .layoutWeight(1)
          Button() {
            Stack() {
              Column()
                .width(16)
                .height(12)
                .borderRadius(3)
                .border({ width: 1.5, color: this.themeTextSecondary() })
                .backgroundColor(this.showRightDrawer ? this.themeSubtleBackground() : this.themeElevatedBackground())
              Column()
                .width(1.5)
                .height(8)
                .backgroundColor(this.themeTextSecondary())
                .position({ x: 10.5, y: 2 })
            }
            .width(16)
            .height(12)
          }
          .type(ButtonType.Normal)
          .width(32)
          .height(28)
          .backgroundColor(this.themePanelBackground())
          .borderRadius(8)
          .border({ width: 0.5, color: this.themeBorder() })
          .onClick(() => {
            this.toggleRightDrawer();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Column() {
          if (this.projects.length === 0) {
            Text('当前暂无项目')
              .copyOption(CopyOptions.LocalDevice)
              .fontSize(16)
              .fontColor(this.themeTextMuted())
            Text('请新建项目')
              .copyOption(CopyOptions.LocalDevice)
              .fontSize(12)
              .fontColor(this.themeTextMuted())
              .margin({ top: 8 })
          } else {
            Text('当前暂无会话')
              .copyOption(CopyOptions.LocalDevice)
              .fontSize(16)
              .fontColor(this.themeTextMuted())
            Text('请在项目中新建会话')
              .copyOption(CopyOptions.LocalDevice)
              .fontSize(12)
              .fontColor(this.themeTextMuted())
              .margin({ top: 8 })
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        this.chatCenterView()
      }
    }
    .height('100%')
    .layoutWeight(1)
    .padding(12)
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.themeBorder() })
    .borderRadius(12)
  }

  @Builder
  private chatContextPanel() {
    Column() {
      Row() {
        this.panelTitle('修改文件', '当前 turn 的 diff 文件')

        Blank()
          .layoutWeight(1)

        Text(`${this.diffFiles.length.toString()} 个文件`)
          .copyOption(CopyOptions.LocalDevice)
          .fontSize(10)
          .fontColor('#1D4ED8')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.eventSoftBackground('tool'))
          .borderRadius(6)
      }
      .width('100%')

      if (this.diffFiles.length > 0) {
        Row() {
          Text('文件列表')
            .copyOption(CopyOptions.None)
            .fontSize(10)
            .fontColor(this.themeTextSecondary())

          Blank()
            .layoutWeight(1)

          Text(this.diffStat)
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(10)
            .fontColor('#16A34A')
        }
        .width('100%')
        .margin({ top: 12 })

        List({ space: 6 }) {
          ForEach(this.diffFiles, (file: CodeDiffFile) => {
            ListItem() {
              this.diffFileRow(file)
            }
          }, (file: CodeDiffFile) => file.path)
        }
        .width('100%')
        .height(Math.min(230, this.diffFiles.length * 58))
        .margin({ top: 8 })
        .scrollBar(BarState.Off)
        .cachedCount(6)

        Row() {
          Text('当前')
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(10)
            .fontColor(this.themeTextMuted())

          Text(this.currentDiffFilePath())
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(10)
            .fontColor(this.themeTextStrong())
            .layoutWeight(1)
            .margin({ left: 8 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(this.currentDiffFileStat())
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(10)
            .fontColor('#1D4ED8')

          Text('↗')
            .copyOption(CopyOptions.None)
            .fontSize(12)
            .fontColor(this.themeTextSecondary())
            .textAlign(TextAlign.Center)
            .width(26)
            .height(26)
            .margin({ left: 8 })
            .backgroundColor(this.themeElevatedBackground())
            .border({ width: 0.5, color: this.themeBorder() })
            .borderRadius(7)
            .onClick(() => {
              this.openSelectedDiffFileWithSystem();
            })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .margin({ top: 10 })
        .backgroundColor(this.themePanelBackground())
        .border({ width: 0.5, color: this.themeBorder() })
        .borderRadius(8)
      } else {
        Column() {
          Text(NO_FILE_CHANGES_TEXT)
            .copyOption(CopyOptions.None)
            .fontSize(13)
            .fontColor(this.themeTextSecondary())
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      if (this.diffFiles.length > 0) {
        Text('Diff')
          .copyOption(CopyOptions.None)
          .fontSize(10)
          .fontColor(this.themeTextSecondary())
          .margin({ top: 12 })

        List({ space: 6 }) {
          ForEach(this.codeLines, (item: CodeDiffLine) => {
            ListItem() {
              this.diffRow(item)
            }
          }, (item: CodeDiffLine) => item.id)
        }
        .layoutWeight(1)
        .width('100%')
        .margin({ top: 8 })
        .scrollBar(BarState.Off)
        .cachedCount(6)
      }
    }
    .height('100%')
    .width('100%')
  }

  @Builder
  private rightPanel() {
    Column() {
      Column() {
        this.chatContextPanel()
      }
      .layoutWeight(1)
      .width('100%')

      Column() {
        this.tokenUsageCard()
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .height('100%')
    .width(this.rightPanelWidth)
    .padding(12)
    .backgroundColor(this.themePanelBackground())
    .border({ width: 0.5, color: this.themeBorder() })
    .borderRadius(20)
  }

  @Builder
  private phoneWorkspace() {
    Column() {
      this.centerPanel()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private tabletWorkspace() {
    Row() {
      if (this.showLeftDrawer) {
        Row() {
          this.leftPanel()

          Column() {
            Column()
              .width(2)
              .height('60%')
              .backgroundColor(this.themeStrongBorder())
              .borderRadius(1)
          }
          .width(8)
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.themeSubtleBackground())
          .borderRadius(4)
          .hitTestBehavior(HitTestMode.Block)
          .gesture(
            PanGesture({ direction: PanDirection.Horizontal })
              .onActionStart(() => {
                this.dragStartLeftW = this.leftPanelWidth;
                this.dragStartRightW = this.rightPanelWidth;
                this.leftHiding = false;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.leftHiding) return;
                const newLeft = this.dragStartLeftW + event.offsetX;
                if (newLeft <= this.leftDrawerMinWidth - 20) {
                  this.leftHiding = true;
                  this.runPanelMotion(() => {
                    this.showLeftDrawer = false;
                  });
                  setTimeout(() => {
                    this.leftPanelWidth = 280;
                  }, 350);
                } else if (newLeft >= this.leftDrawerMinWidth) {
                  this.leftPanelWidth = newLeft;
                }
              })
          )
        }
        .height('100%')
        .transition(TransitionEffect.move(TransitionEdge.START).animation({ duration: this.motionPanelDuration, curve: Curve.FastOutSlowIn }))
      }
      this.centerPanel()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private desktopWorkspace() {
    Row() {
      if (this.showLeftDrawer) {
        Row() {
          this.leftPanel()

          Column() {
            Column()
              .width(2)
              .height('60%')
              .backgroundColor(this.themeStrongBorder())
              .borderRadius(1)
          }
          .width(8)
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.themeSubtleBackground())
          .borderRadius(4)
          .hitTestBehavior(HitTestMode.Block)
          .gesture(
            PanGesture({ direction: PanDirection.Horizontal })
              .onActionStart(() => {
                this.dragStartLeftW = this.leftPanelWidth;
                this.dragStartRightW = this.rightPanelWidth;
                this.leftHiding = false;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.leftHiding) return;
                const newLeft = this.dragStartLeftW + event.offsetX;
                if (newLeft <= this.leftDrawerMinWidth - 20) {
                  this.leftHiding = true;
                  this.runPanelMotion(() => {
                    this.showLeftDrawer = false;
                  });
                  setTimeout(() => {
                    this.leftPanelWidth = 280;
                  }, 350);
                } else if (newLeft >= this.leftDrawerMinWidth) {
                  this.leftPanelWidth = newLeft;
                }
              })
          )
        }
        .height('100%')
        .transition(TransitionEffect.move(TransitionEdge.START).animation({ duration: this.motionPanelDuration, curve: Curve.FastOutSlowIn }))
      }

      this.centerPanel()

      if (this.showRightDrawer) {
        Row() {
          Column() {
            Column()
              .width(2)
              .height('60%')
              .backgroundColor(this.themeStrongBorder())
              .borderRadius(1)
          }
          .width(8)
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.themeSubtleBackground())
          .borderRadius(4)
          .hitTestBehavior(HitTestMode.Block)
          .gesture(
            PanGesture({ direction: PanDirection.Horizontal })
              .onActionStart(() => {
                this.dragStartLeftW = this.leftPanelWidth;
                this.dragStartRightW = this.rightPanelWidth;
                this.rightHiding = false;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.rightHiding) return;
                const newRight = this.dragStartRightW - event.offsetX;
                if (newRight <= this.rightDrawerMinWidth - 20) {
                  this.rightHiding = true;
                  this.runPanelMotion(() => {
                    this.showRightDrawer = false;
                  });
                  setTimeout(() => {
                    this.rightPanelWidth = 360;
                  }, 350);
                } else if (newRight >= this.rightDrawerMinWidth) {
                  this.rightPanelWidth = newRight;
                }
              })
          )

          Column() {
            this.rightPanel()
          }
          .height('100%')
        }
        .transition(TransitionEffect.move(TransitionEdge.END).animation({ duration: this.motionPanelDuration, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .height('100%')
  }

  // ── 上下文助手（Rust 侧预计算 blendedTotal / contextRemainingPercent，前端仅展示）──

  private formatTokenCount(count: number): string {
    if (count !== count) return '0';
    if (count <= 0) return '0';
    if (count < 1000) return count.toString();
    if (count < 1000000) return (count / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
    return (count / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
  }

  private blendedTotal(): number {
    if (this.tokenUsage === null || this.tokenUsage === undefined) return 0;
    const v = this.tokenUsage.total.blendedTotal;
    if (typeof v !== 'number' || v !== v) return 0;
    return v < 0 ? 0 : v;
  }

  private contextWindow(): number {
    if (this.tokenUsage !== null && this.tokenUsage !== undefined) {
      const v = this.tokenUsage.modelContextWindow;
      if (typeof v === 'number' && v === v && v > 0) {
        return v;
      }
    }
    return 0;
  }

  private contextRemainingPct(): number {
    if (this.tokenUsage === null || this.tokenUsage === undefined) return -1;
    const v = this.tokenUsage.contextRemainingPercent;
    if (typeof v !== 'number' || v !== v) return -1;
    return v;
  }

  private usedPct(): number {
    const rem = this.contextRemainingPct();
    if (rem < 0) return -1;
    return (100 - rem);
  }

  private contextBarWidth(): string {
    const pct = this.usedPct();
    if (pct < 0) return '0%';
    const clamped: number = pct > 100 ? 100 : (pct < 0 ? 0 : pct);
    return clamped.toString() + '%';
  }

  private contextBarColor(): ResourceColor {
    const pct = this.usedPct();
    if (pct < 0) return '#3B82F6';
    if (pct >= 90) return '#EF4444';
    if (pct >= 70) return '#F59E0B';
    return '#3B82F6';
  }

  // total.total_tokens — 和 Rust 计算 remaining% 用的是同一个字段
  private totalTokensUsed(): number {
    if (this.tokenUsage === null || this.tokenUsage === undefined) return 0;
    const v = this.tokenUsage.total.totalTokens;
    if (typeof v !== 'number' || v !== v) return 0;
    return v < 0 ? 0 : v;
  }

  private contextText(): string {
    const used = this.totalTokensUsed();
    const win = this.contextWindow();
    const rem = this.contextRemainingPct();
    let suffix: string = '';
    if (win > 0 && rem >= 0) {
      suffix = ' (' + rem.toString() + '% 剩余)';
    }
    if (win <= 0) {
      return suffix.length > 0
        ? this.formatTokenCount(used) + ' / 未上报' + suffix
        : this.formatTokenCount(used) + ' / 未上报';
    }
    return this.formatTokenCount(used) + ' / ' + this.formatTokenCount(win) + suffix;
  }

  private safePct(part: number, whole: number): string {
    if (whole <= 0 || part <= 0 || whole !== whole || part !== part) return '0%';
    const v = (part / whole) * 100;
    if (v !== v || v < 0) return '0%';
    return (v > 100 ? 100 : v).toFixed(0) + '%';
  }

  private tokenMiniText(): string {
    const total = this.totalTokensUsed();
    const win = this.contextWindow();
    const pct = this.contextRemainingPct();
    let suffix: string = '';
    if (win > 0 && pct >= 0) {
      suffix = ' · 剩余 ' + pct.toString() + '%';
    }
    return '总 ' + this.formatTokenCount(total) + suffix;
  }

  private autoCompactionText(): string {
    if (!this.autoCompactEnabled) {
      return '未启用';
    }
    const limit = this.effectiveAutoCompactTokenLimit ?? this.modelAutoCompactTokenLimit;
    if (typeof limit !== 'number' || limit !== limit || limit <= 0) {
      return '未启用';
    }
    return `阈值 ${this.formatTokenCount(limit)}`;
  }

  private currentThreadCompactionNotice(): CompactionNotice | null {
    const threadId: string = this.backendActiveThreadId.trim();
    if (threadId.length === 0) {
      return null;
    }
    return this.compactionNoticeById(`compaction:${threadId}`);
  }

  private contextMemoryModeText(): string {
    const mode = this.contextManagement.memoryMode;
    const forgettingPending = this.contextManagement.memoryForgettingPending === true;
    const forgettingCompletedAt = this.contextManagement.memoryForgettingCompletedAt;
    const forgettingCompleted = typeof forgettingCompletedAt === 'number' && forgettingCompletedAt > 0;
    const baselineSelectedAt = this.contextManagement.memoryPhase2SelectedAt;
    const baselineSelected = typeof baselineSelectedAt === 'number' && baselineSelectedAt > 0;
    const forgettingRelative = forgettingCompleted ? this.relativeTimeFromEpoch(forgettingCompletedAt as number) : '';
    const baselineRelative = baselineSelected ? this.relativeTimeFromEpoch(baselineSelectedAt as number) : '';
    if (mode === null || mode === undefined || mode.trim().length === 0) {
      return '未上报';
    }
    if (mode === 'enabled') {
      if (!baselineSelected) {
        return '已启用';
      }
      if (baselineRelative.length === 0) {
        return '已启用（已纳入基线）';
      }
      if (baselineRelative === '刚刚') {
        return `已启用（${baselineRelative}纳入基线）`;
      }
      return `已启用（${baselineRelative}前纳入基线）`;
    }
    if (mode === 'disabled') return '已禁用';
    if (mode === 'polluted') {
      if (forgettingPending) {
        return '已污染（等待遗忘）';
      }
      if (!forgettingCompleted) {
        return '已污染';
      }
      if (forgettingRelative.length === 0) {
        return '已污染（已完成遗忘）';
      }
      if (forgettingRelative === '刚刚') {
        return `已污染（${forgettingRelative}完成遗忘）`;
      }
      return `已污染（${forgettingRelative}前完成遗忘）`;
    }
    return mode;
  }

  private contextMicroCompactionText(): string {
    const savedTokens = this.contextManagement.lastMicroCompactionSavedTokens;
    const itemCount = this.contextManagement.lastMicroCompactionItemCount;
    const executedAt = this.contextManagement.lastMicroCompactionAt;
    const relative = typeof executedAt === 'number' && executedAt > 0
      ? this.relativeTimeFromEpoch(executedAt)
      : '';
    const parts: string[] = [];
    if (typeof itemCount === 'number' && itemCount > 0) {
      parts.push(`处理 ${itemCount} 项`);
    }
    if (typeof savedTokens === 'number' && savedTokens > 0) {
      parts.push(`节省 ${this.formatTokenCount(savedTokens)} tokens`);
    }
    if (parts.length > 0) {
      const summary = parts.join('，');
      if (relative.length === 0) {
        return summary;
      }
      if (relative === '刚刚') {
        return `${summary}（${relative}）`;
      }
      return `${summary}（${relative}前）`;
    }
    if (typeof executedAt === 'number' && executedAt > 0) {
      if (relative.length === 0) {
        return '已执行';
      }
      if (relative === '刚刚') {
        return `已执行（${relative}）`;
      }
      return `已执行（${relative}前）`;
    }
    return '暂无记录';
  }

  private relativeTimeFromEpoch(timestamp: number): string {
    if (timestamp !== timestamp || timestamp <= 0) {
      return '';
    }
    const normalizedMs: number = timestamp > 1000000000000 ? timestamp : timestamp * 1000;
    return this.relativeTime(new Date(normalizedMs).toISOString());
  }

  private contextMemoryPhase2Text(): string {
    const updatedAt = this.contextManagement.memoryPhase2UpdatedAt;
    const selectionCount = this.contextManagement.memoryPhase2SelectionCount;
    const addedCount = this.contextManagement.memoryPhase2AddedCount;
    const retainedCount = this.contextManagement.memoryPhase2RetainedCount;
    const removedCount = this.contextManagement.memoryPhase2RemovedCount;
    if (
      typeof selectionCount === 'number' && selectionCount >= 0 &&
      typeof addedCount === 'number' && addedCount >= 0 &&
      typeof retainedCount === 'number' && retainedCount >= 0 &&
      typeof removedCount === 'number' && removedCount >= 0
    ) {
      const summary = `选中 ${selectionCount}（新增 ${addedCount} / 保留 ${retainedCount} / 移除 ${removedCount}）`;
      if (typeof updatedAt !== 'number' || updatedAt <= 0) {
        return summary;
      }
      const relative = this.relativeTimeFromEpoch(updatedAt);
      if (relative.length === 0) {
        return summary;
      }
      if (relative === '刚刚') {
        return `${summary}（${relative}）`;
      }
      return `${summary}（${relative}前）`;
    }
    if (typeof updatedAt !== 'number' || updatedAt <= 0) {
      return '暂无记录';
    }
    const relative = this.relativeTimeFromEpoch(updatedAt);
    if (relative.length === 0) {
      return '已完成';
    }
    if (relative === '刚刚') {
      return relative;
    }
    return `${relative}前`;
  }

  private contextMemorySummaryText(): string {
    const preview = this.contextManagement.memorySummaryPreview;
    const updatedAt = this.contextManagement.memorySummaryUpdatedAt;
    const relative = typeof updatedAt === 'number' && updatedAt > 0
      ? this.relativeTimeFromEpoch(updatedAt)
      : '';
    if (typeof preview === 'string' && preview.trim().length > 0) {
      const summary = preview.trim();
      if (relative.length === 0) {
        return summary;
      }
      if (relative === '刚刚') {
        return `${summary}（${relative}）`;
      }
      return `${summary}（${relative}前）`;
    }
    if (typeof updatedAt === 'number' && updatedAt > 0) {
      if (relative.length === 0) {
        return '已生成';
      }
      if (relative === '刚刚') {
        return `已生成（${relative}）`;
      }
      return `已生成（${relative}前）`;
    }
    return '暂无摘要';
  }

  private contextMemoryUsageText(): string {
    const usageCount = this.contextManagement.memoryUsageCount;
    const lastUsageAt = this.contextManagement.memoryLastUsageAt;
    if (typeof usageCount !== 'number' || usageCount < 0) {
      return '暂无记录';
    }
    if (usageCount === 0) {
      return '尚未引用';
    }
    const relative = typeof lastUsageAt === 'number' && lastUsageAt > 0
      ? this.relativeTimeFromEpoch(lastUsageAt)
      : '';
    if (relative.length === 0) {
      return `已引用 ${usageCount} 次`;
    }
    if (relative === '刚刚') {
      return `已引用 ${usageCount} 次（${relative}）`;
    }
    return `已引用 ${usageCount} 次（${relative}前）`;
  }

  private contextMemoryStage1Text(): string {
    const generatedAt = this.contextManagement.memoryStage1GeneratedAt;
    const upToDate = this.contextManagement.memoryStage1UpToDate;
    const jobStatus = this.contextManagement.memoryStage1JobStatus;
    const retryAt = this.contextManagement.memoryStage1RetryAt;
    const retryRemaining = this.contextManagement.memoryStage1RetryRemaining;
    const relative = typeof generatedAt === 'number' && generatedAt > 0
      ? this.relativeTimeFromEpoch(generatedAt)
      : '';
    const retryRelative = typeof retryAt === 'number' && retryAt > 0
      ? this.relativeTimeFromEpoch(retryAt)
      : '';
    if (jobStatus === 'running') {
      if (typeof generatedAt === 'number' && generatedAt > 0) {
        if (relative.length === 0) {
          return '提炼中';
        }
        if (relative === '刚刚') {
          return `提炼中（上次 ${relative}）`;
        }
        return `提炼中（上次 ${relative}前）`;
      }
      return '提炼中';
    }
    if (jobStatus === 'error') {
      if (typeof retryRemaining === 'number' && retryRemaining <= 0) {
        return '提炼失败（重试已耗尽）';
      }
      if (retryRelative.length === 0) {
        if (typeof retryRemaining === 'number' && retryRemaining > 0) {
          return `等待重试（剩余 ${retryRemaining} 次）`;
        }
        return '等待重试';
      }
      if (retryRelative === '刚刚') {
        if (typeof retryRemaining === 'number' && retryRemaining > 0) {
          return `等待重试（${retryRelative}，剩余 ${retryRemaining} 次）`;
        }
        return `等待重试（${retryRelative}）`;
      }
      if (typeof retryRemaining === 'number' && retryRemaining > 0) {
        return `等待重试（${retryRelative}后，剩余 ${retryRemaining} 次）`;
      }
      return `等待重试（${retryRelative}后）`;
    }
    if (jobStatus === 'pending') {
      if (typeof generatedAt === 'number' && generatedAt > 0) {
        if (relative.length === 0) {
          return '排队刷新';
        }
        if (relative === '刚刚') {
          return `排队刷新（上次 ${relative}）`;
        }
        return `排队刷新（上次 ${relative}前）`;
      }
      return '排队提炼';
    }
    if (upToDate === true) {
      if (relative.length === 0) {
        return '已同步';
      }
      if (relative === '刚刚') {
        return `已同步（${relative}）`;
      }
      return `已同步（${relative}前）`;
    }
    if (upToDate === false) {
      if (typeof generatedAt === 'number' && generatedAt > 0) {
        if (relative.length === 0) {
          return '待刷新';
        }
        if (relative === '刚刚') {
          return `待刷新（上次 ${relative}）`;
        }
        return `待刷新（上次 ${relative}前）`;
      }
      return '待提炼';
    }
    if (typeof generatedAt === 'number' && generatedAt > 0) {
      if (relative.length === 0) {
        return '已有记录';
      }
      if (relative === '刚刚') {
        return `已有记录（${relative}）`;
      }
      return `已有记录（${relative}前）`;
    }
    return '暂无记录';
  }

  private fullCompactionTriggerText(trigger: string | null): string {
    if (trigger === 'manual') return '手动';
    if (trigger === 'pre_turn') return '预压缩';
    if (trigger === 'mid_turn') return '中途压缩';
    if (trigger === 'model_switch') return '模型切换';
    if (trigger === null || trigger === undefined || trigger.trim().length === 0) {
      return '';
    }
    return trigger;
  }

  private fullCompactionProviderModeText(providerMode: string | null): string {
    if (providerMode === 'local') return '本地';
    if (providerMode === 'remote') return '远程';
    if (providerMode === null || providerMode === undefined || providerMode.trim().length === 0) {
      return '';
    }
    return providerMode;
  }

  private fullCompactionTrimmedItemText(trimmedItemCount: number | null): string {
    if (typeof trimmedItemCount === 'number' && trimmedItemCount > 0) {
      return `裁剪 ${trimmedItemCount} 项`;
    }
    return '';
  }

  private fullCompactionReferenceContextText(reestablished: boolean | null): string {
    if (reestablished === true) {
      return '已重建上下文';
    }
    if (reestablished === false) {
      return '待重建上下文';
    }
    return '';
  }

  private fullCompactionSourceDetail(
    triggerText: string,
    providerModeText: string,
    trimmedItemText: string,
    referenceContextText: string
  ): string {
    let detailText = '';
    if (triggerText.length > 0 && providerModeText.length > 0) {
      detailText = `${triggerText} / ${providerModeText}`;
    } else if (triggerText.length > 0) {
      detailText = triggerText;
    } else {
      detailText = providerModeText;
    }
    if (trimmedItemText.length > 0) {
      detailText = detailText.length > 0 ? `${detailText}，${trimmedItemText}` : trimmedItemText;
    }
    if (referenceContextText.length > 0) {
      return detailText.length > 0 ? `${detailText}，${referenceContextText}` : referenceContextText;
    }
    return detailText;
  }

  private currentFullCompactionDetailText(): string {
    const triggerText = this.fullCompactionTriggerText(this.contextManagement.lastFullCompactionTrigger);
    const providerModeText = this.fullCompactionProviderModeText(this.contextManagement.lastFullCompactionProviderMode);
    const trimmedItemText = this.fullCompactionTrimmedItemText(this.contextManagement.lastFullCompactionTrimmedItemCount);
    const referenceContextText = this.fullCompactionReferenceContextText(
      this.contextManagement.lastFullCompactionReferenceContextReestablished
    );
    const detailText = this.fullCompactionSourceDetail(
      triggerText,
      providerModeText,
      trimmedItemText,
      referenceContextText
    );
    if (detailText.length > 0) {
      return detailText;
    }
    if (triggerText.length > 0) {
      return `${triggerText}触发过`;
    }
    const relative = typeof this.contextManagement.lastContextCompactionAt === 'number'
      && this.contextManagement.lastContextCompactionAt > 0
      ? this.relativeTimeFromEpoch(this.contextManagement.lastContextCompactionAt)
      : '';
    if (relative.length > 0) {
      return relative === '刚刚' ? '后端刚刚压缩过' : `后端 ${relative}前压缩过`;
    }
    if (typeof this.contextManagement.lastContextCompactionAt === 'number'
      && this.contextManagement.lastContextCompactionAt > 0) {
      return '后端压缩过';
    }
    return '';
  }

  private contextFullCompactionText(): string {
    const notice = this.currentThreadCompactionNotice();
    const detailText = this.currentFullCompactionDetailText();
    if (notice !== null) {
      if (notice.status === 'completed') {
        if (notice.savedTokens > 0) {
          return detailText.length > 0
            ? `已完成（${detailText}），释放 ${this.formatTokenCount(notice.savedTokens)} tokens`
            : `已完成，释放 ${this.formatTokenCount(notice.savedTokens)} tokens`;
        }
        return detailText.length > 0 ? `已完成（${detailText}）` : '已完成';
      }
      if (notice.status === 'failed' || notice.status === 'timeout') {
        return notice.errorMessage.trim().length > 0 ? notice.errorMessage : '失败';
      }
      if (notice.status === 'starting' || notice.status === 'running') {
        return '进行中';
      }
    }
    if (this.compacting) {
      return '进行中';
    }
    if (this.compactError.trim().length > 0) {
      return this.compactError;
    }
    if (detailText.length > 0) {
      return `空闲（上次：${detailText}）`;
    }
    return '空闲';
  }

  private contextCircuitBreakerText(): string {
    const failureCount = this.contextManagement.compactionFailureCount;
    if (this.contextManagement.compactionCircuitOpen === true) {
      if (typeof failureCount === 'number' && failureCount > 0) {
        return `已熔断（失败 ${failureCount} 次）`;
      }
      return '已熔断';
    }
    if (typeof failureCount === 'number' && failureCount > 0) {
      return `存在失败记录（${failureCount} 次）`;
    }
    return '正常';
  }

  private contextRecentArtifactRefsText(): string {
    const refs = this.contextManagement.recentArtifactRefs;
    if (refs === null || refs === undefined || refs.length === 0) {
      return '暂无记录';
    }
    const normalizedRefs: string[] = refs
      .map((item: string) => item.trim())
      .filter((item: string) => item.length > 0);
    if (normalizedRefs.length === 0) {
      return '暂无记录';
    }
    const previewNames: string[] = normalizedRefs.slice(0, 2).map((item: string) => {
      const shortName = this.fileNameFromTarget(item);
      return shortName.length > 0 ? shortName : item;
    });
    if (normalizedRefs.length <= 2) {
      return `${normalizedRefs.length} 项：${previewNames.join('、')}`;
    }
    return `${normalizedRefs.length} 项：${previewNames.join('、')} 等`;
  }

  @Builder contextManagementMetricRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(11)
        .fontColor(this.themeTextMuted())
        .flexShrink(0)
      Text(value)
        .fontSize(11)
        .fontColor(this.themeTextPrimary())
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ top: 6 })
  }

  private readonly TREND_CHART_H: number = 52;

  private trendChartWidth(): number {
    return this.rightPanelWidth - 48;
  }

  private tokenTrendLinePath(data: DailyTokenSnapshot[], maxVal: number, w: number, h: number): string {
    if (data.length === 0 || maxVal <= 0) return '';
    const points: string[] = [];
    const padY = 4;
    const stepX = w / Math.max(data.length - 1, 1);
    for (let i = 0; i < data.length; i++) {
      const x = i * stepX;
      const y = h - (data[i].totalTokens / maxVal) * (h - padY * 2) - padY;
      if (i === 0) {
        points.push(`M ${x} ${y}`);
      } else {
        points.push(`L ${x} ${y}`);
      }
    }
    return points.join(' ');
  }

  private getTrendData(): DailyTokenSnapshot[] {
    if (this.tokenAggregate === null) return [];
    const days = this.tokenTrendRange === 1 ? 7 : 30;
    const len = this.tokenAggregate.daily.length;
    const start = Math.max(len - days, 0);
    return this.tokenAggregate.daily.slice(start, len);
  }

  private getTrendTokenPath(): string {
    const data = this.getTrendData();
    const maxVal = data.reduce((max: number, d: DailyTokenSnapshot) => Math.max(max, d.totalTokens), 0);
    return this.tokenTrendLinePath(data, maxVal, this.trendChartWidth(), this.TREND_CHART_H);
  }

  private getTrendAreaPath(): string {
    const data = this.getTrendData();
    const maxVal = data.reduce((max: number, d: DailyTokenSnapshot) => Math.max(max, d.totalTokens), 0);
    if (data.length === 0 || maxVal <= 0) return '';
    const w = this.trendChartWidth();
    const h = this.TREND_CHART_H;
    const padY = 4;
    const stepX = w / Math.max(data.length - 1, 1);
    let path = `M 0 ${h}`;
    for (let i = 0; i < data.length; i++) {
      const x = i * stepX;
      const y = h - (data[i].totalTokens / maxVal) * (h - padY * 2) - padY;
      path += ` L ${x} ${y}`;
    }
    path += ` L ${w} ${h} Z`;
    return path;
  }

  private getTrendSumTokens(): number {
    return this.getTrendData().reduce((s: number, d: DailyTokenSnapshot): number => s + d.totalTokens, 0);
  }

  private getTrendSumRequests(): number {
    return this.getTrendData().reduce((s: number, d: DailyTokenSnapshot): number => s + d.requestCount, 0);
  }

  private getTrendFirstDate(): string {
    const data = this.getTrendData();
    return data.length > 0 ? data[0].date.substring(5) : '';
  }

  private getTrendLastDate(): string {
    const data = this.getTrendData();
    return data.length > 0 ? data[data.length - 1].date.substring(5) : '';
  }

  @Builder trendLegendDot(color: string) {
    Circle({ width: 6, height: 6 }).fill(color)
  }

  @Builder tokenUsageCard() {
    Column() {
      // 箭头指示器（展开时显示，可拖拽调整高度）
      if (this.tokenCardExpanded) {
        Row() {
          Text('▼')
            .fontSize(10)
            .fontColor(this.themeTextMuted())
        }
        .width('100%')
        .height(16)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.themeElevatedBackground())
        .borderRadius({ topLeft: 10, topRight: 10 })
        .border({ width: 0.5, color: this.themeBorder() })
        .margin({ bottom: -1 })
        .hitTestBehavior(HitTestMode.Block)
        .gesture(
          TapGesture()
            .onAction(() => {
              this.runMotion(() => {
                this.tokenCardExpanded = false;
              });
            })
        )
        .gesture(
          PanGesture({ direction: PanDirection.Vertical })
            .onActionStart(() => {
              this.tokenCardDragStartY = 0;
              this.tokenCardDragStartH = this.tokenCardHeight;
            })
          .onActionUpdate((event: GestureEvent) => {
            const newH = this.tokenCardDragStartH - event.offsetY;
            if (newH >= 120 && newH <= 600) {
              this.tokenCardHeight = newH;
            }
          })
      )
      }

      // 卡片内容
      Column() {
        if (!this.tokenCardExpanded) {
          // 收起状态：只显示摘要
          Row() {
            Text(this.tokenMiniText())
              .fontSize(11)
              .fontColor(this.themeTextSecondary())
              .maxLines(1)
            Blank()
            Text('▲')
              .fontSize(10)
              .fontColor(this.themeTextMuted())
          }
          .width('100%')
          .padding({ top: 8, bottom: 8, left: 12, right: 12 })
          .borderRadius({ topLeft: 10, topRight: 10 })
          .backgroundColor(this.themePanelBackground())
          .border({ width: 0.5, color: this.themeBorder() })
          .hitTestBehavior(HitTestMode.Block)
          .gesture(
            TapGesture()
              .onAction(() => {
                this.runMotion(() => {
                  this.tokenCardExpanded = true;
                });
              })
          )
        } else {
          // 展开状态：固定高度 + 滚动
          Scroll() {
            Column() {
              // 上下文窗口占用（置顶，最重要）
              Column() {
                Row() {
                  Text('上下文窗口')
                    .fontSize(12)
                    .fontColor(this.themeTextPrimary())
                    .fontWeight(FontWeight.Medium)
                  Blank()
                  Text(this.contextText())
                    .fontSize(12)
                    .fontColor(this.themeTextPrimary())
                    .fontWeight(FontWeight.Medium)
                  if (this.compacting || this.compactError.length > 0 || this.contextRemainingPct() >= 0) {
                    Text(this.compacting ? '压缩中...' : (this.compactError.length > 0 ? this.compactError : '手动压缩'))
                      .fontSize(10)
                      .fontColor(this.compactError.length > 0 ? '#EF4444' : this.themeTextStrong())
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .border({ width: 1, color: this.compactError.length > 0 ? '#EF4444' : this.themeBorder() })
                      .borderRadius(6)
                      .backgroundColor(this.compactError.length > 0 ? '#FEF2F2' : this.themePanelBackground())
                      .margin({ left: 6 })
                      .onClick(() => {
                        this.retryCurrentCompaction(this.backendActiveThreadId);
                      })
                  }
                }
                .width('100%')

                if (this.contextRemainingPct() >= 0) {
                  Progress({ value: this.contextRemainingPct(), total: 100, type: ProgressType.Linear })
                    .width('100%')
                    .height(8)
                    .style({ strokeWidth: 8, enableSmoothEffect: true })
                    .color(this.contextBarColor())
                    .margin({ top: 6 })
                }
              }
              .width('100%')
              .padding({ top: 8, bottom: 10 })

              Column() {
                this.contextManagementMetricRow('自动压缩', this.autoCompactionText())
                this.contextManagementMetricRow('微压缩', this.contextMicroCompactionText())
                this.contextManagementMetricRow('Memory', this.contextMemoryModeText())
                this.contextManagementMetricRow('记忆引用', this.contextMemoryUsageText())
                this.contextManagementMetricRow('完整压缩', this.contextFullCompactionText())
                this.contextManagementMetricRow('最近引用', this.contextRecentArtifactRefsText())
                this.contextManagementMetricRow('熔断器', this.contextCircuitBreakerText())
              }
              .width('100%')
              .padding({ bottom: 10 })

              // 标题行
              Row() {
                Text('Token 用量')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.themeTextPrimary())
                Blank()
                Text(this.providerName)
                  .fontSize(11)
                  .fontColor(this.themeTextMuted())
              }
              .width('100%')
              .padding({ bottom: 2 })

          // 标签页 — 分段式选择器
          Row() {
            Text('当前轮')
              .fontSize(12)
              .fontColor(this.tokenTab === 0 ? '#FFFFFF' : this.themeTextSecondary())
              .fontWeight(this.tokenTab === 0 ? FontWeight.Medium : FontWeight.Normal)
              .padding({ left: 14, right: 14, top: 5, bottom: 5 })
              .borderRadius(6)
              .backgroundColor(this.tokenTab === 0 ? '#27272A' : 'transparent')
              .onClick(() => { this.tokenTab = 0; })
            Text('趋势')
              .fontSize(12)
              .fontColor(this.tokenTab === 1 ? '#FFFFFF' : this.themeTextSecondary())
              .fontWeight(this.tokenTab === 1 ? FontWeight.Medium : FontWeight.Normal)
              .padding({ left: 14, right: 14, top: 5, bottom: 5 })
              .borderRadius(6)
              .backgroundColor(this.tokenTab === 1 ? '#27272A' : 'transparent')
              .onClick(() => { this.tokenTab = 1; })
          }
          .margin({ top: 10 })
          .padding(2)
          .borderRadius(8)
          .backgroundColor(this.themeSubtleBackground())
          .width('100%')

          // 当前轮 tab
          if (this.tokenTab === 0) {
            Column() {
              if (this.tokenUsage === null) {
                Text('等待数据...')
                  .fontSize(11)
                  .fontColor(this.themeTextMuted())
                  .margin({ top: 12 })
              } else {
                // 细分数字
                Column() {
                  Row() {
                    Circle({ width: 6, height: 6 }).fill('#3B82F6')
                    Text('输入').fontSize(11).fontColor(this.themeTextMuted()).margin({ left: 6 })
                    Blank()
                    Text(this.formatTokenCount(this.tokenUsage!.last.inputTokens)).fontSize(11).fontColor(this.themeTextPrimary()).fontWeight(FontWeight.Medium)
                  }.width('100%').padding({ top: 6 })
                  Row() {
                    Circle({ width: 6, height: 6 }).fill('#A1A1AA')
                    Text('缓存').fontSize(11).fontColor(this.themeTextMuted()).margin({ left: 6 })
                    Blank()
                    Text(this.formatTokenCount(this.tokenUsage!.last.cachedInputTokens)).fontSize(11).fontColor(this.themeTextPrimary()).fontWeight(FontWeight.Medium)
                  }.width('100%').padding({ top: 6 })
                  Row() {
                    Circle({ width: 6, height: 6 }).fill('#22C55E')
                    Text('输出').fontSize(11).fontColor(this.themeTextMuted()).margin({ left: 6 })
                    Blank()
                    Text(this.formatTokenCount(this.tokenUsage!.last.outputTokens)).fontSize(11).fontColor(this.themeTextPrimary()).fontWeight(FontWeight.Medium)
                  }.width('100%').padding({ top: 6 })
                  Row() {
                    Circle({ width: 6, height: 6 }).fill('#A855F7')
                    Text('推理').fontSize(11).fontColor(this.themeTextMuted()).margin({ left: 6 })
                    Blank()
                    Text(this.formatTokenCount(this.tokenUsage!.last.reasoningOutputTokens)).fontSize(11).fontColor(this.themeTextPrimary()).fontWeight(FontWeight.Medium)
                  }.width('100%').padding({ top: 6 })
                }
                .margin({ top: 4 })
              }
            }
            .margin({ top: 8 })
            .width('100%')
          }

          // 趋势 tab
          if (this.tokenTab === 1) {
            Column() {
              if (this.tokenAggregate === null) {
                Text('加载中...')
                  .fontSize(11)
                  .fontColor(this.themeTextMuted())
                  .margin({ top: 12 })
              } else {
                // 范围切换按钮
                Row() {
                  Text('今日')
                    .fontSize(11)
                    .fontColor(this.tokenTrendRange === 0 ? '#FFFFFF' : this.themeTextSecondary())
                    .fontWeight(this.tokenTrendRange === 0 ? FontWeight.Medium : FontWeight.Normal)
                    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                    .borderRadius(6)
                    .backgroundColor(this.tokenTrendRange === 0 ? '#27272A' : 'transparent')
                    .onClick(() => { this.tokenTrendRange = 0; })
                  Text('近7天')
                    .fontSize(11)
                    .fontColor(this.tokenTrendRange === 1 ? '#FFFFFF' : this.themeTextSecondary())
                    .fontWeight(this.tokenTrendRange === 1 ? FontWeight.Medium : FontWeight.Normal)
                    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                    .borderRadius(6)
                    .backgroundColor(this.tokenTrendRange === 1 ? '#27272A' : 'transparent')
                    .onClick(() => { this.tokenTrendRange = 1; })
                  Text('近30天')
                    .fontSize(11)
                    .fontColor(this.tokenTrendRange === 2 ? '#FFFFFF' : this.themeTextSecondary())
                    .fontWeight(this.tokenTrendRange === 2 ? FontWeight.Medium : FontWeight.Normal)
                    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                    .borderRadius(6)
                    .backgroundColor(this.tokenTrendRange === 2 ? '#27272A' : 'transparent')
                    .onClick(() => { this.tokenTrendRange = 2; })
                }
                .margin({ top: 8 })
                .padding(2)
                .borderRadius(7)
                .backgroundColor(this.themeSubtleBackground())
                .width('100%')

                // 今日视图：水平堆叠条 + 卡片
                if (this.tokenTrendRange === 0) {
                  Column() {
                    // 总量摘要
                    Row() {
                      Text(this.formatTokenCount(this.tokenAggregate!.today.totalTokens))
                        .fontSize(20)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.themeTextPrimary())
                      Text(' tokens')
                        .fontSize(11)
                        .fontColor(this.themeTextMuted())
                        .margin({ left: 2 })
                      Blank()
                      Text(`${this.tokenAggregate!.today.requestCount} 次请求`)
                        .fontSize(11)
                        .fontColor(this.themeTextMuted())
                    }
                    .width('100%')
                    .margin({ top: 10 })
                    .alignItems(VerticalAlign.Bottom)

                    // 水平堆叠条
                    if (this.tokenAggregate!.today.totalTokens > 0) {
                      Row() {
                        if (this.tokenAggregate!.today.inputTokens > 0) {
                          Row()
                            .layoutWeight(this.tokenAggregate!.today.inputTokens)
                            .height(8)
                            .backgroundColor('#3B82F6')
                        }
                        if (this.tokenAggregate!.today.cachedInputTokens > 0) {
                          Row()
                            .layoutWeight(this.tokenAggregate!.today.cachedInputTokens)
                            .height(8)
                            .backgroundColor('#A1A1AA')
                        }
                        if (this.tokenAggregate!.today.outputTokens > 0) {
                          Row()
                            .layoutWeight(this.tokenAggregate!.today.outputTokens)
                            .height(8)
                            .backgroundColor('#22C55E')
                        }
                        if (this.tokenAggregate!.today.reasoningOutputTokens > 0) {
                          Row()
                            .layoutWeight(this.tokenAggregate!.today.reasoningOutputTokens)
                            .height(8)
                            .backgroundColor('#A855F7')
                        }
                      }
                      .width('100%')
                      .height(8)
                      .borderRadius(4)
                      .clip(true)
                      .margin({ top: 10 })
                    }

                    // 分类明细卡片
                    Column() {
                      Row() {
                        this.trendLegendDot('#3B82F6')
                        Text('输入').fontSize(11).fontColor(this.themeTextSecondary()).margin({ left: 6 })
                        Blank()
                        Text(this.formatTokenCount(this.tokenAggregate!.today.inputTokens)).fontSize(11).fontColor(this.themeTextPrimary()).fontWeight(FontWeight.Medium)
                      }.width('100%').padding({ top: 8, bottom: 8 })

                      Row().width('100%').height(0.5).backgroundColor(this.themeSubtleBackground())

                      Row() {
                        this.trendLegendDot('#A1A1AA')
                        Text('缓存').fontSize(11).fontColor(this.themeTextSecondary()).margin({ left: 6 })
                        Blank()
                        Text(this.formatTokenCount(this.tokenAggregate!.today.cachedInputTokens)).fontSize(11).fontColor(this.themeTextPrimary()).fontWeight(FontWeight.Medium)
                      }.width('100%').padding({ top: 8, bottom: 8 })

                      Row().width('100%').height(0.5).backgroundColor(this.themeSubtleBackground())

                      Row() {
                        this.trendLegendDot('#22C55E')
                        Text('输出').fontSize(11).fontColor(this.themeTextSecondary()).margin({ left: 6 })
                        Blank()
                        Text(this.formatTokenCount(this.tokenAggregate!.today.outputTokens)).fontSize(11).fontColor(this.themeTextPrimary()).fontWeight(FontWeight.Medium)
                      }.width('100%').padding({ top: 8, bottom: 8 })

                      Row().width('100%').height(0.5).backgroundColor(this.themeSubtleBackground())

                      Row() {
                        this.trendLegendDot('#A855F7')
                        Text('推理').fontSize(11).fontColor(this.themeTextSecondary()).margin({ left: 6 })
                        Blank()
                        Text(this.formatTokenCount(this.tokenAggregate!.today.reasoningOutputTokens)).fontSize(11).fontColor(this.themeTextPrimary()).fontWeight(FontWeight.Medium)
                      }.width('100%').padding({ top: 8, bottom: 8 })
                    }
                    .width('100%')
                    .margin({ top: 12 })
                    .padding(10)
                    .backgroundColor(this.themePanelBackground())
                    .borderRadius(8)
                  }
                }

                // 近7天/近30天视图：面积图
                if (this.tokenTrendRange === 1 || this.tokenTrendRange === 2) {
                  Column() {
                    // 总量摘要
                    Row() {
                      Text(this.formatTokenCount(this.getTrendSumTokens()))
                        .fontSize(20)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.themeTextPrimary())
                      Text(' tokens')
                        .fontSize(11)
                        .fontColor(this.themeTextMuted())
                        .margin({ left: 2 })
                      Blank()
                      Text(`${this.getTrendSumRequests()} 次请求`)
                        .fontSize(11)
                        .fontColor(this.themeTextMuted())
                    }
                    .width('100%')
                    .margin({ top: 10 })
                    .alignItems(VerticalAlign.Bottom)

                    // 面积图
                    Stack({ alignContent: Alignment.BottomStart }) {
                      // 网格线
                      Column() {
                        Row().width('100%').height(0.5).backgroundColor(this.themeSubtleBackground())
                        Row().width('100%').height(0.5).backgroundColor(this.themeSubtleBackground()).margin({ top: 24 })
                        Row().width('100%').height(0.5).backgroundColor(this.themeSubtleBackground()).margin({ top: 24 })
                      }
                      .width('100%')
                      .height(52)
                      .padding({ left: 2, right: 2 })

                      // 面积填充
                      Shape() {
                        Path()
                          .commands(this.getTrendAreaPath())
                          .fill('#1A3B82F6')
                          .stroke('none')
                      }
                      .width('100%')
                      .height(52)

                      // 折线
                      Shape() {
                        Path()
                          .commands(this.getTrendTokenPath())
                          .stroke('#3B82F6')
                          .strokeWidth(2)
                          .fill('none')
                      }
                      .width('100%')
                      .height(52)
                    }
                    .width('100%')
                    .height(52)
                    .margin({ top: 12 })

                    // X轴日期
                    Row() {
                      Text(this.getTrendFirstDate()).fontSize(9).fontColor(this.themeTextMuted())
                      Blank()
                      Text(this.getTrendLastDate()).fontSize(9).fontColor(this.themeTextMuted())
                    }
                    .width('100%')
                    .margin({ top: 4 })

                    // 每日明细列表
                    Column() {
                      ForEach(this.getTrendData().slice(-7).reverse(), (item: DailyTokenSnapshot) => {
                        Row() {
                          Text(item.date.substring(5))
                            .fontSize(11)
                            .fontColor(this.themeTextSecondary())
                            .width(40)
                          Blank()
                          Text(this.formatTokenCount(item.totalTokens))
                            .fontSize(11)
                            .fontColor(this.themeTextPrimary())
                            .fontWeight(FontWeight.Medium)
                          Text(`  ${item.requestCount}次`)
                            .fontSize(10)
                            .fontColor(this.themeTextMuted())
                        }
                        .width('100%')
                        .padding({ top: 7, bottom: 7 })
                      })
                    }
                    .width('100%')
                    .margin({ top: 12 })
                    .padding(10)
                    .backgroundColor(this.themePanelBackground())
                    .borderRadius(8)
                  }
                }
              }
            }
            .margin({ top: 8 })
            .width('100%')
          }
            }
          }
          .scrollable(ScrollDirection.Vertical)
          .height(this.tokenCardHeight)
          .align(Alignment.TopStart)
        }
      }
      .padding(this.tokenCardExpanded ? 12 : 0)
      .width('100%')
      .backgroundColor(this.themeElevatedBackground())
      .borderRadius({ bottomLeft: 10, bottomRight: 10 })
      .border({ width: 0.5, color: this.themeBorder() })
      .shadow(this.tokenCardExpanded ? { radius: 12, color: '#0A000000', offsetY: 4 } : undefined)
      .animation({ duration: this.motionNormalDuration, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {}
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeRootBackground())
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() {
          if (this.currentBreakpoint === 'lg') {
            this.desktopWorkspace()
          } else if (this.currentBreakpoint === 'md') {
            this.tabletWorkspace()
          } else {
            this.phoneWorkspace()
          }
        }
        .width('100%')
        .height('100%')
        .padding(10)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        if (this.isPhoneBreakpoint() && this.showLeftDrawer) {
          Stack({ alignContent: Alignment.TopStart }) {
            Row() {
              this.leftPanel()
            }
            .height('100%')
          }
          .width('100%')
          .height('100%')
          .padding({ top: 12, bottom: 12, left: 12, right: 48 })
          .backgroundColor(this.themeBackdrop())
          .transition(TransitionEffect.OPACITY.animation({ duration: this.motionPanelDuration, curve: Curve.FastOutSlowIn }))
          .onClick(() => {
            this.showLeftDrawer = false;
          })
        }

        if (this.currentBreakpoint !== 'lg' && this.showRightDrawer) {
          Stack({ alignContent: Alignment.BottomEnd }) {
            Column() {
              this.rightPanel()
            }
            .width(this.rightPanelWidth)
            .height(this.isPhoneBreakpoint() ? '88%' : (this.currentBreakpoint === 'md' ? '78%' : '88%'))
            .padding(4)
          }
          .width('100%')
          .height('100%')
          .padding(this.isPhoneBreakpoint()
            ? { left: 28, right: 8, top: 16, bottom: 8 }
            : { left: 24, right: 12, top: 24, bottom: 12 })
          .backgroundColor(this.themeBackdrop())
          .transition(TransitionEffect.OPACITY.animation({ duration: this.motionPanelDuration, curve: Curve.FastOutSlowIn }))
          .onClick(() => {
            this.showRightDrawer = false;
          })
        }

        if (this.isPhoneBreakpoint() && (this.pendingApproval !== null || this.pendingRequestUserInput !== null)) {
          Column() {
            Blank()
              .layoutWeight(1)
            Column() {
              if (this.pendingApproval !== null) {
                this.approvalCard(this.pendingApproval!)
              }
              if (this.pendingRequestUserInput !== null) {
                this.requestUserInputCard(this.pendingRequestUserInput!)
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 12 })
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#4D000000')
          .transition(TransitionEffect.OPACITY.animation({ duration: this.motionNormalDuration, curve: Curve.FastOutSlowIn }))
          .onClick(() => {
            // tap backdrop to dismiss — do nothing, user must approve/deny
          })
        }

        if (this.showAboutDialog) {
          Stack() {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#0F172A')
              .opacity(0.4)
              .onClick(() => { this.showAboutDialog = false; })

            Column() {
              Row() {
                Text('关于我们')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.themeTextPrimary())

                Blank()
                  .layoutWeight(1)

                Button('×')
                  .type(ButtonType.Normal)
                  .accessibilityText('关闭关于页面')
                  .width(32).height(32)
                  .fontSize(20)
                  .fontColor(this.themeTextStrong())
                  .backgroundColor(this.themeSubtleBackground())
                  .borderRadius(10)
                  .onClick(() => { this.showAboutDialog = false; })
              }
              .width('100%')

              Scroll() {
                Image($r('app.media.splash_bg'))
                  .width('100%')
                  .borderRadius(12)
                  .objectFit(ImageFit.Contain)
              }
              .width('100%')
              .layoutWeight(1)
              .margin({ top: 12 })
              .scrollBar(BarState.Auto)
            }
            .width(this.isPhoneBreakpoint() ? '98%' : '92%')
            .constraintSize({ minHeight: '80vh', maxHeight: '92vh' })
            .padding(20)
            .backgroundColor(this.themeElevatedBackground())
            .borderRadius(24)
            .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: 8 })
          }
          .width('100%')
          .height('100%')
          .transition(TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.FastOutSlowIn }))
        }
      }
      .width('100%')
      .height('100%')

      if (this.showProjectMenuId.length > 0 || this.showSessionMenuId.length > 0) {
        this.topLevelFloatingMenus()
      }
    }
    .width('100%')
    .height('100%')
    .onClick(() => {
      this.showProjectMenuId = '';
      this.showSessionMenuId = '';
    })
  }
}
