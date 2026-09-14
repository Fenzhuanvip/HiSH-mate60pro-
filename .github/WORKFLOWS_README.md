# GitHub Actions 工作流说明

构建入口只有仓库工作流。产物是未签名 HAP artifact，不发布 Release。

## `build-hap.yml`

**触发：** push / PR 到 `master`，或 Actions 手动 Run workflow。

| Job | 产物 |
|-----|------|
| `build-kernel` | `kernel_aarch64` |
| `build-qemu` | `libqemu-system-aarch64.so` / `libqemu-img.so` / `libslirp.so` / `libpcre2-8.so` / `libz.so` |
| `build-rootfs` | `rootfs_aarch64.qcow2` |
| `build-hap` | artifact `phone-hap` |

`build-hap` 把 QEMU 库放到 `feature/hish_main/src/main/libs/arm64-v8a/`，并校验 HAP 内包含：

- `libqemu-system-aarch64.so`
- `libqemu-img.so`
- `libslirp.so`
- `libpcre2-8.so`
- `libz.so`
- `libhish_main.so`

HarmonyOS 只打包 `lib*.so`。工作流把 slirp / pcre2 写成无版本名，不用 `*.so.0`。

镜像：`ghcr.io/sanchuanhehe/harmony-next-pipeline-docker/harmonyos-ci-image:latest`

## `lint.yml`

push/PR 检查 `.ets` 括号和 C++ 格式。

## 产物

Actions → Build HAP (Phone Only) → 下载 `phone-hap`。
