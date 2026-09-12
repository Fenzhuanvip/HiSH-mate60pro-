#include "napi/native_api.h"
#include <assert.h>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <thread>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <setjmp.h>
#include <libgen.h>
#include <mutex>
#include "codex_ohos_host.h"

#include "hilog/log.h"
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3300
#define LOG_TAG "HiSH"

struct data_buffer {
    char *buf;
    size_t size;
};

int serial_input_fd = -1;
napi_threadsafe_function on_data_callback = nullptr;
napi_threadsafe_function on_shutdown_callback = nullptr;

std::mutex buffer_mtx;
std::string temp_buffer = "";

typedef int (*QemuSystemEntry)(int, const char **);

static std::string g_nativeLibDir;

static std::string resolveNativeLibPath(const char *libName) {
    Dl_info info;
    if (dladdr(reinterpret_cast<void *>(resolveNativeLibPath), &info) && info.dli_fname) {
        std::string path = info.dli_fname;
        std::vector<char> pathCopy(path.begin(), path.end());
        pathCopy.push_back('\0');
        char *dir = dirname(pathCopy.data());
        if (dir != nullptr && dir[0] != '\0') {
            g_nativeLibDir = dir;
            return std::string(dir) + "/" + libName;
        }
    }
    return libName;
}

// 获取 native lib 目录（libhish_main.so 所在目录），供 ArkTS 层预检查文件
static std::string getNativeLibDir() {
    if (!g_nativeLibDir.empty()) {
        return g_nativeLibDir;
    }
    Dl_info info;
    if (dladdr(reinterpret_cast<void *>(resolveNativeLibPath), &info) && info.dli_fname) {
        std::string path = info.dli_fname;
        std::vector<char> pathCopy(path.begin(), path.end());
        pathCopy.push_back('\0');
        char *dir = dirname(pathCopy.data());
        if (dir != nullptr && dir[0] != '\0') {
            g_nativeLibDir = dir;
            return g_nativeLibDir;
        }
    }
    return "";
}

// 最近一次 QEMU 加载的诊断信息（JSON 格式）
static std::string g_qemuLoadDiagnostic;

static void preloadOneLib(const std::string &libDir, const char *const *names, const char *tag) {
    for (int i = 0; names[i] != nullptr; i++) {
        std::string path = libDir.empty() ? std::string(names[i]) : (libDir + "/" + names[i]);
        struct stat st;
        if (stat(path.c_str(), &st) != 0) {
            continue;
        }
        void *handle = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
        if (handle != nullptr) {
            OH_LOG_INFO(LOG_APP, "preloaded %{public}s: %{public}s", tag, path.c_str());
            return;
        }
        const char *err = dlerror();
        OH_LOG_ERROR(LOG_APP, "preload %{public}s %{public}s failed: %{public}s",
                     tag, path.c_str(), err ? err : "unknown");
    }
    for (int i = 0; names[i] != nullptr; i++) {
        void *fallback = dlopen(names[i], RTLD_NOW | RTLD_GLOBAL);
        if (fallback != nullptr) {
            OH_LOG_INFO(LOG_APP, "preloaded %{public}s by soname: %{public}s", tag, names[i]);
            return;
        }
    }
}

static void preloadQemuDeps(const std::string &libDir) {
    const char *pcre2[] = {"libpcre2-8.so", "libpcre2-8.so.0", nullptr};
    const char *zlib[] = {"libz.so", "libz.so.1", nullptr};
    const char *slirp[] = {"libslirp.so", "libslirp.so.0", nullptr};
    preloadOneLib(libDir, pcre2, "pcre2");
    preloadOneLib(libDir, zlib, "zlib");
    preloadOneLib(libDir, slirp, "slirp");
}

static void *tryDlopenQemu(const char *libName) {
    std::string fullPath = resolveNativeLibPath(libName);
    // Prepend the lib directory to LD_LIBRARY_PATH so the dynamic linker
    // can find sibling deps (slirp / pcre2 / zlib)
    {
        std::string libDir = fullPath.substr(0, fullPath.rfind('/'));
        const char *existing = getenv("LD_LIBRARY_PATH");
        std::string newPath = libDir;
        if (existing && existing[0] != '\0') {
            newPath = libDir + ":" + existing;
        }
        setenv("LD_LIBRARY_PATH", newPath.c_str(), 1);
        OH_LOG_INFO(LOG_APP, "Set LD_LIBRARY_PATH=%{public}s", newPath.c_str());
        preloadQemuDeps(libDir);
    }

    // 检查文件是否存在（避免 dlopen 报 "file not found" 和 "dep missing" 混淆）
    struct stat st;
    bool fileExists = (stat(fullPath.c_str(), &st) == 0);
    OH_LOG_INFO(LOG_APP, "dlopen trying: %{public}s (exists=%{public}d)", fullPath.c_str(), fileExists);

    void *handle = dlopen(fullPath.c_str(), RTLD_LAZY);
    if (handle != nullptr) {
        return handle;
    }
    const char *err = dlerror();
    OH_LOG_ERROR(LOG_APP, "dlopen(%{public}s) failed: %{public}s", fullPath.c_str(), err ? err : "unknown");

    if (fullPath != libName) {
        OH_LOG_INFO(LOG_APP, "dlopen fallback: %{public}s", libName);
        handle = dlopen(libName, RTLD_LAZY);
        if (handle != nullptr) {
            return handle;
        }
        err = dlerror();
        OH_LOG_ERROR(LOG_APP, "dlopen(%{public}s) failed: %{public}s", libName, err ? err : "unknown");
    }

    // 构建详细诊断信息
    std::ostringstream diag;
    diag << "{\"libName\":\"" << libName << "\""
         << ",\"fullPath\":\"" << fullPath << "\""
         << ",\"fileExists\":" << (fileExists ? "true" : "false")
         << ",\"nativeLibDir\":\"" << g_nativeLibDir << "\""
         << ",\"dlopenError\":\"" << (err ? err : "unknown") << "\""
         << "}";
    g_qemuLoadDiagnostic = diag.str();

    return nullptr;
}

static QemuSystemEntry getQemuSystemEntry(bool supportJit) {

    static QemuSystemEntry qemuSystemEntry = nullptr;

    if (qemuSystemEntry != nullptr) {
        return qemuSystemEntry;
    }

    // 重置诊断，开始新的加载尝试
    g_qemuLoadDiagnostic = "";
    std::string attemptedLib;

    void *libQemuHandle = nullptr;

    if (supportJit) {
        OH_LOG_INFO(LOG_APP, "Loading QEMU: libqemu-system-aarch64.so (JIT)");
        attemptedLib = "libqemu-system-aarch64.so";
        libQemuHandle = tryDlopenQemu("libqemu-system-aarch64.so");
    } else {
        OH_LOG_INFO(LOG_APP, "Loading QEMU: libqemu-system-aarch64-tci.so (TCI)");
        attemptedLib = "libqemu-system-aarch64-tci.so";
        libQemuHandle = tryDlopenQemu("libqemu-system-aarch64-tci.so");
        if (libQemuHandle == nullptr) {
            OH_LOG_INFO(LOG_APP, "TCI load failed, falling back to JIT");
            attemptedLib = "libqemu-system-aarch64.so (TCI->JIT fallback)";
            libQemuHandle = tryDlopenQemu("libqemu-system-aarch64.so");
        }
    }

    if (libQemuHandle == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to load QEMU library");
        // 如果 tryDlopenQemu 没设置诊断（不应该），补一个
        if (g_qemuLoadDiagnostic.empty()) {
            std::ostringstream diag;
            diag << "{\"stage\":\"dlopen_failed\",\"attemptedLib\":\"" << attemptedLib << "\""
                 << ",\"nativeLibDir\":\"" << getNativeLibDir() << "\""
                 << "}";
            g_qemuLoadDiagnostic = diag.str();
        }
        return nullptr;
    }

    qemuSystemEntry = (QemuSystemEntry)dlsym(libQemuHandle, "qemu_system_entry");
    if (qemuSystemEntry == nullptr) {
        const char *err = dlerror();
        OH_LOG_ERROR(LOG_APP, "dlsym(qemu_system_entry) failed: %{public}s", err ? err : "unknown");
        std::ostringstream diag;
        diag << "{\"stage\":\"dlsym_failed\",\"symbol\":\"qemu_system_entry\""
             << ",\"lib\":\"" << attemptedLib << "\""
             << ",\"error\":\"" << (err ? err : "symbol not found") << "\""
             << "}";
        g_qemuLoadDiagnostic = diag.str();
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "libqemu.so, handle: 0x%{public}p, entry: 0x%{public}p", libQemuHandle, qemuSystemEntry);

    return qemuSystemEntry;
}

// 前向声明
static std::string getString(napi_env env, napi_value value);

// qemu-img 入口函数类型
typedef int (*QemuImgEntry)(int, const char **);

static QemuImgEntry getQemuImgEntry() {
    static QemuImgEntry qemuImgEntry = nullptr;
    static void *libQemuImgHandle = nullptr;

    if (qemuImgEntry != nullptr) {
        return qemuImgEntry;
    }

    // Ensure LD_LIBRARY_PATH includes our lib dir (set by tryDlopenQemu earlier,
    // but also do it here in case getQemuImgEntry is called first)
    {
        std::string fullPath = resolveNativeLibPath("libqemu-img.so");
        std::string libDir = fullPath.substr(0, fullPath.rfind('/'));
        const char *existing = getenv("LD_LIBRARY_PATH");
        std::string newPath = libDir;
        if (existing && existing[0] != '\0') {
            newPath = libDir + ":" + existing;
        }
        setenv("LD_LIBRARY_PATH", newPath.c_str(), 1);
    }

    std::string libQemuImgPath = resolveNativeLibPath("libqemu-img.so");
    libQemuImgHandle = dlopen(libQemuImgPath.c_str(), RTLD_LAZY);

    if (!libQemuImgHandle) {
        const char *err = dlerror();
        OH_LOG_ERROR(LOG_APP, "Failed to load %{public}s: %{public}s", libQemuImgPath.c_str(), err ? err : "unknown");
        // fallback: try bare name
        libQemuImgHandle = dlopen("libqemu-img.so", RTLD_LAZY);
        if (!libQemuImgHandle) {
            err = dlerror();
            OH_LOG_ERROR(LOG_APP, "Failed to load libqemu-img.so: %{public}s", err ? err : "unknown");
            return nullptr;
        }
    }

    qemuImgEntry = (QemuImgEntry)dlsym(libQemuImgHandle, "qemu_img_entry");
    OH_LOG_INFO(LOG_APP, "libqemu-img.so, handle: 0x%{public}p, entry: 0x%{public}p", libQemuImgHandle, qemuImgEntry);

    return qemuImgEntry;
}

// QCOW2 文件头结构（简化版）
// 参考: https://github.com/qemu/qemu/blob/master/docs/interop/qcow2.txt
struct Qcow2Header {
    uint32_t magic;                   // 0-3: Magic number 'QFI\xfb'
    uint32_t version;                 // 4-7: Version (2 or 3)
    uint64_t backing_file_offset;     // 8-15
    uint32_t backing_file_size;       // 16-19
    uint32_t cluster_bits;            // 20-23: cluster_size = 1 << cluster_bits
    uint64_t size;                    // 24-31: Virtual size in bytes
    uint32_t crypt_method;            // 32-35
    uint32_t l1_size;                 // 36-39
    uint64_t l1_table_offset;         // 40-47
    uint64_t refcount_table_offset;   // 48-55
    uint32_t refcount_table_clusters; // 56-59
    uint32_t nb_snapshots;            // 60-63
    uint64_t snapshots_offset;        // 64-71
    // QCOW2 v3 additional fields
    uint64_t incompatible_features; // 72-79
    uint64_t compatible_features;   // 80-87
    uint64_t autoclear_features;    // 88-95
    uint32_t refcount_order;        // 96-99: refcount_bits = 1 << refcount_order
    uint32_t header_length;         // 100-103
};

// 大端转小端（网络字节序转主机字节序）
static uint32_t be32toh_manual(uint32_t val) {
    return ((val & 0xFF) << 24) | ((val & 0xFF00) << 8) |
           ((val & 0xFF0000) >> 8) | ((val & 0xFF000000) >> 24);
}

static uint64_t be64toh_manual(uint64_t val) {
    uint32_t low = (uint32_t)(val & 0xFFFFFFFF);
    uint32_t high = (uint32_t)(val >> 32);
    return ((uint64_t)be32toh_manual(low) << 32) | be32toh_manual(high);
}

// 直接从 QCOW2 文件头读取信息
static std::string getQcow2Info(const std::string &imagePath) {
    int fd = open(imagePath.c_str(), O_RDONLY);
    if (fd < 0) {
        // P1-11修复: 返回详细的错误信息
        int err = errno;
        OH_LOG_ERROR(LOG_APP, "Failed to open image file: %{public}s, errno: %{public}d (%{public}s)",
                     imagePath.c_str(), err, strerror(err));
        return "{\"error\": \"Failed to open image file\", \"errno\": " + std::to_string(err) + ", \"message\": \"" + strerror(err) + "\"}";
    }

    // 获取文件大小（实际磁盘占用）
    struct stat st;
    if (fstat(fd, &st) < 0) {
        close(fd);
        return "{\"error\": \"Failed to stat image file\"}";
    }
    uint64_t actual_size = st.st_size;

    // 读取头部
    Qcow2Header header;
    ssize_t bytesRead = read(fd, &header, sizeof(header));
    close(fd);

    if (bytesRead < 72) { // 至少需要读取到 v2 头部
        return "{\"error\": \"Failed to read QCOW2 header\"}";
    }

    // 检查 magic number
    uint32_t magic = be32toh_manual(header.magic);
    if (magic != 0x514649FB) { // 'QFI\xfb'
        return "{\"error\": \"Not a valid QCOW2 file\", \"magic\": " + std::to_string(magic) + "}";
    }

    // 解析头部字段
    uint32_t version = be32toh_manual(header.version);
    uint64_t virtual_size = be64toh_manual(header.size);
    uint32_t cluster_bits = be32toh_manual(header.cluster_bits);
    // P0-07修复: QCOW2规范要求 cluster_bits 在 9-21 范围内 (512B - 2MB clusters)
    if (cluster_bits < 9 || cluster_bits > 21) {
        return "{\"error\": \"Invalid cluster_bits value\", \"cluster_bits\": " + std::to_string(cluster_bits) + "}";
    }
    // P1-09修复: 使用 64 位无符号整数计算 cluster_size，防止中间过程溢出
    uint64_t cluster_size = 1ULL << cluster_bits;
    uint32_t nb_snapshots = be32toh_manual(header.nb_snapshots);

    // QCOW2 v3 特有字段
    bool lazy_refcounts = false;
    bool extended_l2 = false;
    uint32_t refcount_bits = 16; // 默认值

    if (version >= 3 && bytesRead >= 104) {
        uint64_t compat_features = be64toh_manual(header.compatible_features);
        lazy_refcounts = (compat_features & 0x01) != 0; // bit 0: lazy refcounts

        uint64_t incompat_features = be64toh_manual(header.incompatible_features);
        extended_l2 = (incompat_features & 0x10) != 0; // bit 4: extended L2

        uint32_t refcount_order = be32toh_manual(header.refcount_order);
        refcount_bits = 1 << refcount_order;
    }

    // 构建 JSON 输出（与 qemu-img info --output=json 格式兼容）
    std::ostringstream json;
    json << "{"
         << "\"filename\": \"" << imagePath << "\","
         << "\"format\": \"qcow2\","
         << "\"virtual-size\": " << virtual_size << ","
         << "\"actual-size\": " << actual_size << ","
         << "\"cluster-size\": " << cluster_size << ","
         << "\"format-specific\": {"
         << "\"type\": \"qcow2\","
         << "\"data\": {"
         << "\"compat\": \"" << (version >= 3 ? "1.1" : "0.10") << "\","
         << "\"lazy-refcounts\": " << (lazy_refcounts ? "true" : "false") << ","
         << "\"refcount-bits\": " << refcount_bits << ","
         << "\"extended-l2\": " << (extended_l2 ? "true" : "false") << ","
         << "\"corrupt\": false"
         << "}}"
         << "}";

    OH_LOG_INFO(LOG_APP, "QCOW2 info: version=%{public}d, virtual_size=%{public}llu, cluster_size=%{public}d",
                version, (unsigned long long)virtual_size, cluster_size);

    return json.str();
}

// NAPI 函数：获取镜像信息（直接读取 QCOW2 头部，不调用 qemu-img）
static napi_value getImageInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_value result;
        napi_create_string_utf8(env, "{\"error\": \"Missing image path argument\"}", NAPI_AUTO_LENGTH, &result);
        return result;
    }

    std::string imagePath = getString(env, args[0]);

    OH_LOG_INFO(LOG_APP, "getImageInfo called with path: %{public}s", imagePath.c_str());

    // 直接读取 QCOW2 文件头获取信息
    std::string output = getQcow2Info(imagePath);

    napi_value result;
    napi_create_string_utf8(env, output.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// ================== 快照管理功能 ==================

// QCOW2 快照头部结构
// 参考: https://github.com/qemu/qemu/blob/master/docs/interop/qcow2.txt
#pragma pack(push, 1)
struct QcowSnapshotHeader {
    uint64_t l1_table_offset; // 快照 L1 表偏移
    uint32_t l1_size;         // L1 表大小
    uint16_t id_str_size;     // ID 字符串长度
    uint16_t name_size;       // 名称长度
    uint32_t date_sec;        // 创建日期（秒）
    uint32_t date_nsec;       // 创建日期（纳秒）
    uint64_t vm_clock_nsec;   // VM 时钟（纳秒）
    uint32_t vm_state_size;   // VM 状态大小
    uint32_t extra_data_size; // QCOW2 v3: 额外数据大小
    // 后面跟着: id_str, name, padding
};
#pragma pack(pop)

// 标记 qemu-img 是否已调用过（用于检测是否需要重启）
static bool qemu_img_called = false;
static bool qemu_img_failed = false;

// 读取 QCOW2 快照列表（直接解析文件，不调用 qemu-img）
static std::string getSnapshotsFromFile(const std::string &imagePath) {
    int fd = open(imagePath.c_str(), O_RDONLY);
    if (fd < 0) {
        return "{\"error\": \"Failed to open image file\"}";
    }

    // 读取头部
    Qcow2Header header;
    ssize_t bytesRead = read(fd, &header, sizeof(header));

    if (bytesRead < 72) {
        close(fd);
        return "{\"error\": \"Failed to read QCOW2 header\"}";
    }

    // 检查 magic number
    uint32_t magic = be32toh_manual(header.magic);
    if (magic != 0x514649FB) {
        close(fd);
        return "{\"error\": \"Not a valid QCOW2 file\"}";
    }

    uint32_t nb_snapshots = be32toh_manual(header.nb_snapshots);
    uint64_t snapshots_offset = be64toh_manual(header.snapshots_offset);
    uint32_t version = be32toh_manual(header.version);

    OH_LOG_INFO(LOG_APP, "QCOW2: nb_snapshots=%{public}d, snapshots_offset=%{public}llu",
                nb_snapshots, (unsigned long long)snapshots_offset);

    if (nb_snapshots == 0) {
        close(fd);
        return "{\"snapshots\": []}";
    }

    // 跳转到快照表
    if (lseek(fd, snapshots_offset, SEEK_SET) < 0) {
        close(fd);
        return "{\"error\": \"Failed to seek to snapshot table\"}";
    }

    std::ostringstream json;
    json << "{\"snapshots\": [";

    for (uint32_t i = 0; i < nb_snapshots; i++) {
        QcowSnapshotHeader snapHeader;
        if (read(fd, &snapHeader, sizeof(snapHeader)) < (ssize_t)sizeof(snapHeader)) {
            break;
        }

        uint16_t id_str_size = (snapHeader.id_str_size >> 8) | (snapHeader.id_str_size << 8); // BE to LE
        uint16_t name_size = (snapHeader.name_size >> 8) | (snapHeader.name_size << 8);
        uint32_t date_sec = be32toh_manual(snapHeader.date_sec);
        uint64_t vm_clock_nsec = be64toh_manual(snapHeader.vm_clock_nsec);
        uint32_t vm_state_size = be32toh_manual(snapHeader.vm_state_size);
        uint32_t extra_data_size = be32toh_manual(snapHeader.extra_data_size);

        // 跳过额外数据（QCOW2 v3）
        if (version >= 3 && extra_data_size > 0) {
            lseek(fd, extra_data_size, SEEK_CUR);
        }

        // P0-04修复: 限制快照名称最大长度，防止OOM攻击
        const size_t MAX_SNAPSHOT_NAME_SIZE = 4096;

        // 读取 ID 字符串
        if (id_str_size > MAX_SNAPSHOT_NAME_SIZE) {
            OH_LOG_ERROR(LOG_APP, "Snapshot id_str_size too large: %{public}u", id_str_size);
            break;
        }
        std::string id_str(id_str_size, '\0');
        if (id_str_size > 0 && read(fd, &id_str[0], id_str_size) != id_str_size) {
            OH_LOG_ERROR(LOG_APP, "Failed to read snapshot id");
            break;
        }

        // 读取名称
        if (name_size > MAX_SNAPSHOT_NAME_SIZE) {
            OH_LOG_ERROR(LOG_APP, "Snapshot name_size too large: %{public}u", name_size);
            break;
        }
        std::string name(name_size, '\0');
        if (name_size > 0 && read(fd, &name[0], name_size) != name_size) {
            OH_LOG_ERROR(LOG_APP, "Failed to read snapshot name");
            break;
        }

        // 跳过 padding（对齐到 8 字节）
        size_t header_size = sizeof(QcowSnapshotHeader) + extra_data_size + id_str_size + name_size;
        size_t padding = (8 - (header_size % 8)) % 8;
        if (padding > 0) {
            lseek(fd, padding, SEEK_CUR);
        }

        // 转换日期
        char date_str[32];
        time_t t = (time_t)date_sec;
        struct tm *tm_info = localtime(&t);
        strftime(date_str, sizeof(date_str), "%Y-%m-%d %H:%M:%S", tm_info);

        // 转换 VM 时钟
        uint64_t vm_clock_sec = vm_clock_nsec / 1000000000ULL;
        uint32_t hours = vm_clock_sec / 3600;
        uint32_t minutes = (vm_clock_sec % 3600) / 60;
        uint32_t seconds = vm_clock_sec % 60;
        char vm_clock_str[32];
        snprintf(vm_clock_str, sizeof(vm_clock_str), "%02d:%02d:%02d.%03d",
                 hours, minutes, seconds, (int)((vm_clock_nsec % 1000000000ULL) / 1000000));

        if (i > 0)
            json << ",";
        json << "{"
             << "\"id\": " << (i + 1) << ","
             << "\"name\": \"" << name << "\","
             << "\"vm_size\": " << vm_state_size << ","
             << "\"date\": \"" << date_str << "\","
             << "\"vm_clock\": \"" << vm_clock_str << "\""
             << "}";
    }

    json << "]}";
    close(fd);

    return json.str();
}

// NAPI 函数：获取快照列表
static napi_value getSnapshots(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_value result;
        napi_create_string_utf8(env, "{\"error\": \"Missing image path argument\"}", NAPI_AUTO_LENGTH, &result);
        return result;
    }

    std::string imagePath = getString(env, args[0]);
    OH_LOG_INFO(LOG_APP, "getSnapshots called with path: %{public}s", imagePath.c_str());

    std::string output = getSnapshotsFromFile(imagePath);

    napi_value result;
    napi_create_string_utf8(env, output.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 前向声明
static napi_value createSnapshot(napi_env env, napi_callback_info info);

// 全局函数指针
static QemuImgEntry g_qemu_img_entry = nullptr;
static void *g_qemu_lib_handle = nullptr;

// 初始化 QEMU 库 (在父进程调用)
static bool initQemuLibrary() {
    if (g_qemu_img_entry != nullptr)
        return true;

    // 查找库路径
    std::string libPath = "libqemu-img.so";
    Dl_info info;
    if (dladdr((void *)createSnapshot, &info) && info.dli_fname) {
        std::string path = info.dli_fname;
        std::vector<char> pathCopy(path.begin(), path.end());
        pathCopy.push_back('\0');
        char *dir = dirname(pathCopy.data());
        libPath = std::string(dir) + "/libqemu-img.so";
    }

    // 加载库
    // 使用 RTLD_GLOBAL 确保符号可见，RTLD_NOW 立即解析
    g_qemu_lib_handle = dlopen(libPath.c_str(), RTLD_LAZY | RTLD_LOCAL);
    if (!g_qemu_lib_handle) {
        // 尝试默认路径
        g_qemu_lib_handle = dlopen("libqemu-img.so", RTLD_LAZY | RTLD_LOCAL);
    }

    if (!g_qemu_lib_handle) {
        OH_LOG_ERROR(LOG_APP, "Failed to load libqemu-img.so: %{public}s", dlerror());
        return false;
    }

    g_qemu_img_entry = (QemuImgEntry)dlsym(g_qemu_lib_handle, "qemu_img_entry");
    if (!g_qemu_img_entry) {
        OH_LOG_ERROR(LOG_APP, "Failed to find qemu_img_entry symbol");
        dlclose(g_qemu_lib_handle);
        g_qemu_lib_handle = nullptr;
        return false;
    }

    OH_LOG_INFO(LOG_APP, "Successfully loaded libqemu-img.so");
    return true;
}

// 执行 qemu-img 命令（使用 fork + 直接调用方式）
static std::string executeQemuImgCommand(const std::vector<std::string> &args) {
    // 确保库已加载
    if (!initQemuLibrary()) {
        return "{\"error\": \"Failed to load qemu-img library\"}";
    }

    int pipefd[2];
    if (pipe(pipefd) == -1) {
        OH_LOG_ERROR(LOG_APP, "pipe failed: %{public}s", strerror(errno));
        return "{\"error\": \"pipe failed\"}";
    }

    pid_t pid = fork();
    if (pid == -1) {
        OH_LOG_ERROR(LOG_APP, "fork failed: %{public}s", strerror(errno));
        close(pipefd[0]);
        close(pipefd[1]);
        return "{\"error\": \"fork failed\"}";
    }

    if (pid == 0) {       // Child process
        close(pipefd[0]); // Close read end

        // Redirect stdout and stderr to pipe
        if (dup2(pipefd[1], STDOUT_FILENO) == -1 || dup2(pipefd[1], STDERR_FILENO) == -1) {
            _exit(1);
        }
        close(pipefd[1]); // Close write end after dup

        // Prepare args
        std::vector<const char *> argv;
        for (const auto &arg : args) {
            argv.push_back(arg.c_str());
        }

        // Disable buffering
        setbuf(stdout, NULL);
        setbuf(stderr, NULL);

        // Reset signals (important in child)
        signal(SIGPIPE, SIG_DFL);

        // Ignore signals that qemu-img may trigger during shutdown
        // Signal 40, 91, 92 are OHOS-specific signals that can be triggered
        // when qemu-img cleans up resources
        struct sigaction sa;
        sa.sa_handler = SIG_IGN;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;
        sigaction(40, &sa, nullptr);
        sigaction(91, &sa, nullptr);
        sigaction(92, &sa, nullptr);
        sigaction(89, &sa, nullptr);
        sigaction(90, &sa, nullptr);
        // Call entry point directly
        // Since we forked, we have a copy of the parent's memory state.
        // The library is loaded, and global variables are in the state they were in the parent.
        // Assuming the parent NEVER calls this function, the state is clean.
        int ret = g_qemu_img_entry(argv.size(), argv.data());

        _exit(ret);
    } else {              // Parent process
        close(pipefd[1]); // Close write end

        // Read output
        std::string output;
        char buffer[1024];
        ssize_t bytesRead;
        while ((bytesRead = read(pipefd[0], buffer, sizeof(buffer) - 1)) > 0) {
            buffer[bytesRead] = '\0';
            output += buffer;
        }
        close(pipefd[0]);

        int status;
        waitpid(pid, &status, 0);

        if (WIFEXITED(status)) {
            int exit_code = WEXITSTATUS(status);
            if (exit_code != 0) {
                OH_LOG_ERROR(LOG_APP, "qemu-img exited with code %{public}d, output: %{public}s", exit_code, output.c_str());

                if (output.find("{") != 0) {
                    std::string escaped;
                    for (char c : output) {
                        switch (c) {
                        case '"':
                            escaped += "\\\"";
                            break;
                        case '\\':
                            escaped += "\\\\";
                            break;
                        case '\n':
                            escaped += "\\n";
                            break;
                        case '\r':
                            escaped += "\\r";
                            break;
                        case '\t':
                            escaped += "\\t";
                            break;
                        case '\b':
                            escaped += "\\b";
                            break;
                        case '\f':
                            escaped += "\\f";
                            break;
                        default:
                            if ((unsigned char)c < 32) {
                                // 其他不可见控制字符，转义为 \u00xx 格式
                                char temp[8];
                                snprintf(temp, sizeof(temp), "\\u%04x", (unsigned char)c);
                                escaped += temp;
                            } else {
                                escaped += c;
                            }
                            break;
                        }
                    }
                    if (escaped.empty())
                        escaped = "Unknown error (exit code " + std::to_string(exit_code) + ")";
                    return "{\"error\": \"" + escaped + "\"}";
                }
            }
        } else if (WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);
            // Signal 40, 44, 89-92 are OHOS-specific or Real-Time signals triggered during qemu-img cleanup
            // These usually happen after the work is done, so we treat them as success.
            // Standard crash signals (SEGV, ABRT, etc.) are < 32.
            if (sig >= 32) {
                OH_LOG_INFO(LOG_APP, "qemu-img terminated with signal %{public}d (assumed benign cleanup issue)", sig);
                // Continue to success path
            } else {
                OH_LOG_ERROR(LOG_APP, "qemu-img crashed with signal %{public}d", sig);
                return "{\"error\": \"qemu-img crashed with signal " + std::to_string(sig) + "\"}";
            }
        }

        if (output.empty()) {
            return "{\"success\": true}";
        }

        if (output.find("{") == 0 || output.find("[") == 0) {
            return output;
        } else {
            OH_LOG_WARN(LOG_APP, "qemu-img success but unexpected output: %{public}s", output.c_str());
            return "{\"success\": true, \"message\": \"" + output + "\"}";
        }
    }
}

// NAPI 函数：创建快照
static napi_value createSnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_value result;
        napi_create_string_utf8(env, "{\"error\": \"Missing arguments (imagePath, snapshotName)\"}", NAPI_AUTO_LENGTH, &result);
        return result;
    }

    std::string imagePath = getString(env, args[0]);
    std::string snapshotName = getString(env, args[1]);

    OH_LOG_INFO(LOG_APP, "createSnapshot: path=%{public}s, name=%{public}s", imagePath.c_str(), snapshotName.c_str());

    std::vector<std::string> cmdArgs = {"qemu-img", "snapshot", "-c", snapshotName, imagePath};
    std::string output = executeQemuImgCommand(cmdArgs);

    napi_value result;
    napi_create_string_utf8(env, output.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// NAPI 函数：恢复快照
static napi_value applySnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_value result;
        napi_create_string_utf8(env, "{\"error\": \"Missing arguments (imagePath, snapshotName)\"}", NAPI_AUTO_LENGTH, &result);
        return result;
    }

    std::string imagePath = getString(env, args[0]);
    std::string snapshotName = getString(env, args[1]);

    OH_LOG_INFO(LOG_APP, "applySnapshot: path=%{public}s, name=%{public}s", imagePath.c_str(), snapshotName.c_str());

    std::vector<std::string> cmdArgs = {"qemu-img", "snapshot", "-a", snapshotName, imagePath};
    std::string output = executeQemuImgCommand(cmdArgs);

    napi_value result;
    napi_create_string_utf8(env, output.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// NAPI 函数：删除快照
static napi_value deleteSnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_value result;
        napi_create_string_utf8(env, "{\"error\": \"Missing arguments (imagePath, snapshotName)\"}", NAPI_AUTO_LENGTH, &result);
        return result;
    }

    std::string imagePath = getString(env, args[0]);
    std::string snapshotName = getString(env, args[1]);

    OH_LOG_INFO(LOG_APP, "deleteSnapshot: path=%{public}s, name=%{public}s", imagePath.c_str(), snapshotName.c_str());

    std::vector<std::string> cmdArgs = {"qemu-img", "snapshot", "-d", snapshotName, imagePath};
    std::string output = executeQemuImgCommand(cmdArgs);

    napi_value result;
    napi_create_string_utf8(env, output.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// NAPI 函数：优化镜像
// mode: "sparse" - 稀疏压缩, "prealloc" - 预分配, "cleanup" - 清理预分配, "optimize" - 仅优化格式参数
static napi_value optimizeImage(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        napi_value result;
        napi_create_string_utf8(env, "{\"error\": \"Missing arguments (imagePath, outputPath, mode)\"}", NAPI_AUTO_LENGTH, &result);
        return result;
    }

    std::string imagePath = getString(env, args[0]);
    std::string outputPath = getString(env, args[1]);
    std::string mode = getString(env, args[2]);

    OH_LOG_INFO(LOG_APP, "optimizeImage: input=%{public}s, output=%{public}s, mode=%{public}s",
                imagePath.c_str(), outputPath.c_str(), mode.c_str());

    std::vector<std::string> cmdArgs = {"qemu-img", "convert", "-f", "qcow2", "-O", "qcow2"};

    if (mode == "prealloc") {
        // 预分配格式（最高性能）
        cmdArgs.push_back("-o");
        cmdArgs.push_back("preallocation=full");
    }
    // sparse, cleanup, optimize 模式不需要 preallocation 参数

    // 所有模式都启用优化参数
    cmdArgs.push_back("-o");
    cmdArgs.push_back("lazy_refcounts=on");
    cmdArgs.push_back("-o");
    cmdArgs.push_back("extended_l2=on");

    cmdArgs.push_back(imagePath);
    cmdArgs.push_back(outputPath);

    std::string output = executeQemuImgCommand(cmdArgs);

    napi_value result;
    napi_create_string_utf8(env, output.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

static void call_on_data_callback(napi_env env, napi_value js_callback, void *context, void *data) {

    data_buffer *buffer = static_cast<data_buffer *>(data);

    napi_value ab;
    char *input;
    napi_create_arraybuffer(env, buffer->size, (void **)&input, &ab);
    memcpy(input, buffer->buf, buffer->size);

    napi_value global;
    napi_get_global(env, &global);

    napi_value result;
    napi_value args[1] = {ab};
    napi_call_function(env, global, js_callback, 1, args, &result);

    delete[] buffer->buf;
    delete buffer;
}

static void call_on_shutdown_callback(napi_env env, napi_value js_callback, void *context, void *data) {

    napi_value global;
    napi_get_global(env, &global);

    napi_call_function(env, global, js_callback, 0, nullptr, nullptr);
}

std::string convert_to_hex(const uint8_t *buffer, int r) {
    std::string hex;
    for (int i = 0; i < r; i++) {
        if (buffer[i] >= 127 || buffer[i] < 32) {
            char temp[8];
            snprintf(temp, sizeof(temp), "\\x%02x", buffer[i]);
            hex += temp;
        } else if (buffer[i] == '\'' || buffer[i] == '\"' || buffer[i] == '\\') {
            char temp[8];
            snprintf(temp, sizeof(temp), "\\%c", buffer[i]);
            hex += temp;
        } else {
            hex += (char)buffer[i];
        }
    }
    return hex;
}

void send_data_to_callback(const uint8_t *data, size_t len, napi_threadsafe_function callback) {
    if (len == 0)
        return;
    data_buffer *pbuf = new data_buffer{.buf = new char[len], .size = len};
    memcpy(pbuf->buf, data, len);
    // 非阻塞投递：避免串口线程被阻塞拖慢（blocking 会导致 QEMU 写串口阻塞 → 虚拟机卡顿）。
    // 队列满时丢弃该块，TUI 应用会重绘补全，不会导致整体卡死。
    napi_status st = napi_call_threadsafe_function(callback, pbuf, napi_tsfn_nonblocking);
    if (st != napi_ok) {
        delete[] pbuf->buf;
        delete pbuf;
    }
}

void on_serial_data_received(const uint8_t *data, size_t len) {
    if (len > 0) {
        std::lock_guard<std::mutex> lk(buffer_mtx);
        if (on_data_callback != nullptr) {
            send_data_to_callback(data, len, on_data_callback);
        } else {
            temp_buffer.append(reinterpret_cast<const char *>(data), len);
        }
    }
}

void serial_output_worker(const char *unix_socket_path) {

    // 第一阶段：等待 QEMU 创建 serial socket 文件（最多 15 秒）
    const int kMaxWaitSeconds = 15;
    int waitedMs = 0;
    while (true) {
        int acc = access(unix_socket_path, F_OK);
        if (acc == 0) {
            break;
        }
        if (waitedMs >= kMaxWaitSeconds * 1000) {
            OH_LOG_ERROR(LOG_APP, "serial socket not created within %d seconds, QEMU likely failed to start. path=%{public}s",
                         kMaxWaitSeconds, unix_socket_path);
            return; // QEMU 没起来，退出线程避免永远阻塞
        }
        OH_LOG_INFO(LOG_APP, "serial socket not exist yet (%d ms): %{public}s", waitedMs, unix_socket_path);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        waitedMs += 200;
    }

    OH_LOG_INFO(LOG_APP, "serial socket found: %{public}s", unix_socket_path);

    // 第二阶段：连接到 QEMU serial socket（带重试）
    const int kMaxConnectAttempts = 10;
    const int kConnectRetryMs = 500;

    struct sockaddr_un server_addr;
    memset(&server_addr, 0, sizeof(struct sockaddr_un));
    server_addr.sun_family = AF_UNIX;
    // 验证路径长度，防止缓冲区溢出
    size_t path_len = strlen(unix_socket_path);
    if (path_len >= sizeof(server_addr.sun_path)) {
        OH_LOG_ERROR(LOG_APP, "Unix socket path too long: %zu >= %zu",
                     path_len, sizeof(server_addr.sun_path));
        return;
    }
    strncpy(server_addr.sun_path, unix_socket_path, sizeof(server_addr.sun_path) - 1);

    int client_fd = -1;
    for (int attempt = 1; attempt <= kMaxConnectAttempts; attempt++) {
        client_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (client_fd == -1) {
            OH_LOG_ERROR(LOG_APP, "Failed to create unix socket: %d", errno);
            return; // socket 创建失败是致命错误，不重试
        }

        if (connect(client_fd, (struct sockaddr *)&server_addr, sizeof(struct sockaddr_un)) == 0) {
            break; // 连接成功
        }

        OH_LOG_WARN(LOG_APP, "Connect serial socket failed (attempt %d/%d): errno=%d, will retry in %dms",
                    attempt, kMaxConnectAttempts, errno, kConnectRetryMs);
        close(client_fd);
        client_fd = -1;

        if (attempt < kMaxConnectAttempts) {
            std::this_thread::sleep_for(std::chrono::milliseconds(kConnectRetryMs));
        }
    }

    if (client_fd == -1) {
        OH_LOG_ERROR(LOG_APP, "Failed to connect serial socket after %d attempts, giving up", kMaxConnectAttempts);
        return;
    }

    serial_input_fd = client_fd;
    OH_LOG_INFO(LOG_APP, "Connected to serial socket: fd=%d", serial_input_fd);

    // 统计日志节流：避免每个 chunk 都打 hilog（TUI 输出密集时会严重卡顿）
    static uint64_t chunkCount = 0;
    uint8_t buffer[8192];

    while (true) {

        bool broken = false;

        struct pollfd fds[1];
        fds[0].fd = client_fd;
        fds[0].events = POLLIN;
        int res = poll(fds, 1, 100);

        if (res < 0) {
            // poll 出错，通常是 fd 被关闭或信号中断
            if (errno == EINTR) {
                continue; // 信号中断，重试
            }
            OH_LOG_ERROR(LOG_APP, "poll failed: errno=%{public}d", errno);
            break;
        }

        for (int i = 0; i < res; i += 1) {
            int fd = fds[i].fd;
            ssize_t r = read(fd, buffer, sizeof(buffer));
            if (r > 0) {
                // 直接发送原始字节给 ArkTS，不再做 \\xNN 转义（转义会破坏 TUI 转义序列）
                on_serial_data_received(buffer, (size_t)r);
                // 每 200 个 chunk 打一次概要日志，避免 I/O 瓶颈
                if ((++chunkCount % 200) == 0) {
                    OH_LOG_INFO(LOG_APP, "Serial rx chunk #%{public}llu, size=%{public}zd",
                                (unsigned long long)chunkCount, r);
                }
            } else if (r < 0) {
                if (errno == EINTR || errno == EAGAIN) {
                    continue; // 可重试错误
                }
                OH_LOG_INFO(LOG_APP, "Program exited, %{public}ld %{public}d", r, errno);
                broken = true;
            } else if (r == 0) {
                // EOF: 对端关闭了连接
                OH_LOG_INFO(LOG_APP, "Serial socket EOF - peer closed connection");
                broken = true;
            }
        }

        if (broken) {
            break;
        }
    }

    // 清理 socket 资源，但保留回调以便新的 worker 线程使用
    close(client_fd);
    serial_input_fd = -1;
    OH_LOG_INFO(LOG_APP, "Closed serial socket fd: %{public}d", client_fd);

    if (on_data_callback != nullptr) {
        napi_release_threadsafe_function(on_data_callback, napi_threadsafe_function_release_mode::napi_tsfn_release);
        on_data_callback = nullptr;
    }

    OH_LOG_INFO(LOG_APP, "Serial unix socket broken: %{public}d", errno);
}

std::string getString(napi_env env, napi_value value) {

    size_t size;
    napi_get_value_string_utf8(env, value, nullptr, 0, &size);

    char *buf = new char[size + 1];
    napi_get_value_string_utf8(env, value, buf, size + 1, &size);
    buf[size] = 0;

    std::string result = buf;
    delete[] buf;

    return result;
}

std::vector<std::string> splitStringByNewline(const std::string &input) {
    std::vector<std::string> result;
    std::istringstream iss(input);
    std::string line;
    while (std::getline(iss, line)) {
        result.push_back(line);
    }
    return result;
}

static napi_value startVM(napi_env env, napi_callback_info info) {

    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value key_name;
    napi_value nv_arg_lines;
    napi_value nv_unix_socket;
    napi_value nv_support_jit;

    napi_create_string_utf8(env, "argsLines", NAPI_AUTO_LENGTH, &key_name);
    napi_get_property(env, args[0], key_name, &nv_arg_lines);

    napi_create_string_utf8(env, "unixSocket", NAPI_AUTO_LENGTH, &key_name);
    napi_get_property(env, args[0], key_name, &nv_unix_socket);

    // 读取 supportJit 参数（由 ArkTS 层根据 deviceInfo.deviceType 传入）
    bool supportJit = true; // 默认为 true (tablet/2in1)
    napi_create_string_utf8(env, "supportJit", NAPI_AUTO_LENGTH, &key_name);
    napi_get_property(env, args[0], key_name, &nv_support_jit);
    napi_valuetype vt;
    if (napi_typeof(env, nv_support_jit, &vt) == napi_ok && vt == napi_boolean) {
        napi_get_value_bool(env, nv_support_jit, &supportJit);
    }

    std::string argsLines = getString(env, nv_arg_lines);
    std::vector<std::string> argsVector = splitStringByNewline(argsLines);

    std::string unixSocket = getString(env, nv_unix_socket);

    OH_LOG_INFO(LOG_APP, "run qemuEntry with: %{public}s, supportJit=%{public}d", argsLines.c_str(), supportJit);

    auto qemuEntry = getQemuSystemEntry(supportJit);
    if (qemuEntry == nullptr) {
        OH_LOG_ERROR(LOG_APP, "qemuEntry is null, skip starting VM");
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        return result;
    }

    std::thread vm_loop([argsVector, qemuEntry]() {
        const char **argv = new const char *[argsVector.size() + 1];
        for (auto i = 0; i < argsVector.size(); i += 1) {
            argv[i] = argsVector[i].c_str();
        }
        argv[argsVector.size()] = nullptr;

        int argc = argsVector.size();

        OH_LOG_INFO(LOG_APP, "QEMU main thread starting, argc=%d, args[0]=%{public}s", argc, argv[0]);
        for (int i = 0; i < argc; i++) {
            OH_LOG_INFO(LOG_APP, "  argv[%d] = %{public}s", i, argv[i]);
        }

        int status = qemuEntry(argc, argv);

        delete[] argv;

        OH_LOG_ERROR(LOG_APP, "QEMU main thread exited, status=%d (%{public}s)", status,
                     status == 0 ? "success" : status == 1 ? "general error"
                                           : status == 2   ? "invalid command line"
                                           : status == 127 ? "command not found (check QEMU lib)"
                                                           : "unknown error code");

        if (on_shutdown_callback != nullptr) {
            OH_LOG_INFO(LOG_APP, "Calling onShutdown callback");
            napi_call_threadsafe_function(on_shutdown_callback, nullptr, napi_tsfn_nonblocking);
        }
    });
    vm_loop.detach();

    std::thread worker([=]() { serial_output_worker(unixSocket.c_str()); });
    worker.detach();

    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

// NAPI 函数：获取 native lib 目录（libhish_main.so 所在目录）
// 供 ArkTS 层在启动前检查 QEMU so 文件是否存在
static napi_value getNativeLibDirNapi(napi_env env, napi_callback_info info) {
    std::string dir = getNativeLibDir();
    OH_LOG_INFO(LOG_APP, "getNativeLibDir: %{public}s", dir.c_str());
    napi_value result;
    napi_create_string_utf8(env, dir.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// NAPI 函数：获取最近一次 QEMU 加载的诊断信息（JSON 格式）
// 在 startVM 返回 false 后调用，获取 dlopen/dlsym 的详细错误
static napi_value getQemuLoadDiagnosticNapi(napi_env env, napi_callback_info info) {
    // 如果诊断为空（可能是因为 dlopen 还没被调用过），先触发一次 resolveNativeLibPath
    if (g_qemuLoadDiagnostic.empty() && g_nativeLibDir.empty()) {
        getNativeLibDir();
    }
    napi_value result;
    napi_create_string_utf8(env, g_qemuLoadDiagnostic.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// NAPI 函数：预检查所有需要的 QEMU 库是否存在于 native lib 目录
// 返回 JSON: {"ok": bool, "nativeLibDir": str, "libs": [{name, exists, size}]}
static napi_value preflightQemuLibs(napi_env env, napi_callback_info info) {
    std::string libDir = getNativeLibDir();

    const char *requiredLibs[] = {
        "libqemu-system-aarch64.so",
        "libqemu-img.so",
        "libslirp.so",
        "libpcre2-8.so",
        "libz.so",
        nullptr
    };

    std::ostringstream json;
    json << "{\"ok\":true,\"nativeLibDir\":\"" << libDir << "\",\"libs\":[";

    bool allOk = true;
    for (int i = 0; requiredLibs[i] != nullptr; i++) {
        std::string fullPath = libDir + "/" + requiredLibs[i];
        struct stat st;
        bool exists = (stat(fullPath.c_str(), &st) == 0);
        const char *foundName = requiredLibs[i];
        if (!exists) {
            const char *altName = nullptr;
            if (strcmp(requiredLibs[i], "libslirp.so") == 0) {
                altName = "libslirp.so.0";
            } else if (strcmp(requiredLibs[i], "libpcre2-8.so") == 0) {
                altName = "libpcre2-8.so.0";
            } else if (strcmp(requiredLibs[i], "libz.so") == 0) {
                altName = "libz.so.1";
            }
            if (altName != nullptr) {
                std::string alt = libDir + "/" + altName;
                exists = (stat(alt.c_str(), &st) == 0);
                if (exists) {
                    foundName = altName;
                }
            }
        }
        if (!exists) allOk = false;

        if (i > 0) json << ",";
        json << "{\"name\":\"" << foundName << "\""
             << ",\"exists\":" << (exists ? "true" : "false")
             << ",\"size\":" << (exists ? (unsigned long)st.st_size : 0)
             << "}";
    }
    json << "]}";

    // 更新 ok 字段
    std::string resultStr = json.str();
    if (!allOk) {
        // 把开头的 "true" 改成 "false"
        size_t pos = resultStr.find("\"ok\":true");
        if (pos != std::string::npos) {
            resultStr.replace(pos, 10, "\"ok\":false");
        }
    }

    OH_LOG_INFO(LOG_APP, "preflightQemuLibs: %{public}s", resultStr.c_str());

    napi_value result;
    napi_create_string_utf8(env, resultStr.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value sendInput(napi_env env, napi_callback_info info) {

    if (serial_input_fd < 0) {
        return nullptr;
    }

    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint8_t *data;
    size_t length;
    // P0-01修复: 移除assert，使用显式错误处理
    napi_status ret = napi_get_arraybuffer_info(env, args[0], (void **)&data, &length);
    if (ret != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "Failed to get arraybuffer info: %{public}d", ret);
        return nullptr;
    }

    // P0-06修复: 将ret改为length
    // 仅在数据较短时打印概要，避免大段粘贴/输出时的日志 I/O 瓶颈
    if (length <= 64) {
        std::string hex = convert_to_hex(data, length);
        OH_LOG_INFO(LOG_APP, "Send, data: %{public}s", hex.c_str());
    } else {
        OH_LOG_INFO(LOG_APP, "Send, len=%{public}zu", length);
    }

    int written = 0;
    while (written < (int)length) {
        // P0-02修复: 移除assert，使用显式错误处理
        int size = write(serial_input_fd, (uint8_t *)data + written, length - written);
        if (size < 0) {
            OH_LOG_ERROR(LOG_APP, "Serial write failed: errno=%{public}d", errno);
            break;
        }
        written += size;
    }

    return nullptr;
}

static napi_value onData(napi_env env, napi_callback_info info) {

    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_threadsafe_function data_callback;

    napi_value data_cb_name;
    napi_create_string_utf8(env, "data_callback", NAPI_AUTO_LENGTH, &data_cb_name);
    napi_create_threadsafe_function(env, args[0], nullptr, data_cb_name, 4096, 1, nullptr, nullptr, nullptr,
                                    call_on_data_callback, &data_callback);

    {
        std::lock_guard<std::mutex> lk(buffer_mtx);
        if (!temp_buffer.empty()) {
            send_data_to_callback(reinterpret_cast<const uint8_t *>(temp_buffer.data()),
                                  temp_buffer.size(), data_callback);
            temp_buffer.clear();
        }
        on_data_callback = data_callback;
    }

    return nullptr;
}

static napi_value onShutdown(napi_env env, napi_callback_info info) {

    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value data_cb_name;
    napi_create_string_utf8(env, "shutdown_callback", NAPI_AUTO_LENGTH, &data_cb_name);
    napi_create_threadsafe_function(env, args[0], nullptr, data_cb_name, 0, 1, nullptr, nullptr, nullptr,
                                    call_on_shutdown_callback, &on_shutdown_callback);

    return nullptr;
}

static napi_value bool_from_int(napi_env env, int v) {
    napi_value result;
    napi_get_boolean(env, v != 0, &result);
    return result;
}

static napi_value checkPortUsed(napi_env env, napi_callback_info info) {

    napi_status status;

    size_t argc = 1;
    napi_value argv[1];
    status = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (status != napi_ok) {
        return bool_from_int(env, 1);
    }

    if (argc < 1) {
        return bool_from_int(env, 1);
    }

    // Ensure the argument is a number
    napi_valuetype vt;
    status = napi_typeof(env, argv[0], &vt);
    if (status != napi_ok || (vt != napi_number)) {
        return bool_from_int(env, 1);
    }

    double port_d;
    status = napi_get_value_double(env, argv[0], &port_d);
    if (status != napi_ok) {
        return bool_from_int(env, 1);
    }

    if (!(port_d >= 0 && port_d <= 65535)) {
        return bool_from_int(env, 1);
    }

    int port = (int)port_d;

    // Create an IPv4 TCP socket
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        return bool_from_int(env, 1);
    }

    int v = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &v, sizeof(v));

    // Prepare sockaddr_in for binding to INADDR_ANY:port
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons((uint16_t)port);

    int bind_res = bind(sock, (struct sockaddr *)&sa, sizeof(sa));
    if (bind_res == 0) {
        close(sock);
        return bool_from_int(env, 0);
    } else {
        int err = errno;
        close(sock);
        if (err == EADDRINUSE) {
            return bool_from_int(env, 1);
        } else if (err == EACCES) {
            return bool_from_int(env, 1);
        } else {
            return bool_from_int(env, 1);
        }
    }
}


// ===== ArkPilot codex host bridge (begin) =====
namespace {
constexpr size_t MAX_HOME_ARG_LEN = 4096;
constexpr size_t MAX_URL_ARG_LEN = 1024;
constexpr size_t MAX_MODEL_ARG_LEN = 512;
constexpr size_t MAX_NUMBER_ARG_LEN = 64;
constexpr size_t MAX_API_KEY_ARG_LEN = 8192;
constexpr size_t MAX_CATALOG_JSON_ARG_LEN = 65536;
constexpr size_t MAX_REGISTRY_JSON_ARG_LEN = 65536;
constexpr size_t MAX_DIR_PATH_ARG_LEN = 4096;
constexpr size_t MAX_SKILL_JSON_ARG_LEN = 8192;
constexpr size_t MAX_ENTITY_ID_ARG_LEN = 512;
constexpr size_t MAX_PROMPTS_CONTENT_ARG_LEN = 262144;
constexpr size_t MAX_JSON_ARG_LEN = 262144;
constexpr const char* OHOS_DEFAULT_PATH = "/system/bin:/vendor/bin:/system/xbin:/bin";
constexpr const char* OHOS_DEFAULT_SHELL = "/system/bin/sh";

struct BridgeApi {
    void* handle = nullptr;

    int32_t (*start)(const char*, const char*) = nullptr;
    int32_t (*is_running)(void) = nullptr;
    const char* (*last_message)(void) = nullptr;
    const char* (*server_url)(void) = nullptr;
    const char* (*provider_config_json)(const char*) = nullptr;
    int32_t (*save_provider_config)(const char*, const char*, const char*, const char*, const char*, const char*) = nullptr;
    const char* (*provider_catalog_json)(const char*) = nullptr;
    int32_t (*save_provider_catalog)(const char*, const char*) = nullptr;
    const char* (*skills_registry_json)(const char*) = nullptr;
    int32_t (*save_skills_registry)(const char*, const char*) = nullptr;
    const char* (*skills_repos_json)(const char*) = nullptr;
    int32_t (*save_skills_repos)(const char*, const char*) = nullptr;
    const char* (*compute_dir_hash)(const char*) = nullptr;
    const char* (*install_skill_from_dir)(const char*, const char*, const char*) = nullptr;
    const char* (*uninstall_skill)(const char*, const char*) = nullptr;
    const char* (*set_skill_enabled)(const char*, const char*, int32_t) = nullptr;
    const char* (*reconcile_skills)(const char*) = nullptr;
    const char* (*prompts_registry_json)(const char*) = nullptr;
    int32_t (*save_prompts_registry)(const char*, const char*) = nullptr;
    const char* (*read_agents_md)(const char*) = nullptr;
    int32_t (*write_agents_md)(const char*, const char*) = nullptr;
    const char* (*enable_prompt)(const char*, const char*) = nullptr;
    int32_t (*disable_all_prompts)(const char*) = nullptr;
    const char* (*initialize)(const char*) = nullptr;
    const char* (*collaboration_mode_list)(const char*) = nullptr;
    const char* (*thread_start)(const char*) = nullptr;
    const char* (*thread_list)(const char*) = nullptr;
    const char* (*thread_read)(const char*) = nullptr;
    const char* (*thread_resume)(const char*) = nullptr;
    const char* (*thread_name_set)(const char*) = nullptr;
    const char* (*thread_archive)(const char*) = nullptr;
    const char* (*thread_compact_start)(const char*) = nullptr;
    const char* (*turn_start)(const char*) = nullptr;
    const char* (*turn_events)(const char*, const char*) = nullptr;
    const char* (*turn_poll)(const char*, const char*) = nullptr;
    const char* (*turn_interrupt)(const char*, const char*) = nullptr;
    const char* (*approval_poll)(void) = nullptr;
    int32_t (*approval_approve)(const char*) = nullptr;
    int32_t (*approval_decline)(const char*) = nullptr;
    const char* (*mcp_status_list)(const char*) = nullptr;
    const char* (*mcp_config_read)(const char*) = nullptr;
    int32_t (*mcp_config_write)(const char*) = nullptr;
    int32_t (*mcp_config_batch_write)(const char*) = nullptr;
    int32_t (*mcp_config_add)(const char*) = nullptr;
    int32_t (*mcp_config_remove)(const char*) = nullptr;
    int32_t (*mcp_reload)(void) = nullptr;
    const char* (*mcp_oauth_start)(const char*) = nullptr;
    const char* (*account_login)(const char*) = nullptr;
    const char* (*account_read)(void) = nullptr;
    const char* (*check_workspace_access)(const char*) = nullptr;
    const char* (*token_usage_aggregate)(const char*) = nullptr;
};

template <typename T>
bool LoadSymbol(void* handle, const char* name, T* target) {
    *target = reinterpret_cast<T>(dlsym(handle, name));
    return *target != nullptr;
}

bool LoadBridgeApi(BridgeApi* api) {
    api->handle = dlopen("libcodex_ohos_host.so", RTLD_NOW);
    if (api->handle == nullptr) {
        return false;
    }

    bool ok =
        LoadSymbol(api->handle, "codex_ohos_host_start", &api->start) &&
        LoadSymbol(api->handle, "codex_ohos_host_is_running", &api->is_running) &&
        LoadSymbol(api->handle, "codex_ohos_host_last_message", &api->last_message) &&
        LoadSymbol(api->handle, "codex_ohos_host_server_url", &api->server_url) &&
        LoadSymbol(api->handle, "codex_ohos_host_provider_config_json", &api->provider_config_json) &&
        LoadSymbol(api->handle, "codex_ohos_host_save_provider_config", &api->save_provider_config) &&
        LoadSymbol(api->handle, "codex_ohos_host_provider_catalog_json", &api->provider_catalog_json) &&
        LoadSymbol(api->handle, "codex_ohos_host_save_provider_catalog", &api->save_provider_catalog) &&
        LoadSymbol(api->handle, "codex_ohos_host_skills_registry_json", &api->skills_registry_json) &&
        LoadSymbol(api->handle, "codex_ohos_host_save_skills_registry", &api->save_skills_registry) &&
        LoadSymbol(api->handle, "codex_ohos_host_skills_repos_json", &api->skills_repos_json) &&
        LoadSymbol(api->handle, "codex_ohos_host_save_skills_repos", &api->save_skills_repos) &&
        LoadSymbol(api->handle, "codex_ohos_host_compute_dir_hash", &api->compute_dir_hash) &&
        LoadSymbol(api->handle, "codex_ohos_host_install_skill_from_dir", &api->install_skill_from_dir) &&
        LoadSymbol(api->handle, "codex_ohos_host_uninstall_skill", &api->uninstall_skill) &&
        LoadSymbol(api->handle, "codex_ohos_host_set_skill_enabled", &api->set_skill_enabled) &&
        LoadSymbol(api->handle, "codex_ohos_host_reconcile_skills", &api->reconcile_skills) &&
        LoadSymbol(api->handle, "codex_ohos_host_prompts_registry_json", &api->prompts_registry_json) &&
        LoadSymbol(api->handle, "codex_ohos_host_save_prompts_registry", &api->save_prompts_registry) &&
        LoadSymbol(api->handle, "codex_ohos_host_read_agents_md", &api->read_agents_md) &&
        LoadSymbol(api->handle, "codex_ohos_host_write_agents_md", &api->write_agents_md) &&
        LoadSymbol(api->handle, "codex_ohos_host_enable_prompt", &api->enable_prompt) &&
        LoadSymbol(api->handle, "codex_ohos_host_disable_all_prompts", &api->disable_all_prompts) &&
        LoadSymbol(api->handle, "codex_ohos_host_initialize", &api->initialize) &&
        LoadSymbol(api->handle, "codex_ohos_host_collaboration_mode_list", &api->collaboration_mode_list) &&
        LoadSymbol(api->handle, "codex_ohos_host_thread_start", &api->thread_start) &&
        LoadSymbol(api->handle, "codex_ohos_host_thread_list", &api->thread_list) &&
        LoadSymbol(api->handle, "codex_ohos_host_thread_read", &api->thread_read) &&
        LoadSymbol(api->handle, "codex_ohos_host_thread_resume", &api->thread_resume) &&
        LoadSymbol(api->handle, "codex_ohos_host_thread_name_set", &api->thread_name_set) &&
        LoadSymbol(api->handle, "codex_ohos_host_thread_archive", &api->thread_archive) &&
        LoadSymbol(api->handle, "codex_ohos_host_thread_compact_start", &api->thread_compact_start) &&
        LoadSymbol(api->handle, "codex_ohos_host_turn_start", &api->turn_start) &&
        LoadSymbol(api->handle, "codex_ohos_host_turn_events", &api->turn_events) &&
        LoadSymbol(api->handle, "codex_ohos_host_turn_poll", &api->turn_poll) &&
        LoadSymbol(api->handle, "codex_ohos_host_turn_interrupt", &api->turn_interrupt) &&
        LoadSymbol(api->handle, "codex_ohos_host_approval_poll", &api->approval_poll) &&
        LoadSymbol(api->handle, "codex_ohos_host_approval_approve", &api->approval_approve) &&
        LoadSymbol(api->handle, "codex_ohos_host_approval_decline", &api->approval_decline) &&
        LoadSymbol(api->handle, "codex_ohos_host_mcp_status_list", &api->mcp_status_list) &&
        LoadSymbol(api->handle, "codex_ohos_host_mcp_config_read", &api->mcp_config_read) &&
        LoadSymbol(api->handle, "codex_ohos_host_mcp_config_write", &api->mcp_config_write) &&
        LoadSymbol(api->handle, "codex_ohos_host_mcp_config_batch_write", &api->mcp_config_batch_write) &&
        LoadSymbol(api->handle, "codex_ohos_host_mcp_config_add", &api->mcp_config_add) &&
        LoadSymbol(api->handle, "codex_ohos_host_mcp_config_remove", &api->mcp_config_remove) &&
        LoadSymbol(api->handle, "codex_ohos_host_mcp_reload", &api->mcp_reload) &&
        LoadSymbol(api->handle, "codex_ohos_host_mcp_oauth_start", &api->mcp_oauth_start) &&
        LoadSymbol(api->handle, "codex_ohos_host_account_login", &api->account_login) &&
        LoadSymbol(api->handle, "codex_ohos_host_account_read", &api->account_read);

    if (!ok) {
        dlclose(api->handle);
        api->handle = nullptr;
        return false;
    }

    LoadSymbol(api->handle, "codex_ohos_host_check_workspace_access", &api->check_workspace_access);
    LoadSymbol(api->handle, "codex_ohos_host_token_usage_aggregate", &api->token_usage_aggregate);
    return true;
}

BridgeApi& SharedBridgeApi() {
    static BridgeApi api;
    return api;
}

std::mutex& SharedBridgeApiMutex() {
    static std::mutex mutex;
    return mutex;
}

bool AcquireBridgeApi(BridgeApi** api) {
    std::lock_guard<std::mutex> lock(SharedBridgeApiMutex());
    BridgeApi& shared = SharedBridgeApi();
    if (shared.handle == nullptr && !LoadBridgeApi(&shared)) {
        *api = nullptr;
        return false;
    }
    *api = &shared;
    return true;
}

void UnloadBridgeApi(BridgeApi* api) {
    (void)api;
}

void EnsureOhosShellEnvironment() {
#if defined(__OHOS__)
    const char* current_path = std::getenv("PATH");
    if (current_path == nullptr || current_path[0] == '\0') {
        setenv("PATH", OHOS_DEFAULT_PATH, 1);
    } else if (std::strstr(current_path, "/system/bin") == nullptr) {
        std::string merged_path(OHOS_DEFAULT_PATH);
        merged_path.push_back(':');
        merged_path.append(current_path);
        setenv("PATH", merged_path.c_str(), 1);
    }

    const char* current_shell = std::getenv("SHELL");
    if (current_shell == nullptr || current_shell[0] == '\0') {
        setenv("SHELL", OHOS_DEFAULT_SHELL, 1);
    }
#endif
}


bool ReadOptionalUtf8(napi_env env, napi_value value, char* buffer, size_t capacity) {
    if (capacity == 0) {
        return false;
    }
    buffer[0] = '\0';
    if (value == nullptr) {
        return true;
    }
    napi_valuetype value_type = napi_undefined;
    if (napi_typeof(env, value, &value_type) != napi_ok) {
        return false;
    }
    if (value_type == napi_undefined || value_type == napi_null) {
        return true;
    }
    if (value_type != napi_string) {
        napi_throw_type_error(env, nullptr, "Expected a string argument.");
        return false;
    }
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buffer, capacity, &copied) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read UTF-8 string argument.");
        return false;
    }
    buffer[copied] = '\0';
    return true;
}

napi_value CreateUtf8String(napi_env env, const char* value) {
    napi_value result = nullptr;
    napi_create_string_utf8(env, value == nullptr ? "" : value, NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value CreateBoolean(napi_env env, bool value) {
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value CreateInt32(napi_env env, int32_t value) {
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value ThrowLoadError(napi_env env) {
    napi_throw_error(env, nullptr, "Failed to load libcodex_ohos_host.so.");
    return nullptr;
}

napi_value BuildStatusObject(napi_env env, BridgeApi* api, int32_t code) {
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "running", CreateBoolean(env, api->is_running() == 1));
    napi_set_named_property(env, result, "message", CreateUtf8String(env, api->last_message()));
    napi_set_named_property(env, result, "serverUrl", CreateUtf8String(env, api->server_url()));
    napi_set_named_property(env, result, "code", CreateInt32(env, code));
    return result;
}

napi_value StartHost(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr;
    if (!AcquireBridgeApi(&api)) {
        return ThrowLoadError(env);
    }
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN];
    char server_url[MAX_URL_ARG_LEN];
    codex_home[0] = '\0';
    server_url[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) {
        return nullptr;
    }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], server_url, sizeof(server_url))) {
        return nullptr;
    }
    EnsureOhosShellEnvironment();
    int32_t code = api->start(codex_home[0] == '\0' ? nullptr : codex_home, server_url[0] == '\0' ? nullptr : server_url);
    napi_value result = BuildStatusObject(env, api, code);
    return result;
}

napi_value GetStatus(napi_env env, napi_callback_info info) {
    (void)info;
    BridgeApi* api = nullptr;
    if (!AcquireBridgeApi(&api)) {
        return ThrowLoadError(env);
    }
    napi_value result = BuildStatusObject(env, api, 0);
    return result;
}

napi_value IsHostRunning(napi_env env, napi_callback_info info) {
    (void)info;
    BridgeApi* api = nullptr;
    if (!AcquireBridgeApi(&api)) {
        return ThrowLoadError(env);
    }
    napi_value result = CreateBoolean(env, api->is_running() == 1);
    return result;
}

napi_value GetLastMessage(napi_env env, napi_callback_info info) {
    (void)info;
    BridgeApi* api = nullptr;
    if (!AcquireBridgeApi(&api)) {
        return ThrowLoadError(env);
    }
    napi_value result = CreateUtf8String(env, api->last_message());
    return result;
}

napi_value GetServerUrl(napi_env env, napi_callback_info info) {
    (void)info;
    BridgeApi* api = nullptr;
    if (!AcquireBridgeApi(&api)) {
        return ThrowLoadError(env);
    }
    napi_value result = CreateUtf8String(env, api->server_url());
    return result;
}

napi_value CallString1(napi_env env, napi_callback_info info, const char* (*fn)(const char*)) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char arg0[MAX_JSON_ARG_LEN];
    arg0[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], arg0, sizeof(arg0))) {
        return nullptr;
    }
    return CreateUtf8String(env, fn(arg0[0] == '\0' ? nullptr : arg0));
}

napi_value CallString2(napi_env env, napi_callback_info info, const char* (*fn)(const char*, const char*)) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char arg0[MAX_JSON_ARG_LEN];
    char arg1[MAX_JSON_ARG_LEN];
    arg0[0] = '\0';
    arg1[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], arg0, sizeof(arg0))) {
        return nullptr;
    }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], arg1, sizeof(arg1))) {
        return nullptr;
    }
    return CreateUtf8String(env, fn(arg0[0] == '\0' ? nullptr : arg0, arg1[0] == '\0' ? nullptr : arg1));
}

napi_value CallIntString1(napi_env env, napi_callback_info info, int32_t (*fn)(const char*)) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char arg0[MAX_JSON_ARG_LEN];
    arg0[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], arg0, sizeof(arg0))) {
        return nullptr;
    }
    return CreateInt32(env, fn(arg0[0] == '\0' ? nullptr : arg0));
}

napi_value GetProviderConfig(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    napi_value result = CallString1(env, info, api->provider_config_json);
    return result;
}

napi_value SaveProviderConfig(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 6; napi_value args[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], base_url[MAX_URL_ARG_LEN], api_key[MAX_API_KEY_ARG_LEN], model[MAX_MODEL_ARG_LEN], context_window[MAX_NUMBER_ARG_LEN], model_auto_compact_token_limit[MAX_NUMBER_ARG_LEN];
    codex_home[0] = '\0'; base_url[0] = '\0'; api_key[0] = '\0'; model[0] = '\0'; context_window[0] = '\0'; model_auto_compact_token_limit[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], base_url, sizeof(base_url))) { return nullptr; }
    if (argc >= 3 && !ReadOptionalUtf8(env, args[2], api_key, sizeof(api_key))) { return nullptr; }
    if (argc >= 4 && !ReadOptionalUtf8(env, args[3], model, sizeof(model))) { return nullptr; }
    if (argc >= 5 && !ReadOptionalUtf8(env, args[4], context_window, sizeof(context_window))) { return nullptr; }
    if (argc >= 6 && !ReadOptionalUtf8(env, args[5], model_auto_compact_token_limit, sizeof(model_auto_compact_token_limit))) { return nullptr; }
    int32_t code = api->save_provider_config(
        codex_home[0] == '\0' ? nullptr : codex_home,
        base_url[0] == '\0' ? nullptr : base_url,
        api_key[0] == '\0' ? nullptr : api_key,
        model[0] == '\0' ? nullptr : model,
        context_window[0] == '\0' ? nullptr : context_window,
        model_auto_compact_token_limit[0] == '\0' ? nullptr : model_auto_compact_token_limit);
    if (code != 0) { napi_throw_error(env, nullptr, "Failed to save provider config."); return nullptr; }
    napi_value result = CreateUtf8String(env, api->provider_config_json(codex_home[0] == '\0' ? nullptr : codex_home));
    return result;
}

napi_value GetProviderCatalog(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    napi_value result = CallString1(env, info, api->provider_catalog_json);
    return result;
}

napi_value SaveProviderCatalog(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 2; napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], catalog_json[MAX_CATALOG_JSON_ARG_LEN];
    codex_home[0] = '\0'; catalog_json[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], catalog_json, sizeof(catalog_json))) { return nullptr; }
    int32_t code = api->save_provider_catalog(codex_home[0] == '\0' ? nullptr : codex_home, catalog_json[0] == '\0' ? nullptr : catalog_json);
    if (code != 0) { napi_throw_error(env, nullptr, "Failed to save provider catalog."); return nullptr; }
    napi_value result = CreateUtf8String(env, api->provider_catalog_json(codex_home[0] == '\0' ? nullptr : codex_home));
    return result;
}

napi_value GetSkillsRegistry(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->skills_registry_json); return result; }
napi_value SaveSkillsRegistry(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 2; napi_value args[2] = {nullptr, nullptr}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], registry_json[MAX_REGISTRY_JSON_ARG_LEN]; codex_home[0] = '\0'; registry_json[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], registry_json, sizeof(registry_json))) { return nullptr; }
    napi_value result = CreateInt32(env, api->save_skills_registry(codex_home[0] == '\0' ? nullptr : codex_home, registry_json[0] == '\0' ? nullptr : registry_json));
    return result;
}
napi_value GetSkillsRepos(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->skills_repos_json); return result; }
napi_value SaveSkillsRepos(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 2; napi_value args[2] = {nullptr, nullptr}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], repos_json[MAX_REGISTRY_JSON_ARG_LEN]; codex_home[0] = '\0'; repos_json[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], repos_json, sizeof(repos_json))) { return nullptr; }
    napi_value result = CreateInt32(env, api->save_skills_repos(codex_home[0] == '\0' ? nullptr : codex_home, repos_json[0] == '\0' ? nullptr : repos_json));
    return result;
}
napi_value ComputeDirHash(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->compute_dir_hash); return result; }

napi_value InstallSkillFromDir(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 3; napi_value args[3] = {nullptr, nullptr, nullptr}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], source_dir[MAX_DIR_PATH_ARG_LEN], skill_json[MAX_SKILL_JSON_ARG_LEN]; codex_home[0] = '\0'; source_dir[0] = '\0'; skill_json[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], source_dir, sizeof(source_dir))) { return nullptr; }
    if (argc >= 3 && !ReadOptionalUtf8(env, args[2], skill_json, sizeof(skill_json))) { return nullptr; }
    napi_value result = CreateUtf8String(env, api->install_skill_from_dir(codex_home[0] == '\0' ? nullptr : codex_home, source_dir[0] == '\0' ? nullptr : source_dir, skill_json[0] == '\0' ? nullptr : skill_json));
    return result;
}

napi_value UninstallSkill(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 2; napi_value args[2] = {nullptr, nullptr}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], skill_id[MAX_ENTITY_ID_ARG_LEN]; codex_home[0] = '\0'; skill_id[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], skill_id, sizeof(skill_id))) { return nullptr; }
    napi_value result = CreateUtf8String(env, api->uninstall_skill(codex_home[0] == '\0' ? nullptr : codex_home, skill_id[0] == '\0' ? nullptr : skill_id));
    return result;
}

napi_value SetSkillEnabled(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 3; napi_value args[3] = {nullptr, nullptr, nullptr}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], skill_id[MAX_ENTITY_ID_ARG_LEN]; codex_home[0] = '\0'; skill_id[0] = '\0';
    int32_t enabled = 1;
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], skill_id, sizeof(skill_id))) { return nullptr; }
    if (argc >= 3) { napi_get_value_int32(env, args[2], &enabled); }
    napi_value result = CreateUtf8String(env, api->set_skill_enabled(codex_home[0] == '\0' ? nullptr : codex_home, skill_id[0] == '\0' ? nullptr : skill_id, enabled));
    return result;
}

napi_value ReconcileSkills(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->reconcile_skills); return result; }

napi_value GetPromptsRegistry(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->prompts_registry_json); return result; }
napi_value SavePromptsRegistry(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 2; napi_value args[2] = {nullptr, nullptr}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], registry_json[MAX_REGISTRY_JSON_ARG_LEN]; codex_home[0] = '\0'; registry_json[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], registry_json, sizeof(registry_json))) { return nullptr; }
    napi_value result = CreateInt32(env, api->save_prompts_registry(codex_home[0] == '\0' ? nullptr : codex_home, registry_json[0] == '\0' ? nullptr : registry_json));
    return result;
}
napi_value ReadAgentsMd(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->read_agents_md); return result; }

napi_value WriteAgentsMd(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 2; napi_value args[2] = {nullptr, nullptr}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], content[MAX_PROMPTS_CONTENT_ARG_LEN]; codex_home[0] = '\0'; content[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], content, sizeof(content))) { return nullptr; }
    napi_value result = CreateInt32(env, api->write_agents_md(codex_home[0] == '\0' ? nullptr : codex_home, content[0] == '\0' ? nullptr : content));
    return result;
}

napi_value EnablePrompt(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 2; napi_value args[2] = {nullptr, nullptr}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN], prompt_id[MAX_ENTITY_ID_ARG_LEN]; codex_home[0] = '\0'; prompt_id[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    if (argc >= 2 && !ReadOptionalUtf8(env, args[1], prompt_id, sizeof(prompt_id))) { return nullptr; }
    napi_value result = CreateUtf8String(env, api->enable_prompt(codex_home[0] == '\0' ? nullptr : codex_home, prompt_id[0] == '\0' ? nullptr : prompt_id));
    return result;
}

napi_value DisableAllPrompts(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env);
    size_t argc = 1; napi_value args[1] = {nullptr}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codex_home[MAX_HOME_ARG_LEN]; codex_home[0] = '\0';
    if (argc >= 1 && !ReadOptionalUtf8(env, args[0], codex_home, sizeof(codex_home))) { return nullptr; }
    napi_value result = CreateInt32(env, api->disable_all_prompts(codex_home[0] == '\0' ? nullptr : codex_home));
    return result;
}

napi_value InitializeBridge(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->initialize); return result; }
napi_value CollaborationModeList(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->collaboration_mode_list); return result; }
napi_value ThreadStart(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->thread_start); return result; }
napi_value ThreadList(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->thread_list); return result; }
napi_value ThreadRead(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->thread_read); return result; }
napi_value ThreadResume(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->thread_resume); return result; }
napi_value ThreadNameSet(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->thread_name_set); return result; }
napi_value ThreadArchive(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->thread_archive); return result; }
napi_value ThreadCompactStart(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->thread_compact_start); return result; }
napi_value TurnStart(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->turn_start); return result; }
napi_value TurnEvents(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString2(env, info, api->turn_events); return result; }
napi_value TurnPoll(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString2(env, info, api->turn_poll); return result; }
napi_value TurnInterrupt(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString2(env, info, api->turn_interrupt); return result; }
napi_value ApprovalPoll(napi_env env, napi_callback_info info) { (void)info; BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CreateUtf8String(env, api->approval_poll()); return result; }
napi_value ApprovalApprove(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallIntString1(env, info, api->approval_approve); return result; }
napi_value ApprovalDecline(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallIntString1(env, info, api->approval_decline); return result; }
napi_value McpStatusList(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->mcp_status_list); return result; }
napi_value McpConfigRead(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->mcp_config_read); return result; }
napi_value McpConfigWrite(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallIntString1(env, info, api->mcp_config_write); return result; }
napi_value McpConfigBatchWrite(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallIntString1(env, info, api->mcp_config_batch_write); return result; }
napi_value McpConfigAdd(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallIntString1(env, info, api->mcp_config_add); return result; }
napi_value McpConfigRemove(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallIntString1(env, info, api->mcp_config_remove); return result; }
napi_value McpReload(napi_env env, napi_callback_info info) { (void)info; BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CreateInt32(env, api->mcp_reload()); return result; }
napi_value McpOauthStart(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->mcp_oauth_start); return result; }
napi_value AccountLogin(napi_env env, napi_callback_info info) { BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CallString1(env, info, api->account_login); return result; }
napi_value AccountRead(napi_env env, napi_callback_info info) { (void)info; BridgeApi* api = nullptr; if (!AcquireBridgeApi(&api)) return ThrowLoadError(env); napi_value result = CreateUtf8String(env, api->account_read()); return result; }
napi_value CheckWorkspaceAccess(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr;
    if (!AcquireBridgeApi(&api)) {
        return ThrowLoadError(env);
    }
    if (api->check_workspace_access == nullptr) {
        return CreateUtf8String(env, "{\"rootPath\":\"\",\"accessKind\":\"unknown\",\"permissionState\":\"unavailable\",\"writable\":false,\"exists\":false,\"message\":\"workspace access probe unavailable\"}");
    }
    napi_value result = CallString1(env, info, api->check_workspace_access);
    return result;
}

napi_value TokenUsageAggregate(napi_env env, napi_callback_info info) {
    BridgeApi* api = nullptr;
    if (!AcquireBridgeApi(&api)) {
        return ThrowLoadError(env);
    }
    if (api->token_usage_aggregate == nullptr) {
        return CreateUtf8String(env, "{\"today\":0,\"thisWeek\":0,\"thisMonth\":0}");
    }
    napi_value result = CallString1(env, info, api->token_usage_aggregate);
    return result;
}
}  // namespace

// ===== ArkPilot codex host bridge (end) =====

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"startVM", nullptr, startVM, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onData", nullptr, onData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onShutdown", nullptr, onShutdown, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendInput", nullptr, sendInput, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"checkPortUsed", nullptr, checkPortUsed, nullptr, nullptr, nullptr, napi_default, nullptr},
        // 快照管理功能
        {"getImageInfo", nullptr, getImageInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSnapshots", nullptr, getSnapshots, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createSnapshot", nullptr, createSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"applySnapshot", nullptr, applySnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"deleteSnapshot", nullptr, deleteSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"optimizeImage", nullptr, optimizeImage, nullptr, nullptr, nullptr, napi_default, nullptr},
        // QEMU 运行时诊断功能
        {"getNativeLibDir", nullptr, getNativeLibDirNapi, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getQemuLoadDiagnostic", nullptr, getQemuLoadDiagnosticNapi, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"preflightQemuLibs", nullptr, preflightQemuLibs, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ArkPilot codex host bridge
        {"startHost", nullptr, StartHost, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStatus", nullptr, GetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isHostRunning", nullptr, IsHostRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLastMessage", nullptr, GetLastMessage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getServerUrl", nullptr, GetServerUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getProviderConfig", nullptr, GetProviderConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveProviderConfig", nullptr, SaveProviderConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getProviderCatalog", nullptr, GetProviderCatalog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveProviderCatalog", nullptr, SaveProviderCatalog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSkillsRegistry", nullptr, GetSkillsRegistry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveSkillsRegistry", nullptr, SaveSkillsRegistry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSkillsRepos", nullptr, GetSkillsRepos, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveSkillsRepos", nullptr, SaveSkillsRepos, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"computeDirHash", nullptr, ComputeDirHash, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"installSkillFromDir", nullptr, InstallSkillFromDir, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"uninstallSkill", nullptr, UninstallSkill, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setSkillEnabled", nullptr, SetSkillEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reconcileSkills", nullptr, ReconcileSkills, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPromptsRegistry", nullptr, GetPromptsRegistry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"savePromptsRegistry", nullptr, SavePromptsRegistry, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readAgentsMd", nullptr, ReadAgentsMd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeAgentsMd", nullptr, WriteAgentsMd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"enablePrompt", nullptr, EnablePrompt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"disableAllPrompts", nullptr, DisableAllPrompts, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initialize", nullptr, InitializeBridge, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"collaborationModeList", nullptr, CollaborationModeList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"threadStart", nullptr, ThreadStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"threadList", nullptr, ThreadList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"threadRead", nullptr, ThreadRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"threadResume", nullptr, ThreadResume, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"threadNameSet", nullptr, ThreadNameSet, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"threadArchive", nullptr, ThreadArchive, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"threadCompactStart", nullptr, ThreadCompactStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"turnStart", nullptr, TurnStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"turnEvents", nullptr, TurnEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"turnPoll", nullptr, TurnPoll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"turnInterrupt", nullptr, TurnInterrupt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"approvalPoll", nullptr, ApprovalPoll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"approvalApprove", nullptr, ApprovalApprove, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"approvalDecline", nullptr, ApprovalDecline, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mcpStatusList", nullptr, McpStatusList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mcpConfigRead", nullptr, McpConfigRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mcpConfigWrite", nullptr, McpConfigWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mcpConfigBatchWrite", nullptr, McpConfigBatchWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mcpConfigAdd", nullptr, McpConfigAdd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mcpConfigRemove", nullptr, McpConfigRemove, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mcpReload", nullptr, McpReload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mcpOauthStart", nullptr, McpOauthStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"accountLogin", nullptr, AccountLogin, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"accountRead", nullptr, AccountRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"checkWorkspaceAccess", nullptr, CheckWorkspaceAccess, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tokenUsageAggregate", nullptr, TokenUsageAggregate, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "hish_main",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&demoModule);
}
