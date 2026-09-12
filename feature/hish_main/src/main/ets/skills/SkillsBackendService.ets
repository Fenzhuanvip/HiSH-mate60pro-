import {
  getSkillsRegistry, saveSkillsRegistry, getSkillsRepos, saveSkillsRepos,
  computeDirHash, installSkillFromDir, uninstallSkill,
  setSkillEnabledNative, reconcileSkills
} from '../backend/CodexNative';
import {
  InstalledSkill, DiscoverableSkill, UnmanagedSkill, SkillRepo,
  SkillUpdateInfo, SkillsShSearchResult, SkillsShItem,
  DEFAULT_SKILL_REPOS, SkillSource, SkillEntryJson, SkillsRegistryJson,
  SkillRepoEntryJson, SkillsRepoListJson, ReconcileResult
} from './SkillTypes';
import http from '@ohos.net.http';
import fileIo from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import taskpool from '@ohos.taskpool';

const GITHUB_API_BASE = 'https://github.com';
const SKILLS_SH_API = 'https://skills.sh/api/search';
const DOWNLOAD_TIMEOUT_MS = 60000;
const DOWNLOAD_MAX_BYTES = 20 * 1024 * 1024;
const DEFAULT_RECURSION_MAX_DEPTH = 8;

interface DownloadAndExtractResult {
  tempDir: string;
  usedBranch: string;
}

interface DiscoverViaApiResult {
  usedBranch: string;
  skills: DiscoverableSkill[];
}

interface TreeEntry {
  path: string;
  type: string;
  sha: string;
}

interface TreeResponse {
  tree: TreeEntry[];
  truncated: boolean;
}

interface SkillMetadata {
  name: string;
  description: string;
}

interface ImportSourceEntry {
  sourcePath: string;
  installName: string;
  fallbackName: string;
}

interface ScannedSkillJson {
  directory: string;
  name: string;
  description: string;
}

interface SkillsShApiItemJson {
  id: string;
  name: string;
  skillId: string;
  source: string;
  installs: number;
}

interface SkillsShApiResponse {
  skills: SkillsShApiItemJson[];
  count: number;
  query: string;
}

interface InstallSkillResultJson extends SkillEntryJson {
  error?: string;
}

export enum SkillErrorCode {
  INVALID_SKILL_DIRECTORY = 'INVALID_SKILL_DIRECTORY',
  SKILL_DIR_NOT_FOUND = 'SKILL_DIR_NOT_FOUND',
  SKILL_DIRECTORY_CONFLICT = 'SKILL_DIRECTORY_CONFLICT',
  SKILL_NOT_FOUND = 'SKILL_NOT_FOUND',
  UPDATE_NOT_SUPPORTED = 'UPDATE_NOT_SUPPORTED',
  DOWNLOAD_FAILED = 'DOWNLOAD_FAILED',
  EMPTY_ARCHIVE = 'EMPTY_ARCHIVE',
}

export class SkillError extends Error {
  code: SkillErrorCode;
  context: string;
  suggestion: string;

  constructor(code: SkillErrorCode, context: string, suggestion: string) {
    super(`[${code}] ${context}`);
    this.name = 'SkillError';
    this.code = code;
    this.context = context;
    this.suggestion = suggestion;
  }
}

export const SKILL_ERROR_MESSAGES: Map<SkillErrorCode, string> = new Map([
  [SkillErrorCode.INVALID_SKILL_DIRECTORY, 'Skill 目录路径不合法，请检查路径是否包含非法字符'],
  [SkillErrorCode.SKILL_DIR_NOT_FOUND, '在仓库中未找到指定的 Skill 目录，请确认仓库 URL 是否正确'],
  [SkillErrorCode.SKILL_DIRECTORY_CONFLICT, '已存在同名 Skill（来自不同仓库），请先卸载现有 Skill 再重试'],
  [SkillErrorCode.SKILL_NOT_FOUND, '未找到指定的 Skill，可能已被卸载'],
  [SkillErrorCode.UPDATE_NOT_SUPPORTED, '仅支持更新来自 GitHub 的 Skill'],
  [SkillErrorCode.DOWNLOAD_FAILED, '下载仓库失败，请检查仓库地址和网络连接'],
  [SkillErrorCode.EMPTY_ARCHIVE, '下载的 ZIP 文件为空，请确认仓库是否存在'],
]);

// ================================================================
// TaskPool 卸载：重同步 SSOT 扫描 / 目录复制 / 目录删除
// （@Concurrent 函数必须是顶层、不可捕获外部变量、参数与返回值必须可序列化）
// ================================================================

@Concurrent
function scanSsotDirectoryTask(ssotDir: string): string {
  const results: ScannedSkillJson[] = [];
  let entries: string[];
  try {
    entries = fileIo.listFileSync(ssotDir) as string[];
  } catch (_) {
    return '[]';
  }

  for (let i = 0; i < entries.length; i++) {
    const entry: string = entries[i];
    if (entry.startsWith('.')) {
      continue;
    }
    const skillDir: string = `${ssotDir}/${entry}`;
    try {
      const stat = fileIo.statSync(skillDir);
      if (!stat.isDirectory()) {
        continue;
      }
    } catch (_) {
      continue;
    }

    const skillMdPath: string = `${skillDir}/SKILL.md`;
    try {
      fileIo.statSync(skillMdPath);
    } catch (_) {
      continue;
    }

    let name: string = entry;
    let description: string = '';
    try {
      const content: string = fileIo.readTextSync(skillMdPath) as string;
      let clean: string = content;
      if (content.charCodeAt(0) === 0xFEFF) {
        clean = content.substring(1);
      }
      const parts: string[] = clean.split('---');
      if (parts.length >= 3) {
        const frontMatter: string = parts[1].trim();
        const fmLines: string[] = frontMatter.split('\n');
        for (let j = 0; j < fmLines.length; j++) {
          const colonIdx: number = fmLines[j].indexOf(':');
          if (colonIdx === -1) {
            continue;
          }
          const key: string = fmLines[j].substring(0, colonIdx).trim();
          let value: string = fmLines[j].substring(colonIdx + 1).trim();
          if (value.length >= 2 && (value.startsWith("'") || value.startsWith('"'))) {
            const quote: string = value.charAt(0);
            if (value.endsWith(quote)) {
              value = value.substring(1, value.length - 1);
            }
          }
          if (key === 'name' && value.length > 0) {
            name = value;
          }
          if (key === 'description') {
            description = value;
          }
        }
      }
    } catch (_) {
      // 保持 fallback name
    }

    const item: ScannedSkillJson = {
      directory: entry,
      name: name,
      description: description
    };
    results.push(item);
  }

  return JSON.stringify(results);
}

async function scanSsotDirectoryAsync(codexHome: string): Promise<InstalledSkill[]> {
  const results: InstalledSkill[] = [];
  try {
    const ssotDir: string = `${codexHome}/skills`;
    const task = new taskpool.Task(scanSsotDirectoryTask, ssotDir);
    const json: string = await taskpool.execute(task) as string;
    const parsed: ScannedSkillJson[] = JSON.parse(json) as ScannedSkillJson[];
    for (let i = 0; i < parsed.length; i++) {
      const item: ScannedSkillJson = parsed[i];
      results.push(new InstalledSkill(
        `local:${item.directory}`, item.name, item.description, item.directory,
        'local', '', '', '', '', true, Date.now(), '', 0
      ));
    }
  } catch (_) {
    return [];
  }
  return results;
}

@Concurrent
function copyDirRecursiveTask(src: string, dest: string, maxDepth: number): string {
  const stackSrc: string[] = [];
  const stackDest: string[] = [];
  const stackDepth: number[] = [];
  stackSrc.push(src);
  stackDest.push(dest);
  stackDepth.push(0);
  try {
    while (stackSrc.length > 0) {
      const currentSrc: string = stackSrc.pop() as string;
      const currentDest: string = stackDest.pop() as string;
      const depth: number = stackDepth.pop() as number;
      fileIo.mkdirSync(currentDest, true);
      let files: string[];
      try {
        files = fileIo.listFileSync(currentSrc) as string[];
      } catch (_) {
        continue;
      }
      for (let i = 0; i < files.length; i++) {
        const file: string = files[i];
        const srcPath: string = `${currentSrc}/${file}`;
        const destPath: string = `${currentDest}/${file}`;
        try {
          const stat = fileIo.statSync(srcPath);
          if (stat.isDirectory()) {
            if (depth + 1 < maxDepth) {
              stackSrc.push(srcPath);
              stackDest.push(destPath);
              stackDepth.push(depth + 1);
            } else {
              console.warn(`copyDirRecursive depth limit reached, skip: ${srcPath}`);
            }
          } else {
            fileIo.copyFileSync(srcPath, destPath);
          }
        } catch (e) {
          console.warn(`copy failed: ${srcPath} -> ${destPath}: ${JSON.stringify(e)}`);
        }
      }
    }
    return '';
  } catch (e) {
    return 'copy failed: ' + JSON.stringify(e);
  }
}

async function copyDirRecursiveAsync(src: string, dest: string, maxDepth: number): Promise<void> {
  const task = new taskpool.Task(copyDirRecursiveTask, src, dest, maxDepth);
  const result: string = await taskpool.execute(task) as string;
  if (result.length > 0) {
    throw new Error(result);
  }
}

@Concurrent
function removeDirRecursiveTask(rootPath: string, maxDepth: number): string {
  const paths: string[] = [];
  const depths: number[] = [];
  const removeSelf: boolean[] = [];
  paths.push(rootPath);
  depths.push(0);
  removeSelf.push(false);
  try {
    while (paths.length > 0) {
      const p: string = paths.pop() as string;
      const d: number = depths.pop() as number;
      const self: boolean = removeSelf.pop() as boolean;
      if (self) {
        try {
          fileIo.rmdirSync(p);
        } catch (_) {
          try {
            fileIo.unlinkSync(p);
          } catch (_2) {
            // best effort
          }
        }
        continue;
      }
      try {
        const stat = fileIo.statSync(p);
        if (stat.isDirectory()) {
          if (d + 1 < maxDepth) {
            const entries: string[] = fileIo.listFileSync(p) as string[];
            for (let i = 0; i < entries.length; i++) {
              paths.push(`${p}/${entries[i]}`);
              depths.push(d + 1);
              removeSelf.push(false);
            }
          }
          paths.push(p);
          depths.push(d);
          removeSelf.push(true);
        } else {
          fileIo.unlinkSync(p);
        }
      } catch (e) {
        try {
          fileIo.rmdirSync(p);
        } catch (_) {
          try {
            fileIo.unlinkSync(p);
          } catch (_2) {
            // best effort
          }
        }
      }
    }
    return '';
  } catch (e) {
    return 'remove failed: ' + JSON.stringify(e);
  }
}

async function removeDirRecursiveAsync(path: string, maxDepth: number): Promise<void> {
  const task = new taskpool.Task(removeDirRecursiveTask, path, maxDepth);
  const result: string = await taskpool.execute(task) as string;
  if (result.length > 0) {
    throw new Error(result);
  }
}

/**
 * Skills 后端管理服务
 *
 * 职责：
 * - GitHub 仓库 Skill 发现
 * - Skill 安装（下载 → 解压 → 复制到 SSOT → 注册）
 * - Skill 卸载（删除 → 移除注册）
 * - 更新检测（SHA-256 对比）
 * - skills.sh 公共目录搜索
 * - 未管理 Skill 扫描
 */
export class SkillsBackendService {
  private codexHome: string;

  constructor(codexHome: string) {
    this.codexHome = codexHome;
  }

  getSsotDir(): string {
    return `${this.codexHome}/skills`;
  }

  // ================================================================
  // 路径安全校验
  // ================================================================

  private sanitizeSourcePath(raw: string): string | null {
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      return null;
    }

    const parts = trimmed.split('/').filter((p: string): boolean => p.length > 0);
    if (parts.length === 0) {
      return null;
    }

    for (const part of parts) {
      if (part === '.' || part === '..' || part.trim().length === 0) {
        return null;
      }
    }
    return parts.join('/');
  }

  private sanitizeInstallName(raw: string): string | null {
    const trimmed = raw.trim();
    if (trimmed.length === 0 || trimmed.startsWith('.')) {
      return null;
    }
    if (trimmed === '.' || trimmed === '..') {
      return null;
    }
    if (trimmed.includes('/') || trimmed.includes('\\')) {
      return null;
    }
    if (!/^[a-zA-Z0-9\-_]+$/.test(trimmed)) {
      return null;
    }
    return trimmed;
  }

  private normalizeInstallName(raw: string): string | null {
    const normalized = raw.trim()
      .replace(/[^a-zA-Z0-9\-_]+/g, '-')
      .replace(/-+/g, '-')
      .replace(/^[.-]+/, '')
      .replace(/[.-]+$/g, '');
    return this.sanitizeInstallName(normalized);
  }

  private isRootSkillDirectory(directory: string): boolean {
    return directory.trim().length === 0;
  }

  private displaySkillDirectory(directory: string): string {
    return this.isRootSkillDirectory(directory) ? '(仓库根目录)' : directory;
  }

  private buildSkillReadmeUrl(owner: string, repoName: string, branch: string, directory: string): string {
    const relativePath = this.isRootSkillDirectory(directory) ? 'SKILL.md' : `${directory}/SKILL.md`;
    return `https://github.com/${owner}/${repoName}/blob/${branch}/${relativePath}`;
  }

  private getPathBaseName(path: string): string {
    const parts = path.split(/[\\/]/).filter((part: string): boolean => part.length > 0);
    return parts.length > 0 ? parts[parts.length - 1] : '';
  }

  private getZipBaseName(zipPath: string): string {
    const fileName = this.getPathBaseName(zipPath);
    return fileName.replace(/\.zip$/i, '');
  }

  // ================================================================
  // 已安装 Skill 管理
  // ================================================================

  async getInstalled(): Promise<InstalledSkill[]> {
    const json = getSkillsRegistry(this.codexHome);
    let skills: SkillEntryJson[] = [];
    try {
      const parsed: SkillsRegistryJson = JSON.parse(json) as SkillsRegistryJson;
      skills = parsed.skills ?? [];
    } catch (_) {
      skills = [];
    }

    // 兜底：注册表为空时，尝试 reconcile（扫描 SSOT 目录自动注册）
    if (skills.length === 0) {
      try {
        const reconcileJson = reconcileSkills(this.codexHome);
        const reconcileResult = JSON.parse(reconcileJson) as ReconcileResult;
        if (reconcileResult.registered.length > 0) {
          const refreshedJson = getSkillsRegistry(this.codexHome);
          const refreshed: SkillsRegistryJson = JSON.parse(refreshedJson) as SkillsRegistryJson;
          skills = refreshed.skills ?? [];
        }
      } catch (_) {
        // reconcile 失败，继续用空列表
      }
    }

    // 兜底：如果 reconcile 也没结果（native 不可用），直接扫 SSOT 目录（TaskPool 卸载）
    if (skills.length === 0) {
      const scanned = await scanSsotDirectoryAsync(this.codexHome);
      return scanned;
    }

    return skills.map((skill: SkillEntryJson) => InstalledSkill.fromJSON(skill));
  }

  async saveInstalled(skills: InstalledSkill[]): Promise<void> {
    const registry: SkillsRegistryJson = {
      version: 1,
      skills: skills as SkillEntryJson[],
      updatedAt: String(Math.floor(Date.now() / 1000))
    };
    const ok = saveSkillsRegistry(this.codexHome, JSON.stringify(registry));
    if (!ok) {
      throw new Error('Failed to save skills registry');
    }
  }

  /**
   * 切换 Skill 启用/禁用状态（通过 Rust host）
   */
  async setSkillEnabled(id: string, enabled: boolean): Promise<InstalledSkill> {
    const json = setSkillEnabledNative(this.codexHome, id, enabled);
    const parsed = JSON.parse(json) as SkillEntryJson;
    if (parsed.id === undefined || parsed.id.length === 0) {
      throw new SkillError(
        SkillErrorCode.SKILL_NOT_FOUND,
        `id=${id}`,
        '未找到指定的 Skill，可能已被卸载'
      );
    }
    return InstalledSkill.fromJSON(parsed);
  }

  /**
   * 确保 SSOT 目录存在
   */
  ensureSsotDir(): string {
    const ssotDir = this.getSsotDir();
    try {
      fileIo.mkdirSync(ssotDir, true);
    } catch (_) {
      // 目录已存在
    }
    return ssotDir;
  }

  /**
   * 一致性检查与自动修复（通过 Rust host）
   *
   * 检测并修复 registry 与 SSOT 目录之间的不一致：
   * 1. registry 有条目但 SSOT 目录缺失 → 从 registry 移除
   * 2. SSOT 有目录但 registry 无条目 → 注册为 local skill
   */
  async reconcileSkills(): Promise<ReconcileResult> {
    this.ensureSsotDir();
    const json = reconcileSkills(this.codexHome);
    let parsed: ReconcileResult | null = null;
    try {
      parsed = JSON.parse(json) as ReconcileResult;
    } catch (_) {
      parsed = null;
    }
    if (parsed === null) {
      return new ReconcileResult([], []);
    }
    return new ReconcileResult(parsed.removed ?? [], parsed.registered ?? []);
  }

  /**
   * 安装 Skill（完整流程，通过 Rust host 完成 SSOT 复制 + 注册）
   */
  async installFromGithub(skill: DiscoverableSkill): Promise<InstalledSkill> {
    // Step 1: 校验
    const sourceRel = this.isRootSkillDirectory(skill.directory)
      ? ''
      : this.sanitizeSourcePath(skill.directory);
    if (sourceRel === null) {
      throw new SkillError(
        SkillErrorCode.INVALID_SKILL_DIRECTORY,
        `directory=${skill.directory}`,
        '目录路径不合法，请检查是否包含非法字符'
      );
    }

    const installNameRaw = this.isRootSkillDirectory(sourceRel)
      ? skill.repoName
      : sourceRel.split('/')[sourceRel.split('/').length - 1];
    const installName = this.sanitizeInstallName(installNameRaw);
    if (!installName) {
      throw new SkillError(
        SkillErrorCode.INVALID_SKILL_DIRECTORY,
        `directory=${skill.directory}`,
        '安装目录名不合法'
      );
    }

    // Step 2: 冲突检测
    const installed = await this.getInstalled();
    for (const existing of installed) {
      if (existing.directory.toLowerCase() === installName.toLowerCase()) {
        const sameRepo = existing.repoOwner === skill.repoOwner
          && existing.repoName === skill.repoName;
        if (sameRepo) {
          if (!existing.enabled) {
            existing.enabled = true;
            await this.saveInstalled(installed);
          }
          return existing;
        } else {
          throw new SkillError(
            SkillErrorCode.SKILL_DIRECTORY_CONFLICT,
            `name=${installName}, existingRepo=${existing.repoOwner}/${existing.repoName}`,
            `已存在来自 ${existing.repoOwner}/${existing.repoName} 的同名 Skill，请先卸载后再安装`
          );
        }
      }
    }

    // Step 3-4: 下载、解压
    const repo = new SkillRepo(
      skill.repoOwner,
      skill.repoName,
      skill.repoBranch,
      true
    );

    const downloadResult = await this.downloadAndExtractRepo(repo);
    const tempDir = downloadResult.tempDir;
    const usedBranch = downloadResult.usedBranch;

    const sourceDir = this.resolveSourceDir(tempDir, sourceRel);
    if (!sourceDir) {
      await this.removeDir(tempDir);
      throw new SkillError(
        SkillErrorCode.SKILL_DIR_NOT_FOUND,
        `directory=${skill.directory}, repo=${skill.repoOwner}/${skill.repoName}`,
        `在 ${skill.repoOwner}/${skill.repoName} 中未找到目录 ${this.displaySkillDirectory(skill.directory)}`
      );
    }

    // Step 5: 通过 Rust host 复制到 SSOT + 解析 SKILL.md + 计算哈希 + 注册
    const readmeUrl = this.buildSkillReadmeUrl(skill.repoOwner, skill.repoName, usedBranch, sourceRel);
    const skillJson = JSON.stringify({
      id: skill.key,
      source: 'github',
      repoOwner: skill.repoOwner,
      repoName: skill.repoName,
      repoBranch: usedBranch,
      directory: installName,
      readmeUrl: readmeUrl,
      enabled: true,
      installedAt: Date.now()
    });

    const resultJson = installSkillFromDir(this.codexHome, sourceDir, skillJson);
    await this.removeDir(tempDir);

    const trimmedResult = resultJson.trim();
    if (trimmedResult.length === 0 || trimmedResult === '{}') {
      throw new Error('installSkillFromDir 返回空结果');
    }

    const parsed = JSON.parse(trimmedResult) as InstallSkillResultJson;
    if (typeof parsed.error === 'string' && parsed.error.length > 0) {
      throw new Error(`installSkillFromDir failed: ${parsed.error}`);
    }
    if (parsed.id === undefined || parsed.id.length === 0) {
      throw new Error(`installSkillFromDir 返回无效结果: ${trimmedResult}`);
    }

    return InstalledSkill.fromJSON(parsed);
  }

  /**
   * 卸载 Skill（通过 Rust host）
   */
  async uninstall(id: string): Promise<string | null> {
    const result = uninstallSkill(this.codexHome, id);
    if (result.length === 0) {
      throw new SkillError(
        SkillErrorCode.SKILL_NOT_FOUND,
        `id=${id}`,
        '未找到指定的 Skill，可能已被卸载'
      );
    }
    if (result.startsWith('error:')) {
      throw new Error(result);
    }
    return result;
  }

  /**
   * 更新单个 Skill
   */
  async update(id: string): Promise<InstalledSkill> {
    const installed = await this.getInstalled();
    const index = installed.findIndex((s: InstalledSkill): boolean => s.id === id);
    if (index === -1) {
      throw new SkillError(SkillErrorCode.SKILL_NOT_FOUND, `id=${id}`, '');
    }

    const skill = installed[index];
    if (skill.source !== 'github' || !skill.repoOwner || !skill.repoName) {
      throw new SkillError(
        SkillErrorCode.UPDATE_NOT_SUPPORTED,
        `id=${id}, source=${skill.source}`,
        '仅支持更新来自 GitHub 的 Skill'
      );
    }

    const repo = new SkillRepo(
      skill.repoOwner,
      skill.repoName,
      skill.repoBranch || 'main',
      true
    );

    const downloadResult = await this.downloadAndExtractRepo(repo);
    const tempDir = downloadResult.tempDir;
    const usedBranch = downloadResult.usedBranch;

    const sourceDir = this.resolveSourceDir(tempDir, skill.directory);
    if (!sourceDir) {
      await this.removeDir(tempDir);
      throw new SkillError(SkillErrorCode.SKILL_DIR_NOT_FOUND, `directory=${skill.directory}`, '');
    }

    // 替换文件
    const dest = `${this.getSsotDir()}/${skill.directory}`;
    await this.removeDir(dest);
    await copyDirRecursiveAsync(sourceDir, dest, DEFAULT_RECURSION_MAX_DEPTH);
    await this.removeDir(tempDir);

    const contentHash = computeDirHash(dest);
    const metadata = this.parseSkillMetadata(`${dest}/SKILL.md`, skill.directory);
    const name = metadata.name;
    const description = metadata.description;

    const updated = new InstalledSkill(
      skill.id, name, description, skill.directory,
      skill.source, skill.repoOwner, skill.repoName, usedBranch,
      skill.readmeUrl, skill.enabled, skill.installedAt, contentHash, Date.now()
    );

    installed[index] = updated;
    await this.saveInstalled(installed);

    return updated;
  }

  // ================================================================
  // 发现与扫描
  // ================================================================

  async discoverFromRepo(owner: string, name: string, branch: string): Promise<DiscoverableSkill[]> {
    const repo = new SkillRepo(owner, name, branch, true);
    return await this.fetchRepoSkills(repo);
  }

  async discoverFromRepos(): Promise<DiscoverableSkill[]> {
    const reposJson = getSkillsRepos(this.codexHome);
    let repos: SkillRepo[] = [];
    try {
      const reposList: SkillsRepoListJson = JSON.parse(reposJson) as SkillsRepoListJson;
      repos = (reposList.repos ?? [])
        .map((repo: SkillRepoEntryJson) => SkillRepo.fromJSON(repo))
        .filter((repo: SkillRepo) => repo.enabled);
    } catch (_) {
      repos = [];
    }

    const results = await Promise.allSettled(
      repos.map((repo: SkillRepo): Promise<DiscoverableSkill[]> => this.fetchRepoSkills(repo))
    );

    const allSkills: DiscoverableSkill[] = [];
    for (const result of results) {
      if (result.status === 'fulfilled') {
        allSkills.push(...result.value);
      }
    }

    // 去重
    const seen = new Set<string>();
    const unique = allSkills.filter((skill: DiscoverableSkill): boolean => {
      const lower = skill.key.toLowerCase();
      if (seen.has(lower)) {
        return false;
      }
      seen.add(lower);
      return true;
    });

    unique.sort((a: DiscoverableSkill, b: DiscoverableSkill): number => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
    return unique;
  }

  private async fetchRepoSkills(repo: SkillRepo): Promise<DiscoverableSkill[]> {
    const apiResult = await this.discoverRepoSkillsViaApi(repo);
    if (apiResult !== null) {
      return apiResult.skills;
    }

    const downloadResult = await this.downloadAndExtractRepo(repo);
    const tempDir = downloadResult.tempDir;
    const usedBranch = downloadResult.usedBranch;
    const skills = await this.scanDirRecursive(tempDir, tempDir, repo, usedBranch);
    await this.removeDir(tempDir);
    return skills;
  }

  private async discoverRepoSkillsViaApi(repo: SkillRepo): Promise<DiscoverViaApiResult | null> {
    const branches = [repo.branch];
    if (repo.branch !== 'main') {
      branches.push('main');
    }
    if (repo.branch !== 'master') {
      branches.push('master');
    }

    for (const branch of branches) {
      const tree = await this.fetchRepoTree(repo, branch);
      if (tree === null || tree.truncated) {
        continue;
      }

      const manifestPaths: string[] = tree.tree
        .filter((entry: TreeEntry): boolean => entry.type === 'blob' && (entry.path.endsWith('/SKILL.md') || entry.path === 'SKILL.md'))
        .map((entry: TreeEntry): string => entry.path);

      if (manifestPaths.length === 0) {
        return { usedBranch: branch, skills: [] };
      }

      const skills: DiscoverableSkill[] = [];
      for (const manifestPath of manifestPaths) {
        const directory = manifestPath === 'SKILL.md'
          ? ''
          : manifestPath.substring(0, manifestPath.length - '/SKILL.md'.length);
        const fallbackName = this.isRootSkillDirectory(directory) ? repo.name : directory;
        const metadata = await this.fetchSkillMetadataFromGitHub(repo, branch, manifestPath, fallbackName);
        const keyDirectory = this.isRootSkillDirectory(directory) ? '.' : directory;
        skills.push(new DiscoverableSkill(
          `${repo.owner}/${repo.name}:${keyDirectory}`,
          metadata.name,
          metadata.description,
          directory,
          this.buildSkillReadmeUrl(repo.owner, repo.name, branch, directory),
          repo.owner,
          repo.name,
          branch
        ));
      }

      return { usedBranch: branch, skills: skills };
    }

    return null;
  }

  private async fetchRepoTree(repo: SkillRepo, branch: string): Promise<TreeResponse | null> {
    const treeUrl = `https://api.github.com/repos/${repo.owner}/${repo.name}/git/trees/${branch}?recursive=1`;
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(treeUrl, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/vnd.github.v3+json' },
        connectTimeout: DOWNLOAD_TIMEOUT_MS,
        readTimeout: DOWNLOAD_TIMEOUT_MS
      });
      if (response.responseCode !== 200) {
        return null;
      }
      return JSON.parse(response.result as string) as TreeResponse;
    } catch (_) {
      return null;
    } finally {
      httpRequest.destroy();
    }
  }

  private async fetchSkillMetadataFromGitHub(
    repo: SkillRepo,
    branch: string,
    manifestPath: string,
    fallbackName: string
  ): Promise<SkillMetadata> {
    const rawUrl = `https://raw.githubusercontent.com/${repo.owner}/${repo.name}/${branch}/${manifestPath}`;
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(rawUrl, {
        method: http.RequestMethod.GET,
        connectTimeout: DOWNLOAD_TIMEOUT_MS,
        readTimeout: DOWNLOAD_TIMEOUT_MS
      });
      if (response.responseCode !== 200) {
        return { name: fallbackName, description: '' };
      }
      return this.parseSkillMetadataText(response.result as string, fallbackName);
    } catch (_) {
      return { name: fallbackName, description: '' };
    } finally {
      httpRequest.destroy();
    }
  }

  private async scanDirRecursive(
    currentDir: string, baseDir: string,
    repo: SkillRepo, usedBranch: string,
    maxDepth: number = DEFAULT_RECURSION_MAX_DEPTH,
    depth: number = 0
  ): Promise<DiscoverableSkill[]> {
    const results: DiscoverableSkill[] = [];
    if (depth >= maxDepth) {
      console.warn(`scanDirRecursive depth limit reached, stop at: ${currentDir}`);
      return results;
    }

    const skillMdPath = `${currentDir}/SKILL.md`;
    try {
      fileIo.statSync(skillMdPath);

      const directory = currentDir === baseDir
        ? ''
        : currentDir.substring(baseDir.length + 1);
      const fallbackName = this.isRootSkillDirectory(directory) ? repo.name : directory;

      const metadata = this.parseSkillMetadata(skillMdPath, fallbackName);
      const name = metadata.name;
      const description = metadata.description;
      const keyDirectory = this.isRootSkillDirectory(directory) ? '.' : directory;

      results.push(new DiscoverableSkill(
        `${repo.owner}/${repo.name}:${keyDirectory}`,
        name, description, directory,
        this.buildSkillReadmeUrl(repo.owner, repo.name, usedBranch, directory),
        repo.owner, repo.name, usedBranch
      ));

      return results;
    } catch (_) { /* 当前目录无 SKILL.md，继续子目录 */ }

    try {
      const entries: string[] = fileIo.listFileSync(currentDir) as string[];
      for (const entry of entries) {
        if (entry.startsWith('.')) {
          continue;
        }
        const fullPath = `${currentDir}/${entry}`;
        try {
          const stat = fileIo.statSync(fullPath);
          if (stat.isDirectory()) {
            const childResults = await this.scanDirRecursive(fullPath, baseDir, repo, usedBranch, maxDepth, depth + 1);
            results.push(...childResults);
          }
        } catch (_) { /* skip */ }
      }
    } catch (_) { /* skip */ }

    return results;
  }

  /**
   * 扫描未管理的 Skills
   */
  async scanUnmanaged(): Promise<UnmanagedSkill[]> {
    const installed = await this.getInstalled();
    const managedDirs = new Set<string>(installed.map((s: InstalledSkill): string => s.directory.toLowerCase()));

    const ssotDir = this.getSsotDir();
    const unmanaged: UnmanagedSkill[] = [];

    let entries: string[];
    try {
      entries = fileIo.listFileSync(ssotDir) as string[];
    } catch (_) {
      return unmanaged;
    }

    for (const entry of entries) {
      if (entry.startsWith('.') || managedDirs.has(entry.toLowerCase())) {
        continue;
      }

      const skillMdPath = `${ssotDir}/${entry}/SKILL.md`;
      try {
        fileIo.statSync(skillMdPath);
      } catch (_) {
        continue;
      }

      const metadata = this.parseSkillMetadata(skillMdPath, entry);
      const name = metadata.name;
      const description = metadata.description;
      unmanaged.push(new UnmanagedSkill(
        entry, name, description, [ssotDir], `${ssotDir}/${entry}`
      ));
    }

    return unmanaged;
  }

  async importFromLocal(directories: string[], source: SkillSource = 'local'): Promise<InstalledSkill[]> {
    const sources: ImportSourceEntry[] = [];

    for (const sourcePath of directories) {
      const dirName = this.getPathBaseName(sourcePath);
      const installName = this.sanitizeInstallName(dirName);
      if (!installName) {
        continue;
      }
      sources.push({ sourcePath, installName, fallbackName: installName });
    }

    return this.importResolvedSources(sources, source);
  }

  /**
   * 从 ZIP 文件导入 Skill
   */
  async importFromZip(zipPath: string): Promise<InstalledSkill[]> {
    const tempDir = `${this.codexHome}/.tmp_zip_import_${Date.now()}`;
    fileIo.mkdirSync(tempDir, true);

    try {
      await this.extractZip(zipPath, tempDir);
      this.flattenGitHubZipRoot(tempDir);

      // 找到包含 SKILL.md 的目录
      const skillDirs: string[] = [];
      this.findSkillDirs(tempDir, skillDirs);

      if (skillDirs.length === 0) {
        throw new SkillError(
          SkillErrorCode.SKILL_DIR_NOT_FOUND,
          `zipPath=${zipPath}`,
          'ZIP 中未找到包含 SKILL.md 的 Skill 目录'
        );
      }

      const sources = this.resolveZipImportSources(zipPath, tempDir, skillDirs);
      if (sources.length === 0) {
        throw new SkillError(
          SkillErrorCode.INVALID_SKILL_DIRECTORY,
          `zipPath=${zipPath}`,
          'ZIP 已解压，但未找到可安装的 Skill 目录名，请检查 ZIP 文件名或目录名是否仅包含字母、数字、-、_'
        );
      }

      const result = await this.importResolvedSources(sources, 'zip');
      if (result.length === 0) {
        throw new SkillError(
          SkillErrorCode.SKILL_DIRECTORY_CONFLICT,
          `zipPath=${zipPath}`,
          'ZIP 中的 Skill 没有导入任何新内容；如果同名 Skill 已存在，请先卸载或清理后再重试'
        );
      }
      return result;
    } finally {
      try { await this.removeDir(tempDir); } catch (_) { /* */ }
    }
  }

  private findSkillDirs(baseDir: string, result: string[], maxDepth: number = DEFAULT_RECURSION_MAX_DEPTH, depth: number = 0): void {
    if (depth >= maxDepth) {
      return;
    }
    try {
      const entries: string[] = fileIo.listFileSync(baseDir) as string[];
      // 先检查当前目录是否有 SKILL.md
      for (const entry of entries) {
        if (entry === 'SKILL.md') {
          result.push(baseDir);
          return;
        }
      }
      // 递归子目录
      for (const entry of entries) {
        const fullPath = `${baseDir}/${entry}`;
        try {
          const stat = fileIo.statSync(fullPath);
          if (stat.isDirectory()) {
            this.findSkillDirs(fullPath, result, maxDepth, depth + 1);
          }
        } catch (_) { /* */ }
      }
    } catch (_) { /* */ }
  }

  private resolveZipImportSources(zipPath: string, tempDir: string, skillDirs: string[]): ImportSourceEntry[] {
    const results: ImportSourceEntry[] = [];
    const seen = new Set<string>();
    const zipBaseName = this.getZipBaseName(zipPath);

    for (const sourcePath of skillDirs) {
      let installName: string | null = null;

      if (sourcePath === tempDir) {
        const metadata = this.parseSkillMetadata(`${sourcePath}/SKILL.md`, zipBaseName);
        installName = this.normalizeInstallName(metadata.name) || this.normalizeInstallName(zipBaseName);
      } else {
        const dirName = this.getPathBaseName(sourcePath);
        installName = this.sanitizeInstallName(dirName) || this.normalizeInstallName(dirName);
      }

      if (!installName) {
        continue;
      }

      const key = installName.toLowerCase();
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      results.push({ sourcePath, installName, fallbackName: installName });
    }

    return results;
  }

  private async importResolvedSources(sources: ImportSourceEntry[], source: SkillSource): Promise<InstalledSkill[]> {
    const installed = await this.getInstalled();
    const imported: InstalledSkill[] = [];
    const ssotDir = this.getSsotDir();

    for (const sourceEntry of sources) {
      const installName = sourceEntry.installName;
      if (installed.some((s: InstalledSkill): boolean => s.directory.toLowerCase() === installName.toLowerCase())) {
        continue;
      }

      const dest = `${ssotDir}/${installName}`;
      if (this.pathExists(dest)) {
        throw new SkillError(
          SkillErrorCode.SKILL_DIRECTORY_CONFLICT,
          `directory=${installName}`,
          `Skill 目录 ${installName} 已存在，请先卸载现有 Skill 或清理残留目录后再重试`
        );
      }
      await copyDirRecursiveAsync(sourceEntry.sourcePath, dest, DEFAULT_RECURSION_MAX_DEPTH);

      const metadata = this.parseSkillMetadata(`${dest}/SKILL.md`, sourceEntry.fallbackName);
      const name = metadata.name;
      const description = metadata.description;
      const contentHash = computeDirHash(dest);

      const entry = new InstalledSkill(
        `${source}:${installName}`, name, description, installName,
        source, '', '', '', '', true, Date.now(), contentHash, 0
      );

      installed.push(entry);
      imported.push(entry);
    }

    if (imported.length > 0) {
      await this.saveInstalled(installed);
    }

    return imported;
  }

  // ================================================================
  // 更新检测
  // ================================================================

  async checkUpdates(): Promise<SkillUpdateInfo[]> {
    const installed = (await this.getInstalled())
      .filter((s: InstalledSkill): boolean => s.source === 'github' && s.repoOwner.length > 0 && s.repoName.length > 0);

    const updates: SkillUpdateInfo[] = [];

    const groups = new Map<string, InstalledSkill[]>();
    for (const skill of installed) {
      const branch = skill.repoBranch || 'main';
      const key = `${skill.repoOwner}/${skill.repoName}/${branch}`;
      if (!groups.has(key)) {
        groups.set(key, []);
      }
      groups.get(key)!.push(skill);
    }

    const groupEntries = Array.from(groups.entries());
    for (const groupEntry of groupEntries) {
      const key = groupEntry[0];
      const groupSkills = groupEntry[1];
      const parts = key.split('/');
      const owner = parts[0];
      const name = parts[1];
      const branch = parts[2];
      const repo = new SkillRepo(owner, name, branch, true);

      let tempDir: string;
      try {
        const result = await this.downloadAndExtractRepo(repo);
        tempDir = result.tempDir;
      } catch (e) {
        console.warn(`下载 ${owner}/${name} 失败: ${JSON.stringify(e)}`);
        continue;
      }

      for (const skill of groupSkills) {
        const remoteDir = this.resolveSourceDir(tempDir, skill.directory);
        if (!remoteDir) {
          continue;
        }

        const remoteHash = computeDirHash(remoteDir);

        if (skill.contentHash !== remoteHash) {
          updates.push(new SkillUpdateInfo(
            skill.id, skill.name, skill.contentHash, remoteHash
          ));
        }
      }

      await this.removeDir(tempDir);
    }

    return updates;
  }

  // ================================================================
  // skills.sh 搜索
  // ================================================================

  async searchSkillsSh(query: string, limit: number, offset: number): Promise<SkillsShSearchResult> {
    const url = `${SKILLS_SH_API}?q=${encodeURIComponent(query)}&limit=${limit}&offset=${offset}`;

    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000
      });

      if (response.responseCode !== 200) {
        throw new Error(`skills.sh API returned ${response.responseCode}`);
      }

      const data: SkillsShApiResponse = JSON.parse(response.result as string) as SkillsShApiResponse;
      const rawSkills: SkillsShApiItemJson[] = data.skills ?? [];
      const skills = rawSkills
        .filter((skillItem: SkillsShApiItemJson): boolean => {
          const parts = skillItem.source.split('/');
          return parts.length === 2;
        })
        .map((skillItem: SkillsShApiItemJson): SkillsShItem => {
          const srcParts = skillItem.source.split('/');
          const owner = srcParts[0];
          const repo = srcParts[1];
          return new SkillsShItem(
            skillItem.id, skillItem.name, skillItem.skillId,
            owner, repo, 'main', skillItem.installs,
            `https://github.com/${owner}/${repo}`
          );
        });

      return new SkillsShSearchResult(skills, data.count, data.query);
    } finally {
      httpRequest.destroy();
    }
  }

  // ================================================================
  // 仓库管理
  // ================================================================

  async getRepos(): Promise<SkillRepo[]> {
    const json = getSkillsRepos(this.codexHome);
    let parsed: SkillsRepoListJson | null = null;
    try {
      parsed = JSON.parse(json) as SkillsRepoListJson;
    } catch (_) {
      parsed = null;
    }
    if (parsed === null) {
      return [];
    }
    return (parsed.repos ?? []).map((repo: SkillRepoEntryJson) => SkillRepo.fromJSON(repo));
  }

  async saveRepos(repos: SkillRepo[]): Promise<void> {
    const repoList: SkillsRepoListJson = {
      version: 1,
      repos: repos as SkillRepoEntryJson[]
    };
    const ok = saveSkillsRepos(this.codexHome, JSON.stringify(repoList));
    if (!ok) {
      throw new Error('Failed to save repos');
    }
  }

  async addRepo(repo: SkillRepo): Promise<void> {
    const repos = await this.getRepos();
    if (!repos.some((r: SkillRepo): boolean => r.owner === repo.owner && r.name === repo.name)) {
      repos.push(repo);
      await this.saveRepos(repos);
    }
  }

  async removeRepo(owner: string, name: string): Promise<void> {
    const repos = await this.getRepos();
    const filtered = repos.filter((r: SkillRepo): boolean => !(r.owner === owner && r.name === name));
    await this.saveRepos(filtered);
  }

  // ================================================================
  // 下载与解压
  // ================================================================

  private async downloadAndExtractRepo(
    repo: SkillRepo
  ): Promise<DownloadAndExtractResult> {
    const branches = [repo.branch];
    if (repo.branch !== 'main') {
      branches.push('main');
    }
    if (repo.branch !== 'master') {
      branches.push('master');
    }

    let lastError: Error | null = null;

    for (const branch of branches) {
      const tempDir = `${this.codexHome}/.tmp_skill_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      fileIo.mkdirSync(tempDir, true);

      // 策略 1：GitHub API 逐文件下载（无需 ZIP 解压）
      try {
        const apiOk = await this.downloadRepoViaApi(repo, tempDir, branch);
        if (apiOk) {
          return { tempDir: tempDir, usedBranch: branch };
        }
      } catch (e) {
        console.warn(`API download failed for ${branch}: ${JSON.stringify(e)}`);
      }

      // 策略 2：ZIP 下载 + 解压
      try {
        await this.removeDir(tempDir);
      } catch (_) { /* */ }

      const url = `${GITHUB_API_BASE}/${repo.owner}/${repo.name}/archive/refs/heads/${branch}.zip`;
      const httpRequest = http.createHttp();
      try {
        const response = await httpRequest.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          maxLimit: DOWNLOAD_MAX_BYTES,
          connectTimeout: DOWNLOAD_TIMEOUT_MS,
          readTimeout: DOWNLOAD_TIMEOUT_MS
        });

        if (response.responseCode !== 200) {
          throw new Error(`HTTP ${response.responseCode}`);
        }

        fileIo.mkdirSync(tempDir, true);
        const zipPath = `${tempDir}.zip`;
        const zipData: ArrayBuffer = response.result as ArrayBuffer;
        const file = fileIo.openSync(
          zipPath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY
        );
        fileIo.writeSync(file.fd, zipData);
        fileIo.closeSync(file);

        await this.extractZip(zipPath, tempDir);

        try {
          fileIo.unlinkSync(zipPath);
        } catch (_) { /* */ }

        this.flattenGitHubZipRoot(tempDir);

        return { tempDir: tempDir, usedBranch: branch };
      } catch (e) {
        lastError = e instanceof Error ? e : new Error(JSON.stringify(e));
        try { await this.removeDir(tempDir); } catch (_) { /* */ }
        continue;
      } finally {
        httpRequest.destroy();
      }
    }

    throw lastError || new Error(`All branches failed for ${repo.owner}/${repo.name}`);
  }

  /**
   * GitHub ZIP 解压后内容在 {repo}-{branch}/ 子目录下，
   * 将子目录内容移到 tempDir 根以简化路径解析。
   */
  private flattenGitHubZipRoot(tempDir: string): void {
    try {
      const entries: string[] = fileIo.listFileSync(tempDir) as string[];
      const dirs: string[] = entries.filter((entry: string): boolean => {
        try {
          const stat = fileIo.statSync(`${tempDir}/${entry}`);
          return stat.isDirectory();
        } catch (_) {
          return false;
        }
      });

      if (dirs.length === 1) {
        const innerDir = `${tempDir}/${dirs[0]}`;
        const innerEntries: string[] = fileIo.listFileSync(innerDir) as string[];
        for (const entry of innerEntries) {
          const src = `${innerDir}/${entry}`;
          const dst = `${tempDir}/${entry}`;
          fileIo.renameSync(src, dst);
        }
        fileIo.rmdirSync(innerDir);
      }
    } catch (_) { /* best-effort flatten */ }
  }

  /**
   * 通过 GitHub API 逐文件下载仓库内容（不依赖 ZIP 解压）
   */
  private async downloadRepoViaApi(repo: SkillRepo, destDir: string, branch: string): Promise<boolean> {
    const treeUrl = `https://api.github.com/repos/${repo.owner}/${repo.name}/git/trees/${branch}?recursive=1`;
    const httpRequest = http.createHttp();
    try {
      const treeResponse = await httpRequest.request(treeUrl, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/vnd.github.v3+json' },
        connectTimeout: DOWNLOAD_TIMEOUT_MS,
        readTimeout: DOWNLOAD_TIMEOUT_MS
      });

      if (treeResponse.responseCode !== 200) {
        return false;
      }

      interface TreeEntry {
        path: string;
        type: string;
        sha: string;
      }
      interface TreeResponse {
        tree: TreeEntry[];
        truncated: boolean;
      }

      const treeData: TreeResponse = JSON.parse(treeResponse.result as string) as TreeResponse;
      if (treeData.truncated) {
        return false;
      }

      const files: TreeEntry[] = [];
      for (let i = 0; i < treeData.tree.length; i++) {
        if (treeData.tree[i].type === 'blob') {
          files.push(treeData.tree[i]);
        }
      }

      let downloadedCount = 0;
      for (let i = 0; i < files.length; i++) {
        const entry = files[i];
        const rawUrl = `https://raw.githubusercontent.com/${repo.owner}/${repo.name}/${branch}/${entry.path}`;
        const fileResponse = await httpRequest.request(rawUrl, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          maxLimit: DOWNLOAD_MAX_BYTES,
          connectTimeout: DOWNLOAD_TIMEOUT_MS,
          readTimeout: DOWNLOAD_TIMEOUT_MS
        });

        if (fileResponse.responseCode !== 200) {
          continue;
        }

        const filePath = `${destDir}/${entry.path}`;
        const parentDir = filePath.substring(0, filePath.lastIndexOf('/'));
        fileIo.mkdirSync(parentDir, true);

        const file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
        const content: ArrayBuffer = fileResponse.result as ArrayBuffer;
        fileIo.writeSync(file.fd, content);
        fileIo.closeSync(file);
        downloadedCount += 1;
      }

      if (downloadedCount === 0) {
        return false;
      }

      return this.hasAnySkillManifest(destDir);
    } catch (e) {
      console.warn(`GitHub API download failed: ${JSON.stringify(e)}`);
      return false;
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 使用系统 ZIP 解压能力将整个压缩包解到目标目录。
   */
  private async extractZip(zipPath: string, destDir: string): Promise<void> {
    try {
      await zlib.decompressFile(zipPath, destDir);
    } catch (e) {
      const message = e instanceof Error ? e.message : JSON.stringify(e);
      throw new Error(`解压 ZIP 失败: ${message}`);
    }
  }

  // ================================================================
  // 文件操作
  // ================================================================

  private pathExists(path: string): boolean {
    try {
      fileIo.statSync(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  private isSkillDir(path: string): boolean {
    try {
      const stat = fileIo.statSync(path);
      if (!stat.isDirectory()) {
        return false;
      }
      fileIo.statSync(`${path}/SKILL.md`);
      return true;
    } catch (_) {
      return false;
    }
  }

  private hasAnySkillManifest(root: string): boolean {
    const skillDirs: string[] = [];
    this.findSkillDirs(root, skillDirs);
    return skillDirs.length > 0;
  }

  private async removeDir(path: string): Promise<void> {
    try {
      await removeDirRecursiveAsync(path, DEFAULT_RECURSION_MAX_DEPTH);
    } catch (_) { /* ignore */ }
  }

  // ================================================================
  // SKILL.md 解析
  // ================================================================

  private parseSkillMetadata(
    skillMdPath: string,
    fallbackName: string
  ): SkillMetadata {
    try {
      const content: string = fileIo.readTextSync(skillMdPath) as string;
      return this.parseSkillMetadataText(content, fallbackName);
    } catch (_) {
      const fallbackMetadata: SkillMetadata = {
        name: fallbackName,
        description: ''
      };
      return fallbackMetadata;
    }
  }

  private parseSkillMetadataText(content: string, fallbackName: string): SkillMetadata {
    const clean: string = content.replace(/^﻿/, '');

    const parts: string[] = clean.split('---');
    if (parts.length < 3) {
      return {
        name: fallbackName,
        description: ''
      };
    }

    const frontMatter: string = parts[1].trim();
    const lines: string[] = frontMatter.split('\n');
    let name: string | null = null;
    let description: string | null = null;

    for (const line of lines) {
      const colonIdx: number = line.indexOf(':');
      if (colonIdx === -1) {
        continue;
      }

      const key: string = line.substring(0, colonIdx).trim();
      const value: string = line.substring(colonIdx + 1).trim().replace(/^['"]|['"]$/g, '');

      if (key === 'name') {
        name = value;
      }
      if (key === 'description') {
        description = value;
      }
    }

    return {
      name: name || fallbackName,
      description: description || ''
    };
  }

  // ================================================================
  // 路径解析
  // ================================================================

  /**
   * 在解压后的仓库目录中定位 Skill 源目录
   *
   * 三级回退策略：
   * 1. 直接匹配相对路径
   * 2. 按名称递归查找（深度 ≤ 3）
   * 3. 根目录有 SKILL.md 则使用根目录
   */
  private resolveSourceDir(root: string, rawDirectory: string): string | null {
    if (this.isRootSkillDirectory(rawDirectory)) {
      return this.isSkillDir(root) ? root : null;
    }

    // 1. 直接匹配
    const direct = `${root}/${rawDirectory}`;
    if (this.isSkillDir(direct)) {
      return direct;
    }

    const parts = rawDirectory.split('/');
    const targetName = parts[parts.length - 1];

    // 2. 常见 skills 目录布局
    const underSkills = `${root}/skills/${rawDirectory}`;
    if (this.isSkillDir(underSkills)) {
      return underSkills;
    }

    const underSkillsBase = `${root}/skills/${targetName}`;
    if (this.isSkillDir(underSkillsBase)) {
      return underSkillsBase;
    }

    // 3. 递归查找同名目录
    const found = this.findDirByName(root, targetName, 0);
    if (found) {
      return found;
    }

    // 4. 根目录有 SKILL.md
    if (this.isSkillDir(root)) {
      return root;
    }

    return null;
  }

  private findDirByName(dir: string, target: string, depth: number): string | null {
    if (depth > 3) {
      return null;
    }

    let entries: string[];
    try {
      entries = fileIo.listFileSync(dir) as string[];
    } catch (_) {
      return null;
    }

    for (const entry of entries) {
      if (entry.startsWith('.')) {
        continue;
      }
      const fullPath = `${dir}/${entry}`;

      try {
        const stat = fileIo.statSync(fullPath);
        if (!stat.isDirectory()) {
          continue;
        }

        if (entry.toLowerCase() === target.toLowerCase()) {
          try {
            fileIo.statSync(`${fullPath}/SKILL.md`);
            return fullPath;
          } catch (_) { /* 同名目录无 SKILL.md */ }
        }

        const found = this.findDirByName(fullPath, target, depth + 1);
        if (found) {
          return found;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
