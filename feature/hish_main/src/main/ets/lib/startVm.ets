import { fileIo as fs } from '@kit.CoreFileKit'
import napi from 'libhish_main.so'
import { defaultEmulator, PortMapping } from '../model/Emulator'
import deviceInfo from '@ohos.deviceInfo'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0000

interface VmOptions {
  baseDir: string
  cpu: number
  memory: number
  portMapping: PortMapping[]
  kernel: string
  rootVda: string
  rootFilesystem: string
  sharedFolder: string
  serialUnixSocket: string
  qmpUnixSocket: string
  qgaUnixSocket: string
  sharedFolderReadonly: boolean
  init: string,
}

interface RequiredFile {
  path: string
  label: string
}

// startVm 返回值：不仅有成功/失败，还携带诊断信息
export interface VmStartResult {
  success: boolean
  errorCode?: 'PREFLIGHT_FAILED' | 'DLOPEN_FAILED' | 'DLSYM_FAILED' | 'KEYFILE_MISSING' | 'UNKNOWN'
  errorMessage?: string
  nativeLibDir?: string
  missingLibs?: string[]
  dlopenError?: string
}

function startVm(options: VmOptions): VmStartResult {
  hilog.info(DOMAIN, 'startVm', '=== startVm called ===')

  // === Phase 0: Native Lib 预检查 ===
  // 在启动 VM 前先用 native 层检查 QEMU so 文件是否存在
  let preflightResult: any = null
  let nativeLibDir: string = ''
  try {
    const preflightRaw = napi.preflightQemuLibs()
    hilog.info(DOMAIN, 'startVm', 'preflightQemuLibs raw: %{public}s', preflightRaw)
    preflightResult = JSON.parse(preflightRaw)
    nativeLibDir = preflightResult.nativeLibDir || ''

    if (!preflightResult.ok) {
      const missing = (preflightResult.libs || [])
        .filter((l: any) => !l.exists)
        .map((l: any) => l.name)
      hilog.error(DOMAIN, 'startVm',
        'PREFLIGHT FAILED: nativeLibDir=%{public}s, missing=%{public}s',
        nativeLibDir, JSON.stringify(missing))

      const details = missing.map((m: string) =>
        `  - ${m} (expected at: ${nativeLibDir}/${m})`).join('\n')
      return {
        success: false,
        errorCode: 'PREFLIGHT_FAILED',
        errorMessage: `QEMU 运行库缺失！native lib 目录: ${nativeLibDir}\n缺失文件:\n${details}\n\n请用 GitHub Actions 工作流 build-hap 重新构建 HAP 并安装。`,
        nativeLibDir,
        missingLibs: missing,
      }
    }
    hilog.info(DOMAIN, 'startVm', 'preflight OK, nativeLibDir=%{public}s', nativeLibDir)
  } catch (e) {
    hilog.warn(DOMAIN, 'startVm', 'preflightQemuLibs exception (may be OK if libs exist): %{public}s', JSON.stringify(e))
  }

  // === Phase 1: 启动前诊断：检查关键文件是否存在 ===
  const requiredFiles: RequiredFile[] = [
    { path: options.kernel, label: 'kernel' },
    { path: options.rootFilesystem, label: 'rootFilesystem' },
    { path: options.baseDir, label: 'QEMU baseDir (pc-bios)' },
  ]
  for (const f of requiredFiles) {
    try {
      if (!fs.accessSync(f.path, fs.AccessModeType.EXIST)) {
        hilog.error(DOMAIN, 'startVm', '启动失败：关键文件不存在 [%{public}s] path=%{public}s', f.label, f.path)
        return {
          success: false,
          errorCode: 'KEYFILE_MISSING',
          errorMessage: `关键文件缺失: ${f.label} (${f.path})`,
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, 'startVm', '启动失败：访问关键文件异常 [%{public}s] path=%{public}s err=%{public}s',
        f.label, f.path, JSON.stringify(e))
      return {
        success: false,
        errorCode: 'KEYFILE_MISSING',
        errorMessage: `访问文件异常: ${f.label} (${f.path}): ${JSON.stringify(e)}`,
      }
    }
  }
  hilog.info(DOMAIN, 'startVm', '关键文件检查通过，kernel=%{public}s, rootfs=%{public}s', options.kernel, options.rootFilesystem)

  const root = options.rootVda ? options.rootVda : defaultEmulator.rootVda;
  const sharedFolderOption = options.sharedFolderReadonly ? ",readonly" : ""

  const basic = ['-machine', 'virt,acpi=on,gic-version=max,' +
    'iommu=none,its=off,usb=off,virtualization=off,memory-backend=mem0,compact-highmem=on,' +
    'dump-guest-core=off,mem-merge=off,hmat=off',
    '-overcommit', 'cpu-pm=off',
    '-cpu', 'max,pauth-impdef=on,sve=off,pmu=off', '-accel', 'tcg,thread=multi,tb-size=4096',
    "-object", "rng-random,filename=/dev/urandom,id=rng0",
    "-device", "virtio-rng-pci-non-transitional,rng=rng0",
    '-rtc', 'base=utc,clock=host', '-L', options.baseDir]
  const serial = ['-serial', "unix:" + options.serialUnixSocket + ",server,nowait"]
  const cpuMem = ['-smp', `cpus=${options.cpu},sockets=1,cores=${options.cpu},threads=1`,
    "-object", `memory-backend-ram,id=mem0,size=${options.memory}M,merge=off,prealloc=off`, '-m', options.memory + 'M']
  const kernel = ['-kernel', options.kernel]
  const network = ["-global", "virtio-net-pci.ctrl_guest_offloads=off", "-global", "virtio-net-pci.packed=on",
    "-device", "virtio-net-pci-non-transitional," +
    "netdev=eth0,csum=on,gso=on,guest_tso4=on,guest_tso6=on,guest_ecn=off,mrg_rxbuf=on,tx=bh",
    '-netdev', "user,id=eth0" + options.portMapping.map(it => `,hostfwd=tcp::${it.host}-:${it.guest}`).join('')]
  const shared =
    ["-fsdev", "local,security_model=mapped-file,id=fsdev0,path=" + options.sharedFolder + sharedFolderOption,
    "-device", "virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshare"]
  const drive = ["-global", "virtio-blk-pci.scsi=off", "-global", "virtio-scsi-pci.cmd_per_lun=128",
    "-global", "virtio-scsi-pci.packed=on", "-drive", "if=none,format=qcow2,file=" + options.rootFilesystem
    + ",id=hd0,cache=writeback,aio=threads,discard=unmap", "-object", "iothread,id=iothread0,poll-max-ns=2000000",
    "-device", "virtio-scsi-pci-non-transitional,id=scsi0,num_queues=" + options.cpu.toString() +
    ",virtqueue_size=256,iothread=iothread0",
    "-device", "scsi-hd,drive=hd0,bus=scsi0.0,logical_block_size=4096,physical_block_size=4096,rotation_rate=1,bootindex=1"]
  const kernelParam = ["-append",
    "root=" + root + " rw rootfstype=ext4 rootwait console=tty0 console=ttyAMA0 consoleblank=0 " +
    "elevator=noop skew_tick=1 acpi=on " +
    "mitigations=off audit=0 nmi_watchdog=0 hardened_usercopy=off random.trust_cpu=on virtio_balloon.config_impl=0 " +
    "security=none selinux=0 apparmor=0 psi=0 page_alloc.shuffle=0 swiotlb=noforce idle=halt " +
    "cpuidle.off=1 transparent_hugepage=always pci=noaer scsi_mod.use_blk_mq=1 rng_core.default_quality=1000 " +
    "systemd.mask=run-lock.mount systemd.mask=sys-kernel-debug.mount systemd.mask=dev-hugepages.mount " +
    "cryptomgr.notests rodata=off rcupdate.rcu_cpu_stall_timeout=60 " +
    "rcu_expedited=1 init_on_free=0 init_on_alloc=1 page_poison=0 slub_debug=- " +
    "TERM=xterm init=" + options.init]
  const monitor = ['-qmp', 'unix:' + options.qmpUnixSocket + ',server,nowait']
  const qga = [
    '-device', 'virtio-serial-pci-non-transitional,id=virtio-serial0',
    '-chardev', 'socket,path=' + options.qgaUnixSocket + ',server=on,wait=off,id=qga0',
    '-device', 'virtserialport,chardev=qga0,bus=virtio-serial0.0,name=org.qemu.guest_agent.0'
  ]

  const sharedUserFolder = deviceInfo.deviceType !== '2in1' ? [] :
    ["-fsdev", "local,security_model=mapped-file,id=fsdev1,path=/storage/Users/currentUser", "-device",
      "virtio-9p-pci,id=fs1,fsdev=fsdev1,mount_tag=usershare"]

  const args = [
    'qemu-system-aarch64',
    ...basic,
    ...serial,
    ...cpuMem,
    ...kernel,
    ...network,
    ...shared,
    ...drive,
    ...kernelParam,
    ...monitor,
    ...qga,
    ...sharedUserFolder
  ]

  if (fs.accessSync(options.serialUnixSocket, fs.AccessModeType.EXIST)) {
    fs.unlinkSync(options.serialUnixSocket)
  }
  if (fs.accessSync(options.qmpUnixSocket, fs.AccessModeType.EXIST)) {
    fs.unlinkSync(options.qmpUnixSocket)
  }
  if (fs.accessSync(options.qgaUnixSocket, fs.AccessModeType.EXIST)) {
    fs.unlinkSync(options.qgaUnixSocket)
  }
  if (!fs.accessSync(options.sharedFolder, fs.AccessModeType.EXIST)) {
    fs.mkdirSync(options.sharedFolder)
  }

  const supportJit: boolean = true;

  hilog.info(DOMAIN, 'startVm', 'Calling napi.startVM with %{public}d args, supportJit=%{public}d', args.length, supportJit)
  const started: boolean = napi.startVM({
    argsLines: args.join('\n'),
    unixSocket: options.serialUnixSocket,
    qmpSocket: options.qmpUnixSocket,
    supportJit
  })

  if (started) {
    hilog.info(DOMAIN, 'startVm', 'startVM returned true')
    return { success: true }
  }

  // startVM 返回 false，获取 C++ 层详细诊断
  let diagnostic: any = null
  let diagnosticRaw: string = ''
  try {
    diagnosticRaw = napi.getQemuLoadDiagnostic()
    hilog.error(DOMAIN, 'startVm', 'startVM failed, C++ diagnostic: %{public}s', diagnosticRaw)
    diagnostic = JSON.parse(diagnosticRaw)
  } catch (e) {
    hilog.error(DOMAIN, 'startVm', 'Failed to parse diagnostic: %{public}s, raw=%{public}s', JSON.stringify(e), diagnosticRaw)
  }

  // 构建结构化错误返回
  let errorCode: VmStartResult['errorCode'] = 'UNKNOWN'
  let errorMessage = 'VM 启动失败，QEMU 运行库加载失败'
  let dlopenError: string | undefined = undefined

  if (diagnostic) {
    const stage = diagnostic.stage || ''
    if (stage === 'dlsym_failed') {
      errorCode = 'DLSYM_FAILED'
      errorMessage = `QEMU 库已加载但符号缺失: ${diagnostic.symbol}。库 ${diagnostic.lib} 可能不兼容。nativeLibDir: ${diagnostic.nativeLibDir || nativeLibDir}`
    } else if (diagnostic.dlopenError) {
      errorCode = 'DLOPEN_FAILED'
      dlopenError = diagnostic.dlopenError
      const fileExists = diagnostic.fileExists
      if (fileExists === false) {
        errorMessage = `QEMU 库文件不存在！native lib 目录: ${diagnostic.nativeLibDir || nativeLibDir}\n期望文件: ${diagnostic.fullPath}\n\n请确保 HAP 包含 QEMU 运行时库。\n详见: 应用日志中搜索 "preflightQemuLibs"`
      } else {
        // 文件存在但 dlopen 失败 → 依赖缺失
        errorMessage = `QEMU 库加载失败（依赖缺失或 ABI 不兼容）。\n库路径: ${diagnostic.fullPath}\ndlopen 错误: ${diagnostic.dlopenError}\nnativeLibDir: ${diagnostic.nativeLibDir || nativeLibDir}\n\n这通常是因为 QEMU 运行库的依赖（如 libslirp.so）未被打包进 HAP。`
      }
    } else if (diagnostic.stage === 'dlopen_failed') {
      errorCode = 'DLOPEN_FAILED'
      errorMessage = `QEMU dlopen 失败: attempted=${diagnostic.attemptedLib}, nativeLibDir=${diagnostic.nativeLibDir || nativeLibDir}`
    }
  }

  hilog.error(DOMAIN, 'startVm', '=== startVm FAILED: errorCode=%{public}s, errorMessage=%{public}s ===',
    errorCode, errorMessage)

  return {
    success: false,
    errorCode,
    errorMessage,
    nativeLibDir: diagnostic?.nativeLibDir || nativeLibDir,
    dlopenError,
  }
}

export { startVm, VmOptions }
