import fileIo from '@ohos.file.fs';
import taskpool from '@ohos.taskpool';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ProjectRecord } from './ConsoleModels';

const STORE_DOMAIN = 0x0ff3;
const STORE_TAG = 'ProjectStore';
const STORE_FILE_NAME = 'projects.json';

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
      hilog.error(0x0ff3, 'ProjectStore', 'ensureParentDirectory failed: %{public}s', `${err}`);
    }
  }
  try {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, content);
    fileIo.closeSync(file);
  } catch (err) {
    hilog.error(0x0ff3, 'ProjectStore', 'save failed: %{public}s', `${err}`);
  }
}

interface ProjectStoreSnapshot {
  projects: ProjectRecord[];
  deletedPaths: string[];
}

function safeParseSnapshot(rawText: string): ProjectStoreSnapshot {
  try {
    const parsed: Object = JSON.parse(rawText) as Object;
    const record: Record<string, Object> = parsed as Record<string, Object>;
    const projects: ProjectRecord[] = [];
    const itemsRaw: Object | undefined = record['projects'];
    if (Array.isArray(itemsRaw)) {
      itemsRaw.forEach((itemRaw: Object) => {
        const itemRecord: Record<string, Object> = itemRaw as Record<string, Object>;
        const id: string = typeof itemRecord['id'] === 'string' ? (itemRecord['id'] as string) : '';
        const name: string = typeof itemRecord['name'] === 'string' ? (itemRecord['name'] as string) : '';
        const path: string = typeof itemRecord['path'] === 'string' ? (itemRecord['path'] as string) : '';
        const expanded: boolean = typeof itemRecord['expanded'] === 'boolean' ? (itemRecord['expanded'] as boolean) : true;
        const sourceUri: string = typeof itemRecord['sourceUri'] === 'string' ? (itemRecord['sourceUri'] as string) : '';
        if (id.length > 0 && name.length > 0) {
          projects.push(new ProjectRecord(id, name, path, expanded, sourceUri));
        }
      });
    }
    const deletedPaths: string[] = [];
    const deletedRaw: Object | undefined = record['deletedPaths'];
    if (Array.isArray(deletedRaw)) {
      deletedRaw.forEach((item: Object) => {
        if (typeof item === 'string') {
          deletedPaths.push(item as string);
        }
      });
    }
    return { projects, deletedPaths };
  } catch (_err) {
    return { projects: [], deletedPaths: [] };
  }
}

export class ProjectStore {
  private cachedDeletedPaths: string[] = [];
  private pendingSaveTimerId: number = -1;

  load(): ProjectRecord[] {
    const snapshot = this.loadSnapshot();
    this.cachedDeletedPaths = snapshot.deletedPaths;
    return snapshot.projects;
  }

  private loadSnapshot(): ProjectStoreSnapshot {
    const path: string = storeFilePath();
    try {
      fileIo.statSync(path);
    } catch (_err) {
      return { projects: [], deletedPaths: [] };
    }
    try {
      const rawText: string = fileIo.readTextSync(path);
      return safeParseSnapshot(rawText);
    } catch (err) {
      hilog.error(STORE_DOMAIN, STORE_TAG, 'load failed: %{public}s', `${err}`);
      return { projects: [], deletedPaths: [] };
    }
  }

  save(projects: ProjectRecord[]): void {
    const path: string = storeFilePath();
    const payload: string = JSON.stringify({ projects, deletedPaths: this.cachedDeletedPaths }, null, 2);
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

  addDeletedPath(path: string): void {
    if (path.trim().length > 0 && this.cachedDeletedPaths.indexOf(path.trim()) < 0) {
      this.cachedDeletedPaths.push(path.trim());
    }
  }

  isDeletedPath(path: string): boolean {
    return this.cachedDeletedPaths.indexOf(path.trim()) >= 0;
  }

  getDeletedPaths(): string[] {
    return this.cachedDeletedPaths;
  }
}

export const projectStore = new ProjectStore();
