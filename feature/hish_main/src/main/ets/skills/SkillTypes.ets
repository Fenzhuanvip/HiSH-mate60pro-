/**
 * Skill 来源类型
 */
export type SkillSource = 'github' | 'local' | 'zip';

// ── JSON wire types (for JSON.parse deserialization) ──

export interface SkillEntryJson {
  id: string;
  name: string;
  description: string;
  directory: string;
  source: string;
  repoOwner: string;
  repoName: string;
  repoBranch: string;
  readmeUrl: string;
  enabled: boolean;
  installedAt: number;
  contentHash: string;
  updatedAt: number;
}

export interface SkillsRegistryJson {
  version: number;
  skills: SkillEntryJson[];
  updatedAt: string;
}

export interface SkillRepoEntryJson {
  owner: string;
  name: string;
  branch: string;
  enabled: boolean;
}

export interface SkillsRepoListJson {
  version: number;
  repos: SkillRepoEntryJson[];
}

// ── Domain classes ──

/**
 * 已安装 Skill 的注册记录（持久化到 skills-registry.json）
 */
@Observed
export class InstalledSkill {
  id: string; // "owner/repo:directory" 或 "local:directory"
  name: string; // 显示名称（来自 SKILL.md frontmatter）
  description: string; // 描述
  directory: string; // SSOT 中的目录名
  source: SkillSource;

  // GitHub 来源专用
  repoOwner: string;
  repoName: string;
  repoBranch: string;

  // 本地/导入
  readmeUrl: string;
  enabled: boolean;
  installedAt: number; // 毫秒时间戳
  contentHash: string; // SHA-256
  updatedAt: number; // 毫秒时间戳，0 表示从未更新

  constructor(
    id: string, name: string, description: string, directory: string,
    source: SkillSource, repoOwner: string, repoName: string,
    repoBranch: string, readmeUrl: string, enabled: boolean,
    installedAt: number, contentHash: string, updatedAt: number
  ) {
    this.id = id;
    this.name = name;
    this.description = description;
    this.directory = directory;
    this.source = source;
    this.repoOwner = repoOwner;
    this.repoName = repoName;
    this.repoBranch = repoBranch;
    this.readmeUrl = readmeUrl;
    this.enabled = enabled;
    this.installedAt = installedAt;
    this.contentHash = contentHash;
    this.updatedAt = updatedAt;
  }

  static fromJSON(json: SkillEntryJson): InstalledSkill {
    return new InstalledSkill(
      json.id ?? '',
      json.name ?? '',
      json.description ?? '',
      json.directory ?? '',
      (json.source as SkillSource) ?? 'local',
      json.repoOwner ?? '',
      json.repoName ?? '',
      json.repoBranch ?? '',
      json.readmeUrl ?? '',
      json.enabled ?? true,
      json.installedAt ?? Date.now(),
      json.contentHash ?? '',
      json.updatedAt ?? 0
    );
  }
}

/**
 * 可发现 Skill（来自 GitHub 仓库扫描的结果）
 */
export class DiscoverableSkill {
  key: string; // "owner/repo:directory"
  name: string;
  description: string;
  directory: string;
  readmeUrl: string;
  repoOwner: string;
  repoName: string;
  repoBranch: string;

  constructor(
    key: string, name: string, description: string, directory: string,
    readmeUrl: string, repoOwner: string, repoName: string, repoBranch: string
  ) {
    this.key = key;
    this.name = name;
    this.description = description;
    this.directory = directory;
    this.readmeUrl = readmeUrl;
    this.repoOwner = repoOwner;
    this.repoName = repoName;
    this.repoBranch = repoBranch;
  }
}

/**
 * 未管理 Skill（在 Agent skills 目录中发现但未注册）
 */
export class UnmanagedSkill {
  directory: string;
  name: string;
  description: string;
  foundIn: string[];
  path: string;

  constructor(
    directory: string, name: string, description: string,
    foundIn: string[], path: string
  ) {
    this.directory = directory;
    this.name = name;
    this.description = description;
    this.foundIn = foundIn;
    this.path = path;
  }
}

/**
 * GitHub Skill 仓库配置
 */
export class SkillRepo {
  owner: string;
  name: string;
  branch: string;
  enabled: boolean;

  constructor(owner: string, name: string, branch: string, enabled: boolean) {
    this.owner = owner;
    this.name = name;
    this.branch = branch;
    this.enabled = enabled;
  }

  static fromJSON(json: SkillRepoEntryJson): SkillRepo {
    return new SkillRepo(
      json.owner ?? '',
      json.name ?? '',
      json.branch ?? 'main',
      json.enabled ?? true
    );
  }
}

/**
 * Skill 更新信息
 */
export class SkillUpdateInfo {
  id: string;
  name: string;
  currentHash: string;
  remoteHash: string;

  constructor(id: string, name: string, currentHash: string, remoteHash: string) {
    this.id = id;
    this.name = name;
    this.currentHash = currentHash;
    this.remoteHash = remoteHash;
  }
}

/**
 * skills.sh 搜索结果
 */
export class SkillsShSearchResult {
  skills: SkillsShItem[];
  totalCount: number;
  query: string;

  constructor(skills: SkillsShItem[], totalCount: number, query: string) {
    this.skills = skills;
    this.totalCount = totalCount;
    this.query = query;
  }
}

export class SkillsShItem {
  key: string;
  name: string;
  directory: string;
  repoOwner: string;
  repoName: string;
  repoBranch: string;
  installs: number;
  readmeUrl: string;

  constructor(
    key: string, name: string, directory: string,
    repoOwner: string, repoName: string, repoBranch: string,
    installs: number, readmeUrl: string
  ) {
    this.key = key;
    this.name = name;
    this.directory = directory;
    this.repoOwner = repoOwner;
    this.repoName = repoName;
    this.repoBranch = repoBranch;
    this.installs = installs;
    this.readmeUrl = readmeUrl;
  }
}

/** 默认 GitHub 仓库列表 */
export const DEFAULT_SKILL_REPOS: SkillRepo[] = [
  new SkillRepo('anthropics', 'skills', 'main', true),
  new SkillRepo('ComposioHQ', 'awesome-claude-skills', 'master', true),
  new SkillRepo('cexll', 'myclaude', 'master', true),
  new SkillRepo('JimLiu', 'baoyu-skills', 'main', true),
];

/**
 * 一致性检查结果
 */
export class ReconcileResult {
  removed: string[];
  registered: string[];

  constructor(removed: string[], registered: string[]) {
    this.removed = removed;
    this.registered = registered;
  }
}
