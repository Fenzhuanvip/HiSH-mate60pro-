import { configManagerFacade, ConfigActionError } from '../backend/CodexBackend';
import {
  InstalledSkill, DiscoverableSkill, UnmanagedSkill,
  SkillRepo, SkillUpdateInfo, SkillsShSearchResult
} from './SkillTypes';
@Observed
export class SkillsState {
  installed: InstalledSkill[] = [];
  discoverable: DiscoverableSkill[] = [];
  unmanaged: UnmanagedSkill[] = [];
  updates: SkillUpdateInfo[] = [];
  repos: SkillRepo[] = [];
  installedLoading: boolean = false;
  discoverableLoading: boolean = false;
  updatesLoading: boolean = false;
  statusText: string = '';
  errorText: string = '';
}

export class SkillsViewModel {
  state: SkillsState = new SkillsState();

  private lastInstalledFetch: number = 0;
  private lastDiscoverableFetch: number = 0;
  private readonly STALE_TIME_MS: number = 5 * 60 * 1000;

  async loadInstalled(forceRefresh: boolean = false): Promise<void> {
    if (!forceRefresh && Date.now() - this.lastInstalledFetch < this.STALE_TIME_MS) {
      return;
    }

    this.state.installedLoading = true;
    try {
      const result = await configManagerFacade.listInstalledSkills();
      if (!result.ok || result.data === null) {
        this.state.installed = [];
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.state.installed = result.data;
      this.state.errorText = '';
      this.lastInstalledFetch = Date.now();
    } finally {
      this.state.installedLoading = false;
    }
  }

  async discoverFromRepo(owner: string, name: string, branch: string): Promise<DiscoverableSkill[]> {
    const result = await configManagerFacade.discoverFromSingleRepo(owner, name, branch);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return [];
    }
    this.state.errorText = '';
    return result.data;
  }

  async installFromGithub(skill: DiscoverableSkill): Promise<void> {
    try {
      const result = await configManagerFacade.installSkill(skill);
      if (!result.ok || result.data === null) {
        this.state.errorText = this.describeActionError(result.error);
        throw new Error(this.state.errorText);
      }
      this.state.installed = [...this.state.installed, result.data];
      this.state.errorText = '';
    } catch (err) {
      // 兜底：任何非 ConfigActionResult 异常都不能以原始值逃逸，
      // 统一写入 error 状态并重新抛出 Error（调用方依赖 .catch() 处理）
      if (this.state.errorText.length === 0) {
        this.state.errorText = err instanceof Error ? err.message : String(err);
      }
      throw new Error(this.state.errorText);
    }
  }

  async uninstall(id: string): Promise<void> {
    const result = await configManagerFacade.removeInstalledSkill(id);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return;
    }
    this.state.installed = this.state.installed.filter(s => s.id !== id);
    this.state.errorText = '';
    this.state.statusText = 'Skill 已卸载';
  }

  async toggleEnabled(id: string, enabled: boolean): Promise<void> {
    const result = await configManagerFacade.setSkillEnabled(id, enabled);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return;
    }

    const skill = result.data;
    this.state.installed = this.state.installed.map(s =>
      s.id === id ? skill : s
    );
    this.state.errorText = '';
    this.state.statusText = `${skill.name} 已${enabled ? '启用' : '禁用'}`;
  }

  async loadDiscoverable(forceRefresh: boolean = false): Promise<void> {
    if (!forceRefresh && Date.now() - this.lastDiscoverableFetch < this.STALE_TIME_MS) {
      return;
    }

    this.state.discoverableLoading = true;
    try {
      const result = await configManagerFacade.discoverableSkills();
      if (!result.ok || result.data === null) {
        this.state.discoverable = [];
        this.state.errorText = this.describeActionError(result.error);
        this.lastDiscoverableFetch = 0;
        return;
      }
      this.state.discoverable = result.data;
      this.state.errorText = '';
      this.lastDiscoverableFetch = Date.now();
    } finally {
      this.state.discoverableLoading = false;
    }
  }

  async scanUnmanaged(): Promise<void> {
    const result = await configManagerFacade.scanUnmanagedSkills();
    if (!result.ok || result.data === null) {
      this.state.unmanaged = [];
      this.state.errorText = this.describeActionError(result.error);
      return;
    }
    this.state.unmanaged = result.data;
    this.state.errorText = '';
  }

  async importFromLocal(directories: string[]): Promise<void> {
    const result = await configManagerFacade.importLocalSkills(directories);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return;
    }
    await this.loadInstalled(true);
    this.state.errorText = '';
  }

  async checkUpdates(): Promise<void> {
    this.state.updatesLoading = true;
    try {
      const result = await configManagerFacade.checkSkillUpdates();
      if (!result.ok || result.data === null) {
        this.state.updates = [];
        this.state.errorText = this.describeActionError(result.error);
        return;
      }
      this.state.updates = result.data;
      this.state.errorText = '';
    } finally {
      this.state.updatesLoading = false;
    }
  }

  async updateSkill(id: string): Promise<void> {
    const result = await configManagerFacade.updateSkill(id);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return;
    }
    this.state.installed = this.state.installed.map(s =>
      s.id === id ? result.data as InstalledSkill : s
    );
    this.state.updates = this.state.updates.filter(u => u.id !== id);
    this.state.errorText = '';
  }

  async loadRepos(): Promise<void> {
    const result = await configManagerFacade.listSkillRepos();
    if (!result.ok || result.data === null) {
      this.state.repos = [];
      this.state.errorText = this.describeActionError(result.error);
      return;
    }
    this.state.repos = result.data;
    this.state.errorText = '';
  }

  async addRepo(repo: SkillRepo): Promise<void> {
    const result = await configManagerFacade.addSkillRepo(repo);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return;
    }
    await this.loadRepos();
    this.state.errorText = '';
    this.state.statusText = `已添加仓库 ${repo.owner}/${repo.name}`;
  }

  async toggleRepoEnabled(owner: string, name: string, enabled: boolean): Promise<void> {
    const result = await configManagerFacade.setSkillRepoEnabled(owner, name, enabled);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return;
    }
    this.state.repos = this.state.repos.map((repo: SkillRepo) =>
      repo.owner === owner && repo.name === name ? result.data as SkillRepo : repo
    );
    this.state.errorText = '';
    this.state.statusText = `${owner}/${name} 已切换到 ${enabled ? '启用' : '停用'} 状态`;
  }

  async removeRepo(owner: string, name: string): Promise<void> {
    const result = await configManagerFacade.removeSkillRepo(owner, name);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return;
    }
    await this.loadRepos();
    this.state.errorText = '';
    this.state.statusText = `已移除仓库 ${owner}/${name}`;
  }

  async searchSkillsSh(
    query: string, limit: number = 20, offset: number = 0
  ): Promise<SkillsShSearchResult> {
    const result = await configManagerFacade.searchSkillsSh(query, limit, offset);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return new SkillsShSearchResult([], 0, query);
    }
    this.state.errorText = '';
    return result.data;
  }

  async importFromZip(zipPath: string): Promise<void> {
    const result = await configManagerFacade.importFromZipFile(zipPath);
    if (!result.ok || result.data === null) {
      this.state.errorText = this.describeActionError(result.error);
      return;
    }
    this.state.installed = [...this.state.installed, ...result.data];
    this.state.errorText = '';
  }

  private describeActionError(error: ConfigActionError | null): string {
    if (error === null) {
      return '操作失败';
    }
    return error.message;
  }
}

export const skillsVM: SkillsViewModel = new SkillsViewModel();
