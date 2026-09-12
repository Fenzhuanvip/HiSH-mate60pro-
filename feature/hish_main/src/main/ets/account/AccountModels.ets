export const ACCOUNT_ERROR_PACKAGE_FINGERPRINT: number = 1001500001;
export const ACCOUNT_ERROR_NOT_LOGGED_IN: number = 1001502001;
export const ACCOUNT_ERROR_APP_NOT_AUTHORIZED: number = 1001502002;
export const ACCOUNT_ERROR_PARAMETER_INVALID: number = 1001502003;
export const ACCOUNT_ERROR_NETWORK: number = 1001502005;
export const ACCOUNT_ERROR_INTERNAL: number = 1001502009;
export const ACCOUNT_ERROR_USER_CANCELED: number = 1001502012;
export const ACCOUNT_ERROR_SCOPE_OR_PERMISSION: number = 1001502014;
export const ACCOUNT_ERROR_AGREEMENT_NOT_ACCEPTED: number = 1005300001;

export class HuaweiAccountSession {
  unionID: string = '';
  openID: string = '';
  authorizationCode: string = '';
  idToken: string = '';
  loginAt: number = 0;

  constructor(unionID: string, openID: string, authorizationCode: string, idToken: string, loginAt: number) {
    this.unionID = unionID;
    this.openID = openID;
    this.authorizationCode = authorizationCode;
    this.idToken = idToken;
    this.loginAt = loginAt;
  }

  toJson(): string {
    const record: Record<string, string> = {
      'unionID': this.unionID,
      'openID': this.openID,
      'authorizationCode': this.authorizationCode,
      'idToken': this.idToken,
      'loginAt': `${this.loginAt}`
    };
    return JSON.stringify(record);
  }

  static fromJson(rawText: string): HuaweiAccountSession | null {
    try {
      const parsed: Object = JSON.parse(rawText) as Object;
      const record: Record<string, Object> = parsed as Record<string, Object>;
      const unionID: string = typeof record['unionID'] === 'string' ? (record['unionID'] as string) : '';
      const openID: string = typeof record['openID'] === 'string' ? (record['openID'] as string) : '';
      const authorizationCode: string = typeof record['authorizationCode'] === 'string' ? (record['authorizationCode'] as string) : '';
      const idToken: string = typeof record['idToken'] === 'string' ? (record['idToken'] as string) : '';
      const loginAt: number = typeof record['loginAt'] === 'string' ? Number(record['loginAt']) : 0;
      if (unionID.length === 0 || openID.length === 0) {
        return null;
      }
      return new HuaweiAccountSession(unionID, openID, authorizationCode, idToken, loginAt);
    } catch (_err) {
      return null;
    }
  }
}

export function maskAccountId(id: string): string {
  if (id.length === 0) {
    return '';
  }
  if (id.length <= 4) {
    return '****';
  }
  const suffix: string = id.substring(id.length - 4);
  return `****${suffix}`;
}

export function accountErrorMessage(code: number): string {
  switch (code) {
    case ACCOUNT_ERROR_NOT_LOGGED_IN:
      return '设备尚未登录华为账号，请先登录华为账号后重试。';
    case ACCOUNT_ERROR_APP_NOT_AUTHORIZED:
      return '应用未获得华为账号授权，请确认已在 AppGallery Connect 开通华为账号服务。';
    case ACCOUNT_ERROR_PACKAGE_FINGERPRINT:
      return '应用签名校验失败，请确认签名证书指纹已配置到 AppGallery Connect。';
    case ACCOUNT_ERROR_USER_CANCELED:
      return '已取消登录。';
    case ACCOUNT_ERROR_SCOPE_OR_PERMISSION:
      return '应用缺少登录所需权限范围，请联系开发者。';
    case ACCOUNT_ERROR_AGREEMENT_NOT_ACCEPTED:
      return '未同意用户协议，无法继续登录。';
    case ACCOUNT_ERROR_NETWORK:
      return '网络异常，请检查网络后重试。';
    case ACCOUNT_ERROR_INTERNAL:
      return '登录服务内部错误，请稍后重试。';
    default:
      return `登录失败，错误码 ${code}。`;
  }
}
