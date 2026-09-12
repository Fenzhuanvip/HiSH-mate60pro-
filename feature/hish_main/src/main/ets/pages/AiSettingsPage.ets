import router from '@ohos.router';
import { SettingsTab, ProviderRecord, ProviderCategory, ApiWireFormat, McpServerRecord } from '../backend/ConsoleModels';
import { BUILTIN_PROVIDER_PRESETS, EndpointSpeedResult, ChatProbeResult, ApiValidationResult } from '../apim/ApiTypes';
import { apiManagementVM } from '../apim/ApiManagementViewModel';
import { codexBackend } from '../backend/CodexBackend';
import { InstalledSkill, SkillRepo, DiscoverableSkill, SkillsShItem, SkillsShSearchResult } from '../skills/SkillTypes';
import { skillsVM } from '../skills/SkillsViewModel';
import { PromptsViewModel } from '../prompts/PromptsViewModel';
import { PromptsBackendService } from '../prompts/PromptsBackendService';
import { PromptRecord } from '../prompts/PromptTypes';
import { ArkPilotBreakpoint } from '../adaptive/BreakpointTypes';
import { breakpointManager } from '../adaptive/BreakpointManager';
import { ArkPilotLayoutMode, getArkPilotLayoutProfile, getArkPilotLayoutMode } from '../adaptive/LayoutProfiles';
import { picker } from '@kit.CoreFileKit';
import uri from '@ohos.uri';
import fs from '@ohos.file.fs';
import util from '@ohos.util';

type ToastTone = 'info' | 'success' | 'warning' | 'error';
type ApiSubTab = 'providers' | 'presets';
type SkillsSubTab = 'installed' | 'install';

class SettingsNavItem {
  tab: SettingsTab;
  label: string;
  subtitle: string;
  accent: string;

  constructor(tab: SettingsTab, label: string, subtitle: string, accent: string) {
    this.tab = tab;
    this.label = label;
    this.subtitle = subtitle;
    this.accent = accent;
  }
}

class UiToastItem {
  id: number;
  tone: ToastTone;
  message: string;

  constructor(id: number, tone: ToastTone, message: string) {
    this.id = id;
    this.tone = tone;
    this.message = message;
  }
}

class ApiPresetMockItem {
  id: string;
  name: string;
  category: ProviderCategory;
  wireApi: string;
  baseUrl: string;
  description: string;
  websiteUrl: string;
  accent: string;

  constructor(
    id: string,
    name: string,
    category: ProviderCategory,
    wireApi: string,
    baseUrl: string,
    description: string,
    websiteUrl: string,
    accent: string
  ) {
    this.id = id;
    this.name = name;
    this.category = category;
    this.wireApi = wireApi;
    this.baseUrl = baseUrl;
    this.description = description;
    this.websiteUrl = websiteUrl;
    this.accent = accent;
  }
}

class ParsedGithubUrl {
  owner: string;
  name: string;
  branch: string;

  constructor(owner: string, name: string, branch: string) {
    this.owner = owner;
    this.name = name;
    this.branch = branch;
  }
}

@Entry
@Component
struct SettingsPage {
  private readonly navItems: SettingsNavItem[] = [
    new SettingsNavItem('api', 'API', '服务商与模型接入', '#8B5CF6'),
    new SettingsNavItem('skills', 'Skills', 'Skills 与仓库源', '#14B8A6'),
    new SettingsNavItem('prompts', 'Prompt', '预设指令与工作约束', '#F59E0B'),
    new SettingsNavItem('mcp', 'MCP', '桥接与工具通道', '#0A84FF')
  ];

  @StorageProp('arkPilotBreakpoint')
  @Watch('onBreakpointChange')
  currentBreakpoint: ArkPilotBreakpoint = 'sm';
  @State private animatedMode: ArkPilotLayoutMode = 'phone';
  @State private activeTab: SettingsTab = 'api';
  @State private pressedKey: string = '';
  @State private sparkSeed: number = 0;
  @State private toasts: UiToastItem[] = [];
  @State private toastIdSeed: number = 1;
  private toastTimerId: number = -1;

  @State private showValidationDialog: boolean = false;
  @State private validationResult: ApiValidationResult | null = null;

  @State private installedSkills: InstalledSkill[] = [];
  @State private skillRepos: SkillRepo[] = [];
  @State private skillsActiveSubTabIndex: number = 0;
  @State private newRepoOwner: string = 'anthropics';
  @State private newRepoName: string = 'skills';
  @State private newRepoBranch: string = 'main';
  @State private skillsStatusText: string = '';
  @State private pendingDeleteSkillId: string = '';
  @State private pendingDeleteSkillName: string = '';
  @State private showSkillDeleteDialog: boolean = false;
  @State private showSkillDetailDialog: boolean = false;
  @State private selectedSkillId: string = '';
  @State private selectedSkillDetail: InstalledSkill | null = null;
  @State private githubRepoUrl: string = '';
  @State private githubScanResults: DiscoverableSkill[] = [];
  @State private githubScanning: boolean = false;
  @State private installingSkillKeys: string[] = [];
  @State private skillBusy: boolean = false;
  @State private skillsShQuery: string = '';
  @State private skillsShResults: SkillsShItem[] = [];
  @State private skillsShSearching: boolean = false;

  @State private mcpServers: McpServerRecord[] = [];
  @State private selectedMcpServerId: string = '';
  @State private mcpTransportTypeDraft: string = 'stdio';
  @State private mcpCommandDraft: string = '';
  @State private mcpArgsDraft: string = '[]';
  @State private mcpUrlDraft: string = '';
  @State private mcpEnvDraft: string = '{}';
  @State private mcpHttpHeadersDraft: string = '{}';
  @State private mcpEnabledDraft: boolean = true;
  @State private mcpStatusText: string = '';
  @State private mcpNewServerName: string = '';
  @State private showMcpAddDialog: boolean = false;
  @State private showMcpDeleteDialog: boolean = false;
  @State private pendingDeleteMcpName: string = '';
  @State private mcpJsonPasteInput: string = '';
  @State private mcpLoading: boolean = false;
  @State private mcpBusy: boolean = false;

  @State private promptsViewModel: PromptsViewModel = new PromptsViewModel(new PromptsBackendService(''));
  @State private prompts: PromptRecord[] = [];
  @State private selectedPromptId: string = '';
  @State private pendingDeletePromptId: string = '';
  @State private pendingDeletePromptName: string = '';
  @State private showPromptDeleteDialog: boolean = false;
  @State private promptDraftName: string = '';
  @State private promptDraftSummary: string = '';
  @State private promptDraftContent: string = '';
  @State private promptLiveContent: string = '';
  @State private promptsStatusText: string = '';
  @State private promptBusy: boolean = false;

  @State private showConfigToml: boolean = false;
  @State private configTomlContent: string = '';
  @State private configTomlPath: string = '';

  @State private apiProviders: ProviderRecord[] = [];
  @State private apiProviderCount: number = 0;
  @State private apiPresets: ApiPresetMockItem[] = [];
  @State private apiActiveSubTab: ApiSubTab = 'providers';
  @State private selectedApiProviderId: string = '';
  @State private apiPresetCategory: string = 'all';
  @State private apiSpeedTesting: boolean = false;
  @State private apiSpeedResults: EndpointSpeedResult[] = [];
  @State private apiShowSpeedResults: boolean = false;

  aboutToAppear(): void {
    const mediaQuery = this.getUIContext().getMediaQuery();
    breakpointManager.initialize((condition: string) => mediaQuery.matchMediaSync(condition));
    this.animatedMode = getArkPilotLayoutMode(this.currentBreakpoint);
    this.loadMockData();
    const codexHome: string = (AppStorage.get('codexHome') as string) ?? '';
    if (codexHome.length > 0) {
      this.promptsViewModel = new PromptsViewModel(new PromptsBackendService(codexHome));
    }
    this.syncApiStateFromViewModel();
    this.syncPromptsStateFromViewModel();
    this.syncSkillsStateFromViewModel();
    this.syncMcpStateFromBackend();
    this.loadSettingsFacadeState();
  }

  private runMotion(action: () => void, duration: number = 220): void {
    this.getUIContext().animateTo({
      duration: duration,
      curve: Curve.FastOutSlowIn
    }, action);
  }

  private softFadeTransition(): TransitionEffect {
    return TransitionEffect.OPACITY
      .animation({ duration: 220, curve: Curve.Smooth });
  }

  private panelTransition(): TransitionEffect {
    return TransitionEffect.OPACITY
      .animation({ duration: 260, curve: Curve.Smooth })
      .combine(TransitionEffect.translate({ x: 12, y: 0 }).animation({ duration: 260, curve: Curve.Smooth }));
  }

  private dialogTransition(): TransitionEffect {
    return TransitionEffect.OPACITY
      .animation({ duration: 280, curve: Curve.Smooth });
  }

  private onBreakpointChange(): void {
    const newMode = getArkPilotLayoutMode(this.currentBreakpoint);
    if (newMode === this.animatedMode) {
      return;
    }
    this.runMotion(() => {
      this.animatedMode = newMode;
    }, 260);
  }

  onPageShow(): void {
    apiManagementVM.loadProviders();
    this.syncApiStateFromViewModel();
    this.syncPromptsStateFromViewModel();
    this.syncSkillsStateFromViewModel();
    this.syncMcpStateFromBackend();
  }

  aboutToDisappear(): void {
    this.stopMcpPolling();
    if (this.toastTimerId >= 0) {
      clearTimeout(this.toastTimerId);
      this.toastTimerId = -1;
    }
  }

  private isPhoneBreakpoint(): boolean {
    return this.currentBreakpoint === 'xs' || this.currentBreakpoint === 'sm';
  }

  private settingsDialogWidth(): number {
    return getArkPilotLayoutProfile(this.currentBreakpoint).dialogWidth;
  }

  private configTomlDialogWidth(): number {
    if (this.currentBreakpoint === 'lg') {
      return 680;
    }
    if (this.currentBreakpoint === 'md') {
      return 560;
    }
    if (this.currentBreakpoint === 'xs') {
      return 300;
    }
    return 360;
  }

  private configTomlEditorHeight(): number {
    if (this.currentBreakpoint === 'lg') {
      return 520;
    }
    if (this.currentBreakpoint === 'md') {
      return 460;
    }
    if (this.currentBreakpoint === 'xs') {
      return 300;
    }
    return 340;
  }

  private configTomlDialogPadding(): number {
    return this.isPhoneBreakpoint() ? 16 : 22;
  }

  private settingsContentPadding(): number {
    return this.isPhoneBreakpoint() ? 14 : 24;
  }

  private topBarHorizontalPadding(): number {
    return this.isPhoneBreakpoint() ? 12 : 24;
  }

  private topBarTopPadding(): number {
    return this.isPhoneBreakpoint() ? 10 : 20;
  }

  private topBarBottomPadding(): number {
    return this.isPhoneBreakpoint() ? 8 : 12;
  }

  private loadMockData(): void {
    const presets: ApiPresetMockItem[] = [];
    for (let index = 0; index < BUILTIN_PROVIDER_PRESETS.length; index += 1) {
      const preset = BUILTIN_PROVIDER_PRESETS[index];
      presets.push(new ApiPresetMockItem(
        preset.id,
        preset.name,
        preset.category,
        preset.wireApi,
        preset.baseUrl,
        preset.description,
        preset.websiteUrl,
        preset.iconColor.length > 0 ? preset.iconColor : '#8B5CF6'
      ));
    }
    this.apiPresets = presets;
  }

  private selectedPrompt(): PromptRecord | null {
    for (let index = 0; index < this.prompts.length; index += 1) {
      if (this.prompts[index].id === this.selectedPromptId) {
        return this.prompts[index];
      }
    }
    return null;
  }

  private triggerFeedback(message: string, tone: ToastTone = 'info'): void {
    this.runMotion(() => {
      this.sparkSeed += 1;
    }, 180);
    this.showToast(message, tone);
  }

  private syncApiStateFromViewModel(): void {
    this.apiProviders = [...apiManagementVM.state.providers];
    this.apiProviderCount = this.apiProviders.length;
    if (this.apiProviders.length === 0) {
      this.selectedApiProviderId = '';
      return;
    }
    if (this.selectedApiProviderId.length > 0) {
      this.syncApiDraftFromProvider(this.selectedApiProviderId);
    }
  }

  private syncPromptsStateFromViewModel(): void {
    this.prompts = [...this.promptsViewModel.state.prompts];
    this.promptLiveContent = this.promptsViewModel.state.liveContent;
    if (this.prompts.length === 0) {
      this.selectedPromptId = '';
      this.promptDraftName = '';
      this.promptDraftSummary = '';
      this.promptDraftContent = '';
      this.promptsStatusText = this.promptLiveContent.trim().length > 0
        ? '当前 AGENTS.md 已有同步内容。'
        : '当前还没有 Prompt。';
      return;
    }
    const hasCurrent = this.selectedPromptId.length > 0
      && this.prompts.some((prompt: PromptRecord) => prompt.id === this.selectedPromptId);
    const nextId = hasCurrent ? this.selectedPromptId : this.prompts[0].id;
    this.selectedPromptId = nextId;
    const prompt = this.selectedPrompt();
    if (prompt !== null) {
      this.promptDraftName = prompt.name;
      this.promptDraftSummary = prompt.description;
      this.promptDraftContent = prompt.content;
    }
    const activeName = this.promptsViewModel.activePromptName;
    this.promptsStatusText = activeName !== 'None'
      ? `当前启用：${activeName}`
      : (this.promptLiveContent.trim().length > 0 ? '当前仅存在同步内容，未绑定启用 Prompt。' : '当前没有启用 Prompt。');
  }

  private loadSettingsFacadeState(): void {
    apiManagementVM.loadProviders();
    this.syncApiStateFromViewModel();
    this.promptsViewModel.loadAll()
      .then(() => {
        this.syncPromptsStateFromViewModel();
      })
      .catch((err: Object) => {
        this.promptsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.promptsStatusText, 'error');
      });
    skillsVM.loadInstalled(true)
      .then(() => { this.syncSkillsStateFromViewModel(); })
      .catch((err: Object) => { this.skillsStatusText = this.describeRuntimeError(err); this.triggerFeedback(this.skillsStatusText, 'error'); });
    skillsVM.loadRepos()
      .then(() => { this.syncSkillsStateFromViewModel(); })
      .catch((err: Object) => { this.skillsStatusText = this.describeRuntimeError(err); this.triggerFeedback(this.skillsStatusText, 'error'); });
  }

  private selectedSkill(): InstalledSkill | null {
    if (this.selectedSkillId.length === 0) {
      return null;
    }
    for (let index = 0; index < this.installedSkills.length; index += 1) {
      if (this.installedSkills[index].id === this.selectedSkillId) {
        return this.installedSkills[index];
      }
    }
    return null;
  }

  private syncSkillsStateFromViewModel(): void {
    this.installedSkills = [...skillsVM.state.installed];
    this.skillRepos = [...skillsVM.state.repos];
    if (skillsVM.state.statusText.trim().length > 0) {
      this.skillsStatusText = skillsVM.state.statusText;
    } else if (skillsVM.state.errorText.trim().length > 0) {
      this.skillsStatusText = skillsVM.state.errorText;
    }
    const selectedSkill = this.selectedSkill();
    if (selectedSkill !== null) {
      this.selectedSkillDetail = selectedSkill;
    } else if (this.selectedSkillId.length > 0) {
      this.selectedSkillId = '';
      this.selectedSkillDetail = null;
    }
  }

  private toggleSkillEnabled(skillId: string): void {
    let currentSkill: InstalledSkill | null = null;
    for (let index = 0; index < this.installedSkills.length; index += 1) {
      if (this.installedSkills[index].id !== skillId) {
        continue;
      }
      currentSkill = this.installedSkills[index];
      break;
    }
    if (currentSkill === null) {
      return;
    }
    const previousSkill: InstalledSkill = currentSkill;
    const enabled = !previousSkill.enabled;
    const optimisticSkill = new InstalledSkill(
      previousSkill.id, previousSkill.name, previousSkill.description, previousSkill.directory, previousSkill.source,
      previousSkill.repoOwner, previousSkill.repoName, previousSkill.repoBranch, previousSkill.readmeUrl,
      enabled, previousSkill.installedAt, previousSkill.contentHash, previousSkill.updatedAt
    );
    skillsVM.state.installed = skillsVM.state.installed.map((s: InstalledSkill): InstalledSkill =>
      s.id === skillId ? optimisticSkill : s
    );
    this.syncSkillsStateFromViewModel();
    skillsVM.toggleEnabled(skillId, enabled)
      .then(() => {
        if (skillsVM.state.errorText.trim().length > 0) {
          skillsVM.state.installed = skillsVM.state.installed.map((s: InstalledSkill): InstalledSkill =>
            s.id === skillId ? previousSkill : s
          );
        }
        this.syncSkillsStateFromViewModel();
        this.skillsStatusText = skillsVM.state.errorText.trim().length > 0
          ? skillsVM.state.errorText
          : skillsVM.state.statusText;
        this.triggerFeedback(this.skillsStatusText, skillsVM.state.errorText.trim().length > 0 ? 'warning' : 'success');
      })
      .catch((err: Object) => {
        skillsVM.state.installed = skillsVM.state.installed.map((s: InstalledSkill): InstalledSkill =>
          s.id === skillId ? previousSkill : s
        );
        this.syncSkillsStateFromViewModel();
        this.skillsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.skillsStatusText, 'error');
      });
  }

  private requestUninstallSkill(skillId: string): void {
    for (let index = 0; index < this.installedSkills.length; index += 1) {
      if (this.installedSkills[index].id !== skillId) {
        continue;
      }
      this.pendingDeleteSkillId = skillId;
      this.pendingDeleteSkillName = this.installedSkills[index].name;
      this.runMotion(() => {
        this.showSkillDeleteDialog = true;
      });
      return;
    }
  }

  private cancelUninstallSkill(): void {
    this.runMotion(() => {
      this.showSkillDeleteDialog = false;
    });
    this.pendingDeleteSkillId = '';
    this.pendingDeleteSkillName = '';
  }

  private confirmUninstallSkill(): void {
    if (this.skillBusy) {
      this.triggerFeedback('正在处理 Skill，请稍候。', 'info');
      return;
    }
    const skillId = this.pendingDeleteSkillId;
    this.cancelUninstallSkill();
    if (skillId.length === 0) {
      return;
    }
    this.skillBusy = true;
    skillsVM.uninstall(skillId)
      .then(() => {
        this.syncSkillsStateFromViewModel();
        this.skillsStatusText = skillsVM.state.errorText.trim().length > 0
          ? skillsVM.state.errorText
          : skillsVM.state.statusText;
        this.triggerFeedback(this.skillsStatusText, skillsVM.state.errorText.trim().length > 0 ? 'warning' : 'success');
      })
      .catch((err: Object) => {
        this.skillsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.skillsStatusText, 'error');
      })
      .finally(() => { this.skillBusy = false; });
  }

  private showSkillDetail(skill: InstalledSkill): void {
    this.selectedSkillId = skill.id;
    this.selectedSkillDetail = skill;
    this.runMotion(() => {
      this.showSkillDetailDialog = true;
    });
  }

  private closeSkillDetail(): void {
    this.runMotion(() => {
      this.showSkillDetailDialog = false;
    });
    const selectedSkill = this.selectedSkill();
    this.selectedSkillDetail = selectedSkill;
  }

  private addSkillRepo(): void {
    const owner = this.newRepoOwner.trim();
    const name = this.newRepoName.trim();
    const branch = this.newRepoBranch.trim().length > 0 ? this.newRepoBranch.trim() : 'main';
    if (owner.length === 0 || name.length === 0) {
      this.triggerFeedback('仓库所有者与名称不能为空。', 'error');
      return;
    }
    skillsVM.addRepo(new SkillRepo(owner, name, branch, true))
      .then(() => {
        this.syncSkillsStateFromViewModel();
        this.skillsStatusText = skillsVM.state.errorText.trim().length > 0
          ? skillsVM.state.errorText
          : skillsVM.state.statusText;
        this.triggerFeedback(this.skillsStatusText, skillsVM.state.errorText.trim().length > 0 ? 'warning' : 'success');
      })
      .catch((err: Object) => {
        this.skillsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.skillsStatusText, 'error');
      });
  }

  private toggleRepoEnabled(owner: string, name: string): void {
    let nextEnabled: boolean | null = null;
    for (let index = 0; index < this.skillRepos.length; index += 1) {
      const repo = this.skillRepos[index];
      if (repo.owner !== owner || repo.name !== name) {
        continue;
      }
      nextEnabled = !repo.enabled;
      break;
    }
    if (nextEnabled === null) {
      return;
    }
    skillsVM.toggleRepoEnabled(owner, name, nextEnabled)
      .then(() => {
        this.syncSkillsStateFromViewModel();
        this.skillsStatusText = skillsVM.state.errorText.trim().length > 0
          ? skillsVM.state.errorText
          : skillsVM.state.statusText;
        this.triggerFeedback(this.skillsStatusText, skillsVM.state.errorText.trim().length > 0 ? 'warning' : 'success');
      })
      .catch((err: Object) => {
        this.skillsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.skillsStatusText, 'error');
      });
  }

  private removeSkillRepo(owner: string, name: string): void {
    skillsVM.removeRepo(owner, name)
      .then(() => {
        this.syncSkillsStateFromViewModel();
        this.skillsStatusText = skillsVM.state.errorText.trim().length > 0
          ? skillsVM.state.errorText
          : skillsVM.state.statusText;
        this.triggerFeedback(this.skillsStatusText, skillsVM.state.errorText.trim().length > 0 ? 'warning' : 'success');
      })
      .catch((err: Object) => {
        this.skillsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.skillsStatusText, 'error');
      });
  }

  private parseGithubUrl(url: string): ParsedGithubUrl | null {
    const trimmed = url.trim();
    const match = trimmed.match(/^https?:\/\/github\.com\/([^\/]+)\/([^\/\?#]+)(?:\/tree\/([^\/\?#]+))?/);
    if (match === null) {
      return null;
    }
    return new ParsedGithubUrl(match[1], match[2].replace(/\.git$/, ''), match[3] ?? 'main');
  }

  private scanGithubRepo(): void {
    const parsed = this.parseGithubUrl(this.githubRepoUrl);
    if (parsed === null) {
      this.triggerFeedback('请输入有效的 GitHub 仓库 URL，如 https://github.com/owner/repo', 'error');
      return;
    }
    const owner = parsed.owner;
    const name = parsed.name;
    const branch = parsed.branch;
    this.githubScanning = true;
    this.githubScanResults = [];
    skillsVM.discoverFromRepo(owner, name, branch)
      .then((results: DiscoverableSkill[]) => {
        this.githubScanResults = results;
        this.githubScanning = false;
        if (results.length === 0) {
          this.triggerFeedback('未在该仓库中发现 Skill。', 'warning');
        } else {
          this.triggerFeedback(`发现 ${results.length} 个 Skill。`, 'success');
        }
      })
      .catch((err: Object) => {
        this.githubScanning = false;
        this.triggerFeedback(this.describeRuntimeError(err), 'error');
      });
  }

  private isSkillInstalling(key: string): boolean {
    return this.installingSkillKeys.includes(key);
  }

  private setSkillInstalling(key: string, installing: boolean): void {
    if (installing) {
      if (!this.installingSkillKeys.includes(key)) {
        this.installingSkillKeys = [...this.installingSkillKeys, key];
      }
      return;
    }
    this.installingSkillKeys = this.installingSkillKeys.filter((item: string) => item !== key);
  }

  private normalizeSkillMatchText(value: string): string {
    return value.trim().toLowerCase().replace(/[\s._-]+/g, '');
  }

  private matchesSkillsShHint(item: SkillsShItem, skill: DiscoverableSkill): boolean {
    const hint = this.normalizeSkillMatchText(item.directory);
    if (hint.length === 0) {
      return false;
    }

    const candidates: string[] = [skill.directory];
    if (skill.directory.trim().length === 0) {
      candidates.push('.', skill.repoName, skill.name);
    } else {
      const parts = skill.directory.split('/').filter((part: string) => part.length > 0);
      if (parts.length > 0) {
        candidates.push(parts[parts.length - 1]);
      }
    }

    return candidates.some((candidate: string) => this.normalizeSkillMatchText(candidate) === hint);
  }

  private resolveSkillsShCandidate(item: SkillsShItem, skills: DiscoverableSkill[]): DiscoverableSkill | null {
    if (skills.length === 0) {
      return null;
    }
    if (skills.length === 1) {
      return skills[0];
    }

    const normalizedName = this.normalizeSkillMatchText(item.name);
    const nameMatches = skills.filter((skill: DiscoverableSkill) =>
      this.normalizeSkillMatchText(skill.name) === normalizedName
    );
    if (nameMatches.length === 1) {
      return nameMatches[0];
    }

    const hintPool = nameMatches.length > 0 ? nameMatches : skills;
    const hintMatches = hintPool.filter((skill: DiscoverableSkill) => this.matchesSkillsShHint(item, skill));
    if (hintMatches.length === 1) {
      return hintMatches[0];
    }

    return null;
  }

  private installScannedSkill(
    skill: DiscoverableSkill,
    trackingKey: string = skill.key,
    alreadyTracking: boolean = false
  ): void {
    if (!alreadyTracking && this.isSkillInstalling(trackingKey)) {
      this.triggerFeedback(`正在安装 ${skill.name}...`, 'info');
      return;
    }

    if (!alreadyTracking) {
      this.setSkillInstalling(trackingKey, true);
      this.triggerFeedback(`正在安装 ${skill.name}...`, 'info');
    } else {
      this.triggerFeedback(`正在安装 ${skill.name}...`, 'info');
    }

    skillsVM.installFromGithub(skill)
      .then(() => {
        this.syncSkillsStateFromViewModel();
        this.triggerFeedback(`已安装 ${skill.name}。`, 'success');
      })
      .catch((err: Object) => {
        const message = skillsVM.state.errorText.trim().length > 0
          ? skillsVM.state.errorText
          : this.describeRuntimeError(err);
        this.triggerFeedback(message, 'error');
      })
      .finally(() => {
        this.setSkillInstalling(trackingKey, false);
      });
  }

  private async pickAndInstallZip(): Promise<void> {
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext === undefined) {
        this.triggerFeedback('当前页面上下文不可用。', 'error');
        return;
      }
      const documentPicker = new picker.DocumentViewPicker(hostContext);
      const selectedUris: Array<string> = await documentPicker.select();
      if (selectedUris.length === 0) {
        return;
      }
      const selectedUri: string = selectedUris[0];
      const parsedUri = new uri.URI(selectedUri);
      const filePath: string = decodeURIComponent(parsedUri.path ?? '');
      if (filePath.trim().length === 0) {
        this.triggerFeedback('无法解析文件路径。', 'error');
        return;
      }
      this.triggerFeedback('正在导入 ZIP...', 'info');
      skillsVM.importFromZip(filePath)
        .then(() => {
          this.syncSkillsStateFromViewModel();
          this.triggerFeedback(skillsVM.state.errorText.trim().length > 0 ? skillsVM.state.errorText : 'ZIP 导入成功。', skillsVM.state.errorText.trim().length > 0 ? 'warning' : 'success');
        })
        .catch((err: Object) => {
          this.triggerFeedback(this.describeRuntimeError(err), 'error');
        });
    } catch (err) {
      this.triggerFeedback(this.describeRuntimeError(err), 'error');
    }
  }

  private async pickAndInstallDirectory(): Promise<void> {
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext === undefined) {
        this.triggerFeedback('当前页面上下文不可用。', 'error');
        return;
      }
      const documentPicker = new picker.DocumentViewPicker(hostContext);
      const selectedUris: Array<string> = await documentPicker.select({
        selectMode: picker.DocumentSelectMode.FOLDER
      });
      if (selectedUris.length === 0) {
        return;
      }
      const selectedUri: string = selectedUris[0];
      const parsedUri = new uri.URI(selectedUri);
      const dirPath: string = decodeURIComponent(parsedUri.path ?? '');
      if (dirPath.trim().length === 0) {
        this.triggerFeedback('无法解析目录路径。', 'error');
        return;
      }
      this.triggerFeedback('正在导入目录...', 'info');
      skillsVM.importFromLocal([dirPath])
        .then(() => {
          this.syncSkillsStateFromViewModel();
          this.triggerFeedback(skillsVM.state.errorText.trim().length > 0 ? skillsVM.state.errorText : '目录导入成功。', skillsVM.state.errorText.trim().length > 0 ? 'warning' : 'success');
        })
        .catch((err: Object) => {
          this.triggerFeedback(this.describeRuntimeError(err), 'error');
        });
    } catch (err) {
      this.triggerFeedback(this.describeRuntimeError(err), 'error');
    }
  }

  private searchSkillsShAction(): void {
    const query = this.skillsShQuery.trim();
    if (query.length === 0) {
      this.triggerFeedback('请输入搜索关键词。', 'error');
      return;
    }
    this.skillsShSearching = true;
    this.skillsShResults = [];
    skillsVM.searchSkillsSh(query)
      .then((result: SkillsShSearchResult) => {
        this.skillsShResults = result.skills;
        this.skillsShSearching = false;
        if (result.skills.length === 0) {
          this.triggerFeedback('未找到匹配的 Skill。', 'warning');
        } else {
          this.triggerFeedback(`找到 ${result.skills.length} 个 Skill。`, 'success');
        }
      })
      .catch((err: Object) => {
        this.skillsShSearching = false;
        this.triggerFeedback(this.describeRuntimeError(err), 'error');
      });
  }

  private installFromSkillsSh(item: SkillsShItem): void {
    if (this.isSkillInstalling(item.key)) {
      this.triggerFeedback(`正在定位 ${item.name}...`, 'info');
      return;
    }

    this.setSkillInstalling(item.key, true);
    this.triggerFeedback(`正在定位 ${item.name}...`, 'info');
    skillsVM.discoverFromRepo(item.repoOwner, item.repoName, item.repoBranch)
      .then((skills: DiscoverableSkill[]) => {
        if (skillsVM.state.errorText.trim().length > 0) {
          this.triggerFeedback(skillsVM.state.errorText, 'error');
          this.setSkillInstalling(item.key, false);
          return;
        }

        const matched = this.resolveSkillsShCandidate(item, skills);
        if (matched === null) {
          this.setSkillInstalling(item.key, false);
          if (skills.length === 0) {
            this.triggerFeedback(`未在 ${item.repoOwner}/${item.repoName} 中发现可安装的 Skill。`, 'warning');
          } else {
            this.triggerFeedback('该仓库包含多个 Skill，skills.sh 无法唯一定位，请先使用 GitHub 扫描后手动选择。', 'warning');
          }
          return;
        }

        this.installScannedSkill(matched, item.key, true);
      })
      .catch((err: Object) => {
        this.setSkillInstalling(item.key, false);
        this.triggerFeedback(this.describeRuntimeError(err), 'error');
      });
  }

  private skillsSubTabIndex(tab: SkillsSubTab): number {
    if (tab === 'install') return 1;
    return 0;
  }

  private skillsSubTabByIndex(index: number): SkillsSubTab {
    if (index === 1) return 'install';
    return 'installed';
  }

  private refreshActiveSkillsSubTab(): void {
    this.loadSkillsSubTab(this.skillsSubTabByIndex(this.skillsActiveSubTabIndex));
  }

  private switchSkillsSubTab(tab: SkillsSubTab): void {
    this.skillsActiveSubTabIndex = this.skillsSubTabIndex(tab);
    this.loadSkillsSubTab(tab);
  }

  private loadSkillsSubTab(tab: SkillsSubTab): void {
    this.syncSkillsStateFromViewModel();
    if (tab === 'install') {
      this.skillsStatusText = '';
      return;
    }
    this.skillsStatusText = '正在刷新已安装 Skills...';
    skillsVM.loadInstalled(true)
      .then(() => {
        this.syncSkillsStateFromViewModel();
        this.skillsStatusText = skillsVM.state.errorText.trim().length > 0
          ? skillsVM.state.errorText
          : skillsVM.state.statusText;
      })
      .catch((err: Object) => {
        this.skillsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.skillsStatusText, 'error');
      });
  }

  private selectSkillForPreview(skill: InstalledSkill): void {
    this.runMotion(() => {
      this.selectedSkillId = skill.id;
      this.selectedSkillDetail = skill;
    }, 180);
  }

  private skillSourceText(skill: InstalledSkill): string {
    return skill.source === 'github' ? 'GitHub' : '本地';
  }

  private displaySkillDirectory(directory: string): string {
    return directory.trim().length > 0 ? directory : '/';
  }

  private skillsResultListMaxHeight(): number {
    return this.isPhoneBreakpoint() ? 260 : 320;
  }

  private skillMetaText(skill: InstalledSkill): string {
    if (skill.repoOwner.length > 0 && skill.repoName.length > 0) {
      return `${skill.repoOwner}/${skill.repoName}`;
    }
    return this.displaySkillDirectory(skill.directory);
  }

  private skillDetailSourceLabel(): string {
    if (this.selectedSkillDetail === null) return '';
    const src: string = this.selectedSkillDetail.source;
    if (src === 'github') return 'GitHub';
    if (src === 'zip') return 'ZIP 导入';
    return '本地';
  }

  private skillDetailInstalledDate(): string {
    if (this.selectedSkillDetail === null || this.selectedSkillDetail.installedAt <= 0) return '未知';
    return new Date(this.selectedSkillDetail.installedAt).toISOString().replace('T', ' ').substring(0, 19);
  }

  private skillDetailUpdatedDate(): string {
    if (this.selectedSkillDetail === null || this.selectedSkillDetail.updatedAt <= 0) return '从未更新';
    return new Date(this.selectedSkillDetail.updatedAt).toISOString().replace('T', ' ').substring(0, 19);
  }

  private loadMcpDraft(serverId: string): void {
    for (let index = 0; index < this.mcpServers.length; index += 1) {
      const server = this.mcpServers[index];
      if (server.id !== serverId) continue;
      this.applyMcpDraft(server);
      return;
    }
  }

  private applyMcpDraft(server: McpServerRecord): void {
    this.selectedMcpServerId = server.id;
    this.mcpTransportTypeDraft = server.transportType;
    this.mcpCommandDraft = server.command;
    this.mcpArgsDraft = server.argsText.trim().length > 0 ? server.argsText : '[]';
    this.mcpUrlDraft = server.url;
    this.mcpEnvDraft = server.envText.trim().length > 0 ? server.envText : '{}';
    this.mcpHttpHeadersDraft = server.httpHeadersText.trim().length > 0 ? server.httpHeadersText : '{}';
    this.mcpEnabledDraft = server.enabled;
  }

  private selectedMcpServer(): McpServerRecord | null {
    for (let index = 0; index < this.mcpServers.length; index += 1) {
      if (this.mcpServers[index].id === this.selectedMcpServerId) {
        return this.mcpServers[index];
      }
    }
    return null;
  }

  private syncMcpStateFromBackend(): void {
    this.mcpServers = codexBackend.mcpServers();
    const snapshot = codexBackend.snapshot();
    this.mcpStatusText = snapshot.mcpErrorText.trim().length > 0
      ? snapshot.mcpErrorText
      : snapshot.mcpStatusText;
    if (this.mcpServers.length === 0) {
      this.selectedMcpServerId = '';
      this.mcpTransportTypeDraft = 'stdio';
      this.mcpCommandDraft = '';
      this.mcpArgsDraft = '[]';
      this.mcpUrlDraft = '';
      this.mcpEnvDraft = '{}';
      this.mcpEnabledDraft = true;
      return;
    }
    const hasCurrent = this.selectedMcpServerId.length > 0
      && this.mcpServers.some((server: McpServerRecord) => server.id === this.selectedMcpServerId);
    const nextId = hasCurrent ? this.selectedMcpServerId : this.mcpServers[0].id;
    const nextServer = this.mcpServers.find((server: McpServerRecord) => server.id === nextId);
    if (nextServer !== undefined) {
      this.applyMcpDraft(nextServer);
    }
  }

  private saveMcpDraft(): void {
    if (this.mcpBusy) {
      this.triggerFeedback('正在保存 MCP 配置，请稍候。', 'info');
      return;
    }
    const server = this.selectedMcpServer();
    if (server === null) {
      this.triggerFeedback('当前没有可保存的 MCP 服务。', 'warning');
      return;
    }
    this.mcpBusy = true;
    codexBackend.saveMcpServerConfig(
      server.name, this.mcpEnabledDraft, this.mcpTransportTypeDraft,
      this.mcpCommandDraft, this.mcpArgsDraft, this.mcpUrlDraft,
      this.mcpEnvDraft, this.mcpHttpHeadersDraft
    )
      .then(() => {
        this.syncMcpStateFromBackend();
        this.triggerFeedback(`已保存 ${server.name} 的 MCP 配置。`, 'success');
      })
      .catch((err: Object) => {
        this.mcpStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.mcpStatusText, 'error');
      })
      .finally(() => { this.mcpBusy = false; });
  }

  private toggleMcpEnabled(serverId: string): void {
    if (this.mcpBusy) {
      this.triggerFeedback('正在更新 MCP 状态，请稍候。', 'info');
      return;
    }
    const server = this.mcpServers.find((s: McpServerRecord) => s.id === serverId);
    if (server === null || server === undefined) {
      return;
    }
    this.mcpBusy = true;
    codexBackend.saveMcpServerConfig(
      server.name, !server.enabled, server.transportType,
      server.command, server.argsText, server.url,
      server.envText, server.httpHeadersText
    )
      .then(() => {
        this.syncMcpStateFromBackend();
        this.triggerFeedback(`已${server.enabled ? '禁用' : '启用'} ${server.name}。`, 'success');
      })
      .catch((err: Object) => {
        this.mcpStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.mcpStatusText, 'error');
      })
      .finally(() => { this.mcpBusy = false; });
  }

  private revertMcpDraft(): void {
    const server = this.selectedMcpServer();
    if (server === null) {
      this.triggerFeedback('当前没有可还原的 MCP 服务。', 'warning');
      return;
    }
    this.loadMcpDraft(server.id);
    this.triggerFeedback(`已还原 ${server.name} 的草稿。`, 'info');
  }

  private reloadMcpDraft(): void {
    codexBackend.reloadMcpServers()
      .then(() => {
        this.syncMcpStateFromBackend();
        const server = this.selectedMcpServer();
        this.triggerFeedback(server !== null ? `${server.name} 已完成 MCP 重载。` : 'MCP 配置已重载。', 'info');
      })
      .catch((err: Object) => {
        this.mcpStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.mcpStatusText, 'error');
      });
  }

  private startSelectedMcpOauth(): void {
    const server = this.selectedMcpServer();
    if (server === null) {
      this.triggerFeedback('当前没有可登录的 MCP 服务。', 'warning');
      return;
    }
    codexBackend.startMcpOAuthLogin(server.name)
      .then(() => {
        this.syncMcpStateFromBackend();
        this.triggerFeedback(`已为 ${server.name} 发起 OAuth 登录。`, 'success');
      })
      .catch((err: Object) => {
        this.mcpStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.mcpStatusText, 'error');
      });
  }

  private openMcpAddDialog(): void {
    this.mcpNewServerName = '';
    this.runMotion(() => {
      this.showMcpAddDialog = true;
    });
  }

  private cancelMcpAdd(): void {
    this.runMotion(() => {
      this.showMcpAddDialog = false;
    });
    this.mcpNewServerName = '';
    this.mcpJsonPasteInput = '';
  }

  private copyConfigObject(source: Record<string, Object>): Record<string, Object> {
    const result: Record<string, Object> = {};
    const keys: string[] = Object.keys(source);
    for (let i = 0; i < keys.length; i += 1) {
      result[keys[i]] = source[keys[i]];
    }
    return result;
  }

  private parseMcpJsonInput(raw: string): Record<string, Object> | null {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) return null;
    let root: Record<string, Object>;
    try {
      root = JSON.parse(trimmed) as Record<string, Object>;
    } catch (_err) {
      return null;
    }
    const mcpServersObj: Object | undefined = root['mcpServers'];
    if (typeof mcpServersObj === 'object' && mcpServersObj !== null) {
      const keys: string[] = Object.keys(mcpServersObj as Record<string, Object>);
      if (keys.length > 0) {
        const firstName: string = keys[0];
        const serverConfig: Object = (mcpServersObj as Record<string, Object>)[firstName];
        if (typeof serverConfig === 'object' && serverConfig !== null) {
          const result: Record<string, Object> = this.copyConfigObject(serverConfig as Record<string, Object>);
          if (result['name'] === undefined) {
            result['name'] = firstName;
          }
          return result;
        }
      }
    }
    return root;
  }

  private mcpAddPreviewText(): string {
    const parsed: Record<string, Object> | null = this.parseMcpJsonInput(this.mcpJsonPasteInput);
    if (parsed === null) {
      if (this.mcpJsonPasteInput.trim().length === 0) return '粘贴 JSON 后自动解析预览';
      return 'JSON 格式不正确';
    }
    const name: string = this.mcpNewServerName.trim().length > 0
      ? this.mcpNewServerName.trim()
      : (typeof parsed['name'] === 'string' ? (parsed['name'] as string) : '');
    const url: string = typeof parsed['url'] === 'string' ? (parsed['url'] as string) : '';
    const command: string = typeof parsed['command'] === 'string' ? (parsed['command'] as string) : '';
    const transport: string = url.length > 0 ? 'HTTP' : (command.length > 0 ? 'stdio' : '?');
    const headers: Object | undefined = parsed['headers'];
    const hasHeaders: boolean = typeof headers === 'object' && headers !== null && Object.keys(headers as Record<string, Object>).length > 0;
    let preview: string = `名称: ${name.length > 0 ? name : '(未指定)'}\n传输: ${transport}`;
    if (url.length > 0) preview += `\nURL: ${url}`;
    if (command.length > 0) preview += `\n命令: ${command}`;
    if (hasHeaders) preview += `\n请求头: 已配置`;
    return preview;
  }

  private confirmMcpAdd(): void {
    this.confirmMcpAddFromJson();
  }

  private confirmMcpAddFromJson(): void {
    if (this.mcpBusy) {
      this.triggerFeedback('正在添加 MCP 服务，请稍候。', 'info');
      return;
    }
    const parsed: Record<string, Object> | null = this.parseMcpJsonInput(this.mcpJsonPasteInput);
    if (parsed === null) {
      this.triggerFeedback('JSON 格式不正确，请检查后重试。', 'error');
      return;
    }
    let name: string = this.mcpNewServerName.trim();
    if (name.length === 0) {
      if (typeof parsed['name'] === 'string' && (parsed['name'] as string).trim().length > 0) {
        name = (parsed['name'] as string).trim();
      } else {
        this.triggerFeedback('请输入名称，或在 JSON 中包含 "name" 字段。', 'warning');
        return;
      }
    }
    for (let i: number = 0; i < this.mcpServers.length; i += 1) {
      if (this.mcpServers[i].name === name) {
        this.triggerFeedback('已存在同名 MCP 服务。', 'warning');
        return;
      }
    }
    const url: string = typeof parsed['url'] === 'string' ? (parsed['url'] as string).trim() : '';
    const command: string = typeof parsed['command'] === 'string' ? (parsed['command'] as string).trim() : '';
    if (url.length === 0 && command.length === 0) {
      this.triggerFeedback('JSON 中必须包含 "url"（HTTP）或 "command"（stdio）。', 'warning');
      return;
    }
    const transportType: string = url.length > 0 ? 'http' : 'stdio';
    const argsObj: Object | undefined = parsed['args'];
    const argsText: string = argsObj !== undefined ? JSON.stringify(argsObj) : '[]';
    const envObj: Object | undefined = parsed['env'];
    const envText: string = envObj !== undefined ? JSON.stringify(envObj) : '{}';
    const headersObj: Object | undefined = parsed['headers'];
    const httpHeadersText: string = headersObj !== undefined ? JSON.stringify(headersObj) : '{}';
    this.mcpBusy = true;
    codexBackend.addMcpServer(name, transportType, command, argsText, url, envText, httpHeadersText)
      .then(() => {
        this.runMotion(() => {
          this.showMcpAddDialog = false;
        });
        this.mcpNewServerName = '';
        this.mcpJsonPasteInput = '';
        this.syncMcpStateFromBackend();
        this.triggerFeedback(`已添加 MCP 服务：${name}`, 'success');
        // 后台刷新可能尚未完成，轮询等待状态数据
        if (this.mcpServers.length === 0) {
          this.startMcpPolling();
        }
      })
      .catch((err: Object) => {
        this.mcpStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.mcpStatusText, 'error');
      })
      .finally(() => { this.mcpBusy = false; });
  }

  private openMcpDeleteDialog(): void {
    const server = this.selectedMcpServer();
    if (server === null) {
      this.triggerFeedback('当前没有可删除的 MCP 服务。', 'warning');
      return;
    }
    this.pendingDeleteMcpName = server.name;
    this.runMotion(() => {
      this.showMcpDeleteDialog = true;
    });
  }

  private cancelMcpDelete(): void {
    this.runMotion(() => {
      this.showMcpDeleteDialog = false;
    });
    this.pendingDeleteMcpName = '';
  }

  private confirmMcpDelete(): void {
    if (this.mcpBusy) {
      this.triggerFeedback('正在删除 MCP 服务，请稍候。', 'info');
      return;
    }
    const name: string = this.pendingDeleteMcpName;
    this.cancelMcpDelete();
    if (name.length === 0) return;
    this.mcpBusy = true;
    codexBackend.removeMcpServer(name)
      .then(() => {
        this.syncMcpStateFromBackend();
        this.triggerFeedback(`已删除 MCP 服务：${name}`, 'success');
      })
      .catch((err: Object) => {
        this.mcpStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.mcpStatusText, 'error');
      })
      .finally(() => { this.mcpBusy = false; });
  }

  private authLabel(status: string): string {
    switch (status) {
      case 'notRequired': return '无需认证';
      case 'required': return '需要 OAuth';
      case 'pending': return 'OAuth 等待中';
      case 'authenticated': return '已认证';
      case 'failed': return '失败';
      default: return status;
    }
  }

  private healthLabel(status: string): string {
    switch (status) {
      case 'ok': return '正常';
      case 'warning': return '无工具';
      case 'degraded': return '需关注';
      case 'error': return '错误';
      case 'unknown': return '连接中';
      default: return '未知';
    }
  }

  private describeRuntimeError(err: Object): string {
    if (err instanceof Error) {
      return err.message.trim().length > 0 ? err.message : '操作失败，请稍后重试。';
    }
    return '操作失败，请稍后重试。';
  }

  private showToast(message: string, tone: ToastTone = 'info', duration: number = 1800): void {
    const toastId = this.toastIdSeed;
    this.toastIdSeed += 1;
    this.runMotion(() => {
      this.toasts = [...this.toasts, new UiToastItem(toastId, tone, message)];
    }, 180);
    const timerId: number = setTimeout(() => {
      if (this.toastTimerId === timerId) {
        this.toastTimerId = -1;
      }
      this.dismissToast(toastId);
    }, duration);
    this.toastTimerId = timerId;
  }

  private dismissToast(toastId: number): void {
    this.runMotion(() => {
      this.toasts = this.toasts.filter((toast: UiToastItem) => toast.id !== toastId);
    }, 180);
  }

  private updatePressed(key: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.runMotion(() => {
        this.pressedKey = key;
      }, 90);
      return;
    }
    if (this.pressedKey === key) {
      this.runMotion(() => {
        this.pressedKey = '';
      }, 140);
    }
  }

  private pressScale(key: string): number {
    return this.pressedKey === key ? 0.97 : 1;
  }

  private tabAccent(tab: SettingsTab): string {
    switch (tab) {
      case 'mcp':
        return '#0A84FF';
      case 'skills':
        return '#14B8A6';
      case 'prompts':
        return '#F59E0B';
      default:
        return '#8B5CF6';
    }
  }

  private toneBackground(tone: ToastTone): string {
    switch (tone) {
      case 'success':
        return '#DCFCE7';
      case 'warning':
        return '#FEF3C7';
      case 'error':
        return '#FEE2E2';
      default:
        return '#E0F2FE';
    }
  }

  private toneColor(tone: ToastTone): string {
    switch (tone) {
      case 'success':
        return '#166534';
      case 'warning':
        return '#92400E';
      case 'error':
        return '#B91C1C';
      default:
        return '#0C4A6E';
    }
  }

  private statusChipBackground(status: string): string {
    switch (status) {
      case 'Healthy':
      case '正常':
      case 'ok':
      case 'authenticated':
        return '#DCFCE7';
      case 'Standby':
      case '待命':
      case 'pending':
      case 'required':
      case 'degraded':
      case 'warning':
        return '#FEF3C7';
      case 'Draft':
      case '草稿':
      case 'unknown':
        return '#E0F2FE';
      default:
        return '#F1F5F9';
    }
  }

  private statusChipColor(status: string): string {
    switch (status) {
      case 'Healthy':
      case '正常':
      case 'ok':
      case 'authenticated':
        return '#166534';
      case 'Standby':
      case '待命':
      case 'pending':
      case 'required':
      case 'degraded':
      case 'warning':
        return '#92400E';
      case 'Draft':
      case '草稿':
      case 'unknown':
        return '#0C4A6E';
      default:
        return '#475569';
    }
  }

  private formatTimestamp(ts: number): string {
    if (ts <= 0) {
      return '-';
    }
    return new Date(ts).toISOString().replace('T', ' ').substring(0, 19);
  }

  private selectTab(tab: SettingsTab): void {
    this.runMotion(() => {
      this.activeTab = tab;
    }, 220);
    if (tab === 'mcp' && this.mcpServers.length === 0 && !this.mcpLoading) {
      this.mcpLoading = true;
      codexBackend.refreshMcpServers()
        .then(() => {
          this.syncMcpStateFromBackend();
          // 如果缓存为空（后台刷新尚未完成），轮询等待数据就绪
          if (this.mcpServers.length === 0) {
            this.startMcpPolling();
          }
        })
        .catch((err: Object) => {
          this.mcpStatusText = this.describeRuntimeError(err);
          this.triggerFeedback(this.mcpStatusText, 'error');
        })
        .finally(() => { this.mcpLoading = false; });
    }
  }

  private mcpPollTimer: number = -1;

  private startMcpPolling(): void {
    this.stopMcpPolling();
    let elapsed: number = 0;
    this.mcpPollTimer = setInterval(() => {
      elapsed += 2;
      codexBackend.refreshMcpServers()
        .then(() => {
          this.syncMcpStateFromBackend();
          if (this.mcpServers.length > 0 || elapsed >= 30) {
            this.stopMcpPolling();
          }
        })
        .catch(() => {
          this.stopMcpPolling();
        });
    }, 2000);
  }

  private stopMcpPolling(): void {
    if (this.mcpPollTimer >= 0) {
      clearInterval(this.mcpPollTimer);
      this.mcpPollTimer = -1;
    }
  }

  private navLabel(tab: SettingsTab): string {
    switch (tab) {
      case 'mcp':
        return 'MCP';
      case 'skills':
        return 'Skills';
      case 'prompts':
        return 'Prompt';
      default:
        return 'API';
    }
  }

  private selectPrompt(promptId: string): void {
    const prompt = this.prompts.find((item: PromptRecord) => item.id === promptId) ?? null;
    this.runMotion(() => {
      this.selectedPromptId = promptId;
    }, 180);
    if (prompt !== null) {
      this.promptDraftName = prompt.name;
      this.promptDraftSummary = prompt.description;
      this.promptDraftContent = prompt.content;
      this.triggerFeedback(`已载入 ${prompt.name} 的真实草稿。`, 'info');
    }
  }

  private togglePromptEnabled(promptId: string): void {
    const prompt = this.prompts.find((item: PromptRecord) => item.id === promptId) ?? null;
    if (prompt === null) {
      return;
    }
    const wasEnabled = prompt.enabled;
    const action = wasEnabled
      ? this.promptsViewModel.disableAll()
      : this.promptsViewModel.enablePrompt(promptId);
    action
      .then(() => {
        this.syncPromptsStateFromViewModel();
        this.triggerFeedback(`${prompt.name} 已${wasEnabled ? '停用' : '启用'}。`, 'success');
      })
      .catch((err: Object) => {
        this.promptsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.promptsStatusText, 'error');
      });
  }

  private requestDeletePrompt(promptId: string): void {
    const prompt = this.prompts.find((item: PromptRecord) => item.id === promptId) ?? null;
    if (prompt === null) {
      return;
    }
    this.pendingDeletePromptId = prompt.id;
    this.pendingDeletePromptName = prompt.name;
    this.runMotion(() => {
      this.showPromptDeleteDialog = true;
    });
  }

  private cancelDeletePrompt(): void {
    this.runMotion(() => {
      this.showPromptDeleteDialog = false;
    });
    this.pendingDeletePromptId = '';
    this.pendingDeletePromptName = '';
  }

  private confirmDeletePrompt(): void {
    if (this.promptBusy) {
      this.triggerFeedback('正在删除 Prompt，请稍候。', 'info');
      return;
    }
    const promptId: string = this.pendingDeletePromptId;
    const promptName: string = this.pendingDeletePromptName;
    this.cancelDeletePrompt();
    if (promptId.length === 0) {
      return;
    }
    this.promptBusy = true;
    this.promptsViewModel.deletePrompt(promptId)
      .then(() => {
        this.syncPromptsStateFromViewModel();
        this.triggerFeedback(`${promptName} 已删除。`, 'success');
      })
      .catch((err: Object) => {
        this.promptsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.promptsStatusText, 'error');
      })
      .finally(() => { this.promptBusy = false; });
  }

  private createNewPrompt(): void {
    const newId = `prompt-${Date.now()}`;
    const newPrompt = new PromptRecord(
      newId,
      '',
      '',
      '',
      false,
      Date.now(),
      0
    );
    this.promptsViewModel.savePrompt(newPrompt)
      .then(() => {
        this.syncPromptsStateFromViewModel();
        this.selectedPromptId = newId;
        this.promptDraftName = '';
        this.promptDraftSummary = '';
        this.promptDraftContent = '';
        this.triggerFeedback('已创建新 Prompt，请编辑后保存。', 'success');
      })
      .catch((err: Object) => {
        this.promptsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.promptsStatusText, 'error');
      });
  }

  private savePromptDraft(): void {
    if (this.promptBusy) {
      this.triggerFeedback('正在保存 Prompt，请稍候。', 'info');
      return;
    }
    const prompt = this.selectedPrompt();
    const draft = prompt !== null
      ? new PromptRecord(
          prompt.id,
          this.promptDraftName,
          this.promptDraftContent,
          this.promptDraftSummary,
          prompt.enabled,
          prompt.createdAt,
          prompt.updatedAt
        )
      : new PromptRecord(
          `prompt-${Date.now()}`,
          this.promptDraftName,
          this.promptDraftContent,
          this.promptDraftSummary,
          false,
          Date.now(),
          0
        );
    this.promptBusy = true;
    this.promptsViewModel.savePrompt(draft)
      .then(() => {
        this.syncPromptsStateFromViewModel();
        this.triggerFeedback('Prompt 草稿已保存。', 'success');
      })
      .catch((err: Object) => {
        this.promptsStatusText = this.describeRuntimeError(err);
        this.triggerFeedback(this.promptsStatusText, 'error');
      })
      .finally(() => { this.promptBusy = false; });
  }

  private selectedApiProvider(): ProviderRecord | null {
    for (let index = 0; index < this.apiProviders.length; index += 1) {
      if (this.apiProviders[index].id === this.selectedApiProviderId) {
        return this.apiProviders[index];
      }
    }
    return null;
  }

  private apiCategoryLabel(category: string): string {
    switch (category) {
      case 'official':
        return '官方';
      case 'third_party':
        return '第三方';
      case 'cloud_provider':
        return '云服务商';
      case 'aggregator':
        return '聚合';
      case 'custom':
        return '自定义';
      default:
        return category;
    }
  }

  private apiWireApiLabel(wireApi: string): string {
    switch (wireApi) {
      case 'responses':
        return 'Responses';
      default:
        return wireApi;
    }
  }

  private apiHealthColor(status: string): string {
    switch (status) {
      case 'healthy':
        return '#166534';
      case 'degraded':
        return '#C2410C';
      case 'unhealthy':
      case 'error':
        return '#B91C1C';
      default:
        return '#64748B';
    }
  }

  private apiHealthBg(status: string): string {
    switch (status) {
      case 'healthy':
        return '#DCFCE7';
      case 'degraded':
        return '#FFF7ED';
      case 'unhealthy':
      case 'error':
        return '#FEE2E2';
      default:
        return '#F1F5F9';
    }
  }

  private apiHealthLabel(provider: ProviderRecord): string {
    if (provider.healthStatus === 'healthy') {
      return provider.healthLatencyMs > 0 ? `可用 ${provider.healthLatencyMs}ms` : '可用';
    }
    if (provider.healthStatus === 'error' || provider.healthStatus === 'unhealthy') {
      return '不可用';
    }
    if (provider.healthStatus === 'degraded') {
      return '不可对话';
    }
    return '未测速';
  }

  private chatProbeLabel(probe: ChatProbeResult | null): string {
    if (probe === null) {
      return '未测试';
    }
    if (probe.success) {
      return '可对话';
    }
    return '不可用';
  }

  private chatProbeColor(probe: ChatProbeResult | null): string {
    if (probe === null) {
      return '#64748B';
    }
    if (probe.success) {
      return '#166534';
    }
    return '#B91C1C';
  }

  private apiProviderInitial(provider: ProviderRecord): string {
    const name = provider.name.trim();
    if (name.length > 0) {
      return name.substring(0, 1).toUpperCase();
    }
    if (provider.icon.trim().length > 0) {
      return provider.icon.substring(0, 1).toUpperCase();
    }
    return 'P';
  }

  private apiProviderSecondaryText(provider: ProviderRecord): string {
    if (provider.baseUrl.trim().length > 0) {
      return provider.baseUrl;
    }
    if (provider.description.trim().length > 0) {
      return provider.description;
    }
    return '未配置官方网址';
  }

  private apiProviderCardBorder(provider: ProviderRecord): string {
    if (provider.id === this.selectedApiProviderId) {
      return '#93C5FD';
    }
    return '#E5E7EB';
  }

  private apiProviderCardBackground(provider: ProviderRecord): string {
    if (provider.id === this.selectedApiProviderId) {
      return '#F0F7FF';
    }
    return '#FFFFFF';
  }

  private apiProviderEmphasized(provider: ProviderRecord): boolean {
    return provider.id === this.selectedApiProviderId;
  }

  private syncApiDraftFromProvider(providerId: string): void {
    for (let index = 0; index < this.apiProviders.length; index += 1) {
      if (this.apiProviders[index].id === providerId) {
        this.selectedApiProviderId = providerId;
        return;
      }
    }
    this.selectedApiProviderId = '';
  }

  private selectApiProvider(providerId: string): void {
    this.runMotion(() => {
      this.selectedApiProviderId = providerId;
    }, 180);
  }

  private activateApiProvider(providerId: string): void {
    for (let i = 0; i < this.apiProviders.length; i += 1) {
      this.apiProviders[i].isActive = this.apiProviders[i].id === providerId;
    }
    this.apiProviders = [...this.apiProviders];

    apiManagementVM.activateProvider(providerId);

    if (apiManagementVM.state.errorText.trim().length > 0) {
      this.triggerFeedback(apiManagementVM.state.errorText, 'warning');
      return;
    }
    this.triggerFeedback(apiManagementVM.state.statusText, 'success');
    // Provider 切换：配置已写入 config.toml / provider catalog，但 embedded app-server
    // 在启动时缓存了配置与登录态。新建会话虽会重读 config.toml，但 API key 等运行时状态
    // 需重启应用才能完整生效，故弹窗引导用户重启。
    AlertDialog.show({
      title: '已更改配置',
      message: '请重启软件以生效。',
      confirm: { value: '知道了', action: () => {} }
    });
  }

  private removeApiProvider(providerId: string): void {
    apiManagementVM.deleteProvider(providerId);
    this.syncApiStateFromViewModel();

    if (apiManagementVM.state.errorText.trim().length > 0) {
      this.triggerFeedback(apiManagementVM.state.errorText, 'warning');
      return;
    }
    if (this.selectedApiProviderId.length === 0 && this.apiProviders.length > 0) {
      this.selectedApiProviderId = this.apiProviders[0].id;
    }
    this.triggerFeedback(apiManagementVM.state.statusText, 'success');
  }

  private applyApiPreset(presetId: string): void {
    apiManagementVM.state.selectedPresetId = presetId;
    apiManagementVM.state.newApiKey = 'sk-preset-************************';
    apiManagementVM.confirmAddFromPreset();
    this.syncApiStateFromViewModel();
    if (apiManagementVM.state.errorText.trim().length > 0) {
      this.triggerFeedback(apiManagementVM.state.errorText, 'warning');
      return;
    }
    if (apiManagementVM.state.providers.length > 0) {
      const created = apiManagementVM.state.providers[apiManagementVM.state.providers.length - 1];
      this.selectedApiProviderId = created.id;
    }
    this.runMotion(() => {
      this.apiActiveSubTab = 'providers';
    }, 180);
    this.triggerFeedback(apiManagementVM.state.statusText, 'success');
  }

  private filteredApiPresets(): ApiPresetMockItem[] {
    if (this.apiPresetCategory === 'all') {
      return this.apiPresets;
    }
    const result: ApiPresetMockItem[] = [];
    for (let index = 0; index < this.apiPresets.length; index += 1) {
      if (this.apiPresets[index].category === this.apiPresetCategory) {
        result.push(this.apiPresets[index]);
      }
    }
    return result;
  }

  private validateApiDraft(): void {
    const provider = this.selectedApiProvider();
    if (provider === null) {
      this.triggerFeedback('请先选择服务商。', 'warning');
      return;
    }
    apiManagementVM.validateProvider(provider)
      .then(() => {
        const result = apiManagementVM.state.validationResult;
        if (result !== null) {
          this.validationResult = result;
          this.runMotion(() => {
            this.showValidationDialog = true;
          });
        } else {
          const msg = apiManagementVM.state.errorText.trim().length > 0
            ? apiManagementVM.state.errorText
            : '验证未返回结果。';
          this.triggerFeedback(msg, 'warning');
        }
      })
      .catch((err: Object) => {
        this.triggerFeedback(this.describeRuntimeError(err), 'error');
      });
  }

  private runApiSpeedTest(provider: ProviderRecord): void {
    this.apiSpeedTesting = true;
    this.apiSpeedResults = [];
    this.runMotion(() => {
      this.apiShowSpeedResults = true;
    });
    this.selectedApiProviderId = provider.id;
    apiManagementVM.testSpeed(provider, false)
      .then(() => {
        this.apiSpeedResults = [...apiManagementVM.state.speedResults];
        this.apiSpeedTesting = false;
        this.apiProviders = [...apiManagementVM.state.providers];
        this.apiProviderCount = this.apiProviders.length;
        const hasSuccess = this.apiSpeedResults.some((r: EndpointSpeedResult) => r.success);
        if (hasSuccess) {
          this.triggerFeedback('端点测速已完成。', 'success');
          return;
        }
        const msg = apiManagementVM.state.errorText.trim().length > 0
          ? apiManagementVM.state.errorText
          : '测速未获得可用结果，请检查网络与 API Key。';
        this.triggerFeedback(msg, 'warning');
      })
      .catch((err: Object) => {
        this.apiSpeedTesting = false;
        this.triggerFeedback(this.describeRuntimeError(err), 'error');
      });
  }

  private speedTestingLabel(): string {
    return this.apiSpeedTesting ? '测速中...' : '';
  }

  private speedProbeDetail(r: EndpointSpeedResult): string {
    if (r.chatProbe !== null && r.chatProbe.success) {
      return `${r.chatProbe.latencyMs}ms`;
    }
    if (r.chatProbe !== null && !r.chatProbe.success && r.chatProbe.errorMessage.length > 0) {
      return r.chatProbe.errorMessage;
    }
    return '';
  }

  private speedProbeDetailColor(r: EndpointSpeedResult): string {
    if (r.chatProbe !== null && r.chatProbe.success) {
      return '#64748B';
    }
    return '#475569';
  }

  private textPrimary(): string {
    return '#0F172A';
  }

  private textSecondary(): string {
    return '#475569';
  }

  private textMuted(): string {
    return '#64748B';
  }

  private surface(): string {
    return '#FFFFFF';
  }

  private elevatedSurface(): string {
    return '#F8FAFC';
  }

  private pageBackground(): string {
    return '#F1F3F5';
  }

  private speedProbeDetailSize(r: EndpointSpeedResult): number {
    return 10;
  }

  @Builder
  private apiSpeedResultsPanel() {
    if (this.apiShowSpeedResults && (this.apiSpeedResults.length > 0 || this.apiSpeedTesting)) {
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#0F172A')
          .opacity(0.18)
          .onClick(() => { this.runMotion(() => { this.apiShowSpeedResults = false; }); })

        Column() {
          Row() {
            Text('端点测速结果')
              .copyOption(CopyOptions.None)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textPrimary())

            Blank()
              .layoutWeight(1)

            Text(this.speedTestingLabel())
              .copyOption(CopyOptions.None)
              .fontSize(11)
              .fontColor('#2563EB')

            Button() {
              Text('×').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            }
              .type(ButtonType.Normal)
              .accessibilityText('关闭')
              .width(32)
              .height(32)
              .fontSize(20)
              .fontColor(this.textSecondary())
              .backgroundColor('#E2E8F0')
              .borderRadius(10)
              .border({ width: 1, color: '#CBD5E1' })
              .margin({ left: 12 })
              .onClick(() => { this.runMotion(() => { this.apiShowSpeedResults = false; }); })
          }
          .width('100%')

          if (this.apiSpeedTesting && this.apiSpeedResults.length === 0) {
            Row() {
              LoadingProgress()
                .width(16)
                .height(16)
                .color('#2563EB')
              Text('正在测速，请稍候...')
                .copyOption(CopyOptions.None)
                .fontSize(11)
                .fontColor(this.textMuted())
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ top: 20, bottom: 20 })
            .justifyContent(FlexAlign.Center)
          }

          List({ space: 0 }) {
            ForEach(this.apiSpeedResults, (r: EndpointSpeedResult) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(r.endpointUrl)
                      .copyOption(CopyOptions.None)
                      .fontSize(11)
                      .fontColor(this.textSecondary())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text(r.success ? `${r.latencyMs}ms` : '失败')
                      .copyOption(CopyOptions.None)
                      .fontSize(11)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(r.success ? '#166534' : '#B91C1C')
                      .margin({ left: 8, right: 8 })
                    Text(r.success ? '正常' : '错误')
                      .copyOption(CopyOptions.None)
                      .fontSize(10)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(r.success ? '#166534' : '#B91C1C')
                      .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                      .backgroundColor(r.success ? '#DCFCE7' : '#FEE2E2')
                      .borderRadius(8)
                  }
                  .width('100%')

                  Row() {
                    Text('对话测试')
                      .copyOption(CopyOptions.None)
                      .fontSize(10)
                      .fontColor(this.textSecondary())
                    Text(this.chatProbeLabel(r.chatProbe))
                      .copyOption(CopyOptions.None)
                      .fontSize(10)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.chatProbeColor(r.chatProbe))
                      .margin({ left: 6 })
                    Text(this.speedProbeDetail(r))
                      .copyOption(CopyOptions.None)
                      .fontSize(this.speedProbeDetailSize(r))
                      .fontColor(this.speedProbeDetailColor(r))
                      .margin({ left: 4 })
                  }
                  .width('100%')
                  .margin({ top: 4 })
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
              }
            }, (r: EndpointSpeedResult) => r.endpointUrl)
          }
          .width('100%')
          .margin({ top: 10 })
          .height(200)
          .scrollBar(BarState.Off)

          Button('关闭')
            .height(38)
            .width('100%')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .backgroundColor('#111827')
            .borderRadius(14)
            .margin({ top: 16 })
            .onClick(() => { this.runMotion(() => { this.apiShowSpeedResults = false; }); })
        }
        .width(this.settingsDialogWidth())
        .padding(22)
        .backgroundColor(this.surface())
        .border({ width: 1, color: '#E2EAF3' })
        .borderRadius(24)
      }
      .width('100%')
      .height('100%')
      .transition(this.dialogTransition())
    }
  }

  @Builder
  private backdropLayer() {
    Stack() {
      Column()
        .width(320)
        .height(320)
        .backgroundColor('#D7E8FF')
        .opacity(0.42)
        .borderRadius(180)
        .position({ x: -80, y: -40 })

      Column()
        .width(260)
        .height(260)
        .backgroundColor('#DCFCE7')
        .opacity(0.28)
        .borderRadius(180)
        .position({ x: 860, y: 120 })

      Column()
        .width(220)
        .height(220)
        .backgroundColor('#FDE68A')
        .opacity(0.18)
        .borderRadius(140)
        .position({ x: 720, y: 540 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private topBar() {
    Row() {
      Button() {
        Row() {
          Text('<')
            .copyOption(CopyOptions.None)
            .fontSize(16)
            .fontColor(this.textPrimary())
            .fontWeight(FontWeight.Bold)
          if (!this.isPhoneBreakpoint()) {
            Text('返回')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textPrimary())
              .margin({ left: 6 })
          }
        }
      }
      .width(this.isPhoneBreakpoint() ? 34 : undefined)
      .height(this.isPhoneBreakpoint() ? 34 : 36)
      .padding(this.isPhoneBreakpoint() ? 0 : { left: 12, right: 14 })
      .backgroundColor(this.surface())
      .borderRadius(this.isPhoneBreakpoint() ? 12 : 10)
      .border({ width: 1, color: '#E5E7EB' })
      .scale({ x: this.pressScale('back'), y: this.pressScale('back') })
      .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent) => { this.updatePressed('back', event); })
      .onClick(() => { router.back(); })

      Text('设置')
        .copyOption(CopyOptions.None)
        .fontSize(this.isPhoneBreakpoint() ? 22 : 20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textPrimary())
        .margin({ left: this.isPhoneBreakpoint() ? 12 : 16 })

      Blank()
        .layoutWeight(1)

      Row({ space: 8 }) {
        if (this.isPhoneBreakpoint()) {
          Button() {
            Text('config.toml')
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textSecondary())
          }
          .height(34)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.elevatedSurface())
          .borderRadius(12)
          .border({ width: 1, color: '#E5E7EB' })
          .scale({ x: this.pressScale('config-toml'), y: this.pressScale('config-toml') })
          .animation({ duration: 140, curve: Curve.FastOutSlowIn })
          .onTouch((event: TouchEvent) => { this.updatePressed('config-toml', event); })
          .onClick(() => { this.openConfigToml(); })
        }

        Button(this.isPhoneBreakpoint() ? '×' : '关闭')
          .height(34)
          .width(this.isPhoneBreakpoint() ? 34 : 64)
          .fontSize(this.isPhoneBreakpoint() ? 20 : 12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textPrimary())
          .backgroundColor(this.elevatedSurface())
          .borderRadius(12)
          .border({ width: 1, color: '#E5E7EB' })
          .scale({ x: this.pressScale('settings-close'), y: this.pressScale('settings-close') })
          .animation({ duration: 140, curve: Curve.FastOutSlowIn })
          .onTouch((event: TouchEvent) => { this.updatePressed('settings-close', event); })
          .onClick(() => { router.back(); })
      }
    }
    .width('100%')
    .padding({
      left: this.topBarHorizontalPadding(),
      right: this.topBarHorizontalPadding(),
      top: this.topBarTopPadding(),
      bottom: this.topBarBottomPadding()
    })
    .backgroundColor(this.surface())
  }

  @Builder
  private particleCluster() {
    Row() {
      ForEach([0, 1, 2, 3, 4, 5], (index: number) => {
        Column()
          .width(index % 2 === 0 ? 8 : 5)
          .height(index % 2 === 0 ? 8 : 5)
          .backgroundColor(index % 3 === 0 ? '#60A5FA' : (index % 3 === 1 ? '#34D399' : '#FBBF24'))
          .borderRadius(12)
          .opacity((this.sparkSeed + index) % 2 === 0 ? 0.95 : 0.35)
          .scale({ x: (this.sparkSeed + index) % 2 === 0 ? 1.2 : 0.82, y: (this.sparkSeed + index) % 2 === 0 ? 1.2 : 0.82 })
          .margin({ left: index === 0 ? 0 : 8, top: index % 2 === 0 ? 0 : 10 })
          .animation({ duration: 220, curve: Curve.EaseOut })
      })
    }
    .margin({ right: 2 })
  }

  private openConfigToml(): void {
    const codexHome: string = (AppStorage.get('codexHome') as string) ?? '';
    if (codexHome.length === 0) {
      return;
    }
    const configPath: string = codexHome + '/config.toml';
    this.configTomlPath = configPath;
    try {
      const stat = fs.statSync(configPath);
      if (!stat.isFile()) {
        this.configTomlContent = '# config.toml 不存在\n# 保存 Provider 后会自动生成';
        this.runMotion(() => {
          this.showConfigToml = true;
        });
        return;
      }
      const file = fs.openSync(configPath, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const bytesRead = fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const decoder = new util.TextDecoder('utf-8');
      this.configTomlContent = decoder.decode(new Uint8Array(buf, 0, bytesRead));
    } catch (_e) {
      this.configTomlContent = '# 读取失败，请检查文件权限后重试';
    }
    this.runMotion(() => {
      this.showConfigToml = true;
    });
  }

  private saveConfigToml(): void {
    if (this.configTomlPath.length === 0) {
      return;
    }
    try {
      const file = fs.openSync(this.configTomlPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, this.configTomlContent);
      fs.closeSync(file);
      this.runMotion(() => { this.showConfigToml = false; });
    } catch (_e) {
      AlertDialog.show({
        title: '保存失败',
        message: '无法保存配置文件，请检查文件权限后重试。',
        primaryButton: { value: '确定', action: () => {} }
      });
    }
  }

  @Builder
  private configTomlDialog() {
    if (this.showConfigToml) {
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#0F172A')
          .opacity(0.18)
          .onClick(() => { this.runMotion(() => { this.showConfigToml = false; }); })

        Column() {
          Row() {
            Text('config.toml')
              .copyOption(CopyOptions.None)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textPrimary())

            Blank()
              .layoutWeight(1)

            Button() {
              Text('×').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            }
              .type(ButtonType.Normal)
              .accessibilityText('关闭')
              .width(32)
              .height(32)
              .fontSize(20)
              .fontColor(this.textSecondary())
              .backgroundColor('#E2E8F0')
              .borderRadius(10)
              .border({ width: 1, color: '#CBD5E1' })
              .onClick(() => { this.runMotion(() => { this.showConfigToml = false; }); })
          }
          .width('100%')

          TextArea({ text: this.configTomlContent, placeholder: '' })
            .width('100%')
            .height(this.configTomlEditorHeight())
            .margin({ top: this.isPhoneBreakpoint() ? 12 : 14 })
            .fontSize(this.isPhoneBreakpoint() ? 11 : 12)
            .fontFamily('monospace')
            .backgroundColor(this.elevatedSurface())
            .border({ width: 1, color: '#E5E7EB' })
            .borderRadius(8)
            .padding(12)
            .onChange((value: string) => { this.configTomlContent = value; })

          Row() {
            Button('保存')
              .height(38)
              .layoutWeight(1)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .backgroundColor('#111827')
              .borderRadius(14)
              .onClick(() => { this.saveConfigToml(); })

            Button('关闭')
              .height(38)
              .layoutWeight(1)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textMuted())
              .backgroundColor('#F1F5F9')
              .borderRadius(14)
              .margin({ left: 10 })
              .onClick(() => { this.runMotion(() => { this.showConfigToml = false; }); })
          }
          .width('100%')
          .margin({ top: this.isPhoneBreakpoint() ? 14 : 18 })
        }
        .width(this.configTomlDialogWidth())
        .padding(this.configTomlDialogPadding())
        .backgroundColor(this.surface())
        .border({ width: 1, color: '#E2EAF3' })
        .borderRadius(this.isPhoneBreakpoint() ? 20 : 24)
      }
      .width('100%')
      .height('100%')
      .transition(this.dialogTransition())
    }
  }

  @Builder
  private sidebar() {
    Column() {
      Column() {
        ForEach(this.navItems, (item: SettingsNavItem) => {
          this.sidebarEntry(item)
        }, (item: SettingsNavItem) => item.tab)
      }

      Blank()
        .layoutWeight(1)

      Button() {
        Row() {
          Text('⚙')
            .fontSize(14)
            .margin({ right: 6 })
          Text('config.toml')
            .fontSize(12)
            .fontColor(this.textMuted())
        }
      }
      .width('100%')
      .height(36)
      .backgroundColor(this.elevatedSurface())
      .borderRadius(10)
      .border({ width: 1, color: '#E5E7EB' })
      .onClick(() => { this.openConfigToml(); })
    }
    .width(260)
    .height('100%')
    .padding(16)
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#E5E7EB' })
    .borderRadius(16)
  }

  @Builder
  private topTabs() {
    Scroll() {
      Row() {
        ForEach(this.navItems, (item: SettingsNavItem) => {
          this.topTabEntry(item)
        }, (item: SettingsNavItem) => item.tab)
      }
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#E5E7EB' })
    .borderRadius(16)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
  }

  @Builder
  private topTabEntry(item: SettingsNavItem) {
    Button() {
      Column() {
        Text(item.label)
          .copyOption(CopyOptions.None)
          .fontSize(13)
          .fontWeight(this.activeTab === item.tab ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.activeTab === item.tab ? this.textPrimary() : this.textMuted())

        if (this.activeTab === item.tab) {
          Column()
            .width(18)
            .height(3)
            .margin({ top: 5 })
            .backgroundColor(item.accent)
            .borderRadius(3)
        }
      }
      .padding({ left: 12, right: 12, top: 8, bottom: 6 })
    }
    .height(42)
    .margin({ right: 6 })
      .backgroundColor(this.activeTab === item.tab ? this.elevatedSurface() : this.surface())
      .border({ width: 1, color: this.activeTab === item.tab ? '#93C5FD' : '#EDF2F7' })
    .borderRadius(16)
    .scale({ x: this.pressScale(`top-nav-${item.tab}`), y: this.pressScale(`top-nav-${item.tab}`) })
    .animation({ duration: 140, curve: Curve.FastOutSlowIn })
    .onTouch((event: TouchEvent) => { this.updatePressed(`top-nav-${item.tab}`, event); })
    .onClick(() => {
      this.selectTab(item.tab);
    })
  }

  @Builder
  private sidebarHero() {
    Column() {
      Text('设置')
        .copyOption(CopyOptions.None)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textPrimary())
    }
    .width('100%')
    .padding(18)
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#DFE9F5' })
    .borderRadius(24)
  }

  @Builder
  private sidebarEntry(item: SettingsNavItem) {
    Button() {
      Row() {
        Column()
          .width(4)
          .height(20)
          .backgroundColor(this.activeTab === item.tab ? item.accent : 'transparent')
          .borderRadius(2)

        Column() {
          Text(item.label)
            .copyOption(CopyOptions.None)
            .fontSize(14)
            .fontWeight(this.activeTab === item.tab ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(this.activeTab === item.tab ? this.textPrimary() : this.textSecondary())

          Text(item.subtitle)
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor(this.activeTab === item.tab ? this.textSecondary() : this.textMuted())
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    }
    .width('100%')
    .margin({ top: 4 })
    .backgroundColor(this.activeTab === item.tab ? this.elevatedSurface() : 'transparent')
    .borderRadius(10)
    .scale({ x: this.pressScale(`nav-${item.tab}`), y: this.pressScale(`nav-${item.tab}`) })
    .animation({ duration: 140, curve: Curve.FastOutSlowIn })
    .onTouch((event: TouchEvent) => { this.updatePressed(`nav-${item.tab}`, event); })
    .onClick(() => {
      this.selectTab(item.tab);
    })
  }

  @Builder
  private sideFootnote() {
    Column() {
    }
    .width('100%')
  }

  @Builder
  private contentArea() {
    Scroll() {
      Column() {
        this.contentHero()

        if (this.activeTab === 'skills') {
          this.skillsPanel()
        } else if (this.activeTab === 'mcp') {
          this.mcpPanel()
        } else if (this.activeTab === 'prompts') {
          this.promptsPanel()
        } else {
          this.apiPanel()
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: this.settingsContentPadding(), right: this.settingsContentPadding(), top: 16, bottom: 28 })
    }
    .layoutWeight(1)
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#E5E7EB' })
    .borderRadius(16)
    .margin({ left: this.isPhoneBreakpoint() ? 0 : 16, top: this.isPhoneBreakpoint() ? 10 : 0 })
  }

  @Builder
  private phoneSettingsLayout() {
    Column() {
      this.topTabs()
      this.contentArea()
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 12 })
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  private wideSettingsLayout() {
    Row() {
      this.sidebar()
      this.contentArea()
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 24 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private contentHero() {
    Column() {
      Text(this.heroTitle())
        .copyOption(CopyOptions.None)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textPrimary())
      if (this.heroSubtitle().length > 0) {
        Text(this.heroSubtitle())
          .copyOption(CopyOptions.None)
          .fontSize(12)
          .fontColor(this.textSecondary())
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 16 })
  }

  private heroTitle(): string {
    switch (this.activeTab) {
      case 'mcp':
        return 'MCP 服务';
      case 'skills':
        return 'Skills 目录与安装管理';
      case 'prompts':
        return 'Prompt 套件与会话前置约束';
      default:
        return '服务商、模型与端点布局';
    }
  }

  private heroSubtitle(): string {
    switch (this.activeTab) {
      case 'mcp':
        return '连接和工具配置';
      case 'skills':
        return '';
      case 'prompts':
        return '';
      default:
        return '';
    }
  }

  @Builder
  private sectionCard(title: string, subtitle: string) {
    Column() {
      Text(title)
        .copyOption(CopyOptions.None)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textPrimary())
      if (subtitle.length > 0) {
        Text(subtitle)
          .copyOption(CopyOptions.None)
          .fontSize(11)
          .fontColor(this.textSecondary())
          .margin({ top: 4 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(18)
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#E2EAF3' })
    .borderRadius(22)
  }

  @Builder
  private pill(label: string, background: string, color: string) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontColor(color)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor(background)
      .borderRadius(10)
  }

  @Builder
  private actionButton(label: string, key: string, primary: boolean, onClick: () => void) {
    Button(label)
      .height(38)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(primary ? '#FFFFFF' : this.textPrimary())
      .backgroundColor(primary ? '#111827' : this.surface())
      .borderRadius(16)
      .border({ width: primary ? 0 : 1, color: '#D5E0ED' })
      .padding({ left: 16, right: 16 })
      .scale({ x: this.pressScale(key), y: this.pressScale(key) })
      .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent) => { this.updatePressed(key, event); })
      .onClick(onClick)
  }


  @Builder
  private formLabel(label: string, color: string = '') {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(color.length > 0 ? color : this.textPrimary())
      .margin({ top: 12 })
  }

  @Builder
  private tabBarBuilder(title: string, index: number) {
    Column() {
      Text(title)
        .fontSize(13)
        .fontWeight(this.skillsActiveSubTabIndex === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.skillsActiveSubTabIndex === index ? '#0A84FF' : '#475569')
        .margin({ bottom: 6 })
      Column()
        .width(24)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.skillsActiveSubTabIndex === index ? '#0A84FF' : 'transparent')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  private skillActionButton(label: string, key: string, color: string, bg: string, border: string, onClick: () => void) {
    Button(label)
      .height(30)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(color)
      .backgroundColor(bg)
      .borderRadius(10)
      .border({ width: 1, color: border })
      .padding({ left: 10, right: 10 })
      .margin({ left: 6 })
      .scale({ x: this.pressScale(key), y: this.pressScale(key) })
      .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent) => { this.updatePressed(key, event); })
      .onClick(onClick)
  }

  @Builder
  private skillsEmptyState(title: string, subtitle: string) {
    Column() {
      Text(title)
        .copyOption(CopyOptions.None)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textPrimary())
      Text(subtitle)
        .copyOption(CopyOptions.None)
        .fontSize(11)
        .fontColor(this.textMuted())
        .lineHeight(17)
        .margin({ top: 6 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(18)
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#E2EAF3' })
    .borderRadius(18)
  }

  @Builder
  private installedSkillsList() {
    Column() {
      if (this.installedSkills.length === 0) {
        this.skillsEmptyState('暂无已安装 Skills', '点击刷新重新扫描本机 Skills 目录。')
      } else {
        ForEach(this.installedSkills, (skill: InstalledSkill) => {
          Button() {
            Column() {
              Row() {
                Column() {
                  Text(skill.name)
                    .copyOption(CopyOptions.None)
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.textPrimary())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(skill.description)
                    .copyOption(CopyOptions.None)
                    .fontSize(11)
                    .fontColor(this.textMuted())
                    .lineHeight(17)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: skill.enabled })
                  .selectedColor('#16A34A')
                  .switchPointColor('#FFFFFF')
                  .width(44)
                  .height(22)
                  .onChange((isOn: boolean) => { this.toggleSkillEnabled(skill.id); })
              }
              .width('100%')
              Row() {
                Text(this.skillSourceText(skill))
                  .copyOption(CopyOptions.None)
                  .fontSize(10)
                  .fontColor(this.textMuted())
                Text(this.skillMetaText(skill))
                  .copyOption(CopyOptions.None)
                  .fontSize(10)
                  .fontColor(this.textMuted())
                  .margin({ left: 10 })
              }
              .width('100%')
              .margin({ top: 8 })
            }
            .width('100%')
            .padding(14)
          }
          .width('100%')
          .margin({ top: 8 })
          .backgroundColor(this.selectedSkillId === skill.id ? '#F0F9FF' : this.surface())
          .border({ width: 1, color: this.selectedSkillId === skill.id ? '#93C5FD' : '#E5E7EB' })
          .borderRadius(12)
          .onClick(() => { this.selectSkillForPreview(skill); })
        }, (skill: InstalledSkill) => `${skill.id}-${skill.enabled}`)
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private skillPreview() {
    Column() {
      if (this.selectedSkill() === null) {
        Column() {
          Text('请选择 Skill')
            .copyOption(CopyOptions.None)
            .fontSize(14)
            .fontColor(this.textSecondary())
        }
        .width('100%')
        .height(200)
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          Text(this.selectedSkill()!.name)
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textPrimary())
            .width('100%')
          Text(this.selectedSkill()!.description)
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(12)
            .fontColor(this.textSecondary())
            .lineHeight(20)
            .margin({ top: 12 })
            .width('100%')
          Column() {
            this.skillDetailRow('来源', this.skillSourceText(this.selectedSkill()!))
            this.skillDetailRow('目录', this.displaySkillDirectory(this.selectedSkill()!.directory))
            this.skillDetailRow('ID', this.selectedSkill()!.id)
            if (this.selectedSkill()!.source === 'github') {
              this.skillDetailRow('仓库', this.selectedSkill()!.repoOwner + '/' + this.selectedSkill()!.repoName)
              this.skillDetailRow('分支', this.selectedSkill()!.repoBranch)
            }
            if (this.selectedSkill()!.readmeUrl.length > 0) {
              this.skillDetailRow('README', this.selectedSkill()!.readmeUrl)
            }
            if (this.selectedSkill()!.installedAt > 0) {
              this.skillDetailRow('安装时间', new Date(this.selectedSkill()!.installedAt).toISOString().replace('T', ' ').substring(0, 19))
            }
            if (this.selectedSkill()!.updatedAt > 0) {
              this.skillDetailRow('更新时间', new Date(this.selectedSkill()!.updatedAt).toISOString().replace('T', ' ').substring(0, 19))
            }
            if (this.selectedSkill()!.contentHash.length > 0) {
              this.skillDetailRow('哈希', this.selectedSkill()!.contentHash.substring(0, 16) + '...')
            }
          }
          .width('100%')
          .margin({ top: 16 })
          .padding(14)
          .backgroundColor(this.elevatedSurface())
          .borderRadius(12)
          Row() {
            this.skillActionButton(
              '删除', `skill-preview-delete-${this.selectedSkill()!.id}`, '#EF4444', '#FEF2F2', '#FECACA',
              () => { this.requestUninstallSkill(this.selectedSkill()!.id); }
            )
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
          .margin({ top: 16 })
        }
        .width('100%')
        .padding(18)
        .backgroundColor(this.surface())
        .border({ width: 1, color: '#E5E7EB' })
        .borderRadius(14)
      }
    }
    .width('100%')
  }

  @Builder
  private skillDetailRow(label: string, value: string) {
    Row() {
      Text(label)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(11)
        .fontColor(this.textMuted())
        .width(70)
      Text(value)
        .copyOption(CopyOptions.LocalDevice)
        .fontSize(11)
        .fontColor('#334155')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: 8 })
  }

  @Builder
  private skillInstallPanel() {
    Column() {
      // 卡片 1：从 ZIP 安装
      Row() {
        Column() {
          Text('从 ZIP 安装')
            .copyOption(CopyOptions.None).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.textPrimary())
          Text('选择包含 SKILL.md 的 ZIP 文件')
            .copyOption(CopyOptions.None).fontSize(11).fontColor(this.textMuted()).margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        this.actionButton('选择 ZIP 文件', 'zip-install', true, () => { this.pickAndInstallZip(); })
      }
      .width('100%').alignItems(VerticalAlign.Center).padding(18)
      .backgroundColor(this.surface()).border({ width: 1, color: '#E2EAF3' }).borderRadius(18)
      .margin({ top: 16 })

      // 卡片 2：从本地目录安装
      Row() {
        Column() {
          Text('从本地目录安装')
            .copyOption(CopyOptions.None).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.textPrimary())
          Text('选择包含 SKILL.md 的目录')
            .copyOption(CopyOptions.None).fontSize(11).fontColor(this.textMuted()).margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        this.actionButton('选择目录', 'dir-install', true, () => { this.pickAndInstallDirectory(); })
      }
      .width('100%').alignItems(VerticalAlign.Center).padding(18)
      .backgroundColor(this.surface()).border({ width: 1, color: '#E2EAF3' }).borderRadius(18)
      .margin({ top: 16 })

      // 卡片 3：从 skills.sh 搜索
      Column() {
        Row() {
          Column() {
            Text('从 skills.sh 搜索')
              .copyOption(CopyOptions.None).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.textPrimary())
            Text('搜索公开 Skill 目录')
              .copyOption(CopyOptions.None).fontSize(11).fontColor(this.textMuted()).margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 12 })
        Row() {
          TextInput({ text: this.skillsShQuery, placeholder: '搜索 Skill...' })
            .layoutWeight(1).height(40).backgroundColor(this.elevatedSurface()).borderRadius(14)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => { this.skillsShQuery = value; })
          Column() {
            this.actionButton(this.skillsShSearching ? '搜索中...' : '搜索', 'skillsh-search', !this.skillsShSearching, () => { this.searchSkillsShAction(); })
          }
          .margin({ left: 10 })
        }
        .width('100%')
        if (this.skillsShResults.length > 0) {
          Scroll() {
            Column() {
              ForEach(this.skillsShResults, (item: SkillsShItem) => {
                Row() {
                  Column() {
                    Text(item.name)
                      .copyOption(CopyOptions.None).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.textPrimary())
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${item.repoOwner}/${item.repoName} · ${item.installs} 次安装`)
                        .copyOption(CopyOptions.None).fontSize(10).fontColor(this.textMuted()).margin({ top: 4 })
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Column() {
                    this.actionButton(
                      this.isSkillInstalling(item.key) ? '安装中...' : '安装',
                      `skillsh-install-${item.key}`,
                      !this.isSkillInstalling(item.key),
                      () => { this.installFromSkillsSh(item); }
                    )
                  }
                  .margin({ left: 12 })
                }
                .width('100%').padding(14).backgroundColor(this.surface())
                .border({ width: 1, color: '#E2EAF3' }).borderRadius(14).margin({ top: 8 })
              }, (item: SkillsShItem) => `${item.key}`)
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: this.skillsResultListMaxHeight() })
          .scrollBar(BarState.Auto)
          .margin({ top: 8 })
        }
      }
      .width('100%').padding(18)
      .backgroundColor(this.surface()).border({ width: 1, color: '#E2EAF3' }).borderRadius(18)
      .margin({ top: 16 })

      // 卡片 4：从 GitHub 安装
      Column() {
        Row() {
          Column() {
            Text('从 GitHub 安装')
              .copyOption(CopyOptions.None).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.textPrimary())
            Text('粘贴仓库 URL，扫描并安装 Skill')
              .copyOption(CopyOptions.None).fontSize(11).fontColor(this.textMuted()).margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 12 })
        Row() {
          TextInput({ text: this.githubRepoUrl, placeholder: 'https://github.com/owner/repo' })
            .layoutWeight(1).height(40).backgroundColor(this.elevatedSurface()).borderRadius(14)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => { this.githubRepoUrl = value; })
          Column() {
            this.actionButton(this.githubScanning ? '扫描中...' : '扫描', 'github-scan', !this.githubScanning, () => { this.scanGithubRepo(); })
          }
          .margin({ left: 10 })
        }
        .width('100%')
        if (this.githubScanResults.length > 0) {
          Column() {
            ForEach(this.githubScanResults, (skill: DiscoverableSkill) => {
              Row() {
                Column() {
                  Text(skill.name)
                    .copyOption(CopyOptions.None).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.textPrimary())
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(skill.description)
                    .copyOption(CopyOptions.None).fontSize(11).fontColor(this.textMuted()).lineHeight(17)
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 4 })
                  Text(this.displaySkillDirectory(skill.directory))
                    .copyOption(CopyOptions.None).fontSize(10).fontColor(this.textMuted()).margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                Column() {
                  this.actionButton(
                    this.isSkillInstalling(skill.key) ? '安装中...' : '安装',
                    `github-install-${skill.key}`,
                    !this.isSkillInstalling(skill.key),
                    () => { this.installScannedSkill(skill); }
                  )
                }
                .margin({ left: 12 })
              }
              .width('100%').padding(14).backgroundColor(this.surface())
              .border({ width: 1, color: '#E2EAF3' }).borderRadius(14).margin({ top: 8 })
            }, (skill: DiscoverableSkill) => skill.key)
          }
          .width('100%')
          .margin({ top: 8 })
        }
      }
      .width('100%').padding(18)
      .backgroundColor(this.surface()).border({ width: 1, color: '#E2EAF3' }).borderRadius(18)
      .margin({ top: 16 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private skillsPanel() {
    if (this.animatedMode !== 'desktop' && this.selectedSkillId.length > 0) {
      this.phoneSkillPreviewView()
    } else {
      this.skillsListPreviewLayout()
    }
  }

  @Builder
  private phoneSkillPreviewView() {
    Column() {
      Row() {
        Button('← 返回列表')
          .fontSize(12).height(28).backgroundColor(this.surface()).fontColor(this.textPrimary())
          .borderRadius(14).border({ width: 1, color: '#CBD5E1' })
          .onClick(() => { this.runMotion(() => { this.selectedSkillId = ''; this.selectedSkillDetail = null; }, 180); })
      }
      .width('100%').margin({ bottom: 12 })
      this.skillPreview()
    }
    .width('100%')
  }

  @Builder
  private skillsListPreviewLayout() {
    Column() {
      Row() {
        Column() {
          Row() {
            Text('Skills 管理')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textPrimary())
            Blank().layoutWeight(1)
            this.actionButton('刷新', 'skill-refresh-current', false, () => { this.refreshActiveSkillsSubTab(); })
          }
          .width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 12 })
          Text(this.skillsStatusText)
            .copyOption(CopyOptions.None).fontSize(11)
            .fontColor(skillsVM.state.errorText.trim().length > 0 ? '#B91C1C' : '#64748B')
            .margin({ bottom: 8 })
            .visibility(this.skillsStatusText.length > 0 ? Visibility.Visible : Visibility.None)
          Tabs({ barPosition: BarPosition.Start, index: this.skillsActiveSubTabIndex }) {
            TabContent() {
              this.installedSkillsList()
            }
            .tabBar(this.tabBarBuilder('已安装', 0))
            TabContent() {
              this.skillInstallPanel()
            }
            .tabBar(this.tabBarBuilder('安装', 1))
          }
          .barMode(BarMode.Fixed)
          .onChange((index: number) => { this.switchSkillsSubTab(this.skillsSubTabByIndex(index)); })
          .width('100%')
        }
        .width(this.animatedMode !== 'desktop' ? '100%' : '38%')

        if (this.animatedMode === 'desktop') {
          Column() { this.skillPreview() }
            .layoutWeight(1).margin({ left: 16 })
            .transition(this.panelTransition())
        }
      }
      .width('100%').alignItems(VerticalAlign.Top).margin({ top: 18 })
    }
    .width('100%')
  }

  @Builder
  private skillDeleteDialog() {
    if (this.showSkillDeleteDialog) {
      Stack() {
        Column()
          .width('100%').height('100%').backgroundColor('#0F172A').opacity(0.18).animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .onClick(() => { this.cancelUninstallSkill(); })
        Column() {
          Row() {
            Text('删除 Skill')
              .copyOption(CopyOptions.None).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            Blank().layoutWeight(1)
            Button() {
              Text('×').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            }
              .type(ButtonType.Normal)
              .accessibilityText('关闭')
              .width(32).height(32)
              .fontSize(20).fontColor(this.textSecondary())
              .backgroundColor('#E2E8F0').borderRadius(10)
              .border({ width: 1, color: '#CBD5E1' })
              .onClick(() => { this.cancelUninstallSkill(); })
          }
          .width('100%')
          Row() {
            Button('取消')
              .height(40).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.textSecondary()).backgroundColor(this.surface()).borderRadius(14)
              .border({ width: 1, color: '#D5E0ED' })
              .scale({ x: this.pressScale('skill-delete-cancel'), y: this.pressScale('skill-delete-cancel') })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed('skill-delete-cancel', event); })
              .onClick(() => { this.cancelUninstallSkill(); })
            Button('确认删除')
              .height(40).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF').backgroundColor('#F97373').borderRadius(14).margin({ left: 12 })
              .scale({ x: this.pressScale('skill-delete-confirm'), y: this.pressScale('skill-delete-confirm') })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed('skill-delete-confirm', event); })
              .enabled(!this.skillBusy)
              .onClick(() => { this.confirmUninstallSkill(); })
          }
          .width('100%').margin({ top: 20 })
        }
        .width(this.settingsDialogWidth()).padding(22).backgroundColor(this.surface())
        .border({ width: 1, color: '#E2EAF3' }).borderRadius(24)
      }
      .width('100%').height('100%')
      .transition(this.dialogTransition())
    }
  }

  @Builder
  private skillDetailDialog() {
    if (this.showSkillDetailDialog && this.selectedSkillDetail !== null) {
      Stack() {
        Column()
          .width('100%').height('100%').backgroundColor('#0F172A').opacity(0.18).animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .onClick(() => { this.closeSkillDetail(); })
        Column() {
          Row() {
            Text(this.selectedSkillDetail.name)
              .copyOption(CopyOptions.LocalDevice).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.textPrimary()).layoutWeight(1)
            Text(this.selectedSkillDetail.enabled ? '启用' : '禁用')
              .copyOption(CopyOptions.None).fontSize(11)
              .fontColor(this.selectedSkillDetail.enabled ? '#16A34A' : '#64748B')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(this.selectedSkillDetail.enabled ? '#DCFCE7' : '#F5F7FA').borderRadius(8)
          }
          .width('100%').alignItems(VerticalAlign.Center)
          Text(this.selectedSkillDetail.description)
            .copyOption(CopyOptions.LocalDevice).fontSize(12).fontColor(this.textSecondary())
            .lineHeight(20).margin({ top: 10 }).width('100%')
          Column() {
            this.skillDetailRow('来源', this.skillDetailSourceLabel())
            this.skillDetailRow('目录', this.displaySkillDirectory(this.selectedSkillDetail.directory))
            this.skillDetailRow('ID', this.selectedSkillDetail.id)
            if (this.selectedSkillDetail.source === 'github') {
              this.skillDetailRow('仓库', this.selectedSkillDetail.repoOwner + '/' + this.selectedSkillDetail.repoName)
              this.skillDetailRow('分支', this.selectedSkillDetail.repoBranch)
            }
            if (this.selectedSkillDetail.readmeUrl.length > 0) {
              this.skillDetailRow('README', this.selectedSkillDetail.readmeUrl)
            }
            this.skillDetailRow('安装时间', this.skillDetailInstalledDate())
            this.skillDetailRow('更新时间', this.skillDetailUpdatedDate())
            if (this.selectedSkillDetail.contentHash.length > 0) {
              this.skillDetailRow('内容哈希', this.selectedSkillDetail.contentHash.substring(0, 16) + '...')
            }
          }
          .width('100%').margin({ top: 16 })
          .padding({ top: 14, bottom: 14, left: 14, right: 14 })
          .backgroundColor(this.elevatedSurface()).borderRadius(12)
          Row() {
            Button('关闭')
              .height(40).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.textSecondary()).backgroundColor(this.surface()).borderRadius(14)
              .border({ width: 1, color: '#D5E0ED' })
              .scale({ x: this.pressScale('skill-detail-close'), y: this.pressScale('skill-detail-close') })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed('skill-detail-close', event); })
              .onClick(() => { this.closeSkillDetail(); })
          }
          .width('100%').margin({ top: 20 })
        }
        .width(this.settingsDialogWidth()).padding(22).backgroundColor(this.surface())
        .border({ width: 1, color: '#E2EAF3' }).borderRadius(24)
      }
      .width('100%').height('100%')
      .transition(this.dialogTransition())
    }
  }

  @Builder
  private mcpServerCard(server: McpServerRecord) {
    Column() {
      Row() {
        Column() {
          Text(server.name)
            .copyOption(CopyOptions.None).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.textPrimary())
          Text(server.id)
            .copyOption(CopyOptions.None).fontSize(10).fontColor(this.textMuted()).margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        Blank().layoutWeight(1)
        this.pill(this.healthLabel(server.healthStatus), this.statusChipBackground(server.healthStatus), this.statusChipColor(server.healthStatus))
      }
      .width('100%')
      Row() {
        Toggle({ type: ToggleType.Switch, isOn: server.enabled })
          .selectedColor('#16A34A')
          .switchPointColor('#FFFFFF')
          .width(44)
          .height(22)
          .onChange((isOn: boolean) => { this.toggleMcpEnabled(server.id); })
        this.pill(this.authLabel(server.authStatus), this.statusChipBackground(server.authStatus), this.statusChipColor(server.authStatus))
      }
      .width('100%').margin({ top: 10 }).alignItems(VerticalAlign.Center)
      Text(`${server.toolCount} 个工具 · ${server.resourceCount} 个资源 · ${server.transportType}`)
        .copyOption(CopyOptions.None).fontSize(10).fontColor(this.textMuted()).margin({ top: 10 })
    }
    .width('100%').padding(16)
    .width('100%').margin({ top: 10 })
    .backgroundColor(this.selectedMcpServerId === server.id ? '#F8FBFF' : '#FFFFFF')
    .border({ width: 1.3, color: this.selectedMcpServerId === server.id ? '#0A84FF' : '#E2EAF3' })
    .borderRadius(22)
    .scale({ x: this.pressScale(`mcp-${server.id}`), y: this.pressScale(`mcp-${server.id}`) })
    .animation({ duration: 140, curve: Curve.FastOutSlowIn })
    .onTouch((event: TouchEvent) => { this.updatePressed(`mcp-${server.id}`, event); })
    .onClick(() => {
      this.loadMcpDraft(server.id);
      this.triggerFeedback(`已切换到 ${server.name} 草稿。`, 'info');
    })
  }

  @Builder
  private mcpEditorCard() {
    Column() {
      if (this.selectedMcpServer() === null) {
        Column() {
          Text('请选择服务')
            .copyOption(CopyOptions.None)
            .fontSize(14).fontColor(this.textSecondary()).margin({ top: 24 })
        }
        .width('100%').height(200).alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center)
        .backgroundColor(this.surface()).border({ width: 1, color: '#E2EAF3' }).borderRadius(22)
      } else {
        Column() {
          Row() {
            Column() {
              Text(this.selectedMcpServer()!.name)
                .copyOption(CopyOptions.None).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.textPrimary())
              Text(this.selectedMcpServer()!.id)
                .copyOption(CopyOptions.None).fontSize(11).fontColor(this.textMuted()).margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            this.pill(this.healthLabel(this.selectedMcpServer()!.healthStatus), this.statusChipBackground(this.selectedMcpServer()!.healthStatus), this.statusChipColor(this.selectedMcpServer()!.healthStatus))
            this.pill(this.authLabel(this.selectedMcpServer()!.authStatus), this.statusChipBackground(this.selectedMcpServer()!.authStatus), this.statusChipColor(this.selectedMcpServer()!.authStatus))
          }
          .width('100%')
          if (this.mcpStatusText.length > 0) {
            Text(this.mcpStatusText)
              .copyOption(CopyOptions.None).fontSize(12).fontColor('#334155').margin({ top: 10 })
          }
          Divider().margin({ top: 14 }).color('#F1F5F9')
          this.formLabel('传输方式')
          Row() {
            Button('stdio')
              .type(ButtonType.Normal)
              .fontSize(11)
              .fontWeight(this.mcpTransportTypeDraft === 'stdio' ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.mcpTransportTypeDraft === 'stdio' ? '#0A84FF' : '#475569')
              .backgroundColor(this.mcpTransportTypeDraft === 'stdio' ? '#EAF3FF' : '#F8FAFC')
              .borderRadius(12)
              .border({ width: 1, color: this.mcpTransportTypeDraft === 'stdio' ? '#BFDBFE' : '#DCE5EF' })
              .height(32)
              .padding({ left: 14, right: 14 })
              .margin({ right: 8 })
              .onClick(() => { this.mcpTransportTypeDraft = 'stdio'; })
            Button('http')
              .type(ButtonType.Normal)
              .fontSize(11)
              .fontWeight(this.mcpTransportTypeDraft === 'http' ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.mcpTransportTypeDraft === 'http' ? '#0A84FF' : '#475569')
              .backgroundColor(this.mcpTransportTypeDraft === 'http' ? '#EAF3FF' : '#F8FAFC')
              .borderRadius(12)
              .border({ width: 1, color: this.mcpTransportTypeDraft === 'http' ? '#BFDBFE' : '#DCE5EF' })
              .height(32)
              .padding({ left: 14, right: 14 })
              .onClick(() => { this.mcpTransportTypeDraft = 'http'; })
          }
          this.formLabel('启用状态')
          Toggle({ type: ToggleType.Switch, isOn: this.mcpEnabledDraft })
            .selectedColor('#16A34A')
            .switchPointColor('#FFFFFF')
            .width(44)
            .height(22)
            .margin({ top: 6 })
            .onChange((isOn: boolean) => { this.mcpEnabledDraft = isOn; })
          if (this.mcpTransportTypeDraft === 'stdio') {
            this.formLabel('命令')
            TextInput({ text: this.mcpCommandDraft, placeholder: '例如 npx / node / 可执行文件路径' })
              .width('100%').height(40).backgroundColor(this.elevatedSurface()).borderRadius(14)
              .padding({ left: 12, right: 12 }).margin({ top: 6 })
              .onChange((value: string) => { this.mcpCommandDraft = value; })
            this.formLabel('参数 JSON')
            TextInput({ text: this.mcpArgsDraft, placeholder: '["--flag"]' })
              .width('100%').height(40).backgroundColor(this.elevatedSurface()).borderRadius(14)
              .padding({ left: 12, right: 12 }).margin({ top: 6 })
              .onChange((value: string) => { this.mcpArgsDraft = value; })
          }
          if (this.mcpTransportTypeDraft === 'http') {
            this.formLabel('URL')
            TextInput({ text: this.mcpUrlDraft, placeholder: 'https://example.com/mcp' })
              .width('100%').height(40).backgroundColor(this.elevatedSurface()).borderRadius(14)
              .padding({ left: 12, right: 12 }).margin({ top: 6 })
              .onChange((value: string) => { this.mcpUrlDraft = value; })
            this.formLabel('HTTP 请求头')
            TextArea({ text: this.mcpHttpHeadersDraft, placeholder: '{"Authorization":"Bearer your-token"}' })
              .width('100%').height(94).backgroundColor(this.elevatedSurface()).borderRadius(16)
              .padding(12).margin({ top: 6 })
              .onChange((value: string) => { this.mcpHttpHeadersDraft = value; })
          }
          this.formLabel('环境变量')
          TextArea({ text: this.mcpEnvDraft, placeholder: '{"KEY":"VALUE"}' })
            .width('100%').height(94).backgroundColor(this.elevatedSurface()).borderRadius(16)
            .padding(12).margin({ top: 6 })
            .onChange((value: string) => { this.mcpEnvDraft = value; })
          Divider().margin({ top: 16 }).color('#F1F5F9')
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
            this.actionButton('删除服务', 'mcp-delete', false, () => { this.openMcpDeleteDialog(); })
            this.actionButton('OAuth 登录', 'mcp-oauth', false, () => { this.startSelectedMcpOauth(); })
            this.actionButton('放弃更改', 'mcp-revert', false, () => { this.revertMcpDraft(); })
            this.actionButton('保存配置', 'mcp-save', true, () => { this.saveMcpDraft(); })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('100%').padding(18)
        .backgroundColor(this.surface()).border({ width: 1, color: '#E2EAF3' }).borderRadius(22)
      }
    }
    .width('100%')
  }

  @Builder
  private mcpPanel() {
    if (this.animatedMode !== 'desktop' && this.selectedMcpServerId.length > 0) {
      this.phoneMcpEditorView()
    } else {
      this.mcpListEditorLayout()
    }
  }

  @Builder
  private phoneMcpEditorView() {
    Column() {
      Row() {
        Button('← 返回列表')
          .fontSize(12).height(28).backgroundColor(this.surface()).fontColor(this.textPrimary())
          .borderRadius(14).border({ width: 1, color: '#CBD5E1' })
          .onClick(() => { this.runMotion(() => { this.selectedMcpServerId = ''; }, 180); })
        Blank().layoutWeight(1)
        Button('重载 MCP')
          .height(28).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor(this.textSecondary()).backgroundColor(this.elevatedSurface())
          .borderRadius(12).border({ width: 1, color: '#DCE5EF' })
          .padding({ left: 12, right: 12 })
          .onClick(() => { this.reloadMcpDraft(); })
      }
      .width('100%').margin({ bottom: 12 })
      this.mcpEditorCard()
    }
    .width('100%').margin({ top: 18 })
  }

  @Builder
  private mcpListEditorLayout() {
    Column() {
      if (this.mcpLoading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
          Text('加载 MCP...')
            .copyOption(CopyOptions.None)
            .fontSize(14)
            .fontColor(this.textSecondary())
            .margin({ top: 12 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 100 })
      } else {
      Row() {
        Column() {
          this.sectionCard('服务器', '选择服务，编辑配置')
          if (this.mcpServers.length === 0) {
            Column() {
              Text('暂无服务')
                .copyOption(CopyOptions.None).fontSize(14).fontColor(this.textSecondary()).margin({ top: 24 })
            }
            .width('100%').alignItems(HorizontalAlign.Center)
          }
          Column() {
            ForEach(this.mcpServers, (server: McpServerRecord) => {
              this.mcpServerCard(server)
            }, (server: McpServerRecord) => server.id)
          }
          .width('100%').margin({ top: 12 })
          Button('添加服务')
            .width('100%').height(40).margin({ top: 10 }).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor('#0A84FF').backgroundColor('#F0F7FF').borderRadius(16)
            .border({ width: 1, color: '#BDD7FF' })
            .scale({ x: this.pressScale('mcp-add'), y: this.pressScale('mcp-add') })
            .animation({ duration: 140, curve: Curve.FastOutSlowIn })
            .onTouch((event: TouchEvent) => { this.updatePressed('mcp-add', event); })
            .onClick(() => { this.openMcpAddDialog(); })
        }
        .width(this.animatedMode !== 'desktop' ? '100%' : '34%')

        if (this.animatedMode === 'desktop') {
          Column() {
            Row() {
              Blank()
              Button('重载 MCP')
                .height(32).fontSize(12).fontWeight(FontWeight.Medium)
                .fontColor(this.textSecondary()).backgroundColor(this.elevatedSurface())
                .borderRadius(12).border({ width: 1, color: '#DCE5EF' })
                .padding({ left: 12, right: 12 })
                .onClick(() => { this.reloadMcpDraft(); })
            }
            .width('100%').margin({ bottom: 10 })
            this.mcpEditorCard()
          }
          .layoutWeight(1).margin({ left: 16 })
          .transition(this.panelTransition())
        }
      }
      .width('100%').alignItems(VerticalAlign.Top)
      }
    }
    .width('100%').margin({ top: 18 })
  }

  @Builder
  private mcpAddDialog() {
    if (this.showMcpAddDialog) {
      Stack() {
        Column()
          .width('100%').height('100%').backgroundColor('#0F172A').opacity(0.18).animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .onClick(() => { this.cancelMcpAdd(); })
        Column() {
          Row() {
            Text('新增 MCP 服务')
              .copyOption(CopyOptions.None).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            Blank().layoutWeight(1)
            Button() {
              Text('×').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            }
              .type(ButtonType.Normal)
              .accessibilityText('关闭')
              .width(32).height(32)
              .fontSize(20).fontColor(this.textSecondary())
              .backgroundColor('#E2E8F0').borderRadius(10)
              .border({ width: 1, color: '#CBD5E1' })
              .onClick(() => { this.cancelMcpAdd(); })
          }
          .width('100%')
          Text('粘贴 JSON 配置添加服务')
            .copyOption(CopyOptions.None).fontSize(12).fontColor(this.textMuted()).lineHeight(20).margin({ top: 10 })
            TextInput({ text: this.mcpNewServerName, placeholder: '名称（可选）' })
            .width('100%').height(40).backgroundColor(this.elevatedSurface()).borderRadius(14)
            .padding({ left: 12, right: 12 }).margin({ top: 12 })
            .onChange((value: string) => { this.mcpNewServerName = value; })
          TextArea({ text: this.mcpJsonPasteInput, placeholder: '粘贴 MCP JSON 配置' })
            .width('100%').height(150).backgroundColor(this.elevatedSurface()).borderRadius(16)
            .padding(12).margin({ top: 10 })
            .onChange((value: string) => { this.mcpJsonPasteInput = value; })
          Column() {
            Text(this.mcpAddPreviewText())
              .copyOption(CopyOptions.None).fontSize(11).fontColor(this.textSecondary()).lineHeight(18)
          }
          .width('100%').padding(10).margin({ top: 8 })
          .backgroundColor('#F1F5F9').borderRadius(12)
          Row() {
            Button('取消')
              .height(40).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.textSecondary()).backgroundColor(this.surface()).borderRadius(14)
              .border({ width: 1, color: '#D5E0ED' })
              .scale({ x: this.pressScale('mcp-add-cancel'), y: this.pressScale('mcp-add-cancel') })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed('mcp-add-cancel', event); })
              .onClick(() => { this.cancelMcpAdd(); })
            Button('添加')
              .height(40).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF').backgroundColor('#0A84FF').borderRadius(14).margin({ left: 12 })
              .scale({ x: this.pressScale('mcp-add-confirm'), y: this.pressScale('mcp-add-confirm') })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed('mcp-add-confirm', event); })
              .enabled(!this.mcpBusy)
              .onClick(() => { this.confirmMcpAdd(); })
          }
          .width('100%').margin({ top: 14 })
        }
        .width(this.settingsDialogWidth()).padding(22).backgroundColor(this.surface())
        .border({ width: 1, color: '#E2EAF3' }).borderRadius(24)
      }
      .width('100%').height('100%')
      .transition(this.dialogTransition())
    }
  }

  @Builder
  private mcpDeleteDialog() {
    if (this.showMcpDeleteDialog) {
      Stack() {
        Column()
          .width('100%').height('100%').backgroundColor('#0F172A').opacity(0.18).animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .onClick(() => { this.cancelMcpDelete(); })
        Column() {
          Row() {
            Text('删除 MCP 服务')
              .copyOption(CopyOptions.None).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            Blank().layoutWeight(1)
            Button() {
              Text('×').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            }
              .type(ButtonType.Normal)
              .accessibilityText('关闭')
              .width(32).height(32)
              .fontSize(20).fontColor(this.textSecondary())
              .backgroundColor('#E2E8F0').borderRadius(10)
              .border({ width: 1, color: '#CBD5E1' })
              .onClick(() => { this.cancelMcpDelete(); })
          }
          .width('100%')
          Text(`移除 "${this.pendingDeleteMcpName}"，且无法恢复。`)
            .copyOption(CopyOptions.None).fontSize(12).fontColor(this.textMuted()).lineHeight(20).margin({ top: 10 })
          Row() {
            Button('取消')
              .height(40).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.textSecondary()).backgroundColor(this.surface()).borderRadius(14)
              .border({ width: 1, color: '#D5E0ED' })
              .scale({ x: this.pressScale('mcp-delete-cancel'), y: this.pressScale('mcp-delete-cancel') })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed('mcp-delete-cancel', event); })
              .onClick(() => { this.cancelMcpDelete(); })
            Button('确认删除')
              .height(40).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF').backgroundColor('#F97373').borderRadius(14).margin({ left: 12 })
              .scale({ x: this.pressScale('mcp-delete-confirm'), y: this.pressScale('mcp-delete-confirm') })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed('mcp-delete-confirm', event); })
              .enabled(!this.mcpBusy)
              .onClick(() => { this.confirmMcpDelete(); })
          }
          .width('100%').margin({ top: 20 })
        }
        .width(this.settingsDialogWidth()).padding(22).backgroundColor(this.surface())
        .border({ width: 1, color: '#E2EAF3' }).borderRadius(24)
      }
      .width('100%').height('100%')
      .transition(this.dialogTransition())
    }
  }

  @Builder
  private promptDeleteDialog() {
    if (this.showPromptDeleteDialog) {
      Stack() {
        Column()
          .width('100%').height('100%').backgroundColor('#0F172A').opacity(0.18).animation({ duration: 220, curve: Curve.FastOutSlowIn })
          .onClick(() => { this.cancelDeletePrompt(); })
        Column() {
          Row() {
            Text('删除 Prompt')
              .copyOption(CopyOptions.None).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            Blank().layoutWeight(1)
            Button() {
              Text('×').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            }
              .type(ButtonType.Normal)
              .accessibilityText('关闭')
              .width(32).height(32)
              .fontSize(20).fontColor(this.textSecondary())
              .backgroundColor('#E2E8F0').borderRadius(10)
              .border({ width: 1, color: '#CBD5E1' })
              .onClick(() => { this.cancelDeletePrompt(); })
          }
          .width('100%')
          Text(`确认删除 "${this.pendingDeletePromptName}" 吗？`)
            .copyOption(CopyOptions.None).fontSize(12).fontColor(this.textMuted()).lineHeight(20).margin({ top: 10 })
          Row() {
            Button('取消')
              .height(40).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.textSecondary()).backgroundColor(this.surface()).borderRadius(14)
              .border({ width: 1, color: '#D5E0ED' })
              .scale({ x: this.pressScale('prompt-delete-cancel'), y: this.pressScale('prompt-delete-cancel') })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed('prompt-delete-cancel', event); })
              .onClick(() => { this.cancelDeletePrompt(); })
            Button('确认删除')
              .height(40).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF').backgroundColor('#F97373').borderRadius(14).margin({ left: 12 })
              .scale({ x: this.pressScale('prompt-delete-confirm'), y: this.pressScale('prompt-delete-confirm') })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed('prompt-delete-confirm', event); })
              .enabled(!this.promptBusy)
              .onClick(() => { this.confirmDeletePrompt(); })
          }
          .width('100%').margin({ top: 20 })
        }
        .width(this.settingsDialogWidth()).padding(22).backgroundColor(this.surface())
        .border({ width: 1, color: '#E2EAF3' }).borderRadius(24)
      }
      .width('100%').height('100%')
      .transition(this.dialogTransition())
    }
  }

  @Builder
  private promptsPanel() {
    if (this.animatedMode !== 'desktop' && this.selectedPromptId.length > 0) {
      this.phonePromptEditorView()
    } else {
      this.promptsListEditorLayout()
    }
  }

  @Builder
  private phonePromptEditorView() {
    Column() {
      Row() {
        Button('← 返回列表')
          .fontSize(12)
          .height(28)
          .backgroundColor(this.surface())
          .fontColor(this.textSecondary())
          .borderRadius(14)
          .border({ width: 1, color: '#CBD5E1' })
          .onClick(() => {
            this.runMotion(() => {
              this.selectedPromptId = '';
            }, 180);
          })
      }
      .width('100%')
      .margin({ bottom: 12 })

      this.promptEditor()
    }
    .width('100%')
  }

  @Builder
  private promptsListEditorLayout() {
    Column() {
      Row() {
        Column() {
          Row() {
            Button('刷新')
              .fontSize(12)
              .height(28)
              .backgroundColor(this.surface())
              .fontColor('#334155')
              .borderRadius(14)
              .border({ width: 1, color: '#CBD5E1' })
              .onClick(() => {
                this.promptsViewModel.loadAll()
                  .then(() => {
                    this.syncPromptsStateFromViewModel();
                    this.triggerFeedback('已刷新', 'success');
                  })
                  .catch((err: Object) => {
                    this.promptsStatusText = this.describeRuntimeError(err);
                    this.triggerFeedback(this.promptsStatusText, 'error');
                  });
              })
            Button('新增')
              .fontSize(12)
              .height(28)
              .backgroundColor('#F59E0B')
              .fontColor('#FFFFFF')
              .borderRadius(14)
              .onClick(() => {
                this.createNewPrompt();
              })
              .margin({ left: 8 })
          }
          .width('100%')
          .margin({ bottom: 12 })

          this.sectionCard('Prompt 列表', '')

          Column() {
            ForEach(this.prompts, (prompt: PromptRecord) => {
              this.promptCard(prompt)
            }, (prompt: PromptRecord) => `${prompt.id}-${prompt.enabled}`)
          }
          .width('100%')
          .margin({ top: 12 })
        }
        .width(this.animatedMode !== 'desktop' ? '100%' : '38%')

        if (this.animatedMode === 'desktop') {
          Column() {
            this.promptEditor()
          }
          .layoutWeight(1)
          .margin({ left: 16 })
          .transition(this.panelTransition())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 18 })
    }
    .width('100%')
  }

  @Builder
  private promptCard(prompt: PromptRecord) {
    Button() {
      Column() {
        Row() {
          Column() {
            Text(prompt.name)
              .copyOption(CopyOptions.None)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textPrimary())
            Text(prompt.description)
              .copyOption(CopyOptions.None)
              .fontSize(11)
              .fontColor(this.textMuted())
              .lineHeight(18)
              .margin({ top: 6 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          this.pill(prompt.enabled ? '已启用' : '草稿', prompt.enabled ? '#DCFCE7' : '#F1F5F9', prompt.enabled ? '#166534' : '#64748B')
        }
        .width('100%')

        Row() {
          Text(`更新于 ${this.formatTimestamp(prompt.updatedAt > 0 ? prompt.updatedAt : prompt.createdAt)}`)
            .copyOption(CopyOptions.None)
            .fontSize(10)
            .fontColor(this.textMuted())
            .layoutWeight(1)

          Button(prompt.enabled ? '禁用' : '启用')
            .fontSize(10)
            .height(24)
            .backgroundColor(prompt.enabled ? '#FEF3C7' : '#DCFCE7')
            .fontColor(prompt.enabled ? '#92400E' : '#166534')
            .borderRadius(12)
            .onClick(() => {
              this.togglePromptEnabled(prompt.id);
            })
            .margin({ right: 6 })

          Button('编辑')
            .fontSize(10)
            .height(24)
            .backgroundColor('#E0F2FE')
            .fontColor('#0C4A6E')
            .borderRadius(12)
            .onClick(() => {
              this.selectPrompt(prompt.id);
            })
            .margin({ right: 6 })

          Button('删除')
            .fontSize(10)
            .height(24)
            .backgroundColor('#FEE2E2')
            .fontColor('#991B1B')
            .borderRadius(12)
            .onClick(() => {
              this.requestDeletePrompt(prompt.id);
            })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .margin({ top: 10 })
    .backgroundColor(this.selectedPromptId === prompt.id ? '#FFFDF5' : '#FFFFFF')
    .border({ width: 1.3, color: this.selectedPromptId === prompt.id ? '#F59E0B' : '#E2EAF3' })
    .borderRadius(22)
    .scale({ x: this.pressScale(`prompt-${prompt.id}`), y: this.pressScale(`prompt-${prompt.id}`) })
    .animation({ duration: 140, curve: Curve.FastOutSlowIn })
    .onTouch((event: TouchEvent) => { this.updatePressed(`prompt-${prompt.id}`, event); })
    .onClick(() => { this.selectPrompt(prompt.id); })
  }

  @Builder
  private promptEditor() {
    Column() {
      this.sectionCard('Prompt 编辑器', '编辑内容并启用')

      Column() {
        Row() {
          if (this.selectedPrompt() !== null) {
            this.pill(this.selectedPrompt()!.enabled ? '会话就绪' : '仅草稿', this.selectedPrompt()!.enabled ? '#DCFCE7' : '#F1F5F9', this.selectedPrompt()!.enabled ? '#166534' : '#64748B')
          }
          this.pill(this.promptLiveContent.trim().length > 0 ? 'AGENTS.md 已同步' : 'AGENTS.md 为空', this.promptLiveContent.trim().length > 0 ? '#E0F2FE' : '#FEF3C7', this.promptLiveContent.trim().length > 0 ? '#0C4A6E' : '#92400E')
        }
        .width('100%')

        Text(this.promptsStatusText)
          .copyOption(CopyOptions.None)
          .fontSize(11)
          .fontColor(this.textMuted())
          .margin({ top: 10 })
          .width('100%')

        this.formLabel('名称', '#000000')
        TextInput({ text: this.promptDraftName, placeholder: 'Prompt 名称' })
          .width('100%')
          .height(40)
          .backgroundColor(this.elevatedSurface())
          .borderRadius(14)
          .padding({ left: 12, right: 12 })
          .margin({ top: 6 })
          .onChange((value: string) => { this.promptDraftName = value; })

        this.formLabel('摘要', '#000000')
        TextInput({ text: this.promptDraftSummary, placeholder: '一句话说明这个 Prompt 的作用' })
          .width('100%')
          .height(40)
          .backgroundColor(this.elevatedSurface())
          .borderRadius(14)
          .padding({ left: 12, right: 12 })
          .margin({ top: 6 })
          .onChange((value: string) => { this.promptDraftSummary = value; })

        this.formLabel('Prompt 内容', '#000000')
        TextArea({ text: this.promptDraftContent, placeholder: 'Prompt 内容' })
          .width('100%')
          .height(220)
          .backgroundColor(this.elevatedSurface())
          .borderRadius(18)
          .padding(14)
          .margin({ top: 6 })
          .onChange((value: string) => { this.promptDraftContent = value; })

        if (this.promptLiveContent.trim().length > 0) {
          this.formLabel('当前 AGENTS.md')
          Text(this.promptLiveContent)
            .copyOption(CopyOptions.None)
            .width('100%')
            .fontSize(11)
            .fontColor(this.textSecondary())
            .lineHeight(18)
            .padding(14)
            .backgroundColor(this.elevatedSurface())
            .borderRadius(18)
            .margin({ top: 6 })
            .maxLines(10)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        Row() {
          if (this.selectedPrompt() !== null) {
            this.actionButton(this.selectedPrompt()!.enabled ? '停用' : '启用', `prompt-toggle-${this.selectedPrompt()!.id}`, false, () => { this.togglePromptEnabled(this.selectedPrompt()!.id); })
          }
          Column() {
            this.actionButton('保存草稿', 'prompt-save', true, () => { this.savePromptDraft(); })
          }
          .margin({ left: 10 })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 18 })
      }
      .width('100%')
      .margin({ top: 12 })
      .padding(18)
      .backgroundColor(this.surface())
      .border({ width: 1, color: '#E2EAF3' })
      .borderRadius(22)
    }
    .width('100%')
  }

  @Builder
  private apiSubTabChip(label: string, tab: ApiSubTab) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(11)
      .fontWeight(this.apiActiveSubTab === tab ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.apiActiveSubTab === tab ? '#1D4ED8' : '#64748B')
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.apiActiveSubTab === tab ? '#EEF4FF' : '#F8FAFC')
      .border({ width: 1, color: this.apiActiveSubTab === tab ? '#BFDBFE' : '#E5E7EB' })
      .borderRadius(12)
      .margin({ right: 8 })
      .scale({ x: this.pressScale(`api-subtab-${tab}`), y: this.pressScale(`api-subtab-${tab}`) })
      .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent) => { this.updatePressed(`api-subtab-${tab}`, event); })
      .onClick(() => { this.runMotion(() => { this.apiActiveSubTab = tab; }, 180); })
  }

  @Builder
  private apiFilterChip(label: string, category: string) {
    Text(label)
      .copyOption(CopyOptions.None)
      .fontSize(10)
      .fontWeight(this.apiPresetCategory === category ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.apiPresetCategory === category ? '#1D4ED8' : '#64748B')
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(this.apiPresetCategory === category ? '#EEF4FF' : '#FFFFFF')
      .border({ width: 1, color: this.apiPresetCategory === category ? '#BFDBFE' : '#DCE7F3' })
      .borderRadius(10)
      .margin({ right: 8, top: 8 })
      .scale({ x: this.pressScale(`api-filter-${category}`), y: this.pressScale(`api-filter-${category}`) })
      .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent) => { this.updatePressed(`api-filter-${category}`, event); })
      .onClick(() => { this.runMotion(() => { this.apiPresetCategory = category; }, 180); })
  }

  @Builder
  private apiSpeedTestButton(provider: ProviderRecord) {
    Row() {
      if (this.apiSpeedTesting && this.selectedApiProviderId === provider.id) {
        LoadingProgress()
          .width(14)
          .height(14)
          .color('#2563EB')
        Text('测速中')
          .copyOption(CopyOptions.None)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#2563EB')
          .margin({ left: 4 })
      } else {
        Text('测速')
          .copyOption(CopyOptions.None)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#374151')
      }
    }
    .height(28)
    .backgroundColor('#F9FAFB')
    .borderRadius(8)
    .border({ width: 1, color: (this.apiSpeedTesting && this.selectedApiProviderId === provider.id) ? '#93C5FD' : '#E5E7EB' })
    .padding({ left: 10, right: 10 })
    .scale({ x: this.pressScale(`api-speed-${provider.id}`), y: this.pressScale(`api-speed-${provider.id}`) })
    .animation({ duration: 140, curve: Curve.FastOutSlowIn })
    .onTouch((event: TouchEvent) => { this.updatePressed(`api-speed-${provider.id}`, event); })
    .onClick(() => {
      if (!this.apiSpeedTesting) {
        this.runApiSpeedTest(provider);
      }
    })
  }

  @Builder
  private apiProviderActionButton(label: string, key: string, danger: boolean, onClick: () => void) {
    Button(label)
      .height(28)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(danger ? '#DC2626' : '#374151')
      .backgroundColor('#F9FAFB')
      .borderRadius(8)
      .border({ width: 1, color: danger ? '#FECACA' : '#E5E7EB' })
      .padding({ left: 10, right: 10 })
      .scale({ x: this.pressScale(key), y: this.pressScale(key) })
      .animation({ duration: 140, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent) => { this.updatePressed(key, event); })
      .onClick(onClick)
  }

  @Builder
  private apiProviderCard(provider: ProviderRecord) {
    Column() {
      // 顶部行：拖动手柄 + 头像 + 名称信息 + 操作按钮
      Row() {
        // 拖动手柄
        Column() {
          Row()
            .width(16)
            .height(2)
            .backgroundColor('#D1D5DB')
            .borderRadius(1)
            .margin({ bottom: 3 })
          Row()
            .width(16)
            .height(2)
            .backgroundColor('#D1D5DB')
            .borderRadius(1)
            .margin({ bottom: 3 })
          Row()
            .width(16)
            .height(2)
            .backgroundColor('#D1D5DB')
            .borderRadius(1)
        }
        .width(24)
        .justifyContent(FlexAlign.Center)
        .margin({ right: 12 })

        // 头像
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(40)
            .height(40)
            .backgroundColor(provider.isActive ? '#EFF6FF' : '#F3F4F6')
            .borderRadius(10)

          Text(this.apiProviderInitial(provider))
            .copyOption(CopyOptions.None)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(provider.iconColor.trim().length > 0 ? provider.iconColor : (provider.isActive ? '#2563EB' : '#6B7280'))
        }
        .margin({ right: 12 })

        // 名称 + 状态
        Column() {
          Row() {
            Text(provider.name.length > 0 ? provider.name : '未命名')
              .copyOption(CopyOptions.None)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textPrimary())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (provider.isActive) {
              Text('当前')
                .copyOption(CopyOptions.None)
                .fontSize(10)
                .fontWeight(FontWeight.Medium)
                .fontColor('#2563EB')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor('#EFF6FF')
                .borderRadius(4)
                .margin({ left: 6 })
            }
          }
          .width('100%')

          Text(this.apiProviderSecondaryText(provider))
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor(provider.baseUrl.trim().length > 0 ? '#2563EB' : '#64748B')
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 操作按钮
        if (this.apiProviderEmphasized(provider)) {
          Row({ space: 6 }) {
            Button(provider.isActive ? '启用中' : '启用')
              .height(28)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .padding({ left: 12, right: 12 })
              .backgroundColor(provider.isActive ? '#2563EB' : '#F9FAFB')
              .fontColor(provider.isActive ? '#FFFFFF' : '#374151')
              .borderRadius(8)
              .border({ width: provider.isActive ? 0 : 1, color: '#E5E7EB' })
              .scale({ x: this.pressScale(`api-activate-${provider.id}`), y: this.pressScale(`api-activate-${provider.id}`) })
              .animation({ duration: 140, curve: Curve.FastOutSlowIn })
              .onTouch((event: TouchEvent) => { this.updatePressed(`api-activate-${provider.id}`, event); })
              .onClick(() => {
                if (!provider.isActive) {
                  this.activateApiProvider(provider.id);
                } else {
                  this.triggerFeedback('当前服务商已启用。', 'info');
                }
              })

            this.apiProviderActionButton('编辑', `api-edit-${provider.id}`, false, () => { router.pushUrl({ url: 'pages/AiAddProviderPage', params: { editId: provider.id } }); })
            this.apiProviderActionButton('验证', `api-validate-${provider.id}`, false, () => {
              this.selectedApiProviderId = provider.id;
              this.validateApiDraft();
            })
            this.apiSpeedTestButton(provider)
            this.apiProviderActionButton('删除', `api-delete-${provider.id}`, true, () => { this.removeApiProvider(provider.id); })
          }
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 标签行
      Row({ space: 6 }) {
        this.pill(this.apiCategoryLabel(provider.category), '#F0F4FF', '#3B5BDB')
        this.pill(this.apiWireApiLabel(provider.wireApi), '#F3F4F6', '#6B7280')
        this.pill(this.apiHealthLabel(provider), this.apiHealthBg(provider.healthStatus), this.apiHealthColor(provider.healthStatus))
      }
      .margin({ top: 10 })
      .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor(this.apiProviderCardBackground(provider))
    .border({
      width: this.apiProviderEmphasized(provider) ? 1.5 : 1,
      color: this.apiProviderCardBorder(provider)
    })
    .borderRadius(12)
    .animation({ duration: 200, curve: Curve.FastOutSlowIn })
    .onClick(() => {
      this.selectApiProvider(provider.id);
    })
  }

  @Builder
  private apiProvidersPanel() {
    Column() {
      Row() {
        Column() {
          Text('服务商列表')
            .copyOption(CopyOptions.None)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textPrimary())
          Text('长按拖动排序')
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor(this.textSecondary())
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)

        Blank()
          .layoutWeight(1)

        this.pill(`${this.apiProviderCount} 个服务商`, '#EEF4FF', '#1D4ED8')
      }
      .width('100%')

      List({ space: 12 }) {
        ForEach(this.apiProviders, (provider: ProviderRecord) => {
          ListItem() {
            this.apiProviderCard(provider)
          }
        }, (provider: ProviderRecord) => `${provider.id}-${provider.isActive}`)
          .onMove((from: number, to: number) => {
            const moved = this.apiProviders.splice(from, 1)[0];
            this.apiProviders.splice(to, 0, moved);
            this.apiProviders = [...this.apiProviders];
            apiManagementVM.reorderProviders(this.apiProviders);
          })
      }
      .width('100%')
      .height(this.apiProviders.length * 120)
      .margin({ top: 14 })
      .scrollBar(BarState.Off)
      .divider({ strokeWidth: 0 })
    }
    .width('100%')
  }

  @Builder
  private apiPresetCard(preset: ApiPresetMockItem) {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(38)
            .height(38)
            .backgroundColor(this.elevatedSurface())
            .border({ width: 1, color: '#E2E8F0' })
            .borderRadius(19)

          Text(preset.name.substring(0, 1).toUpperCase())
            .copyOption(CopyOptions.None)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(preset.accent)
        }
        .margin({ right: 12 })

        Column() {
          Text(preset.name)
            .copyOption(CopyOptions.None)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textPrimary())
          Text(preset.baseUrl)
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor('#2563EB')
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(preset.description)
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor(this.textMuted())
            .lineHeight(18)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 8 })

          Row() {
            this.pill(this.apiCategoryLabel(preset.category), '#F4F8FF', '#3563C8')
            this.pill(this.apiWireApiLabel(preset.wireApi), '#F8FAFC', '#64748B')
          }
          .margin({ top: 8 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Row() {
        Button('使用此预设')
          .height(30)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .padding({ left: 14, right: 14 })
          .backgroundColor('#111827')
          .fontColor('#FFFFFF')
          .borderRadius(12)
          .scale({ x: this.pressScale(`api-preset-${preset.id}`), y: this.pressScale(`api-preset-${preset.id}`) })
          .animation({ duration: 140, curve: Curve.FastOutSlowIn })
          .onTouch((event: TouchEvent) => { this.updatePressed(`api-preset-${preset.id}`, event); })
          .onClick(() => { this.applyApiPreset(preset.id); })
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(16)
    .backgroundColor(this.surface())
    .border({ width: 1, color: '#E2EAF3' })
    .borderRadius(20)
    .margin({ top: 12 })
  }

  @Builder
  private apiPresetsPanel() {
    Column() {
      this.sectionCard('服务商预设库', '选择预设开始配置')
      Flex({ wrap: FlexWrap.Wrap }) {
        this.apiFilterChip('全部', 'all')
        this.apiFilterChip('官方', 'official')
        this.apiFilterChip('第三方', 'third_party')
        this.apiFilterChip('云服务商', 'cloud_provider')
        this.apiFilterChip('聚合', 'aggregator')
      }
      .width('100%')
      .margin({ top: 12 })

      Column() {
        ForEach(this.filteredApiPresets(), (preset: ApiPresetMockItem) => {
          this.apiPresetCard(preset)
        }, (preset: ApiPresetMockItem) => preset.id)
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .width('100%')
  }

  @Builder
  private apiPanel() {
    Column() {
      Column() {
        Row() {
          Column() {
            Text('服务商工作区')
              .copyOption(CopyOptions.None)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
                    .fontColor(this.textPrimary())
            if (apiManagementVM.state.errorText.trim().length > 0) {
              Text(apiManagementVM.state.errorText)
                .copyOption(CopyOptions.None)
                .fontSize(11)
                .fontColor('#B91C1C')
                .margin({ top: 4 })
            }
          }
          .alignItems(HorizontalAlign.Start)

          Blank()
            .layoutWeight(1)

          Row() {
            this.apiSubTabChip('服务商', 'providers')
          }

          Button('+')
            .width(42)
            .height(42)
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .backgroundColor('#FF8A1F')
            .borderRadius(16)
            .margin({ left: 12 })
            .scale({ x: this.pressScale('api-add-provider'), y: this.pressScale('api-add-provider') })
            .animation({ duration: 140, curve: Curve.FastOutSlowIn })
            .onTouch((event: TouchEvent) => { this.updatePressed('api-add-provider', event); })
            .onClick(() => { router.pushUrl({ url: 'pages/AiAddProviderPage' }); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.apiActiveSubTab === 'presets') {
          this.apiPresetsPanel()
        } else {
          this.apiProvidersPanel()
        }
      }
      .width('100%')
      .margin({ top: 18 })
      .padding(20)
      .backgroundColor('#FBFDFF')
      .border({ width: 1, color: '#DCE7F3' })
      .borderRadius(24)
    }
    .width('100%')
  }

  @Builder
  private toastHost() {
    Column() {
      ForEach(this.toasts, (toast: UiToastItem) => {
        Row() {
          Column()
            .width(8)
            .height(8)
            .backgroundColor(this.toneColor(toast.tone))
            .borderRadius(8)

          Text(toast.message)
            .copyOption(CopyOptions.None)
            .fontSize(11)
            .fontColor(this.textPrimary())
            .margin({ left: 10 })
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width(this.settingsDialogWidth())
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(this.toneBackground(toast.tone))
        .border({ width: 1, color: '#FFFFFF' })
        .borderRadius(18)
        .margin({ top: 10 })
        .transition(this.softFadeTransition())
      }, (toast: UiToastItem) => `${toast.id}`)
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .alignItems(HorizontalAlign.End)
    .position({ x: 0, y: 28 })
  }

  private validationStatusCodeText(): string {
    if (this.validationResult === null) return '—';
    return this.validationResult.statusCode > 0 ? `${this.validationResult.statusCode}` : '—';
  }

  private validationLatencyText(): string {
    if (this.validationResult === null) return '—';
    return this.validationResult.latencyMs > 0 ? `${this.validationResult.latencyMs} ms` : '—';
  }

  private validationModelsText(): string {
    if (this.validationResult === null) return '';
    return this.validationResult.modelsCount > 0 ? `${this.validationResult.modelsCount}` : '';
  }

  private validationAccountText(): string {
    if (this.validationResult === null) return '';
    return this.validationResult.accountInfo.trim();
  }

  private validationErrorText(): string {
    if (this.validationResult === null) return '';
    return this.validationResult.errorMessage.trim();
  }

  private validationTitleText(): string {
    if (this.validationResult === null) return '验证结果';
    return this.validationResult.success ? '验证通过' : '验证失败';
  }

  private validationTitleColor(): string {
    if (this.validationResult === null) return '#0F172A';
    return this.validationResult.success ? '#16A34A' : '#DC2626';
  }

  @Builder
  private validationResultDialog() {
    if (this.showValidationDialog && this.validationResult !== null) {
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#0F172A')
          .opacity(0.18)
          .onClick(() => { this.runMotion(() => { this.showValidationDialog = false; }); })

        Column() {
          Row() {
            Text(this.validationTitleText())
              .copyOption(CopyOptions.None)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.validationTitleColor())

            Blank()
              .layoutWeight(1)

            Button() {
              Text('×').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.textPrimary())
            }
              .type(ButtonType.Normal)
              .accessibilityText('关闭')
              .width(32)
              .height(32)
              .fontSize(20)
              .fontColor(this.textSecondary())
              .backgroundColor('#E2E8F0')
              .borderRadius(10)
              .border({ width: 1, color: '#CBD5E1' })
              .onClick(() => { this.runMotion(() => { this.showValidationDialog = false; }); })
          }
          .width('100%')

        Column() {
          Row() {
            Text('状态码')
              .copyOption(CopyOptions.None)
              .fontSize(12)
                    .fontColor(this.textMuted())
              .width(80)
            Text(this.validationStatusCodeText())
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontColor(this.textPrimary())
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ top: 14 })

          Row() {
            Text('延迟')
              .copyOption(CopyOptions.None)
              .fontSize(12)
                  .fontColor(this.textMuted())
              .width(80)
            Text(this.validationLatencyText())
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontColor(this.textPrimary())
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ top: 10 })

          Row() {
            Text('模型数')
              .copyOption(CopyOptions.None)
              .fontSize(12)
                  .fontColor(this.textMuted())
              .width(80)
            Text(this.validationModelsText().length > 0 ? this.validationModelsText() : '—')
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontColor(this.textPrimary())
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ top: 10 })

          Row() {
            Text('账户')
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontColor(this.textMuted())
              .width(80)
            Text(this.validationAccountText().length > 0 ? this.validationAccountText() : '—')
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontColor(this.textPrimary())
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 10 })

          Row() {
            Text('错误')
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontColor(this.textMuted())
              .width(80)
            Text(this.validationErrorText().length > 0 ? this.validationErrorText() : '无')
              .copyOption(CopyOptions.None)
              .fontSize(12)
              .fontColor(this.validationErrorText().length > 0 ? '#DC2626' : '#64748B')
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 10 })
        }
        .width('100%')
        .padding({ left: 4, right: 4 })

        Button('关闭')
          .height(38)
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .backgroundColor('#111827')
          .borderRadius(14)
          .margin({ top: 18 })
          .onClick(() => { this.runMotion(() => { this.showValidationDialog = false; }); })
      }
      .width(this.settingsDialogWidth())
      .padding(22)
      .backgroundColor(this.surface())
      .border({ width: 1, color: '#E2EAF3' })
      .borderRadius(24)
    }
    .width('100%')
    .height('100%')
    .transition(this.dialogTransition())
    }
  }

  build() {
    Stack() {
      Column() {
        this.topBar()

        if (this.isPhoneBreakpoint()) {
          this.phoneSettingsLayout()
        } else {
          this.wideSettingsLayout()
        }
      }
      .width('100%')
      .height('100%')

      this.toastHost()
      this.skillDeleteDialog()
      this.skillDetailDialog()
      this.mcpAddDialog()
      this.mcpDeleteDialog()
      this.promptDeleteDialog()
      this.validationResultDialog()
      this.apiSpeedResultsPanel()
      this.configTomlDialog()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBackground())
  }
}
