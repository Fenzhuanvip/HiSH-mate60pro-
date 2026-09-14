import { codeArtsService, CODEARTS_REGIONS, CodeArtsConfig, CodeArtsProject, CodeArtsRepo } from '../../backend/CodeArtsService';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import pasteboard from '@ohos.pasteboard';

const DOMAIN = 0x0ff4;

/**
 * CodeArts（云码道）配置面板 — 设置页的 codearts Tab 内容。
 * 包含：AK/SK 输入、区域选择、连接测试、项目列表、仓库列表。
 */
@Component
export struct CodeArtsConfigPanel {
  @State private ak: string = '';
  @State private sk: string = '';
  @State private region: string = 'cn-north-4';
  @State private projectId: string = '';
  @State private connected: boolean = false;
  @State private connecting: boolean = false;
  @State private statusMessage: string = '';
  @State private statusError: boolean = false;
  @State private projects: CodeArtsProject[] = [];
  @State private repos: CodeArtsRepo[] = [];
  @State private selectedProjectId: string = '';
  @State private loadingProjects: boolean = false;
  @State private loadingRepos: boolean = false;
  @State private showCreateRepo: boolean = false;
  @State private newRepoName: string = '';
  @State private newRepoDesc: string = '';
  @State private creatingRepo: boolean = false;
  @State private skVisible: boolean = false;

  aboutToAppear(): void {
    void this.loadSavedConfig();
  }

  private async loadSavedConfig(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      const config = await codeArtsService.loadConfig(ctx);
      if (config !== null) {
        this.ak = config.ak;
        this.sk = config.sk;
        this.region = config.region;
        this.projectId = config.projectId;
        this.connected = true;
        if (config.projectId.length > 0) {
          this.selectedProjectId = config.projectId;
          void this.loadRepos();
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, 'CodeArtsConfigPanel', 'loadSavedConfig failed: %{public}s', JSON.stringify(e));
    }
  }

  private async saveAndTest(): Promise<void> {
    if (this.ak.trim().length === 0 || this.sk.trim().length === 0) {
      this.statusMessage = '请填写 AK 和 SK';
      this.statusError = true;
      return;
    }
    this.connecting = true;
    this.statusMessage = '正在连接...';
    this.statusError = false;
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      const config: CodeArtsConfig = {
        ak: this.ak.trim(),
        sk: this.sk.trim(),
        region: this.region,
        projectId: this.projectId.trim(),
      };
      await codeArtsService.saveConfig(ctx, config);
      const result = await codeArtsService.testConnection();
      this.connected = result.success;
      this.statusMessage = result.message;
      this.statusError = !result.success;
      if (result.success) {
        void this.loadProjects();
      }
    } catch (e) {
      this.statusMessage = `错误: ${(e as Error).message}`;
      this.statusError = true;
    } finally {
      this.connecting = false;
    }
  }

  private async loadProjects(): Promise<void> {
    this.loadingProjects = true;
    try {
      const projects = await codeArtsService.listProjects();
      this.projects = projects;
      if (projects.length > 0 && this.selectedProjectId.length === 0) {
        this.selectedProjectId = projects[0].id.toString();
        void this.loadRepos();
      }
    } catch (e) {
      this.statusMessage = `加载项目失败: ${(e as Error).message}`;
      this.statusError = true;
    } finally {
      this.loadingProjects = false;
    }
  }

  private async loadRepos(): Promise<void> {
    if (this.selectedProjectId.length === 0) {
      this.repos = [];
      return;
    }
    this.loadingRepos = true;
    try {
      const repos = await codeArtsService.listRepos(this.selectedProjectId);
      this.repos = repos;
    } catch (e) {
      this.statusMessage = `加载仓库失败: ${(e as Error).message}`;
      this.statusError = true;
    } finally {
      this.loadingRepos = false;
    }
  }

  private async createRepo(): Promise<void> {
    if (this.newRepoName.trim().length === 0) {
      return;
    }
    this.creatingRepo = true;
    try {
      await codeArtsService.createRepo(this.selectedProjectId, this.newRepoName.trim(), this.newRepoDesc.trim());
      this.showCreateRepo = false;
      this.newRepoName = '';
      this.newRepoDesc = '';
      void this.loadRepos();
      this.statusMessage = `仓库创建成功`;
      this.statusError = false;
    } catch (e) {
      this.statusMessage = `创建仓库失败: ${(e as Error).message}`;
      this.statusError = true;
    } finally {
      this.creatingRepo = false;
    }
  }

  build() {
    Column() {
      // === 配置区 ===
      this.configSection()

      // === 状态提示 ===
      if (this.statusMessage.length > 0) {
        Text(this.statusMessage)
          .fontSize(12)
          .fontColor(this.statusError ? '#DC2626' : '#16A34A')
          .margin({ top: 8, bottom: 8 })
          .width('100%')
      }

      // === 项目 + 仓库列表 ===
      if (this.connected) {
        this.repoSection()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  configSection() {
    Column() {
      Text('凭证配置')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1E293B')
        .margin({ bottom: 12 })

      // AK
      Row() {
        Text('AK')
          .fontSize(12)
          .fontColor('#64748B')
          .width(50)
        TextInput({ text: this.ak, placeholder: 'Access Key ID' })
          .fontSize(12)
          .layoutWeight(1)
          .onChange((v: string) => { this.ak = v; })
      }
      .width('100%')
      .margin({ bottom: 8 })

      // SK
      Row() {
        Text('SK')
          .fontSize(12)
          .fontColor('#64748B')
          .width(50)
        TextInput({ text: this.sk, placeholder: 'Secret Access Key' })
          .fontSize(12)
          .layoutWeight(1)
          .type(this.skVisible ? InputType.Normal : InputType.Password)
          .onChange((v: string) => { this.sk = v; })
        Button(this.skVisible ? '隐藏' : '显示')
          .fontSize(10)
          .height(28)
          .backgroundColor('#F1F5F9')
          .fontColor('#64748B')
          .borderRadius(6)
          .margin({ left: 6 })
          .onClick(() => { this.skVisible = !this.skVisible; })
      }
      .width('100%')
      .margin({ bottom: 8 })

      // 区域选择
      Row() {
        Text('区域')
          .fontSize(12)
          .fontColor('#64748B')
          .width(50)
        Select(this.getRegionOptions())
          .value(this.getRegionName())

          .layoutWeight(1)
          .onSelect((index: number) => {
            this.region = CODEARTS_REGIONS[index].id;
          })
      }
      .width('100%')
      .margin({ bottom: 12 })

      // 连接测试按钮
      Button(this.connecting ? '连接中...' : '保存并测试连接')
        .width('100%')
        .height(38)
        .fontSize(13)
        .backgroundColor(this.connected ? '#16A34A' : '#1E40AF')
        .fontColor('#FFFFFF')
        .borderRadius(8)
        .enabled(!this.connecting)
        .onClick(() => { void this.saveAndTest(); })
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#F8FAFC')
    .border({ width: 0.5, color: '#E2E8F0' })
    .borderRadius(10)
  }

  @Builder
  repoSection() {
    Column() {
      // 项目选择
      Row() {
        Text('项目')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1E293B')
        Blank()
        if (this.loadingProjects) {
          LoadingProgress()
            .width(16)
            .height(16)
        }
      }
      .width('100%')
      .margin({ top: 16, bottom: 8 })

      if (this.projects.length === 0 && !this.loadingProjects) {
        Text('暂无项目，请在华为云控制台创建 CodeArts 项目')
          .fontSize(11)
          .fontColor('#94A3B8')
          .margin({ bottom: 8 })
      } else {
        Select(this.getProjectOptions())
          .value(this.getSelectedProjectName())

          .width('100%')
          .onSelect((index: number) => {
            this.selectedProjectId = this.projects[index].id.toString();
            void this.loadRepos();
          })
      }

      // 仓库列表
      Row() {
        Text('仓库')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1E293B')
        Blank()
        Button('新建仓库')
          .fontSize(10)
          .height(26)
          .backgroundColor('#F1F5F9')
          .fontColor('#1E40AF')
          .borderRadius(6)
          .onClick(() => { this.showCreateRepo = !this.showCreateRepo; })
      }
      .width('100%')
      .margin({ top: 16, bottom: 8 })

      // 新建仓库表单
      if (this.showCreateRepo) {
        Column() {
          TextInput({ text: this.newRepoName, placeholder: '仓库名称' })
            .fontSize(12)
            .width('100%')
            .onChange((v: string) => { this.newRepoName = v; })
          TextInput({ text: this.newRepoDesc, placeholder: '仓库描述（可选）' })
            .fontSize(12)
            .width('100%')
            .margin({ top: 6 })
            .onChange((v: string) => { this.newRepoDesc = v; })
          Row() {
            Button('取消')
              .fontSize(11)
              .height(30)
              .backgroundColor('#F1F5F9')
              .fontColor('#64748B')
              .borderRadius(6)
              .onClick(() => { this.showCreateRepo = false; })
            Button(this.creatingRepo ? '创建中...' : '创建')
              .fontSize(11)
              .height(30)
              .backgroundColor('#1E40AF')
              .fontColor('#FFFFFF')
              .borderRadius(6)
              .margin({ left: 8 })
              .enabled(!this.creatingRepo)
              .onClick(() => { void this.createRepo(); })
          }
          .margin({ top: 8 })
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#FFFFFF')
        .border({ width: 0.5, color: '#E2E8F0' })
        .borderRadius(8)
        .margin({ bottom: 8 })
      }

      // 仓库列表
      if (this.loadingRepos) {
        Row() {
          LoadingProgress().width(16).height(16)
          Text('加载仓库...').fontSize(11).fontColor('#94A3B8').margin({ left: 6 })
        }.margin({ top: 8 })
      } else if (this.repos.length === 0) {
        Text('暂无仓库')
          .fontSize(11)
          .fontColor('#94A3B8')
          .margin({ top: 8 })
      } else {
        ForEach(this.repos, (repo: CodeArtsRepo) => {
          this.repoCard(repo)
        }, (repo: CodeArtsRepo) => repo.id.toString())
      }
    }
    .width('100%')
    .margin({ top: 12 })
  }

  @Builder
  repoCard(repo: CodeArtsRepo) {
    Column() {
      Row() {
        Text(repo.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1E293B')
        Blank()
        Text(repo.visibility === 'private' ? '私有' : '公开')
          .fontSize(10)
          .fontColor('#64748B')
          .backgroundColor('#F1F5F9')
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
      .width('100%')

      if (repo.description.length > 0) {
        Text(repo.description)
          .fontSize(11)
          .fontColor('#64748B')
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (repo.httpsUrl.length > 0) {
        Row() {
          Text(repo.httpsUrl)
            .fontSize(10)
            .fontColor('#3B82F6')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .copyOption(CopyOptions.LocalDevice)
          Text('复制')
            .fontSize(10)
            .fontColor('#1E40AF')
            .margin({ left: 6 })
            .onClick(() => {
              const board = pasteboard.getSystemPasteboard();
              const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, repo.httpsUrl);
              board.setData(data);
            })
        }
        .width('100%')
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .border({ width: 0.5, color: '#E2E8F0' })
    .borderRadius(8)
    .margin({ top: 6 })
  }

  // ====== 辅助方法 ======

  private getRegionOptions(): SelectOption[] {
    return CODEARTS_REGIONS.map(r => ({ value: r.name } as SelectOption));
  }

  private getRegionName(): string {
    const r = CODEARTS_REGIONS.find(r => r.id === this.region);
    return r !== undefined ? r.name : CODEARTS_REGIONS[0].name;
  }

  private getProjectOptions(): SelectOption[] {
    return this.projects.map(p => ({ value: p.name } as SelectOption));
  }

  private getSelectedProjectName(): string {
    const p = this.projects.find(p => p.id.toString() === this.selectedProjectId);
    return p !== undefined ? p.name : '选择项目';
  }
}
