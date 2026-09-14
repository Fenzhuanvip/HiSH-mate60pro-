import fileIo from '@ohos.file.fs';

// ================================================================
// TaskPool 辅助文件操作：供 @Concurrent 任务函数通过 import 引用。
// @Concurrent 函数体只能使用 import 变量或局部变量；两个 @Concurrent
// 函数嵌套调用时，被调用方必须独立成文件并 export，通过 import 引入。
// ================================================================

@Concurrent
export function copyStandaloneFileChunk(sourcePath: string, targetPath: string): void {
  let source: fileIo.File | null = null;
  let target: fileIo.File | null = null;
  try {
    source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
  } catch (err) {
    throw new Error(`打开源文件失败: ${sourcePath}`);
  }
  try {
    target = fileIo.openSync(targetPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  } catch (err) {
    fileIo.closeSync(source);
    throw new Error(`打开目标文件失败: ${targetPath}`);
  }
  try {
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
    fileIo.closeSync(source);
    fileIo.closeSync(target);
  }
}

@Concurrent
export function deletePathTask(rootPath: string): string {
  let deletedCount: number = 0;
  const pending: string[] = [];
  pending.push(rootPath);
  while (pending.length > 0) {
    const current: string = pending.pop() as string;
    let stat: fileIo.Stat;
    try {
      stat = fileIo.statSync(current);
    } catch (err) {
      return JSON.stringify({ error: `删除路径失败: ${current}` });
    }
    if (stat.isDirectory()) {
      let entries: string[];
      try {
        entries = fileIo.listFileSync(current) as string[];
      } catch (err) {
        return JSON.stringify({ error: `删除路径失败: ${current}` });
      }
      for (let index: number = 0; index < entries.length; index += 1) {
        pending.push(`${current}/${entries[index]}`);
      }
      try {
        fileIo.rmdirSync(current);
      } catch (err) {
        return JSON.stringify({ error: `删除路径失败: ${current}` });
      }
    } else {
      try {
        fileIo.unlinkSync(current);
      } catch (err) {
        return JSON.stringify({ error: `删除路径失败: ${current}` });
      }
    }
    deletedCount += 1;
  }
  return JSON.stringify({ deletedCount });
}
