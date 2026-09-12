import { InstalledSkill, SkillsRegistryJson, SkillEntryJson } from './SkillTypes';
import {
  getSkillsRegistry, saveSkillsRegistry, computeDirHash
} from '../backend/CodexNative';
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';

const BUNDLED_SKILLS_MARKER_NAME = '.bundled-skills-installed';

interface BundledExtraFile {
  name: string;
  content: string;
}

interface BundledSkillDef {
  id: string;
  directory: string;
  skillMd: string;
  extraFiles?: BundledExtraFile[];
}

const SKILL_BRAINSTORMING = `---
name: brainstorming
description: "You MUST use this before any creative work - creating features, building components, adding functionality, or modifying behavior. Explores user intent, requirements and design before implementation."
---

# Brainstorming Ideas Into Designs

Help turn ideas into fully formed designs and specs through natural collaborative dialogue.

Start by understanding the current project context, then ask questions one at a time to refine the idea. Once you understand what you're building, present the design and get user approval.

<HARD-GATE>
Do NOT invoke any implementation skill, write any code, scaffold any project, or take any implementation action until you have presented a design and the user has approved it. This applies to EVERY project regardless of perceived simplicity.
</HARD-GATE>

## Checklist

1. **Explore project context** - check files, docs, recent commits
2. **Ask clarifying questions** - one at a time, understand purpose/constraints/success criteria
3. **Propose 2-3 approaches** - with trade-offs and your recommendation
4. **Present design** - in sections scaled to their complexity, get user approval after each section
5. **Write design doc** - save to docs and commit

## Key Principles

- **One question at a time** - Don't overwhelm with multiple questions
- **Multiple choice preferred** - Easier to answer than open-ended when possible
- **YAGNI ruthlessly** - Remove unnecessary features from all designs
- **Explore alternatives** - Always propose 2-3 approaches before settling
- **Incremental validation** - Present design, get approval before moving on
`;

const SKILL_FIND_SKILLS = `---
name: find-skills
description: Helps users discover and install agent skills when they ask questions like "how do I do X", "find a skill for X", "is there a skill that can...", or express interest in extending capabilities.
---

# Find Skills

This skill helps you discover and install skills from the open agent skills ecosystem.

## When to Use This Skill

Use this skill when the user:

- Asks "how do I do X" where X might be a common task with an existing skill
- Says "find a skill for X" or "is there a skill for X"
- Asks "can you do X" where X is a specialized capability
- Expresses interest in extending agent capabilities
- Wants to search for tools, templates, or workflows

## How to Help Users Find Skills

### Step 1: Understand What They Need

When a user asks for help with something, identify:

1. The domain (e.g., React, testing, design, deployment)
2. The specific task (e.g., writing tests, creating animations, reviewing PRs)
3. Whether this is a common enough task that a skill likely exists

### Step 2: Search for Skills

Search the skills.sh directory for relevant skills matching the user's need.

### Step 3: Verify Quality Before Recommending

**Do not recommend a skill based solely on search results.** Always verify:

1. **Install count** - Prefer skills with 1K+ installs
2. **Source reputation** - Official sources are more trustworthy than unknown authors

### Step 4: Present Options to the User

When you find relevant skills, present them with:

1. The skill name and what it does
2. The install count and source
3. A link to learn more

## Common Skill Categories

| Category        | Example Queries                          |
| --------------- | ---------------------------------------- |
| Web Development | react, nextjs, typescript, css, tailwind |
| Testing         | testing, jest, playwright, e2e           |
| DevOps          | deploy, docker, kubernetes, ci-cd        |
| Documentation   | docs, readme, changelog, api-docs        |
| Code Quality    | review, lint, refactor, best-practices   |
| Design          | ui, ux, design-system, accessibility     |

## When No Skills Are Found

If no relevant skills exist, acknowledge that no existing skill was found and offer to help with the task directly.
`;

const SKILL_FRONTEND_DESIGN = `---
name: frontend-design
description: Create distinctive, production-grade frontend interfaces with high design quality. Use this skill when the user asks to build web components, pages, artifacts, posters, or applications. Generates creative, polished code and UI design that avoids generic AI aesthetics.
---

This skill guides creation of distinctive, production-grade frontend interfaces that avoid generic "AI slop" aesthetics. Implement real working code with exceptional attention to aesthetic details and creative choices.

## Design Thinking

Before coding, understand the context and commit to a BOLD aesthetic direction:

- **Purpose**: What problem does this interface solve? Who uses it?
- **Tone**: Pick an extreme: brutally minimal, maximalist chaos, retro-futuristic, organic/natural, luxury/refined, playful/toy-like, editorial/magazine, brutalist/raw, art deco/geometric, soft/pastel, industrial/utilitarian.
- **Constraints**: Technical requirements (framework, performance, accessibility).
- **Differentiation**: What makes this UNFORGETTABLE?

**CRITICAL**: Choose a clear conceptual direction and execute it with precision.

## Frontend Aesthetics Guidelines

Focus on:

- **Typography**: Choose fonts that are beautiful, unique, and interesting. Avoid generic fonts like Arial and Inter.
- **Color & Theme**: Commit to a cohesive aesthetic. Use CSS variables for consistency. Dominant colors with sharp accents outperform timid palettes.
- **Motion**: Use animations for effects and micro-interactions. Focus on high-impact moments.
- **Spatial Composition**: Unexpected layouts. Asymmetry. Overlap. Diagonal flow.
- **Backgrounds & Visual Details**: Create atmosphere and depth. Add contextual effects and textures.

NEVER use generic AI-generated aesthetics like overused font families, cliched color schemes, predictable layouts, or cookie-cutter design.

Match implementation complexity to the aesthetic vision. Maximalist designs need elaborate code. Minimalist designs need restraint and precision.
`;

const SKILL_INDUSTRIAL_DEV_CORE = `---
name: industrial-dev-core
description: "工业软件开发规范：涵盖设计流程、架构方法、编码质量与工程化交付。适用于 CAD/CAE/仿真、上位机/SCADA/HMI 等工业软件场景。触发词：工业软件、上位机、SCADA、HMI、CAD、CAE、仿真、实时系统、设备通信、数据采集、工控。"
user-invocable: true
---

# 工业软件开发规范

本 Skill 是工业软件开发的总纲，定义从需求到交付的完整流程。编码细节见 \`coding-standards.md\`，工程化细节见 \`engineering.md\`。

---

## 开发流程六阶段

### 1. 需求澄清

在动手之前，必须明确以下工业场景约束：

- **实时性要求**：软实时（UI 响应 < 200ms）还是硬实时（控制周期 < 1ms）？
- **精度要求**：浮点精度等级、有效位数、是否需要定点数或任意精度库
- **设备协议**：OPC UA / Modbus TCP-RTU / MQTT / 自定义串口协议 / CAN 总线？
- **安全等级**：SIL 等级、功能安全要求、是否涉及人身安全
- **部署环境**：Windows 工控机 / Linux 嵌入式 / 边缘网关 / 云端？
- **并发规模**：同时管理的设备数、数据点数、用户数

**输出物**：需求清单（含非功能需求），用户确认签字。

### 2. 架构设计

工业软件推荐分层架构：

\`\`\`
┌─────────────────────────────────┐
│         表示层 (UI)              │  Qt / WPF / Web 前端
├─────────────────────────────────┤
│         业务逻辑层               │  工艺流程、报警规则、数据处理
├─────────────────────────────────┤
│         领域模型层               │  核心实体、值对象、领域服务
├─────────────────────────────────┤
│         设备通信层               │  协议适配、连接管理、报文编解码
├─────────────────────────────────┤
│         数据持久层               │  时序数据库、关系数据库、文件存储
└─────────────────────────────────┘
\`\`\`

**架构原则**：

- **UI 与业务逻辑严格分离**：计算核心独立为库，可被不同前端（桌面/Web/CLI）复用
- **设备抽象层**：所有硬件通信通过统一接口（\`IDeviceDriver\`），支持多协议热切换
- **数据流单向**：采集 → 处理 → 存储 → 展示，每层有明确的数据契约（DTO/VO）
- **故障隔离**：单设备异常不扩散，引入看门狗、熔断器、降级策略

### 3. 模块划分

- **单一职责**：每个模块只做一件事（如 \`DataCollector\` 只负责采集，不做存储）
- **接口隔离**：模块间通过接口通信，不直接依赖实现
- **通信机制选择**：
  - 同进程：信号槽（Qt）/ 事件总线 / 观察者模式
  - 跨进程：共享内存 / 消息队列（ZeroMQ/RabbitMQ）/ gRPC
  - 跨设备：MQTT / OPC UA / HTTP REST
- **依赖方向**：UI → 业务逻辑 → 领域模型 ← 设备通信 ← 数据持久（领域模型不依赖任何外层）

### 4. 接口设计

- **契约优先**：先定义接口（API/协议文档），再实现
- **数据格式标准化**：
  - 内部统一使用 SI 单位制，展示层做单位转换
  - 时间戳统一 UTC，展示层做时区转换
  - 枚举状态用明确的命名，不用魔数
- **版本化**：API 带版本号（\`/api/v1/\`），协议有版本字段，保证向后兼容
- **工业协议适配**：为每种协议实现适配器（Adapter），将协议特定数据映射为统一领域模型

### 5. 实现与验证

- 按模块逐步实现，每阶段有可测试的输出
- 关键路径先做原型验证（数值算法、设备通信、实时性能）
- 编码规范详见 \`coding-standards.md\`

### 6. 交付与文档

- 交付物清单：安装包、配置文件、用户手册、运维指南、API 文档
- 发布流程详见 \`engineering.md\`

---

## 领域模型设计要点

工业软件的核心领域模型通常包含：

- **设备树**：工厂 → 车间 → 产线 → 工位 → 设备 → 数据点，树形层次结构
- **数据点（Tag）**：名称、地址、数据类型、量程、单位、报警阈值、采集周期
- **工艺流程**：状态机建模（待机 → 运行 → 暂停 → 报警 → 维护），状态转换有明确触发条件
- **报警模型**：报警等级（提示/警告/严重/致命）、报警确认、报警历史、联动动作
- **配方/参数集**：可版本化的参数集合，支持下发、回读、比对

---

## 反模式警告

工业软件中常见的设计错误：

- **上帝类**：一个类承担设备通信 + 数据处理 + UI 更新，应拆分
- **硬编码协议**：协议细节散落在业务代码中，应集中到适配层
- **UI 线程阻塞**：在 UI 线程做网络请求或大量数据计算
- **无超时的设备通信**：设备掉线时程序永久挂起
- **浮点数直接比较**：\`if (temperature == 36.5)\` 必然出 bug
- **状态用数字魔法值**：\`if (status == 3)\` 应改为 \`if (status == DeviceState.Running)\`
- **日志不足**：出问题后无法追溯设备通信报文和系统状态变化

---

## 工作方式

当用户在工业软件项目中工作时：

1. **设计阶段**：引导用户走完六阶段流程，每个阶段输出明确文档
2. **编码阶段**：自动应用 \`coding-standards.md\` 中的规范，在代码审查时检查
3. **交付阶段**：按 \`engineering.md\` 的流程执行

在回答用户问题时，优先引用本 Skill 中的设计原则和反模式检查。
`;

const SKILL_INDUSTRIAL_DEV_CODING = `---
name: industrial-dev-coding
description: "工业软件编码规范：浮点精度、异常安全、实时性、内存管理、线程安全、日志诊断。"
---

# 工业软件编码规范

本文档定义工业软件开发中的编码规范和质量要求。适用于 C/C++/C#/Python 技术栈。

---

## 1. 浮点精度处理

### 禁止直接比较

\`\`\`cpp
// 错误
if (temperature == 36.5) { ... }

// 正确：使用 epsilon 容差
constexpr double EPSILON = 1e-6;
if (std::abs(temperature - 36.5) < EPSILON) { ... }
\`\`\`

### 精度选择策略

| 场景 | 推荐类型 | 说明 |
|------|----------|------|
| UI 显示 | \`float\` | 6-7 位有效数字足够 |
| 工程计算 | \`double\` | 15-16 位有效数字 |
| 财务/计量 | \`decimal\` / 定点数 | 避免浮点累积误差 |
| 科学仿真 | \`double\` 或更高 | 根据数值稳定性要求选择 |

### 单位系统

- 内部统一使用 SI 单位制（米、秒、千克、帕斯卡）
- 展示层负责单位转换（mm、min、kg、MPa）
- 单位转换函数集中管理，不散落在业务代码中

---

## 2. 异常安全与错误处理

### 设备通信层

\`\`\`cpp
// 每次通信必须有超时
auto result = device->read(address, timeout_ms{1000});
if (!result.ok()) {
    LOG_WARN("Device read failed: {}", result.error());
    // 重试逻辑，最多 N 次
}
\`\`\`

- 所有 I/O 操作必须有超时，禁止无限等待
- 重试策略：指数退避 + 最大重试次数 + 熔断
- 设备掉线后自动进入重连流程，不影响其他设备

### 资源管理

\`\`\`cpp
// C++：RAII
{
    auto lock = std::lock_guard(mutex);
    auto file = std::ifstream(path);  // 析构自动关闭
    // ...
}  // 自动释放

// C#：using
using (var connection = new DeviceConnection(config))
{
    // ...
}  // 自动 Dispose
\`\`\`

### 异常边界

- 异常不允许跨越模块/线程边界
- 模块入口处 catch 所有异常，转换为错误码或 Result 类型
- 未捕获异常必须有全局兜底处理（记录日志 + 安全停机）

---

## 3. 实时性要求

### UI 线程保护

\`\`\`
UI 线程禁止：
  ✗ 网络请求
  ✗ 数据库查询
  ✗ 大量数据计算（>10ms）
  ✗ 文件 I/O

UI 线程允许：
  ✓ 界面渲染
  ✓ 事件分发
  ✓ 小数据量的状态更新
\`\`\`

### 计算优化

- 关键路径避免动态内存分配（预分配、对象池）
- 热路径避免虚函数调用（编译期多态 / CRTP）
- 数据局部性：结构体数组（AoS）→ 数组结构体（SoA）根据访问模式选择
- 批量处理：设备数据按批次处理，减少锁竞争和系统调用

### 锁策略

- 优先无锁队列（\`moodycamel::ConcurrentQueue\` / \`System.Threading.Channels\`）
- 需要锁时，锁粒度要细（按设备/按数据点，不全局锁）
- 禁止嵌套锁（死锁风险），必须时按固定顺序获取
- 锁内不做 I/O 和计算，只做数据交换

---

## 4. 内存管理

### C/C++

\`\`\`cpp
// 优先使用智能指针
auto device = std::make_unique<ModbusDevice>(config);
auto shared_data = std::make_shared<TimeSeriesBuffer>();

// 大块数据用内存池
class DataPointPool {
    std::vector<std::byte> buffer_;
    // ...
};
\`\`\`

- 禁止裸 \`new/delete\`，使用 \`unique_ptr\` / \`shared_ptr\`
- 值类型优先（栈分配），堆分配用智能指针
- 定期用 Valgrind / AddressSanitizer 检测内存泄漏
- 长期运行的服务注意内存碎片，关键数据结构预分配

### C#

- \`IDisposable\` 对象必须用 \`using\` 管理
- 大对象（>85KB）注意 LOH 碎片，考虑 \`ArrayPool\` / \`MemoryPool\`
- 事件订阅必须有对应的取消订阅，防止内存泄漏

---

## 5. 线程安全

### 数据共享原则

- 共享数据必须有同步保护（互斥锁 / 读写锁 / 原子操作）
- 优先使用消息传递而非共享内存
- 线程间通信使用线程安全队列

### 常见陷阱

\`\`\`cpp
// 危险：check-then-act 竞态
if (device->is_connected()) {   // 线程 A 检查
    // 此时线程 B 断开了连接
    device->send(command);       // 线程 A 发送 → 崩溃
}

// 正确：原子操作或锁保护
{
    auto lock = std::lock_guard(device->mutex());
    if (device->is_connected()) {
        device->send(command);
    }
}
\`\`\`

---

## 6. 日志与诊断

### 日志分级

| 级别 | 用途 | 示例 |
|------|------|------|
| DEBUG | 开发调试信息 | 数据点原始报文、算法中间值 |
| INFO | 正常运行事件 | 设备连接成功、配方下发完成 |
| WARN | 异常但可恢复 | 设备响应超时（重试中）、数据越限 |
| ERROR | 功能受损 | 设备通信失败、数据库写入错误 |
| FATAL | 系统不可用 | 内存分配失败、关键服务崩溃 |

### 必须记录的事件

- 设备连接/断开事件（含原因）
- 通信报文（至少 WARN 级别以上，可选全部）
- 报警触发/确认/恢复
- 配方/参数下发与回读
- 用户登录/权限变更/关键操作
- 系统启停

### 日志格式

\`\`\`
2026-05-14 10:23:45.123 [WARN ] [DeviceManager] [PLC-001] Read timeout after 1000ms, retrying (2/3)
\`\`\`

包含：时间戳、级别、模块名、设备标识、描述信息。

---

## 7. 状态管理

### 状态机模式

\`\`\`python
class DeviceState(Enum):
    IDLE = auto()
    RUNNING = auto()
    PAUSED = auto()
    ALARM = auto()
    MAINTENANCE = auto()
    OFFLINE = auto()

# 状态转换表
TRANSITIONS = {
    DeviceState.IDLE:      [DeviceState.RUNNING, DeviceState.MAINTENANCE, DeviceState.OFFLINE],
    DeviceState.RUNNING:   [DeviceState.PAUSED, DeviceState.ALARM, DeviceState.IDLE],
    DeviceState.PAUSED:    [DeviceState.RUNNING, DeviceState.IDLE],
    DeviceState.ALARM:     [DeviceState.IDLE, DeviceState.MAINTENANCE],
    DeviceState.MAINTENANCE: [DeviceState.IDLE],
    DeviceState.OFFLINE:   [DeviceState.IDLE],
}
\`\`\`

- 状态用枚举，不用数字魔数
- 状态转换必须经过合法性校验
- 状态变更必须触发事件通知（UI 更新、日志记录、联动动作）

---

## 8. 配置管理

- 配置与代码分离（JSON/YAML/TOML 配置文件）
- 支持运行时热加载（文件监听 + 变更通知）
- 配置项有默认值和校验规则
- 敏感配置（密码、密钥）加密存储
- 配置变更有审计日志
`;

const SKILL_INDUSTRIAL_DEV_ENGINEERING = `---
name: industrial-dev-engineering
description: "工业软件工程化规范：版本管理、CI/CD、文档规范、发布流程。"
---

# 工业软件工程化规范

本文档定义工业软件项目的工程化实践，涵盖版本管理、持续集成、文档和发布流程。

---

## 1. 版本管理

### 语义化版本

\`\`\`
主版本.次版本.补丁 (MAJOR.MINOR.PATCH)

主版本：接口不兼容的变更（设备协议大改、数据格式不兼容）
次版本：新增功能（新设备支持、新报表），向后兼容
补丁：Bug 修复、性能优化，完全向后兼容
\`\`\`

### 分支策略

\`\`\`
main          ← 稳定发布版本，每次发布打 tag
  └── develop ← 开发集成分支，功能合并到这里
       ├── feature/device-driver    ← 新设备驱动开发
       ├── feature/alarm-engine     ← 报警引擎重构
       └── fix/precision-loss       ← 浮点精度修复

hotfix/*      ← 生产环境紧急修复，从 main 拉出，修完合并回 main + develop
\`\`\`

### 提交规范

\`\`\`
<类型>(<范围>): <描述>

类型：
  feat     - 新功能
  fix      - 修复
  refactor - 重构（不改变外部行为）
  docs     - 文档
  test     - 测试
  perf     - 性能优化
  chore    - 构建/工具链变更

示例：
  feat(modbus): 支持 Modbus TCP 多设备并发采集
  fix(alarm): 修复报警阈值边界条件判断错误
  refactor(collector): 将数据采集抽象为独立模块
  perf(buffer): 优化时序数据缓冲区内存分配
\`\`\`

---

## 2. CI/CD 流水线

### 流水线阶段

\`\`\`
代码提交
  │
  ├─→ 静态分析（lint / clang-tidy / C# Analyzers）
  │     └─→ 代码风格 + 潜在 bug 检测
  │
  ├─→ 编译构建（多平台：Windows x64 / Linux x64 / ARM）
  │     └─→ 警告视为错误（-Werror / TreatWarningsAsErrors）
  │
  ├─→ 单元测试
  │     └─→ 覆盖率报告（核心模块 > 80%）
  │
  ├─→ 数值回归测试（工业软件特有）
  │     └─→ 计算结果与基准数据比对，误差 < 容差
  │
  ├─→ 集成测试
  │     └─→ 模拟设备通信、端到端数据流验证
  │
  └─→ 制品打包
        └─→ 安装包 + 校验和 + 签名
\`\`\`

### 数值回归测试

工业软件的核心计算模块（仿真引擎、数据处理算法）必须有回归测试：

\`\`\`python
def test_heat_transfer_calculation():
    """与基准数据比对，误差不超过 0.1%"""
    result = heat_transfer.simulate(input_params)
    expected = load_baseline("heat_transfer_v2.3.csv")
    assert_allclose(result, expected, rtol=1e-3)
\`\`\`

- 基准数据版本化管理
- 基准数据更新需经过审查和确认
- 测试失败时输出详细的差异报告

---

## 3. 文档规范

### 文档体系

| 文档类型 | 受众 | 更新时机 | 格式 |
|----------|------|----------|------|
| 架构文档 | 开发团队 | 架构变更时 | Markdown + 图表 |
| API 文档 | 开发团队 | 接口变更时 | 自动从代码生成 |
| 用户手册 | 操作人员 | 每次发布 | Word/PDF |
| 运维指南 | 运维人员 | 部署变更时 | Markdown |
| 变更日志 | 所有人 | 每次发布 | CHANGELOG.md |

### 架构文档必备内容

- 系统架构图（分层 + 模块关系）
- 数据流图（采集 → 处理 → 存储 → 展示）
- 部署图（服务器/工控机/边缘设备分布）
- 关键设计决策记录（ADR）：为什么选这个方案、权衡了什么

### 变更日志格式

\`\`\`markdown
## [1.2.0] - 2026-05-14

### Added
- 支持 OPC UA 协议的设备发现功能
- 新增数据导出为 CSV/Excel 功能

### Fixed
- 修复高温报警在阈值边界不触发的问题
- 修复 Modbus RTU 在波特率 9600 下偶发超时

### Changed
- 时序数据库从 InfluxDB 1.x 升级到 2.x
- 报警引擎性能优化，处理延迟降低 40%
\`\`\`

---

## 4. 发布流程

### 发布检查清单

\`\`\`
□ 所有 CI 检查通过
□ 数值回归测试通过
□ 架构文档已更新
□ API 文已更新
□ 用户手册已更新
□ CHANGELOG 已填写
□ 版本号已更新（所有相关位置）
□ 安装包已签名
□ 回归测试在目标环境通过
□ Release Notes 已准备
\`\`\`

### 发布阶段

\`\`\`
1. Release Candidate (RC)
   - 从 develop 合并到 main
   - 打 RC tag：v1.2.0-rc.1
   - 内部测试团队验证

2. 内部测试
   - 功能测试 + 性能测试 + 兼容性测试
   - 发现问题 → 修复 → 新 RC

3. 灰度发布（可选）
   - 选择 1-2 个试点用户
   - 观察 1-2 周，收集反馈

4. 正式发布
   - 去掉 RC 后缀：v1.2.0
   - 正式打 tag
   - 发布公告 + 用户通知
\`\`\`

### 制品管理

- 每个发布版本保留完整的安装包和校验和
- 安装包进行数字签名（防篡改）
- 保留 N 个历史版本供回退
- 制品存储位置有明确的目录结构：

\`\`\`
releases/
├── v1.2.0/
│   ├── setup-v1.2.0.exe
│   ├── setup-v1.2.0.sha256
│   ├── release-notes.md
│   └── changelog.md
├── v1.1.1/
│   └── ...
└── v1.1.0/
    └── ...
\`\`\`

### 回退方案

- 每次发布前确认回退步骤
- 数据库 schema 变更必须有对应的回退脚本
- 配置文件变更向后兼容，新版本能读旧配置
- 回退操作写入运维手册，一键可执行

---

## 5. 依赖管理

- 锁定依赖版本（\`package-lock.json\` / \`Cargo.lock\` / \`conan.lock\`）
- 定期检查依赖安全漏洞（\`npm audit\` / \`pip audit\`）
- 工业软件优先选择成熟稳定的库，不盲目追新
- 私有依赖（内部库、设备 SDK）有版本管理和发布流程
`;

const BUNDLED_DEFS: BundledSkillDef[] = [
  {
    id: 'bundled:brainstorming',
    directory: 'brainstorming',
    skillMd: SKILL_BRAINSTORMING
  },
  {
    id: 'bundled:find-skills',
    directory: 'find-skills',
    skillMd: SKILL_FIND_SKILLS
  },
  {
    id: 'bundled:frontend-design',
    directory: 'frontend-design',
    skillMd: SKILL_FRONTEND_DESIGN
  },
  {
    id: 'bundled:industrial-dev-core',
    directory: 'industrial-dev-core',
    skillMd: SKILL_INDUSTRIAL_DEV_CORE,
    extraFiles: [
      { name: 'coding-standards.md', content: SKILL_INDUSTRIAL_DEV_CODING },
      { name: 'engineering.md', content: SKILL_INDUSTRIAL_DEV_ENGINEERING }
    ]
  }
];

function bundledSkillsMarkerPath(codexHome: string): string {
  return `${codexHome}/${BUNDLED_SKILLS_MARKER_NAME}`;
}

function hasBundledSkillsMarker(codexHome: string): boolean {
  try {
    fileIo.statSync(bundledSkillsMarkerPath(codexHome));
    return true;
  } catch (_) {
    return false;
  }
}

function writeBundledSkillsMarker(codexHome: string): void {
  const markerFile = fileIo.openSync(
    bundledSkillsMarkerPath(codexHome),
    fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
  );
  fileIo.closeSync(markerFile);
}

/**
 * 首次启动时安装预设 Skill。
 * 安装完成后写入 marker，后续启动不再自动补装。
 *
 * @param codexHome - 应用 codex-home 目录路径
 */
export function installBundledSkills(codexHome: string): void {
  const ssotDir = `${codexHome}/skills`;

  // 迁移：旧 SSOT 路径 `{codexHome}/../.agents/skills` → 新路径 `{codexHome}/skills`
  const oldSsotDir = `${codexHome}/../.agents/skills`;
  try {
    const oldEntries = fileIo.listFileSync(oldSsotDir) as string[];
    for (const entry of oldEntries) {
      if (entry.startsWith('.')) {
        continue;
      }
      const oldPath = `${oldSsotDir}/${entry}`;
      const newPath = `${ssotDir}/${entry}`;
      try {
        const stat = fileIo.statSync(oldPath);
        if (stat.isDirectory()) {
          try {
            fileIo.statSync(newPath);
            // 新路径已存在，跳过
          } catch (_) {
            // 新路径不存在，移动
            try {
              fileIo.mkdirSync(ssotDir, true);
            } catch (_) { /* 目录已存在 */ }
            fileIo.renameSync(oldPath, newPath);
          }
        }
      } catch (_) { /* skip */ }
    }
  } catch (_) {
    // 旧目录不存在，无需迁移
  }

  if (hasBundledSkillsMarker(codexHome)) {
    return;
  }

  // 读取现有 registry
  let existing: InstalledSkill[] = [];
  try {
    const json = getSkillsRegistry(codexHome);
    const parsed: SkillsRegistryJson = JSON.parse(json) as SkillsRegistryJson;
    const entries: SkillEntryJson[] = parsed.skills ?? [];
    existing = entries.map((e: SkillEntryJson) => InstalledSkill.fromJSON(e));
  } catch (_) {
    // registry 不存在或为空，继续安装
  }

  if (existing.length > 0) {
    writeBundledSkillsMarker(codexHome);
    return;
  }

  const now = Date.now();
  const newSkills: InstalledSkill[] = [];

  for (const def of BUNDLED_DEFS) {
    // 跳过已存在的
    const alreadyInstalled = existing.some((s: InstalledSkill) => s.directory === def.directory);
    if (alreadyInstalled) {
      continue;
    }

    // 写入 SSOT 目录
    const destDir = `${ssotDir}/${def.directory}`;
    try {
      fileIo.mkdirSync(destDir, true);
    } catch (_) {
      // 目录已存在
    }
    const skillMdPath = `${destDir}/SKILL.md`;
    const file = fileIo.openSync(skillMdPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    const encoder = new util.TextEncoder();
    const encoded = encoder.encodeInto(def.skillMd);
    fileIo.writeSync(file.fd, encoded.buffer);
    fileIo.closeSync(file);

    // 写入额外文件
    if (def.extraFiles) {
      for (const extra of def.extraFiles) {
        const extraPath = `${destDir}/${extra.name}`;
        const extraFile = fileIo.openSync(extraPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        const extraEncoded = encoder.encodeInto(extra.content);
        fileIo.writeSync(extraFile.fd, extraEncoded.buffer);
        fileIo.closeSync(extraFile);
      }
    }

    // 计算哈希
    const contentHash = computeDirHash(destDir);

    // 解析 name / description
    let name = def.directory;
    let description = '';
    const parts = def.skillMd.split('---');
    if (parts.length >= 3) {
      const frontMatter = parts[1].trim();
      const lines = frontMatter.split('\n');
      for (const line of lines) {
        const colonIdx = line.indexOf(':');
        if (colonIdx === -1) {
          continue;
        }
        const key = line.substring(0, colonIdx).trim();
        const value = line.substring(colonIdx + 1).trim().replace(/^['"]|['"]$/g, '');
        if (key === 'name') {
          name = value;
        }
        if (key === 'description') {
          description = value;
        }
      }
    }

    const entry = new InstalledSkill(
      def.id, name, description, def.directory,
      'local', '', '', '',
      '', true, now, contentHash, 0
    );
    newSkills.push(entry);
  }

  if (newSkills.length === 0) {
    writeBundledSkillsMarker(codexHome);
    return;
  }

  // 合并写入 registry
  const merged = [...existing, ...newSkills];
  const registry: SkillsRegistryJson = {
    version: 1,
    skills: merged as SkillEntryJson[],
    updatedAt: new Date(now).toISOString()
  };
  const saved: boolean = saveSkillsRegistry(codexHome, JSON.stringify(registry));
  if (saved) {
    writeBundledSkillsMarker(codexHome);
  }
}
