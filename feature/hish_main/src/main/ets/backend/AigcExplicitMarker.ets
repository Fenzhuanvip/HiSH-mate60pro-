/**
 * AIGC 显式标注纯逻辑模块 —— 无 fileIo 依赖，可单测。
 *
 * 在 AI 生成文件的内容部分开头加"本文件由AI生成，请注意甄别"，配合隐式标注。
 * - 位置：隐式标注（frontmatter/注释）之后、正文开头
 * - 代码文件用注释形式（不破坏可编译性）
 * - 依据：华为文档要求应用提供 AI 生成内容的显式标识
 */
import { AigcCommentSyntax, commentPrefixForFormat } from './AigcProvenance';

/** 显式标注文案。 */
export const EXPLICIT_MARKER_TEXT: string = '本文件由AI生成，请注意甄别';

/** 幂等检测范围（前 N 字符）。 */
const EXPLICIT_SCAN_BYTES: number = 8192;

/** 隐式标注块定位结果。 */
export interface AigcMarkerSpan {
  span: string;
  endIndex: number;
}

/**
 * 生成一行显式标注。
 * - md/markdown/txt → 纯文本行（打开即见）
 * - html/xml/svg → HTML 注释（不破坏结构）
 * - css → /* *​/
 * - py/sh/rb 等 → #
 * - 其它（ts/js/java/go 等）→ //
 */
export function buildExplicitMarkerLine(fileName: string): string {
  const lower: string = fileName.toLowerCase();
  const idx: number = lower.lastIndexOf('.');
  const ext: string = idx >= 0 ? lower.substring(idx + 1) : '';
  if (ext === 'md' || ext === 'markdown' || ext === 'txt') {
    return EXPLICIT_MARKER_TEXT;
  }
  const comment: AigcCommentSyntax = commentPrefixForFormat(fileName);
  if (comment.close.length > 0) {
    return `${comment.open} ${EXPLICIT_MARKER_TEXT} ${comment.close}`;
  }
  return `${comment.open} ${EXPLICIT_MARKER_TEXT}`;
}

/** 判断文本是否已包含显式标注（前 EXPLICIT_SCAN_BYTES 字符）。 */
export function hasExplicitMarker(text: string): boolean {
  const head: string = text.substring(0, EXPLICIT_SCAN_BYTES);
  return head.indexOf(EXPLICIT_MARKER_TEXT) >= 0;
}

/**
 * 定位文本头部的隐式标注块。
 * 返回 { span, endIndex }：span 是完整隐式块（含末尾换行），endIndex 是其后的索引。
 * 支持：YAML frontmatter、<!--AIGC-->、# AIGC、// AIGC、/* AIGC*​/、AIGC: 多行键值对。
 */
export function matchImplicitMarkerAtHead(text: string): AigcMarkerSpan | null {
  const head: string = text.substring(0, EXPLICIT_SCAN_BYTES);
  // YAML frontmatter：--- 开头，含 AIGC:，到第二个 --- 结束
  const lines: string[] = head.split('\n');
  if (lines.length > 0 && lines[0].trim() === '---') {
    let endLine: number = -1;
    for (let i: number = 1; i < lines.length; i += 1) {
      if (lines[i].trim() === '---') {
        endLine = i;
        break;
      }
    }
    if (endLine > 0 && head.indexOf('AIGC:') >= 0) {
      // 计算 span：0 到 endLine 行末尾（含换行）
      const pos: number = head.split('\n').slice(0, endLine + 1).join('\n').length;
      const endIdx: number = pos < head.length && head.charAt(pos) === '\n' ? pos + 1 : pos;
      const frontmatterSpan: AigcMarkerSpan = {
        span: head.substring(0, endIdx),
        endIndex: endIdx
      };
      return frontmatterSpan;
    }
  }
  // 单行/多行注释
  const patterns: RegExp[] = [
    /^<!--AIGC:[\s\S]*?-->\s*\n?/,
    /^#\s*AIGC:[^\n]*\n?/,
    /^\/\/\s*AIGC:[^\n]*\n?/,
    /^\/\*\s*AIGC:[\s\S]*?\*\/\s*\n?/,
    /^AIGC:[\s\S]*?ReservedCode2:[^\n]*\n?/
  ];
  for (let i: number = 0; i < patterns.length; i += 1) {
    const m = head.match(patterns[i]);
    if (m !== null && m.length > 0) {
      const commentSpan: AigcMarkerSpan = {
        span: m[0],
        endIndex: m[0].length
      };
      return commentSpan;
    }
  }
  return null;
}

/** 在隐式标注之后、正文开头插入显式标注行。 */
export function insertExplicitAfterImplicit(rawText: string, explicitLine: string): string {
  const m: AigcMarkerSpan | null = matchImplicitMarkerAtHead(rawText);
  if (m === null) {
    // 无隐式块 → 直接插到头部
    return `${explicitLine}\n${rawText}`;
  }
  const endIdx: number = m.endIndex;
  return `${rawText.substring(0, endIdx)}${explicitLine}\n${rawText.substring(endIdx)}`;
}

/** 轻量 XML 良构校验：维护标签栈，处理自闭合、CDATA、注释、属性含 >。 */
export function isWellFormedXml(xmlText: string): boolean {
  let text: string = xmlText;
  // 去 XML 声明
  text = text.replace(/<\?xml[\s\S]*?\?>/g, '');
  // 去注释
  text = text.replace(/<!--[\s\S]*?-->/g, '');
  // 去 DOCTYPE
  text = text.replace(/<!DOCTYPE[\s\S]*?>/g, '');
  // 去 CDATA
  text = text.replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, '');
  const stack: string[] = [];
  const tagPattern: RegExp = /<\/?([a-zA-Z][\w:.-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>/g;
  // String.match(global) 返回所有匹配的字符串数组（含捕获组不可直接取，改用 matchAll 语义的循环）
  // ArkTS 限制：不用 RegExp.exec / RegExpMatchArray 显式类型，改用 match + 逐项解析
  const matched: string[] = text.match(tagPattern) ?? [];
  for (let i: number = 0; i < matched.length; i += 1) {
    const tagText: string = matched[i];
    // 解析标签名：< 或 </ 后到空白/属性/结束
    const nameMatch = tagText.match(/^<\/?([a-zA-Z][\w:.-]*)/);
    if (nameMatch === null) {
      continue;
    }
    const name: string = nameMatch[1];
    const isClosing: boolean = tagText.startsWith('</');
    const isSelfClosing: boolean = tagText.endsWith('/>');
    if (isClosing) {
      const top: string | undefined = stack.pop();
      if (top !== name) {
        return false;
      }
    } else if (!isSelfClosing) {
      stack.push(name);
    }
  }
  return stack.length === 0;
}

/** JSON 有效性校验。 */
export function isValidJson(jsonText: string): boolean {
  try {
    JSON.parse(jsonText);
    return true;
  } catch (_err) {
    return false;
  }
}

/** 构建 docx 显式标注段落（在 <w:body> 后插入）。 */
export function buildDocxExplicitParagraph(markerText: string): string {
  const escaped: string = escapeXmlText(markerText);
  return `<w:p><w:r><w:t xml:space="preserve">${escaped}</w:t></w:r></w:p>`;
}

/** 构建 xlsx 显式标注行。 */
export function buildXlsxExplicitRow(markerText: string): string {
  const escaped: string = escapeXmlText(markerText);
  return `<row r="1" spans="1:1"><c r="A1" t="inlineStr"><is><t>${escaped}</t></is></c></row>`;
}

/** 构建 xlsx 显式标注单元格（追加到首行，列号自增）。 */
export function buildXlsxExplicitCell(markerText: string, colLetter: string): string {
  const escaped: string = escapeXmlText(markerText);
  return `<c r="${colLetter}1" t="inlineStr"><is><t>${escaped}</t></is></c>`;
}

/** 构建 pptx 显式标注文本框（shapeId 递增）。 */
export function buildPptxExplicitShape(markerText: string, shapeId: number): string {
  const escaped: string = escapeXmlText(markerText);
  return `<p:sp><p:nvSpPr><p:cNvPr id="${shapeId.toString()}" name="AI生成显式标注"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>` +
    `<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="320000"/></a:xfrm>` +
    `<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>` +
    `<p:txBody><a:bodyPr wrap="none"/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" dirty="0" b="1" sz="1400"/><a:t>${escaped}</a:t></a:r></a:p></p:txBody></p:sp>`;
}

/** xmind 显式标注子 topic 结构。 */
export interface AigcXmindTopic {
  id: string;
  topicClass: string;
  title: string;
  structureClass: string;
}

/** 构建 xmind 显式标注子 topic。 */
export function buildXmindExplicitTopic(markerText: string, produceId: string): AigcXmindTopic {
  const topic: AigcXmindTopic = {
    id: `aigc-note-${produceId}`,
    topicClass: 'topic',
    title: markerText,
    structureClass: 'org.xmind.ui.map.clockwise'
  };
  return topic;
}

/** 构建 OFD 显式标注 TextObject。 */
export function buildOfdExplicitTextObject(markerText: string, nextId: number, fontId: string): string {
  const escaped: string = escapeXmlText(markerText);
  return `<ofd:TextObject ID="${nextId.toString()}" CTM="1 0 0 1 0 0" Boundary="10 10 100 15" Font="${fontId}">` +
    `<ofd:TextCode X="10" Y="10">${escaped}</ofd:TextCode></ofd:TextObject>`;
}

/** PDF 页面尺寸（PDF 坐标单位：点，1pt = 1/72 inch）。 */
export interface PdfPageSize {
  width: number;
  height: number;
}

/** PDF 显式标注页的两个对象段（内容流对象 + 页面对象）。 */
export interface PdfExplicitPageObjects {
  contentObj: string;
  pageObj: string;
}

/** 标准 A4 页面尺寸（595.276 x 841.89 pt），作为未取到 MediaBox 时的兜底。 */
export const PDF_A4_SIZE: PdfPageSize = { width: 595.276, height: 841.89 };

/**
 * 中文字符串 → UTF-16BE 十六进制串（PDF Type0 字体 UniGB-UCS2-H 编码的 <...> 十六进制串）。
 * BMP 字符一个码点 = 一个 2 字节码元；UTF-16BE 中每码元两个字节，输出 4 位 hex。
 */
export function utf16HexString(text: string): string {
  const hexParts: string[] = [];
  for (let i: number = 0; i < text.length; i += 1) {
    const code: number = text.charCodeAt(i);
    const hex: string = code.toString(16).toUpperCase().padStart(4, '0');
    hexParts.push(hex);
  }
  return hexParts.join('');
}

/**
 * 构建 PDF 显式标注页的内容流。
 *
 * 与 docx"正文开头插入可见段落"等价：新增一个标注页，顶部画浅黄横幅，
 * 横幅上用 Type0 中文字体（STSong-Light + UniGB-UCS2-H）绘制
 * "本文件由AI生成，请注意甄别"，文本以 <hex> 十六进制串嵌入。
 * 横幅与文本坐标以 MediaBox 左下角为原点，与尺寸无关。
 *
 * @param size 页面尺寸（宽/高）
 * @param markerHex 标记文本的 UTF-16BE hex（由 utf16HexString 生成）
 */
export function buildPdfExplicitContentStream(size: PdfPageSize, markerHex: string): string {
  const h: number = size.height;
  const w: number = size.width;
  const bannerH: number = 56;
  const bannerY: number = h - bannerH;
  const content: string =
    'q\n' +
    '0.98 0.94 0.55 rg\n' + // 浅黄横幅填充
    `0 ${bannerY} ${w} ${bannerH} re f\n` +
    '0 0 0 RG\n' +
    `0 ${bannerY} ${w} 1 re S\n` + // 横幅底边线
    'Q\n' +
    'BT\n' +
    '/F1 16 Tf\n' + // Type0 中文字体
    '0 0 0 rg\n' +
    `72 ${bannerY + 18} Td\n` + // 文本基线
    `<${markerHex}> Tj\n` +
    'ET\n';
  return content;
}

/** 构建 PDF 显式标注页的 Type0 中文字体对象（STSong-Light，不嵌入字体，依赖阅读器内置 CJK 字体）。 */
export function buildPdfExplicitFontObject(fontObjNum: number, descendantObjNum: number): string {
  return `${fontObjNum} 0 obj\n` +
    `<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light /Encoding /UniGB-UCS2-H ` +
    `/DescendantFonts [${descendantObjNum} 0 R] >>\nendobj\n`;
}

/** 构建 STSong-Light 的 CIDFontType2 后代字体对象。 */
export function buildPdfExplicitCidFontObject(cidObjNum: number, descriptorObjNum: number): string {
  return `${cidObjNum} 0 obj\n` +
    `<< /Type /Font /Subtype /CIDFontType2 /BaseFont /STSong-Light ` +
    `/CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 5 >> ` +
    `/FontDescriptor ${descriptorObjNum} 0 R /DW 1000 /W [1 [1000]] >>\nendobj\n`;
}

/** 构建 STSong-Light 的 FontDescriptor 对象。 */
export function buildPdfExplicitFontDescriptor(descriptorObjNum: number): string {
  return `${descriptorObjNum} 0 obj\n` +
    `<< /Type /FontDescriptor /FontName /STSong-Light /Flags 4 ` +
    `/FontBBox [-25 -254 1000 880] /ItalicAngle 0 /Ascent 880 /Descent -254 /CapHeight 880 /StemV 80 >>\nendobj\n`;
}

/** 构建 PDF 显式标注页的对象块（内容流对象 + 页面对象）。 */
export function buildPdfExplicitPageObjects(
  pageObjNum: number,
  contentObjNum: number,
  pagesRef: number,
  fontRef: number,
  mediaBoxRaw: string,
  size: PdfPageSize,
  markerHex: string
): PdfExplicitPageObjects {
  const contentStream: string = buildPdfExplicitContentStream(size, markerHex);
  // 内容流对象 Length 用字节数：stream\n 与 endstream 之间是 contentStream + 末尾 \n。
  // 内容流全 ASCII（操作符 + hex），字节数 = 字符串长度 + 1（追加的换行）。
  const streamLen: number = contentStream.length + 1;
  const contentObj: string =
    `${contentObjNum} 0 obj\n` +
    `<< /Length ${streamLen} >>\n` +
    `stream\n${contentStream}\nendstream\nendobj\n`;
  const pageObj: string =
    `${pageObjNum} 0 obj\n` +
    `<< /Type /Page /Parent ${pagesRef} 0 R ` +
    `/MediaBox ${mediaBoxRaw} ` +
    `/Resources << /Font << /F1 ${fontRef} 0 R >> >> ` +
    `/Contents ${contentObjNum} 0 R >>\nendobj\n`;
  const result: PdfExplicitPageObjects = { contentObj: contentObj, pageObj: pageObj };
  return result;
}

/**
 * 构建重定义的 Pages 根对象：在原字典体上替换/补齐 /Kids 与 /Count，
 * 保留其余键（/MediaBox、/Resources、/Parent 等），否则子页会丢失继承属性。
 * 在 Kids 数组前追加标注页引用，Count 加 1。
 */
export function buildPdfRedefinedPagesObject(pagesObjNum: number, originalDictBody: string, newPageObjNum: number, newCount: number): string {
  let body: string = originalDictBody.trim();
  const kidsRe: RegExp = /\/Kids\s*\[[^\]]*\]/;
  if (kidsRe.test(body)) {
    const innerMatch = body.match(/\/Kids\s*\[([^\]]*)\]/);
    const inner: string = innerMatch !== null && innerMatch.length > 1 ? innerMatch[1].trim() : '';
    const newKids: string = inner.length > 0 ? `/Kids [${newPageObjNum} 0 R ${inner}]` : `/Kids [${newPageObjNum} 0 R]`;
    body = body.replace(kidsRe, newKids);
  } else {
    body = `${body} /Kids [${newPageObjNum} 0 R]`;
  }
  const countRe: RegExp = /\/Count\s+\d+/;
  if (countRe.test(body)) {
    body = body.replace(countRe, `/Count ${newCount}`);
  } else {
    body = `${body} /Count ${newCount}`;
  }
  return `${pagesObjNum} 0 obj\n<< ${body} >>\nendobj\n`;
}

/** XML 文本转义。 */
function escapeXmlText(input: string): string {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** 列字母转数字（A=1, B=2, ..., AA=27）。 */
export function columnLetterToNumber(letter: string): number {
  let result: number = 0;
  for (let i: number = 0; i < letter.length; i += 1) {
    result = result * 26 + (letter.charCodeAt(i) - 64);
  }
  return result;
}

/** 数字转列字母。 */
export function numberToColumnLetter(num: number): string {
  let n: number = num;
  let result: string = '';
  while (n > 0) {
    const rem: number = (n - 1) % 26;
    result = String.fromCharCode(65 + rem) + result;
    n = Math.floor((n - 1) / 26);
  }
  return result;
}
