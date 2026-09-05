# GitHub Actions 工作流说明

## 工作流文件

### 1. `build-hap.yml` — 构建 HAP

在 push 到 master 或手动触发时，自动构建 phone 模块的 debug HAP。

**需要配置的 GitHub Secret：**

| Secret 名称 | 说明 |
|-------------|------|
| `CMDLINE_TOOLS_URL` | HarmonyOS Command Line Tools (Linux) 的下载链接 |

**获取 Command Line Tools：**

1. 访问 https://developer.huawei.com/consumer/cn/download/
2. 下载 "HarmonyOS Command Line Tools (Linux)" 的 zip 包
3. 上传到任意可公开访问的存储（如 GitHub Release、阿里云 OSS 等）
4. 将下载链接设置为仓库的 Secret `CMDLINE_TOOLS_URL`

**签名说明：**

工作流会自动生成自签名证书用于 debug 构建。因为是开发版自用，自签名证书足够。
如需使用正式签名，将 `.p12`、`.cer`、`.p7b` 文件内容作为 Secrets 上传，并修改 `build-hap.yml` 中的签名配置步骤。

**产物：**

构建成功后，HAP 文件会作为 Artifact 上传，保留 30 天。

### 2. `lint.yml` — 代码检查

在 push/PR 时自动检查：
- `.ets` 文件的括号匹配
- TODO/FIXME 标记警告
- C++ 代码格式（如果 clang-format 可用）

## 手动触发构建

在 GitHub 仓库页面 → Actions → Build HAP → Run workflow 即可手动触发。
