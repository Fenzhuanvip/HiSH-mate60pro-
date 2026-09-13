import fileIo from '@ohos.file.fs';
import taskpool from '@ohos.taskpool';
import { hilog } from '@kit.PerformanceAnalysisKit';

const STORE_DOMAIN = 0x0ff2;
const STORE_TAG = 'WorkspaceBindingStore';
const STORE_FILE_NAME = 'workspace-bindings.json';

export class StoredWorkspaceItem {
  id: number = 0;
  title: string = '';
  description: string = '';
  workspaceId: string = '';
  workspaceRoot: string = '';
  workspaceUri: string = '';
  projectId: string = '';
}

export class StoredWorkspaceSnapshot {
  activeWorkspaceId: number = 1;
  items: StoredWorkspaceItem[] = [];
}

function defaultSnapshot(): StoredWorkspaceSnapshot {
  return new StoredWorkspaceSnapshot();
}

function storeFilePath(): string {
  const codexHome: string = (AppStorage.get('codexHome') as string) ?? '';
  if (codexHome.trim().length > 0) {
    return `${codexHome}/${STORE_FILE_NAME}`;
  }
  return STORE_FILE_NAME;
}

@Concurrent
function writeFileTask(path: string, content: string): void {
  const slashIndex: number = path.lastIndexOf('/');
  if (slashIndex > 0) {
    const parentPath: string = path.substring(0, slashIndex);
    try {
      fileIo.mkdirSync(parentPath, true);
    } catch (err) {
      hilog.error(0x0ff2, 'WorkspaceBindingStore', 'ensureParentDirectory failed: %{public}s', `${err}`);
    }
  }
  try {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, content);
    fileIo.closeSync(file);
  } catch (err) {
    hilog.error(0x0ff2, 'WorkspaceBindingStore', 'save failed: %{public}s', `${err}`);
  }
}

function safeParseSnapshot(rawText: string): StoredWorkspaceSnapshot {
  try {
    const parsed: Object = JSON.parse(rawText) as Object;
    const record: Record<string, Object> = parsed as Record<string, Object>;
    const snapshot: StoredWorkspaceSnapshot = new StoredWorkspaceSnapshot();
    const activeWorkspaceId: Object | undefined = record['activeWorkspaceId'];
    if (typeof activeWorkspaceId === 'number' && activeWorkspaceId > 0) {
      snapshot.activeWorkspaceId = activeWorkspaceId;
    }

    const itemsRaw: Object | undefined = record['items'];
    if (Array.isArray(itemsRaw)) {
      snapshot.items = itemsRaw.map((itemRaw: Object) => {
        const itemRecord: Record<string, Object> = itemRaw as Record<string, Object>;
        const item: StoredWorkspaceItem = new StoredWorkspaceItem();
        item.id = typeof itemRecord['id'] === 'number' ? (itemRecord['id'] as number) : 0;
        item.title = typeof itemRecord['title'] === 'string' ? (itemRecord['title'] as string) : '';
        item.description = typeof itemRecord['description'] === 'string' ? (itemRecord['description'] as string) : '';
        item.workspaceId = typeof itemRecord['workspaceId'] === 'string' ? (itemRecord['workspaceId'] as string) : '';
        item.workspaceRoot = typeof itemRecord['workspaceRoot'] === 'string' ? (itemRecord['workspaceRoot'] as string) : '';
        item.workspaceUri = typeof itemRecord['workspaceUri'] === 'string' ? (itemRecord['workspaceUri'] as string) : '';
        item.projectId = typeof itemRecord['projectId'] === 'string' ? (itemRecord['projectId'] as string) : '';
        return item;
      }).filter((item: StoredWorkspaceItem) => item.id > 0);
    }
    return snapshot;
  } catch (_err) {
    return defaultSnapshot();
  }
}

export class WorkspaceBindingStore {
  private pendingSaveTimerId: number = -1;

  load(): StoredWorkspaceSnapshot {
    const path: string = storeFilePath();
    try {
      fileIo.statSync(path);
    } catch (_err) {
      return defaultSnapshot();
    }
    try {
      const rawText: string = fileIo.readTextSync(path);
      return safeParseSnapshot(rawText);
    } catch (err) {
      hilog.error(STORE_DOMAIN, STORE_TAG, 'load failed: %{public}s', `${err}`);
      return defaultSnapshot();
    }
  }

  save(snapshot: StoredWorkspaceSnapshot): void {
    const path: string = storeFilePath();
    const payload: string = JSON.stringify(snapshot, null, 2);
    this.scheduleSave(path, payload);
  }

  private scheduleSave(path: string, payload: string): void {
    if (this.pendingSaveTimerId >= 0) {
      clearTimeout(this.pendingSaveTimerId);
    }
    this.pendingSaveTimerId = setTimeout(() => {
      this.pendingSaveTimerId = -1;
      const task: taskpool.Task = new taskpool.Task(writeFileTask, path, payload);
      void taskpool.execute(task).catch((err: Error) => {
        hilog.error(STORE_DOMAIN, STORE_TAG, 'save failed: %{public}s', `${err}`);
      });
    }, 300);
  }

  saveBindings(activeWorkspaceId: number, items: StoredWorkspaceItem[]): void {
    const snapshot: StoredWorkspaceSnapshot = new StoredWorkspaceSnapshot();
    snapshot.activeWorkspaceId = activeWorkspaceId;
    snapshot.items = items;
    this.save(snapshot);
  }
}

export const workspaceBindingStore = new WorkspaceBindingStore();
