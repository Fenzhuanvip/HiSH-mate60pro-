import { socket } from "@kit.NetworkKit"
import { hilog } from "@kit.PerformanceAnalysisKit"
import { util } from "@kit.ArkTS"
import { fileIo as fs } from '@kit.CoreFileKit'

const DOMAIN = 0x0000

@Component
export default struct QemuMonitor {
  tempDir = this.getUIContext().getHostContext()!!.getApplicationContext().tempDir
  localSocket?: socket.LocalSocket = undefined
  utf8Decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
  private queryIntervalId?: number = undefined
  @State qmpConnected: boolean = false

  async aboutToAppear(): Promise<void> {
    await this.connectQmpWithRetry()
  }

  /**
   * 带重试的 QMP 连接。
   * QEMU 在独立线程中启动，qmp_socket 创建有延迟，需要等待并重试。
   */
  private async connectQmpWithRetry(): Promise<void> {
    const socketPath = this.tempDir + '/qmp_socket'
    const maxAttempts = 15       // 最多重试 15 次
    const retryInterval = 1000   // 每次间隔 1 秒

    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        // 1. 等待 qmp_socket 文件出现
        const socketReady = await this.waitForSocket(socketPath, 3000)
        if (!socketReady) {
          hilog.warn(DOMAIN, "QemuMonitor", 'qmp_socket 尚未出现 (attempt %{public}d/%{public}d)', attempt, maxAttempts)
          continue
        }

        // 2. 连接 QMP socket
        const local = socket.constructLocalSocketInstance()
        await local.connect({ address: { address: socketPath }, timeout: 5000 })
        this.localSocket = local

        // 3. 监听 QMP 消息
        local.on('message', (info) => {
          const trunk = this.utf8Decoder.decodeToString(new Uint8Array(info.message))
          hilog.debug(DOMAIN, "QemuMonitor", 'qmp msg: %{public}s', trunk)
        })

        local.on('error', (err: Error) => {
          hilog.error(DOMAIN, "QemuMonitor", 'qmp socket error: %{public}s', JSON.stringify(err))
          this.qmpConnected = false
        })

        local.on('close', () => {
          hilog.info(DOMAIN, "QemuMonitor", 'qmp socket closed')
          this.qmpConnected = false
        })

        // 4. 发送 qmp_capabilities 进入命令模式
        await local.send({ data: '{ "execute": "qmp_capabilities" }\n' })

        hilog.info(DOMAIN, "QemuMonitor", 'QMP 连接成功 (attempt %{public}d)', attempt)
        this.qmpConnected = true

        // 5. 启动定时查询
        this.startQueryLoop()
        return
      } catch (e) {
        hilog.warn(DOMAIN, "QemuMonitor", 'QMP 连接失败 (attempt %{public}d/%{public}d): %{public}s',
          attempt, maxAttempts, JSON.stringify(e))
        // 清理本次连接的资源
        try {
          await this.localSocket?.close()
        } catch (_) { /* ignore */ }
        this.localSocket = undefined
      }

      // 等待后重试
      if (attempt < maxAttempts) {
        await new Promise<void>(resolve => setTimeout(resolve, retryInterval))
      }
    }

    // 所有重试都失败
    hilog.error(DOMAIN, "QemuMonitor", 'QMP 连接最终失败，已重试 %{public}d 次', maxAttempts)
    this.qmpConnected = false
  }

  /**
   * 等待 socket 文件出现
   */
  private async waitForSocket(socketPath: string, timeoutMs: number): Promise<boolean> {
    const startTime = Date.now()
    while (Date.now() - startTime < timeoutMs) {
      try {
        if (fs.accessSync(socketPath, fs.AccessModeType.EXIST)) {
          return true
        }
      } catch (_) { /* 文件不存在，继续等待 */ }
      await new Promise<void>(resolve => setTimeout(resolve, 200))
    }
    return false
  }

  private startQueryLoop(): void {
    // 先查询一次状态
    this.sendQmpCommand('query-status')

    this.queryIntervalId = setInterval(async () => {
      if (!this.localSocket || !this.qmpConnected) {
        return
      }
      try {
        await this.localSocket.send({ data: '{ "execute": "query-cpus-fast" }\n' })
        await this.localSocket.send({ data: '{ "execute": "query-memory-size-summary" }\n' })
      } catch (e) {
        hilog.error(DOMAIN, "QemuMonitor", 'qmp query failed: %{public}s', JSON.stringify(e))
      }
    }, 3000)
  }

  async sendQmpCommand(command: string): Promise<void> {
    if (!this.localSocket) {
      hilog.warn(DOMAIN, "QemuMonitor", 'sendQmpCommand: socket not connected')
      return
    }
    try {
      await this.localSocket.send({ data: `{ "execute": "${command}" }\n` })
    } catch (e) {
      hilog.error(DOMAIN, "QemuMonitor", 'sendQmpCommand failed (%{public}s): %{public}s', command, JSON.stringify(e))
    }
  }

  async aboutToDisappear(): Promise<void> {
    if (this.queryIntervalId !== undefined) {
      clearInterval(this.queryIntervalId)
      this.queryIntervalId = undefined
    }
    try {
      await this.localSocket?.close()
    } catch (e) {
      hilog.error(DOMAIN, "QemuMonitor", "close qmp socket failed: %{public}s", JSON.stringify(e))
    }
    this.localSocket = undefined
  }

  build() {
    Column() {
    }
  }
}
