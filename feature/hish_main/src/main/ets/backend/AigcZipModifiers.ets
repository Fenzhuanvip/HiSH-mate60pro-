/**
 * AIGC 隐式标识 zip 容器格式修改器。
 *
 * 作用于"已解压出的目录树"，就地修改目标条目（docProps/custom.xml、OFD.xml、
 * metadata.json、meta.json 等），随后由调用方重新打包。
 *
 * 依据：TC260《网络安全标准实践指南——人工智能生成合成内容标识方法
 *       文件元数据隐式标识 文本文件》。
 */
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  buildOfdCustomDataXml,
  buildOoxmlContentTypesOverride,
  buildOoxmlCustomPropertyXml,
  buildOoxmlFreshCustomXml,
  buildOoxmlRelsRelationship,
  OOXML_CUSTOM_PROPS_CONTENT_TYPE,
  OOXML_CUSTOM_PROPS_RELATIONSHIP_TYPE
} from './AigcProvenance';
import {
  AigcXmindTopic,
  EXPLICIT_MARKER_TEXT,
  buildDocxExplicitParagraph,
  buildXlsxExplicitRow,
  buildPptxExplicitShape,
  buildXmindExplicitTopic,
  buildOfdExplicitTextObject,
  hasExplicitMarker,
  isValidJson,
  isWellFormedXml
} from './AigcExplicitMarker';

const MODIFIER_DOMAIN: number = 0x0ff7;
const MODIFIER_TAG: string = 'AigcZipModifiers';

/** zip 容器条目修改器接口。 */
export interface AigcZipEntryModifier {
  /** 重打包后必须存在于 zip 根的条目名（验证门用）。 */
  rootVerifyEntry: string;
  /** 显式标注修改的内容条目（验证门需良构校验）。 */
  contentVerifyEntries: string[];
  /** 就地修改解压目录；返回是否成功。 */
  modify(extractedDir: string, payloadJson: string, fileName: string): boolean;
}

function fileExists(absPath: string): boolean {
  try {
    fileIo.statSync(absPath);
    return true;
  } catch (_err) {
    return false;
  }
}

function readText(absPath: string): string {
  return fileIo.readTextSync(absPath);
}

function writeText(absPath: string, content: string): void {
  const file = fileIo.openSync(absPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, content);
  } finally {
    fileIo.closeSync(file);
  }
}

/** 从现有 custom.xml 提取最大 pid；无则返回 1（新属性从 2 起）。 */
function extractMaxPid(customXml: string): number {
  let maxPid: number = 1;
  const matches: string[] = customXml.match(/pid="(\d+)"/g) ?? [];
  for (let i: number = 0; i < matches.length; i += 1) {
    const pid: number = parseInt(matches[i].replace(/[^0-9]/g, ''), 10);
    if (!isNaN(pid) && pid > maxPid) {
      maxPid = pid;
    }
  }
  return maxPid;
}

/**
 * 提取文本块中的 ProduceID。
 * 兼容：原始 JSON（"ProduceID":"..."）与 XML 转义后的 JSON（&quot;ProduceID&quot;:&quot;...&quot;）。
 */
function extractProduceIdFromBlock(block: string): string {
  // 匹配 "ProduceID":"..." 或 &quot;ProduceID&quot;:&quot;...&quot;
  const pattern: RegExp = /ProduceID(?:&quot;|["'])?\s*:\s*(?:&quot;|["'])([^"&]{8,64})(?:&quot;|["'])/;
  const matchResult = block.match(pattern);
  if (matchResult !== null && matchResult.length > 1) {
    return matchResult[1];
  }
  return '';
}

/** 提取现有 custom.xml 中 AIGC property 的 ProduceID（无则空串）。 */
function extractAigcProduceIdFromCustomXml(customXml: string): string {
  // 找 name="AIGC" 的 property 块
  const propMatch = customXml.match(/<property[^>]*name="AIGC"[^>]*>[\s\S]*?<\/property>/);
  if (propMatch === null) {
    return '';
  }
  return extractProduceIdFromBlock(propMatch[0]);
}

/** 在 custom.xml 中替换 AIGC property（ProduceID 不同时）。 */
function replaceAigcPropertyInCustomXml(customXml: string, payloadJson: string): string {
  const propPattern: RegExp = /<property[^>]*name="AIGC"[^>]*>[\s\S]*?<\/property>/;
  const newProp: string = buildOoxmlCustomPropertyXml(2, payloadJson); // pid 用 2（替换场景，pid 不重要）
  return customXml.replace(propPattern, newProp);
}

/** 在 custom.xml 的 </Properties> 前插入新 property。 */
function insertPropertyIntoCustomXml(customXml: string, payloadJson: string): string {
  const nextPid: number = extractMaxPid(customXml) + 1;
  const newProp: string = buildOoxmlCustomPropertyXml(nextPid, payloadJson);
  const closeIndex: number = customXml.lastIndexOf('</Properties>');
  if (closeIndex < 0) {
    return '';
  }
  return `${customXml.substring(0, closeIndex)}${newProp}${customXml.substring(closeIndex)}`;
}

/** OOXML 修改器（docx/xlsx/pptx 共用）：元数据 custom.xml + 内容条目显式标注。 */
class OoxmlModifier implements AigcZipEntryModifier {
  rootVerifyEntry: string = '[Content_Types].xml';
  contentVerifyEntries: string[] = [];

  modify(extractedDir: string, payloadJson: string, fileName: string): boolean {
    const docPropsDir: string = `${extractedDir}/docProps`;
    try {
      fileIo.mkdirSync(docPropsDir, true);
    } catch (_err) {
    }
    const customPath: string = `${docPropsDir}/custom.xml`;
    if (fileExists(customPath)) {
      const text: string = readText(customPath);
      const existingProduceId: string = extractAigcProduceIdFromCustomXml(text);
      let result: string = text;
      if (existingProduceId.length > 0) {
        // 幂等：ProduceID 相同则跳过（不重复）
        const currentProduceId: string = extractProduceIdFromJson(payloadJson);
        if (existingProduceId === currentProduceId) {
          return true;
        }
        result = replaceAigcPropertyInCustomXml(text, payloadJson);
      } else {
        result = insertPropertyIntoCustomXml(text, payloadJson);
        if (result.length === 0) {
          return false;
        }
      }
      writeText(customPath, result);
    } else {
      // custom.xml 不存在 → 新建 + 补 [Content_Types].xml + _rels/.rels
      if (!fileExists(`${extractedDir}/[Content_Types].xml`) || !fileExists(`${extractedDir}/_rels/.rels`)) {
        return false;
      }
      writeText(customPath, buildOoxmlFreshCustomXml(payloadJson));
      // [Content_Types].xml 加 Override
      const ctPath: string = `${extractedDir}/[Content_Types].xml`;
      const ct: string = readText(ctPath);
      if (ct.indexOf(OOXML_CUSTOM_PROPS_CONTENT_TYPE) < 0) {
        const override: string = buildOoxmlContentTypesOverride();
        const ctClose: number = ct.lastIndexOf('</Types>');
        if (ctClose < 0) {
          return false;
        }
        writeText(ctPath, `${ct.substring(0, ctClose)}${override}${ct.substring(ctClose)}`);
      }
      // _rels/.rels 加关系
      const relsPath: string = `${extractedDir}/_rels/.rels`;
      const rels: string = readText(relsPath);
      if (rels.indexOf(OOXML_CUSTOM_PROPS_RELATIONSHIP_TYPE) < 0) {
        const nextRid: number = extractMaxRid(rels) + 1;
        const relation: string = buildOoxmlRelsRelationship(`rId${nextRid.toString()}`);
        const relsClose: number = rels.lastIndexOf('</Relationships>');
        if (relsClose < 0) {
          return false;
        }
        writeText(relsPath, `${rels.substring(0, relsClose)}${relation}${rels.substring(relsClose)}`);
      }
    }
    // 显式标注：在内容条目开头插入提示（best-effort）
    this.injectExplicitContent(extractedDir, fileName);
    return true;
  }

  /** 按扩展名在内容条目开头插入显式标注。 */
  private injectExplicitContent(extractedDir: string, fileName: string): void {
    const lower: string = fileName.toLowerCase();
    const idx: number = lower.lastIndexOf('.');
    const ext: string = idx >= 0 ? lower.substring(idx + 1) : '';
    try {
      if (ext === 'docx') {
        this.injectDocxContent(extractedDir);
      } else if (ext === 'xlsx') {
        this.injectXlsxContent(extractedDir);
      } else if (ext === 'pptx') {
        this.injectPptxContent(extractedDir);
      }
    } catch (err) {
      hilog.warn(MODIFIER_DOMAIN, MODIFIER_TAG, 'injectExplicitContent failed: %{public}s', `${err}`);
    }
  }

  /** docx：word/document.xml 的 <w:body> 后插显式段落。 */
  private injectDocxContent(extractedDir: string): void {
    const docPath: string = `${extractedDir}/word/document.xml`;
    if (!fileExists(docPath)) {
      return;
    }
    const text: string = readText(docPath);
    if (hasExplicitMarker(text)) {
      return; // 已注入
    }
    const bodyIdx: number = text.indexOf('<w:body');
    if (bodyIdx < 0) {
      return;
    }
    const bodyEnd: number = text.indexOf('>', bodyIdx);
    if (bodyEnd < 0) {
      return;
    }
    const paragraph: string = buildDocxExplicitParagraph(EXPLICIT_MARKER_TEXT);
    writeText(docPath, `${text.substring(0, bodyEnd + 1)}${paragraph}${text.substring(bodyEnd + 1)}`);
    this.contentVerifyEntries.push('word/document.xml');
  }

  /** xlsx：xl/worksheets/sheet1.xml 的 <sheetData> 后插显式行（三级策略）。 */
  private injectXlsxContent(extractedDir: string): void {
    const sheetPath: string = `${extractedDir}/xl/worksheets/sheet1.xml`;
    if (!fileExists(sheetPath)) {
      return;
    }
    const text: string = readText(sheetPath);
    if (hasExplicitMarker(text)) {
      return;
    }
    const row: string = buildXlsxExplicitRow(EXPLICIT_MARKER_TEXT);
    // 策略1：空 <sheetData/> 或 <sheetData></sheetData>
    const emptySheetData: RegExp = /<sheetData\s*\/>/;
    if (emptySheetData.test(text)) {
      writeText(sheetPath, text.replace(emptySheetData, `<sheetData>${row}</sheetData>`));
      this.contentVerifyEntries.push('xl/worksheets/sheet1.xml');
      return;
    }
    const sheetDataIdx: number = text.indexOf('<sheetData');
    if (sheetDataIdx < 0) {
      return;
    }
    const sheetDataEnd: number = text.indexOf('>', sheetDataIdx);
    if (sheetDataEnd < 0) {
      return;
    }
    writeText(sheetPath, `${text.substring(0, sheetDataEnd + 1)}${row}${text.substring(sheetDataEnd + 1)}`);
    this.contentVerifyEntries.push('xl/worksheets/sheet1.xml');
  }

  /** pptx：ppt/slides/slide1.xml 的 <p:spTree> 后插显式文本框。 */
  private injectPptxContent(extractedDir: string): void {
    const slidePath: string = `${extractedDir}/ppt/slides/slide1.xml`;
    if (!fileExists(slidePath)) {
      return;
    }
    const text: string = readText(slidePath);
    if (hasExplicitMarker(text)) {
      return;
    }
    const spTreeIdx: number = text.indexOf('<p:spTree');
    if (spTreeIdx < 0) {
      return;
    }
    const spTreeEnd: number = text.indexOf('>', spTreeIdx);
    if (spTreeEnd < 0) {
      return;
    }
    // 计算 shapeId：现有最大 id + 1
    const maxId: number = extractMaxShapeId(text);
    const shape: string = buildPptxExplicitShape(EXPLICIT_MARKER_TEXT, maxId + 1);
    writeText(slidePath, `${text.substring(0, spTreeEnd + 1)}${shape}${text.substring(spTreeEnd + 1)}`);
    this.contentVerifyEntries.push('ppt/slides/slide1.xml');
  }
}

/** 从 pptx slide XML 提取最大 cNvPr id。 */
function extractMaxShapeId(xml: string): number {
  let maxId: number = 0;
  const matches: string[] = xml.match(/id="(\d+)"/g) ?? [];
  for (let i: number = 0; i < matches.length; i += 1) {
    const num: number = parseInt(matches[i].replace(/[^0-9]/g, ''), 10);
    if (!isNaN(num) && num > maxId) {
      maxId = num;
    }
  }
  return maxId;
}

/** 从 _rels/.rels 提取最大 rId 数字。 */
function extractMaxRid(rels: string): number {
  let maxRid: number = 0;
  const matches: string[] = rels.match(/rId(\d+)/g) ?? [];
  for (let i: number = 0; i < matches.length; i += 1) {
    const rid: number = parseInt(matches[i].replace(/[^0-9]/g, ''), 10);
    if (!isNaN(rid) && rid > maxRid) {
      maxRid = rid;
    }
  }
  return maxRid;
}

/** 从 payloadJson（原始 JSON）提取 ProduceID。 */
function extractProduceIdFromJson(payloadJson: string): string {
  return extractProduceIdFromBlock(payloadJson);
}

/** OFD 修改器：OFD.xml 的 CustomDatas + 页面 Content.xml 显式 TextObject。 */
class OfdModifier implements AigcZipEntryModifier {
  rootVerifyEntry: string = 'OFD.xml';
  contentVerifyEntries: string[] = [];

  modify(extractedDir: string, payloadJson: string, _fileName: string): boolean {
    const ofdPath: string = `${extractedDir}/OFD.xml`;
    if (!fileExists(ofdPath)) {
      return false;
    }
    const text: string = readText(ofdPath);
    // 已有 AIGC CustomData → 幂等/替换
    const existing = text.match(/<CustomData\s+Name="AIGC"[^>]*>[\s\S]*?<\/CustomData>/);
    if (existing !== null) {
      const existingProduceId: string = extractProduceIdFromText(existing[0]);
      const currentProduceId: string = extractProduceIdFromJson(payloadJson);
      if (existingProduceId === currentProduceId) {
        return true;
      }
      writeText(ofdPath, text.replace(existing[0], buildOfdCustomDataXml(payloadJson)));
    } else {
      const newElem: string = buildOfdCustomDataXml(payloadJson);
      const customDatasClose: number = text.lastIndexOf('</CustomDatas>');
      if (customDatasClose >= 0) {
        writeText(ofdPath, `${text.substring(0, customDatasClose)}${newElem}${text.substring(customDatasClose)}`);
      } else {
        // 无 CustomDatas → 在 </DocInfo> 前建块
        const docInfoClose: number = text.lastIndexOf('</DocInfo>');
        if (docInfoClose >= 0) {
          const block: string = `<CustomDatas>${newElem}</CustomDatas>`;
          writeText(ofdPath, `${text.substring(0, docInfoClose)}${block}${text.substring(docInfoClose)}`);
        }
      }
    }
    // 显式标注：在首个页面 Content.xml 插入 TextObject（best-effort，无字体则跳过）
    this.injectExplicitContent(extractedDir);
    return true;
  }

  /** OFD 页面内容显式标注。 */
  private injectExplicitContent(extractedDir: string): void {
    try {
      // 探测字体：Doc_0/Document.xml 中第一个 <ofd:Font ID="...">
      const docXmlPath: string = `${extractedDir}/Doc_0/Document.xml`;
      if (!fileExists(docXmlPath)) {
        return;
      }
      const docXml: string = readText(docXmlPath);
      const fontMatch = docXml.match(/<ofd:Font\s+ID="([^"]+)"/);
      if (fontMatch === null || fontMatch.length < 2) {
        return; // 无字体资源 → 跳过
      }
      const fontId: string = fontMatch[1];
      // 找首个 Content.xml
      const contentPath: string = this.findFirstContentXml(extractedDir);
      if (contentPath === '') {
        return;
      }
      const text: string = readText(contentPath);
      if (hasExplicitMarker(text)) {
        return;
      }
      const pageBlockIdx: number = text.indexOf('<ofd:PageBlock');
      if (pageBlockIdx < 0) {
        return;
      }
      const pageBlockEnd: number = text.indexOf('>', pageBlockIdx);
      if (pageBlockEnd < 0) {
        return;
      }
      const nextId: number = extractMaxOfdId(text) + 1;
      const textObj: string = buildOfdExplicitTextObject(EXPLICIT_MARKER_TEXT, nextId, fontId);
      writeText(contentPath, `${text.substring(0, pageBlockEnd + 1)}${textObj}${text.substring(pageBlockEnd + 1)}`);
      this.contentVerifyEntries.push(this.relativePath(extractedDir, contentPath));
    } catch (err) {
      hilog.warn(MODIFIER_DOMAIN, MODIFIER_TAG, 'ofd injectExplicitContent failed: %{public}s', `${err}`);
    }
  }

  /** 扫描 Doc_0/Pages 下第一个 Content.xml。 */
  private findFirstContentXml(extractedDir: string): string {
    const pagesDir: string = `${extractedDir}/Doc_0/Pages`;
    if (!fileExists(pagesDir)) {
      return '';
    }
    return this.scanContentXml(pagesDir);
  }

  private scanContentXml(dir: string): string {
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(dir) as string[];
    } catch (_err) {
      return '';
    }
    for (let i: number = 0; i < entries.length; i += 1) {
      const child: string = `${dir}/${entries[i]}`;
      try {
        const stat = fileIo.statSync(child);
        if (stat.isDirectory()) {
          const found: string = this.scanContentXml(child);
          if (found !== '') {
            return found;
          }
        } else if (entries[i] === 'Content.xml') {
          return child;
        }
      } catch (_err) {
      }
    }
    return '';
  }

  private relativePath(root: string, abs: string): string {
    if (abs.startsWith(`${root}/`)) {
      return abs.substring(root.length + 1);
    }
    return abs;
  }
}

/** 从 OFD XML 提取最大数字 ID。 */
function extractMaxOfdId(xml: string): number {
  let maxId: number = 0;
  const matches: string[] = xml.match(/ID="(\d+)"/g) ?? [];
  for (let i: number = 0; i < matches.length; i += 1) {
    const num: number = parseInt(matches[i].replace(/[^0-9]/g, ''), 10);
    if (!isNaN(num) && num > maxId) {
      maxId = num;
    }
  }
  return maxId;
}

function extractProduceIdFromText(block: string): string {
  return extractProduceIdFromBlock(block);
}

/** JSON 容器修改器（xmind: metadata.json + content.json；posm/posf: meta.json）。 */
class JsonContainerModifier implements AigcZipEntryModifier {
  rootVerifyEntry: string;
  contentVerifyEntries: string[] = [];
  private isXmind: boolean;

  constructor(rootVerifyEntry: string, isXmind: boolean) {
    this.rootVerifyEntry = rootVerifyEntry;
    this.isXmind = isXmind;
  }

  modify(extractedDir: string, payloadJson: string, fileName: string): boolean {
    const entryPath: string = `${extractedDir}/${this.rootVerifyEntry}`;
    if (!fileExists(entryPath)) {
      return false;
    }
    try {
      const text: string = readText(entryPath);
      const obj: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const aigcObj: Object | undefined = obj['AIGC'];
      if (aigcObj !== undefined) {
        const existingProduceId: string = extractProduceIdFromJson(JSON.stringify(aigcObj));
        const currentProduceId: string = extractProduceIdFromJson(payloadJson);
        if (existingProduceId === currentProduceId) {
          return true; // 幂等
        }
      }
      obj['AIGC'] = JSON.parse(payloadJson) as Object;
      writeText(entryPath, JSON.stringify(obj));
    } catch (_err) {
      return false;
    }
    // 显式标注：xmind 向 content.json 根 topic 加子 topic
    if (this.isXmind) {
      this.injectXmindContent(extractedDir, payloadJson, fileName);
    }
    return true;
  }

  /** xmind 显式标注：content.json 根 topic 下新建子 topic。 */
  private injectXmindContent(extractedDir: string, payloadJson: string, _fileName: string): void {
    try {
      const contentPath: string = `${extractedDir}/content.json`;
      if (!fileExists(contentPath)) {
        return;
      }
      const text: string = readText(contentPath);
      if (hasExplicitMarker(text)) {
        return;
      }
      const produceId: string = extractProduceIdFromJson(payloadJson);
      const topic: AigcXmindTopic = buildXmindExplicitTopic(EXPLICIT_MARKER_TEXT, produceId);
      const parsed: Object = JSON.parse(text) as Object;
      const arr: Object[] = parsed as Object[];
      if (arr.length === 0) {
        return;
      }
      const firstSheet: Record<string, Object> = arr[0] as Record<string, Object>;
      const rootTopic: Record<string, Object> | undefined = firstSheet['rootTopic'] as Record<string, Object> | undefined;
      if (rootTopic === undefined) {
        return;
      }
      const children: Record<string, Object> | undefined = rootTopic['children'] as Record<string, Object> | undefined;
      if (children === undefined) {
        const newChildren: Record<string, Object> = {};
        const attachedList: Object[] = [topic];
        newChildren['attached'] = attachedList;
        rootTopic['children'] = newChildren;
      } else {
        const attached: Object[] = (children['attached'] as Object[]) ?? [];
        attached.push(topic);
        children['attached'] = attached;
      }
      writeText(contentPath, JSON.stringify(parsed));
      this.contentVerifyEntries.push('content.json');
    } catch (err) {
      hilog.warn(MODIFIER_DOMAIN, MODIFIER_TAG, 'xmind injectExplicitContent failed: %{public}s', `${err}`);
    }
  }
}

/** 根据扩展名返回修改器；未知返回 null。 */
export function zipModifierForExt(ext: string): AigcZipEntryModifier | null {
  switch (ext.toLowerCase()) {
    case 'docx':
    case 'xlsx':
    case 'pptx':
      return new OoxmlModifier();
    case 'ofd':
      return new OfdModifier();
    case 'xmind':
      return new JsonContainerModifier('metadata.json', true);
    case 'posm':
    case 'posf':
      return new JsonContainerModifier('meta.json', false);
    default:
      return null;
  }
}
