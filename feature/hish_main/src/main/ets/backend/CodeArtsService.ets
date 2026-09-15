import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0ff4;
const TAG = 'CodeArtsService';
const PREFS_NAME = 'codearts_config';
const KEY_AK = 'ak';
const KEY_SK = 'sk';
const KEY_REGION = 'region';
const KEY_PROJECT_ID = 'projectId';

/** CodeArts 支持的区域 */
export interface CodeArtsRegion {
  id: string;
  name: string;
  endpoint: string;
}

export const CODEARTS_REGIONS: CodeArtsRegion[] = [
  { id: 'cn-north-4', name: '华北-北京四', endpoint: 'codearts.cn-north-4.myhuaweicloud.com' },
  { id: 'cn-north-1', name: '华北-北京一', endpoint: 'codearts.cn-north-1.myhuaweicloud.com' },
  { id: 'cn-south-1', name: '华南-广州', endpoint: 'codearts.cn-south-1.myhuaweicloud.com' },
  { id: 'cn-east-3', name: '华东-上海一', endpoint: 'codearts.cn-east-3.myhuaweicloud.com' },
  { id: 'cn-southwest-2', name: '西南-贵阳一', endpoint: 'codearts.cn-southwest-2.myhuaweicloud.com' },
];

/** 仓库信息 */
export interface CodeArtsRepo {
  id: number;
  name: string;
  httpsUrl: string;
  sshUrl: string;
  description: string;
  visibility: string;
  defaultBranch: string;
}

/** 项目信息 */
export interface CodeArtsProject {
  id: number;
  name: string;
  description: string;
}

/** CodeArts 配置 */
export interface CodeArtsConfig {
  ak: string;
  sk: string;
  region: string;
  projectId: string;
}

/** URL 解析结果 */
interface ParsedUrl {
  host: string;
  path: string;
  query: string;
}

/** 连接测试结果 */
interface ConnectionResult {
  success: boolean;
  message: string;
}

/** 项目列表响应 */
interface ProjectsResponse {
  projects?: CodeArtsProject[];
}

/** 仓库列表响应 */
interface ReposResponse {
  repositories?: CodeArtsRepo[];
}

/** 将 Uint8Array 转 hex 字符串 */
function uint8ToHex(bytes: Uint8Array): string {
  const hexChars = '0123456789abcdef';
  let result = '';
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    result += hexChars.charAt((b >> 4) & 0x0f);
    result += hexChars.charAt(b & 0x0f);
  }
  return result;
}

/** 手动解析 URL（ArkTS 无 URL 构造器） */
function parseUrl(url: string): ParsedUrl {
  // 去掉 https://
  let rest = url;
  if (rest.startsWith('https://')) {
    rest = rest.substring(8);
  } else if (rest.startsWith('http://')) {
    rest = rest.substring(7);
  }
  // 分离 host 和 path
  const slashIdx = rest.indexOf('/');
  let host: string;
  let pathAndQuery: string;
  if (slashIdx >= 0) {
    host = rest.substring(0, slashIdx);
    pathAndQuery = rest.substring(slashIdx);
  } else {
    host = rest;
    pathAndQuery = '/';
  }
  // 分离 path 和 query
  const qIdx = pathAndQuery.indexOf('?');
  let path: string;
  let query: string;
  if (qIdx >= 0) {
    path = pathAndQuery.substring(0, qIdx);
    query = pathAndQuery.substring(qIdx + 1);
  } else {
    path = pathAndQuery;
    query = '';
  }
  const result: ParsedUrl = { host: host, path: path, query: query };
  return result;
}

class CodeArtsServiceImpl {
  private config: CodeArtsConfig | null = null;

  /** 从本地偏好加载配置 */
  async loadConfig(context: common.Context): Promise<CodeArtsConfig | null> {
    try {
      const prefs = await preferences.getPreferences(context, PREFS_NAME);
      const ak = (await prefs.get(KEY_AK, '')).toString();
      const sk = (await prefs.get(KEY_SK, '')).toString();
      const region = (await prefs.get(KEY_REGION, 'cn-north-4')).toString();
      const projectId = (await prefs.get(KEY_PROJECT_ID, '')).toString();
      if (ak.length > 0 && sk.length > 0) {
        this.config = { ak, sk, region, projectId };
        return this.config;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadConfig failed: %{public}s', JSON.stringify(e));
    }
    return null;
  }

  /** 保存配置到本地偏好 */
  async saveConfig(context: common.Context, config: CodeArtsConfig): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(context, PREFS_NAME);
      await prefs.put(KEY_AK, config.ak);
      await prefs.put(KEY_SK, config.sk);
      await prefs.put(KEY_REGION, config.region);
      await prefs.put(KEY_PROJECT_ID, config.projectId);
      await prefs.flush();
      this.config = config;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveConfig failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 清除配置 */
  async clearConfig(context: common.Context): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(context, PREFS_NAME);
      await prefs.delete(KEY_AK);
      await prefs.delete(KEY_SK);
      await prefs.delete(KEY_REGION);
      await prefs.delete(KEY_PROJECT_ID);
      await prefs.flush();
      this.config = null;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clearConfig failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 获取当前配置 */
  getConfig(): CodeArtsConfig | null {
    return this.config;
  }

  /** 获取区域 endpoint */
  private getEndpoint(): string {
    if (this.config === null) {
      return CODEARTS_REGIONS[0].endpoint;
    }
    const region = CODEARTS_REGIONS.find(r => r.id === this.config!.region);
    return region !== undefined ? region.endpoint : CODEARTS_REGIONS[0].endpoint;
  }

  /**
   * 测试连接 — 调用 API 列出项目，验证 AK/SK 是否有效。
   */
  async testConnection(): Promise<ConnectionResult> {
    if (this.config === null) {
      const failResult: ConnectionResult = { success: false, message: '未配置 AK/SK' };
      return failResult;
    }
    try {
      const projects = await this.listProjects();
      const okResult: ConnectionResult = { success: true, message: `连接成功，找到 ${projects.length} 个项目` };
      return okResult;
    } catch (e) {
      const errResult: ConnectionResult = { success: false, message: `连接失败: ${this.describeError(e)}` };
      return errResult;
    }
  }

  /**
   * 列出 CodeArts 项目。
   * GET https://{endpoint}/v1/projects
   */
  async listProjects(): Promise<CodeArtsProject[]> {
    const endpoint = this.getEndpoint();
    const url = `https://${endpoint}/v1/projects?limit=50`;
    const response = await this.signedRequest('GET', url, '');
    const json = JSON.parse(response) as ProjectsResponse;
    return json.projects ?? [];
  }

  /**
   * 列出项目下的仓库。
   * GET https://{endpoint}/v1/repositories?project_id={projectId}
   */
  async listRepos(projectId: string): Promise<CodeArtsRepo[]> {
    const endpoint = this.getEndpoint();
    const url = `https://${endpoint}/v1/repositories?project_id=${projectId}&limit=50`;
    const response = await this.signedRequest('GET', url, '');
    const json = JSON.parse(response) as ReposResponse;
    return json.repositories ?? [];
  }

  /**
   * 创建仓库。
   * POST https://{endpoint}/v1/repositories
   */
  async createRepo(projectId: string, name: string, description: string): Promise<CodeArtsRepo> {
    const endpoint = this.getEndpoint();
    const url = `https://${endpoint}/v1/repositories`;
    const body = JSON.stringify({
      project_id: Number(projectId),
      repository_name: name,
      description: description,
      visibility: 'private',
      import_members: true,
    });
    const response = await this.signedRequest('POST', url, body);
    return JSON.parse(response) as CodeArtsRepo;
  }

  // ====== IAM 签名 + HTTP ======

  /**
   * 发送带 IAM 签名的 HTTP 请求。
   * 华为云 SDK 签名算法：Basic SDK 签名（Authorization: SDK-HMAC-SHA256 ...）
   */
  private async signedRequest(method: string, url: string, body: string): Promise<string> {
    if (this.config === null) {
      throw new Error('未配置 AK/SK');
    }

    const urlObj = parseUrl(url);
    const datetime = this.getUtcDateTime();

    // 1. Content-SHA256
    const contentSha256 = await this.sha256Hex(body);

    // 2. Canonical headers
    const host = urlObj.host;
    const signedHeaderKeys = ['host', 'x-sdk-content-sha256', 'x-sdk-date'];
    const canonicalHeaders = `host:${host}\nx-sdk-content-sha256:${contentSha256}\nx-sdk-date:${datetime}\n`;
    const signedHeaders = signedHeaderKeys.join(';');

    // 3. Canonical URI
    const canonicalUri = this.encodeUri(urlObj.path);

    // 4. Canonical Query String
    const canonicalQueryString = this.canonicalQueryString(urlObj.query);

    // 5. Canonical Request
    const canonicalRequest = [
      method,
      canonicalUri,
      canonicalQueryString,
      canonicalHeaders,
      signedHeaders,
      contentSha256,
    ].join('\n');

    // 6. String to Sign
    const canonicalRequestHash = await this.sha256Hex(canonicalRequest);
    const stringToSign = [
      'SDK-HMAC-SHA256',
      datetime,
      canonicalRequestHash,
    ].join('\n');

    // 7. Signature
    const signature = await this.hmacSha256Hex(this.config.sk, stringToSign);

    // 8. Authorization header
    const authHeader = `SDK-HMAC-SHA256 Access=${this.config.ak}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

    // 9. Send HTTP request
    const httpRequest = http.createHttp();
    try {
      const headerObj: Record<string, string> = {
        'Content-Type': 'application/json',
        'X-Sdk-Content-Sha256': contentSha256,
        'X-Sdk-Date': datetime,
        'Authorization': authHeader,
      };

      const response = await httpRequest.request(url, {
        method: method === 'GET' ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: headerObj,
        extraData: body.length > 0 ? body : undefined,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000,
      });

      const respCode = response.responseCode;
      const respData = response.result as string;

      if (respCode < 200 || respCode >= 300) {
        throw new Error(`HTTP ${respCode}: ${respData}`);
      }

      return respData;
    } finally {
      httpRequest.destroy();
    }
  }

  // ====== 工具方法 ======

  private describeError(e: Object): string {
    const err = e as Error;
    return err.message ?? JSON.stringify(e);
  }

  private encodeUri(path: string): string {
    // URI 编码，斜杠不编码
    return path.split('/').map(seg => encodeURIComponent(seg)).join('/');
  }

  private canonicalQueryString(query: string): string {
    if (query.length === 0) {
      return '';
    }
    const pairs = query.split('&').map(p => {
      const idx = p.indexOf('=');
      const key = idx >= 0 ? p.substring(0, idx) : p;
      const val = idx >= 0 ? p.substring(idx + 1) : '';
      return `${encodeURIComponent(key)}=${encodeURIComponent(val)}`;
    });
    pairs.sort();
    return pairs.join('&');
  }

  private getUtcDateTime(): string {
    const now = new Date();
    const yyyy = now.getUTCFullYear().toString();
    const mm = (now.getUTCMonth() + 1).toString().padStart(2, '0');
    const dd = now.getUTCDate().toString().padStart(2, '0');
    const hh = now.getUTCHours().toString().padStart(2, '0');
    const mi = now.getUTCMinutes().toString().padStart(2, '0');
    const ss = now.getUTCSeconds().toString().padStart(2, '0');
    return `${yyyy}${mm}${dd}T${hh}${mi}${ss}Z`;
  }


  /** SHA256 哈希，返回 hex 字符串 */
  private async sha256Hex(data: string): Promise<string> {
    const encoder = new util.TextEncoder();
    const input = encoder.encodeInto(data);
    const md = cryptoFramework.createMd('SHA256');
    const inputBlob: cryptoFramework.DataBlob = { data: input };
    md.updateSync(inputBlob);
    const resultBlob = md.digestSync();
    return uint8ToHex(resultBlob.data);
  }

  /** HMAC-SHA256，返回 hex 字符串 */
  private async hmacSha256Hex(key: string, data: string): Promise<string> {
    const encoder = new util.TextEncoder();
    const keyBytes = encoder.encodeInto(key);
    const dataBytes = encoder.encodeInto(data);
    const mac = cryptoFramework.createMac('SHA256');
    const keyGenerator = cryptoFramework.createSymKeyGenerator('HMAC-SHA256|256');
    const keyDataBlob: cryptoFramework.DataBlob = { data: keyBytes };
    const symKey = keyGenerator.convertKeySync(keyDataBlob);
    mac.initSync(symKey);
    const dataBlob: cryptoFramework.DataBlob = { data: dataBytes };
    mac.updateSync(dataBlob);
    const resultBlob = mac.doFinalSync();
    return uint8ToHex(resultBlob.data);
  }
}

export const codeArtsService = new CodeArtsServiceImpl();
