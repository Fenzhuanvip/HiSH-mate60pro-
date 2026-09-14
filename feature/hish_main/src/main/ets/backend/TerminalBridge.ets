import napi from 'libhish_main.so';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const MAX_LINES = 200; // 环形缓冲区最大行数

/**
 * 终端桥接器（单例）— 打通 AI 工作台与 QEMU 终端。
 *
 * 能力：
 * 1. captureOutput(data) — WebTerminal.onData 调此方法，把终端输出存入环形缓冲区
 * 2. getRecentOutput(lines?) — 获取最近 N 行终端纯文本输出，供 AI 作为上下文
 * 3. sendCommand(cmd) — 往 QEMU 终端注入一条命令并回车，等价于用户手动敲
 * 4. 事件通知 — 发命令时通过 AppStorage 写一个递增计数器，Index.ets 监听后自动切到终端 Tab
 */
class TerminalBridgeImpl {
  private static instance: TerminalBridgeImpl | null = null;

  /** 环形缓冲区：存最近的终端输出行 */
  private lineBuffer: string[] = [];
  /** 当前缓冲区行数 */
  private lineCount: number = 0;
  /** 未完成的行（没有以 \n 结尾的部分） */
  private partialLine: string = '';
  /** UTF-8 解码器 */
  private decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  /** 命令发送计数器，用于触发 AppStorage 事件 */
  private commandCounter: number = 0;

  static getInstance(): TerminalBridgeImpl {
    if (TerminalBridgeImpl.instance === null) {
      TerminalBridgeImpl.instance = new TerminalBridgeImpl();
    }
    return TerminalBridgeImpl.instance;
  }

  /**
   * 捕获终端输出 — 由 WebTerminal.onData() 调用。
   * 将原始字节解码为文本，按行存入环形缓冲区。
   */
  captureOutput(ab: ArrayBuffer): void {
    try {
      const text = this.decoder.decodeWithStream(new Uint8Array(ab), { stream: true });
      if (text.length === 0) {
        return;
      }

      // 去掉 ANSI 转义序列，保留纯文本
      const cleanText = this.stripAnsi(text);

      // 按行分割
      const lines = cleanText.split('\n');
      // 第一段接上上次未完成的行
      lines[0] = this.partialLine + lines[0];

      for (let i = 0; i < lines.length - 1; i++) {
        this.pushLine(lines[i]);
      }
      // 最后一段可能未完成（没有 \n 结尾）
      this.partialLine = lines[lines.length - 1];
    } catch (e) {
      hilog.error(DOMAIN, 'TerminalBridge', 'captureOutput failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 获取最近 N 行终端输出（纯文本，已去除 ANSI 转义）。
   * 用于 AI 发消息时附加上下文。
   */
  getRecentOutput(lines: number = 50): string {
    const actualLines = Math.min(lines, this.lineCount);
    if (actualLines === 0) {
      return '';
    }
    const startIdx = this.lineCount - actualLines;
    const result: string[] = [];
    for (let i = 0; i < actualLines; i++) {
      const idx = (startIdx + i) % MAX_LINES;
      result.push(this.lineBuffer[idx]);
    }
    return result.join('\n');
  }

  /**
   * 往 QEMU 终端注入一条命令并回车。
   * 命令会像用户手动敲入一样出现在终端里并执行。
   * 同时通过 AppStorage 触发事件，通知 Index.ets 切到终端 Tab。
   */
  sendCommand(command: string): void {
    try {
      const cmd = command.trim() + '\n';
      const encoder = util.TextEncoder.createInto('utf-8');
      const buffer = encoder.encodeInto(cmd);
      napi.sendInput(buffer.buffer);

      // 触发事件：递增计数器，Index.ets 用 @StorageProp 监听
      this.commandCounter += 1;
      AppStorage.setOrCreate('terminalCommandSent', this.commandCounter);

      hilog.info(DOMAIN, 'TerminalBridge', 'sendCommand: %{public}s', command.trim());
    } catch (e) {
      hilog.error(DOMAIN, 'TerminalBridge', 'sendCommand failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 清空缓冲区 */
  clearBuffer(): void {
    this.lineBuffer = [];
    this.lineCount = 0;
    this.partialLine = '';
  }

  // ====== 内部方法 ======

  private pushLine(line: string): void {
    const trimmed = line.replace(/\r/g, '').trimEnd();
    if (trimmed.length === 0 && this.lineCount > 0) {
      // 空行也存，但避免连续空行过多
      const lastIdx = (this.lineCount - 1) % MAX_LINES;
      if (this.lineBuffer[lastIdx].length === 0) {
        return;
      }
    }
    const idx = this.lineCount % MAX_LINES;
    this.lineBuffer[idx] = trimmed;
    this.lineCount += 1;
  }

  /**
   * 去除 ANSI 转义序列（颜色、光标移动等），保留纯文本内容。
   */
  private stripAnsi(text: string): string {
    // 匹配 ANSI 转义序列：ESC [ ... letter  和  ESC ] ... BEL/ST
    return text
      .replace(/\x1b\[[0-9;]*[A-Za-z]/g, '')   // CSI 序列
      .replace(/\x1b\][^\x07]*\x07/g, '')        // OSC 序列 (BEL 结尾)
      .replace(/\x1b\][^\x1b]*\x1b\\/g, '')      // OSC 序列 (ST 结尾)
      .replace(/\x1b[()][AB012]/g, '')           // 字符集切换
      .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, ''); // 其他控制字符 (保留 \t \n \r)
  }
}

export const TerminalBridge = TerminalBridgeImpl.getInstance();
