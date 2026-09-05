# GitHub Actions 工作流说明

## 工作流文件

### 1. `build-hap.yml` — 构建 + 签名 + 发布 HAP

使用预构建 Docker 镜像 `ghcr.io/sanchuanhehe/harmony-next-pipeline-docker/harmonyos-ci-image:latest`，
内置 ohpm、hvigorw、hap-sign-tool 等全部 HarmonyOS 构建工具，**无需手动下载 SDK**。

**触发条件：**
- push 到 master 分支 → 自动构建
- 打 `v*` 标签（如 `v1.0.0`）→ 构建并发布到 GitHub Releases
- Pull Request → 自动构建检查
- 手动触发（Actions 页面 → Run workflow）

**构建流程：**
1. Checkout 代码（含子模块）
2. 从 template 生成 build-profile.json5
3. `ohpm install --all` 安装依赖
4. `hvigorw assembleHap` 构建 phone debug HAP
5. 上传 HAP 作为 Artifact（保留 30 天）

**发布流程（仅打标签时触发）：**
1. 下载构建产物
2. 用 `hap-sign-tool` 签名（需配置 Secrets）
3. 创建 GitHub Release 并上传签名后的 HAP

**签名 Secrets（可选，仅发布时需要）：**

| Secret 名称 | 说明 |
|-------------|------|
| `SIGNING_CERT` | .cer 证书文件路径 |
| `SIGNING_PROFILE` | .p7b profile 文件路径 |
| `SIGNING_KEY` | .p12 密钥库文件路径 |
| `KEY_PASSWORD` | 密钥密码 |
| `KEYSTORE_PASSWORD` | 密钥库密码 |

> 不配置签名 Secrets 时，构建仍会成功，发布时上传未签名的 HAP。

### 2. `lint.yml` — 代码检查

在 push/PR 时自动检查：
- `.ets` 文件的括号匹配
- TODO/FIXME 标记警告
- C++ 代码格式（如果 clang-format 可用）

## 使用方式

### 自动构建
每次 push 到 master 自动触发。

### 手动触发
GitHub 仓库 → Actions → Build HAP → Run workflow

### 发布 Release
```bash
git tag v1.0.0
git push origin v1.0.0
```
会自动构建、签名并创建 GitHub Release。

## 参考

工作流基于 [harmony-next-pipeline](https://gitcode.com/sanchuanhehe1/harmony-next-pipeline) 项目适配。
