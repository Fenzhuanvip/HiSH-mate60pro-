/**
 * AIGC 隐式标识 PDF 写入器 —— 向 Document Information Dictionary 追加 /AIGC({json})。
 *
 * 策略：纯 append 增量更新段，不重写原字节。
 * 1. 校验适用性：%PDF 头、无 /Encrypt、非 linearized、尾部可解析 startxref+%%EOF
 * 2. 解析 trailer：/Size、/Root、/Info、startxref
 * 3. 有 Info → 重定义该对象（追加 /AIGC）；无 → 新建对象 size，trailer 加 /Info
 * 4. append 新对象 + xref + trailer（/Prev <oldStartxref>）+ startxref + %%EOF
 *
 * 依据：TC260《文本文件》指南 6.3，/AIGC({"Label":"1",...}) 写入 Document Information Dictionary。
 */
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import {
  EXPLICIT_MARKER_TEXT,
  PDF_A4_SIZE,
  PdfPageSize,
  buildPdfExplicitCidFontObject,
  buildPdfExplicitFontDescriptor,
  buildPdfExplicitFontObject,
  buildPdfExplicitPageObjects,
  buildPdfRedefinedPagesObject,
  utf16HexString
} from './AigcExplicitMarker';

const PDF_DOMAIN: number = 0x0ff8;
const PDF_TAG: string = 'AigcPdfInjector';
const TAIL_SCAN_BYTES: number = 64 * 1024;
const MAX_PDF_BYTES: number = 200 * 1024 * 1024;

/** PDF 字符串字面量转义：\ ( ) 控制符 非 ASCII → \ooo 八进制（字节级）。 */
export function escapePdfLiteralString(jsonText: string): string {
  const encoder: util.TextEncoder = new util.TextEncoder();
  const bytes: Uint8Array = encoder.encodeInto(jsonText);
  const parts: string[] = [];
  for (let i: number = 0; i < bytes.length; i += 1) {
    const b: number = bytes[i];
    if (b === 0x5c) { // backslash
      parts.push('\\\\');
    } else if (b === 0x28) { // (
      parts.push('\\(');
    } else if (b === 0x29) { // )
      parts.push('\\)');
    } else if (b === 0x0a) { // LF
      parts.push('\\n');
    } else if (b === 0x0d) { // CR
      parts.push('\\r');
    } else if (b === 0x09) { // TAB
      parts.push('\\t');
    } else if (b < 0x20 || b >= 0x80) {
      parts.push(`\\${b.toString(8).padStart(3, '0')}`);
    } else {
      parts.push(String.fromCharCode(b));
    }
  }
  return parts.join('');
}

/** 读取文件尾部字节并解码为字符串。 */
function readFileTailText(absPath: string): string {
  const stat = fileIo.statSync(absPath);
  const readLen: number = Math.min(stat.size, TAIL_SCAN_BYTES);
  const offset: number = stat.size - readLen;
  const file = fileIo.openSync(absPath, fileIo.OpenMode.READ_ONLY);
  try {
    const buffer = new ArrayBuffer(readLen);
    fileIo.readSync(file.fd, buffer, { offset, length: readLen });
    const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
    return decoder.decode(new Uint8Array(buffer, 0, readLen));
  } finally {
    fileIo.closeSync(file);
  }
}

interface PdfTrailerInfo {
  oldStartxref: number;
  size: number;
  rootRef: number;
  infoRef: number;
  infoDictBody: string; // 原 Info 对象字典内容（无外层 << >>），无则空串
}

/** 增量段中写入的单个对象：对象号 + 段文本。 */
interface PdfWrittenObject {
  objNum: number;
  segment: string;
}

/** 解析 PDF trailer；不适用返回 null。 */
function parsePdfTrailer(absPath: string, tailText: string): PdfTrailerInfo | null {
  // 找最后一个 startxref
  const sxIndex: number = tailText.lastIndexOf('startxref');
  if (sxIndex < 0) {
    return null;
  }
  const afterSx: string = tailText.substring(sxIndex);
  const sxMatch = afterSx.match(/startxref\s+(\d+)\s*%%EOF/);
  if (sxMatch === null || sxMatch.length < 2) {
    return null;
  }
  const oldStartxref: number = parseInt(sxMatch[1], 10);

  // 找 trailer 字典
  const trailerIndex: number = tailText.lastIndexOf('trailer');
  if (trailerIndex < 0) {
    return null;
  }
  const trailerSection: string = tailText.substring(trailerIndex);
  const dictStart: number = trailerSection.indexOf('<<');
  const dictEnd: number = trailerSection.lastIndexOf('>>');
  if (dictStart < 0 || dictEnd <= dictStart) {
    return null;
  }
  const dict: string = trailerSection.substring(dictStart + 2, dictEnd);

  const sizeMatch = dict.match(/\/Size\s+(\d+)/);
  const rootMatch = dict.match(/\/Root\s+(\d+)\s+0\s+R/);
  const infoMatch = dict.match(/\/Info\s+(\d+)\s+0\s+R/);
  if (rootMatch === null || rootMatch.length < 2) {
    return null; // 必须有 /Root
  }
  const size: number = sizeMatch !== null && sizeMatch.length > 1 ? parseInt(sizeMatch[1], 10) : 0;
  const rootRef: number = parseInt(rootMatch[1], 10);
  const infoRef: number = infoMatch !== null && infoMatch.length > 1 ? parseInt(infoMatch[1], 10) : -1;

  // 尝试读取原 Info 对象字典
  let infoDictBody: string = '';
  if (infoRef > 0) {
    infoDictBody = readObjectDict(absPath, infoRef);
  }
  const result: PdfTrailerInfo = {
    oldStartxref: oldStartxref,
    size: size,
    rootRef: rootRef,
    infoRef: infoRef,
    infoDictBody: infoDictBody
  };
  return result;
}

/** 定位并读取指定对象号的字典体（无 << >> 包裹）。 */
function readObjectDict(absPath: string, objNum: number): string {
  try {
    const stat = fileIo.statSync(absPath);
    const file = fileIo.openSync(absPath, fileIo.OpenMode.READ_ONLY);
    try {
      // 扫描对象：找 "<objNum> 0 obj" 到 "endobj"
      const chunkSize: number = 64 * 1024;
      let offset: number = 0;
      const marker: string = `${objNum.toString()} 0 obj`;
      while (offset < stat.size) {
        const readLength: number = Math.min(chunkSize, stat.size - offset);
        const buffer = new ArrayBuffer(readLength);
        const bytesRead: number = fileIo.readSync(file.fd, buffer, { offset, length: readLength });
        if (bytesRead <= 0) {
          break;
        }
        const chunk: string = new util.TextDecoder('utf-8').decode(new Uint8Array(buffer, 0, bytesRead));
        const idx: number = chunk.indexOf(marker);
        if (idx >= 0) {
          const afterObj: string = chunk.substring(idx + marker.length);
          const dictStart: number = afterObj.indexOf('<<');
          const dictEnd: number = afterObj.lastIndexOf('>>');
          if (dictStart >= 0 && dictEnd > dictStart) {
            return afterObj.substring(dictStart + 2, dictEnd);
          }
          return '';
        }
        // 避免漏跨块：重叠 8 字节
        offset += (bytesRead > 8 ? bytesRead - 8 : bytesRead);
      }
      return '';
    } finally {
      fileIo.closeSync(file);
    }
  } catch (_err) {
    return '';
  }
}

/** 从 PDF 结构解析出的 Pages 根信息。 */
interface PdfPagesInfo {
  pagesObjNum: number;
  pagesDictBody: string;
  mediaBoxRaw: string; // 原样保留的 /MediaBox 值（形如 [0 0 595.276 841.89]）
  mediaBox: PdfPageSize; // 解析出的宽/高，用于标注页内容流布局
  oldCount: number;
}

/** 从 Root 对象解析 Pages 根：对象号 + 字典体 + MediaBox + Count。失败返回 null。 */
function parsePagesInfo(absPath: string, rootRef: number): PdfPagesInfo | null {
  const rootBody: string = readObjectDict(absPath, rootRef);
  if (rootBody.length === 0) {
    return null;
  }
  const pagesMatch = rootBody.match(/\/Pages\s+(\d+)\s+0\s+R/);
  if (pagesMatch === null || pagesMatch.length < 2) {
    return null;
  }
  const pagesObjNum: number = parseInt(pagesMatch[1], 10);
  const pagesBody: string = readObjectDict(absPath, pagesObjNum);
  if (pagesBody.length === 0) {
    return null;
  }
  let mediaBoxRaw: string = '[0 0 595.276 841.89]';
  let size: PdfPageSize = PDF_A4_SIZE;
  const mbMatch = pagesBody.match(/\/MediaBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]/);
  if (mbMatch !== null && mbMatch.length >= 5) {
    const raw: string = mbMatch[0].substring('/MediaBox'.length).trim();
    if (raw.length > 0) {
      mediaBoxRaw = raw;
    }
    const x: number = parseFloat(mbMatch[1]);
    const y: number = parseFloat(mbMatch[2]);
    const w: number = parseFloat(mbMatch[3]);
    const h: number = parseFloat(mbMatch[4]);
    // MediaBox 是 [llx lly urx ury]，尺寸 = (urx-llx, ury-lly)
    if (!isNaN(x) && !isNaN(y) && !isNaN(w) && !isNaN(h)) {
      const width: number = w - x;
      const height: number = h - y;
      if (width > 0 && height > 0) {
        size = { width: width, height: height };
      }
    }
  }
  let oldCount: number = 1;
  const countMatch = pagesBody.match(/\/Count\s+(\d+)/);
  if (countMatch !== null && countMatch.length > 1) {
    const parsedCount: number = parseInt(countMatch[1], 10);
    if (!isNaN(parsedCount)) {
      oldCount = parsedCount;
    }
  }
  const result: PdfPagesInfo = {
    pagesObjNum: pagesObjNum,
    pagesDictBody: pagesBody,
    mediaBoxRaw: mediaBoxRaw,
    mediaBox: size,
    oldCount: oldCount
  };
  return result;
}

/** 追加 PDF 增量更新段。返回是否成功。 */
export function injectPdfIncremental(absPath: string, targetPath: string, payloadJson: string): boolean {
  try {
    const stat = fileIo.statSync(absPath);
    if (stat.size > MAX_PDF_BYTES) {
      return false;
    }
    const head: string = readFileHead(absPath);
    if (!head.startsWith('%PDF-')) {
      return false;
    }
    const fullTail: string = readFileTailText(absPath);
    // 加密 / 线性化检查
    if (fullTail.indexOf('/Encrypt') >= 0) {
      return false;
    }
    const headBlock: string = readFileHead(absPath);
    if (headBlock.indexOf('/Linearized') >= 0) {
      return false;
    }

    const trailer: PdfTrailerInfo | null = parsePdfTrailer(absPath, fullTail);
    if (trailer === null) {
      return false;
    }

    const escaped: string = escapePdfLiteralString(payloadJson);

    // best-effort：解析 Pages 根，能取到则追加显式标注页（插入 Kids 头部），否则仅隐式
    const pagesInfo: PdfPagesInfo | null = parsePagesInfo(absPath, trailer.rootRef);
    const markerHex: string = utf16HexString(EXPLICIT_MARKER_TEXT);

    // 按序收集本增量段写入的对象（对象号 + 段文本），偏移由段字节长度从文件尾累计
    const written: PdfWrittenObject[] = [];

    // 1) Info 对象：有则重定义（追加 /AIGC），无则新建
    let infoRefUsed: number = trailer.infoRef;
    if (trailer.infoRef > 0) {
      let dictBody: string = trailer.infoDictBody.trim();
      if (dictBody.length > 0) {
        dictBody = `${dictBody} /AIGC(${escaped})`;
      } else {
        dictBody = `/AIGC(${escaped})`;
      }
      const infoSegment: string = `${trailer.infoRef.toString()} 0 obj\n<< ${dictBody} >>\nendobj\n`;
      const infoObj: PdfWrittenObject = { objNum: trailer.infoRef, segment: infoSegment };
      written.push(infoObj);
    } else {
      const newInfoNum: number = Math.max(trailer.size, trailer.rootRef + 1);
      const infoSegment: string = `${newInfoNum.toString()} 0 obj\n<< /AIGC(${escaped}) >>\nendobj\n`;
      const infoObj: PdfWrittenObject = { objNum: newInfoNum, segment: infoSegment };
      written.push(infoObj);
      infoRefUsed = newInfoNum;
    }

    // 2) 显式标注页（best-effort）：字体对象 + 内容流 + 页面对象 + 重定义 Pages 根
    if (pagesInfo !== null) {
      // 在已写对象号之上分配连续新块
      let maxObj: number = Math.max(trailer.size, trailer.rootRef + 1);
      for (let i: number = 0; i < written.length; i += 1) {
        if (written[i].objNum >= maxObj) {
          maxObj = written[i].objNum + 1;
        }
      }
      const fontObjNum: number = maxObj;
      const cidObjNum: number = maxObj + 1;
      const descObjNum: number = maxObj + 2;
      const contentObjNum: number = maxObj + 3;
      const pageObjNum: number = maxObj + 4;

      const fontSegment: string = buildPdfExplicitFontObject(fontObjNum, cidObjNum);
      const cidSegment: string = buildPdfExplicitCidFontObject(cidObjNum, descObjNum);
      const descSegment: string = buildPdfExplicitFontDescriptor(descObjNum);
      const pageObjects = buildPdfExplicitPageObjects(
        pageObjNum, contentObjNum, pagesInfo.pagesObjNum, fontObjNum, pagesInfo.mediaBoxRaw, pagesInfo.mediaBox, markerHex
      );
      const pagesSegment: string = buildPdfRedefinedPagesObject(
        pagesInfo.pagesObjNum, pagesInfo.pagesDictBody, pageObjNum, pagesInfo.oldCount + 1
      );

      const obj1: PdfWrittenObject = { objNum: fontObjNum, segment: fontSegment };
      const obj2: PdfWrittenObject = { objNum: cidObjNum, segment: cidSegment };
      const obj3: PdfWrittenObject = { objNum: descObjNum, segment: descSegment };
      const obj4: PdfWrittenObject = { objNum: contentObjNum, segment: pageObjects.contentObj };
      const obj5: PdfWrittenObject = { objNum: pageObjNum, segment: pageObjects.pageObj };
      const obj6: PdfWrittenObject = { objNum: pagesInfo.pagesObjNum, segment: pagesSegment };
      written.push(obj1);
      written.push(obj2);
      written.push(obj3);
      written.push(obj4);
      written.push(obj5);
      written.push(obj6);
    }

    // 3) 拼接对象段，累计字节偏移（每个对象在最终文件中的位置 = 文件尾 + 已写段字节和）
    const encoder: util.TextEncoder = new util.TextEncoder();
    let objectSegment: string = '';
    let offset: number = stat.size;
    const nums: number[] = [];
    const offsets: number[] = [];
    for (let i: number = 0; i < written.length; i += 1) {
      const seg: string = written[i].segment;
      const segBytes: Uint8Array = encoder.encodeInto(seg);
      nums.push(written[i].objNum);
      offsets.push(offset);
      objectSegment += seg;
      offset += segBytes.length;
    }

    // 4) newSize = 最大对象号 + 1
    let newSize: number = trailer.size;
    for (let i: number = 0; i < nums.length; i += 1) {
      if (nums[i] + 1 > newSize) {
        newSize = nums[i] + 1;
      }
    }

    // 5) xref：每个对象一个子段（对象号可非连续，如重定义的 Pages 与原 Info）
    let xrefSegment: string = 'xref\n';
    for (let i: number = 0; i < nums.length; i += 1) {
      xrefSegment += `${nums[i].toString()} 1\n${offsets[i].toString().padStart(10, '0')} 00000 n \n`;
    }
    xrefSegment += 'trailer\n';
    xrefSegment += `<< /Size ${newSize.toString()} /Root ${trailer.rootRef.toString()} 0 R `;
    xrefSegment += `/Info ${infoRefUsed.toString()} 0 R /Prev ${trailer.oldStartxref.toString()} >>\n`;
    const xrefOffset: number = offset;
    xrefSegment += 'startxref\n';
    xrefSegment += `${xrefOffset.toString()}\n`;
    xrefSegment += '%%EOF\n';

    const fullSegment: string = objectSegment + xrefSegment;

    // 写目标：先复制原文件，再追加新段
    copyFileAppend(absPath, targetPath, fullSegment);
    return true;
  } catch (err) {
    hilog.warn(PDF_DOMAIN, PDF_TAG, 'injectPdfIncremental failed: %{public}s', `${err}`);
    return false;
  }
}

function readFileHead(absPath: string): string {
  const file = fileIo.openSync(absPath, fileIo.OpenMode.READ_ONLY);
  try {
    const buffer = new ArrayBuffer(4096);
    const bytesRead: number = fileIo.readSync(file.fd, buffer, { offset: 0, length: 4096 });
    return new util.TextDecoder('utf-8').decode(new Uint8Array(buffer, 0, bytesRead));
  } finally {
    fileIo.closeSync(file);
  }
}

/** 复制原文件到目标，然后追加增量段。 */
function copyFileAppend(sourcePath: string, targetPath: string, appendSegment: string): void {
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
    const encoder: util.TextEncoder = new util.TextEncoder();
    const encoded: Uint8Array = encoder.encodeInto(appendSegment);
    // encodeInto 返回 Uint8Array，其底层 buffer 可能含多余字节；取精确切片转 ArrayBuffer
    const exactBytes: Uint8Array = encoded.subarray(0, encoded.byteLength);
    fileIo.writeSync(target.fd, exactBytes.buffer as ArrayBuffer);
  } finally {
    if (source !== null) {
      fileIo.closeSync(source);
    }
    if (target !== null) {
      fileIo.closeSync(target);
    }
  }
}
