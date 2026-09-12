import { authentication, loginComponentManager } from '@kit.AccountKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import util from '@ohos.util';
import { HuaweiAccountSession, maskAccountId } from './AccountModels';

const ACCOUNT_SERVICE_DOMAIN = 0x0ff3;
const ACCOUNT_SERVICE_TAG = 'HuaweiAccountService';
const ACCOUNT_PREFS_NAME = 'arkpilot_account';
const ACCOUNT_SESSION_KEY = 'session';
const ACCOUNT_LAST_OPENID_KEY = 'lastOpenId';
const APPSTORAGE_LOGGED_IN_KEY = 'arkPilotLoggedIn';

export class HuaweiAccountService {
  lastErrorCode: number = 0;
  isLoggedIn: boolean = false;
  private prefs: preferences.Preferences | null = null;
  private session: HuaweiAccountSession | null = null;
  private initialized: boolean = false;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;

  init(context: common.Context): void {
    if (this.initialized) {
      this.restoreSession();
      return;
    }
    this.initialized = true;
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: ACCOUNT_PREFS_NAME });
    } catch (err) {
      this.prefs = null;
      hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'init preferences failed: %{public}s', `${err}`);
    }
    this.restoreSession();
    this.subscribeAccountEvents();
  }

  ensureInit(context: common.Context): void {
    this.init(context);
  }

  maskedUnionID(): string {
    if (this.session === null) {
      return '';
    }
    return maskAccountId(this.session.unionID);
  }

  applyCredential(credential: loginComponentManager.HuaweiIDCredential): void {
    const session: HuaweiAccountSession = new HuaweiAccountSession(
      credential.unionID,
      credential.openID,
      credential.authorizationCode,
      credential.idToken ?? '',
      Date.now()
    );
    this.session = session;
    this.isLoggedIn = true;
    this.lastErrorCode = 0;
    this.saveSession(session);
    this.saveLastAccount(credential.openID);
    AppStorage.setOrCreate<boolean>(APPSTORAGE_LOGGED_IN_KEY, true);
  }

  lastAccountMasked(): string {
    if (this.prefs === null) {
      return '';
    }
    try {
      const raw: preferences.ValueType = this.prefs.getSync(ACCOUNT_LAST_OPENID_KEY, '');
      if (typeof raw === 'string' && raw.length > 0) {
        return maskAccountId(raw);
      }
    } catch (err) {
      hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'read last account failed: %{public}s', `${err}`);
    }
    return '';
  }

  private saveLastAccount(openID: string): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync(ACCOUNT_LAST_OPENID_KEY, openID);
      void this.prefs.flush();
    } catch (err) {
      hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'save last account failed: %{public}s', `${err}`);
    }
  }

  private saveSession(session: HuaweiAccountSession): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync(ACCOUNT_SESSION_KEY, session.toJson());
      void this.prefs.flush();
    } catch (err) {
      hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'save session failed: %{public}s', `${err}`);
    }
  }

  private restoreSession(): void {
    if (this.prefs === null) {
      this.isLoggedIn = false;
      this.session = null;
      AppStorage.setOrCreate<boolean>(APPSTORAGE_LOGGED_IN_KEY, false);
      return;
    }
    try {
      const raw: preferences.ValueType = this.prefs.getSync(ACCOUNT_SESSION_KEY, '');
      if (typeof raw === 'string' && raw.length > 0) {
        const restored: HuaweiAccountSession | null = HuaweiAccountSession.fromJson(raw);
        if (restored !== null) {
          this.session = restored;
          this.isLoggedIn = true;
          AppStorage.setOrCreate<boolean>(APPSTORAGE_LOGGED_IN_KEY, true);
          return;
        }
      }
      this.isLoggedIn = false;
      this.session = null;
      AppStorage.setOrCreate<boolean>(APPSTORAGE_LOGGED_IN_KEY, false);
    } catch (err) {
      this.isLoggedIn = false;
      this.session = null;
      AppStorage.setOrCreate<boolean>(APPSTORAGE_LOGGED_IN_KEY, false);
      hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'restore session failed: %{public}s', `${err}`);
    }
  }

  async logout(context?: common.Context): Promise<void> {
    this.session = null;
    this.isLoggedIn = false;
    this.lastErrorCode = 0;
    if (this.prefs !== null) {
      try {
        this.prefs.deleteSync(ACCOUNT_SESSION_KEY);
        this.prefs.deleteSync(ACCOUNT_LAST_OPENID_KEY);
        void this.prefs.flush();
      } catch (err) {
        hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'logout clear failed: %{public}s', `${err}`);
      }
    }
    AppStorage.setOrCreate<boolean>(APPSTORAGE_LOGGED_IN_KEY, false);
    if (context !== undefined) {
      await this.cancelAuthorization(context);
    }
  }

  /**
   * Cancels the app's authorization for the current HUAWEI ID account.
   * After cancellation, the next login will show the authorization UI again,
   * allowing the user to switch to another HUAWEI ID account.
   * @returns true if the cancellation succeeded; false otherwise.
   */
  async cancelAuthorization(context: common.Context): Promise<boolean> {
    try {
      const provider = new authentication.HuaweiIDProvider();
      const request = provider.createCancelAuthorizationRequest();
      request.state = util.generateRandomUUID();
      const controller = new authentication.AuthenticationController(context);
      const response = await controller.executeRequest(request);
      const cancelResponse = response as authentication.CancelAuthorizationResponse;
      const responseState: string = cancelResponse.state ?? '';
      if (responseState.length > 0 && responseState !== request.state) {
        hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, '%{public}s', 'cancel authorization state mismatch');
        return false;
      }
      hilog.info(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, '%{public}s', 'cancel authorization succeeded');
      return true;
    } catch (err) {
      const bizErr = err as BusinessError;
      hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'cancel authorization failed: %{public}s, code=%{public}d', `${bizErr}`, bizErr.code);
      return false;
    }
  }

  /**
   * Subscribes to the HUAWEI ID account login/logout broadcast events so that
   * the app follows the system account state. When the user signs out of the
   * HUAWEI ID on the device, the app automatically signs out locally.
   */
  subscribeAccountEvents(): void {
    if (this.subscriber !== null) {
      return;
    }
    const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
      events: [
        commonEventManager.Support.COMMON_EVENT_DISTRIBUTED_ACCOUNT_LOGIN,
        commonEventManager.Support.COMMON_EVENT_DISTRIBUTED_ACCOUNT_LOGOUT
      ]
    };
    try {
      commonEventManager.createSubscriber(subscribeInfo).then((commonEventSubscriber: commonEventManager.CommonEventSubscriber) => {
        this.subscriber = commonEventSubscriber;
        commonEventManager.subscribe(commonEventSubscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
          if (err) {
            hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'subscribe account event failed: code=%{public}d, msg=%{public}s', err.code, `${err.message}`);
            return;
          }
          if (data.event === commonEventManager.Support.COMMON_EVENT_DISTRIBUTED_ACCOUNT_LOGOUT) {
            hilog.info(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, '%{public}s', 'HUAWEI ID logged out on system, sign out locally');
            this.handleSystemAccountLoggedOut();
          } else if (data.event === commonEventManager.Support.COMMON_EVENT_DISTRIBUTED_ACCOUNT_LOGIN) {
            hilog.info(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, '%{public}s', 'HUAWEI ID logged in on system');
          }
        });
      }).catch((err: BusinessError) => {
        hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'create account subscriber failed: code=%{public}d, msg=%{public}s', err.code, `${err.message}`);
      });
    } catch (err) {
      hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'subscribe account events failed: %{public}s', `${err}`);
    }
  }

  private handleSystemAccountLoggedOut(): void {
    if (!this.isLoggedIn) {
      return;
    }
    this.session = null;
    this.isLoggedIn = false;
    this.lastErrorCode = 0;
    if (this.prefs !== null) {
      try {
        this.prefs.deleteSync(ACCOUNT_SESSION_KEY);
        this.prefs.deleteSync(ACCOUNT_LAST_OPENID_KEY);
        void this.prefs.flush();
      } catch (err) {
        hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'system logout clear failed: %{public}s', `${err}`);
      }
    }
    AppStorage.setOrCreate<boolean>(APPSTORAGE_LOGGED_IN_KEY, false);
  }

  /**
   * Verifies whether the system HUAWEI ID is still logged in for the locally
   * stored account. Called at app launch and when returning to foreground.
   * If the user signed out of the HUAWEI ID on the device, the local session
   * is cleared so the app returns to the login gate.
   */
  async verifySystemAccountState(): Promise<void> {
    if (!this.isLoggedIn || this.session === null) {
      return;
    }
    const openID: string = this.session.openID;
    if (openID.length === 0) {
      return;
    }
    try {
      const provider = new authentication.HuaweiIDProvider();
      const request: authentication.StateRequest = {
        idType: authentication.IdType.OPEN_ID,
        idValue: openID
      };
      const result: authentication.StateResult = await provider.getHuaweiIDState(request);
      if (result.state === authentication.State.UNLOGGED_IN) {
        hilog.info(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, '%{public}s', 'system HUAWEI ID not logged in, clear local session');
        this.handleSystemAccountLoggedOut();
      }
    } catch (err) {
      const bizErr = err as BusinessError;
      hilog.error(ACCOUNT_SERVICE_DOMAIN, ACCOUNT_SERVICE_TAG, 'verify system account state failed: code=%{public}d, msg=%{public}s', bizErr.code, `${bizErr.message}`);
    }
  }
}

export const huaweiAccountService: HuaweiAccountService = new HuaweiAccountService();
