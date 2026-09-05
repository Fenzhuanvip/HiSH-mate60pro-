# GitHub Actions 工作流说明

## 工作流文件

### 1. `build-hap.yml` — 完整构建 + 签名 + 发布 HAP

完整 CI/CD pipeline 包含 5 个 job，覆盖从内核到 HAP 的全链路构建。

**触发条件：**
- push 到 master 分支 → 自动构建
- 打 `v*` 标签（如 `v1.0.0`）→ 构建并发布到 GitHub Releases
- Pull Request → 自动构建检查
- 手动触发（Actions 页面 → Run workflow）

**构建流程（4 个并行/串行 job）：**

| Job | 运行环境 | 说明 |
|-----|---------|------|
| `build-kernel` | ubuntu-latest | 克隆 Linux v6.12 源码，下载 arm64_virt 配置，用 LLVM/Clang 交叉编译内核，产物 `kernel_aarch64` |
| `build-qemu` | Docker 镜像 | 在预构建镜像中运行 `deps/Makefile`，编译 QEMU 及 6 个依赖库（zstd/zlib/pcre2/libglib/pixman/libqemu），产物 `.so` + keymaps + efi-virtio.rom |
| `build-rootfs` | ubuntu-latest | 下载 Alpine v3.22 minirootfs，创建 8G ext4 镜像，填充内容后转为 qcow2，产物 `rootfs_aarch64.qcow2` |
| `build-hap` | Docker 镜像 | 下载前三个 job 的产物，放置到正确目录后 `ohpm install` + `hvigorw assembleHap`，产物 `.hap` |

**发布流程（仅打标签时触发）：**

| Job | 说明 |
|-----|------|
| `publish` | 下载 HAP artifact，用 `hap-sign-tool` 签名（需配置 Secrets），创建 GitHub Release |

**Docker 镜像：**
`ghcr.io/sanchuanhehe/harmony-next-pipeline-docker/harmonyos-ci-image:latest`
内置 ohpm、hvigorw、hap-sign-tool、HarmonyOS SDK LLVM 工具链等全部构建工具，无需手动下载 SDK。

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
每次 push 到 master 自动触发全链路构建。

### 手动触发
GitHub 仓库 → Actions → Build HAP → Run workflow

### 发布 Release
```bash
git tag v1.0.0
git push origin v1.0.0
```
会自动构建内核、QEMU、rootfs、HAP，签名并创建 GitHub Release。

## 参考

工作流基于 [harmony-next-pipeline](https://gitcode.com/sanchuanhehe1/harmony-next-pipeline) 项目适配。
