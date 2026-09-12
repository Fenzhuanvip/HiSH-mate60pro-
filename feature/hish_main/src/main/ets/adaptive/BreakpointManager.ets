import mediaquery from '@ohos.mediaquery';
import { ArkPilotBreakpoint, ARK_PILOT_BREAKPOINT_STORAGE_KEY } from './BreakpointTypes';

class BreakpointMediaQueryItem {
  condition: string;
  breakpoint: ArkPilotBreakpoint;

  constructor(condition: string, breakpoint: ArkPilotBreakpoint) {
    this.condition = condition;
    this.breakpoint = breakpoint;
  }
}

class BreakpointListenerItem {
  listener: mediaquery.MediaQueryListener;
  breakpoint: ArkPilotBreakpoint;

  constructor(listener: mediaquery.MediaQueryListener, breakpoint: ArkPilotBreakpoint) {
    this.listener = listener;
    this.breakpoint = breakpoint;
  }
}

class ArkPilotBreakpointManager {
  private initialized: boolean = false;
  private listeners: BreakpointListenerItem[] = [];
  private readonly queries: BreakpointMediaQueryItem[] = [
    new BreakpointMediaQueryItem('(max-width: 319vp)', 'xs'),
    new BreakpointMediaQueryItem('(min-width: 320vp) and (max-width: 599vp)', 'sm'),
    new BreakpointMediaQueryItem('(min-width: 600vp) and (max-width: 839vp)', 'md'),
    new BreakpointMediaQueryItem('(min-width: 840vp)', 'lg')
  ];

  initialize(matchMediaSync?: (condition: string) => mediaquery.MediaQueryListener): void {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    AppStorage.setOrCreate<ArkPilotBreakpoint>(ARK_PILOT_BREAKPOINT_STORAGE_KEY, 'sm');
    const resolveMediaQuery = matchMediaSync ?? mediaquery.matchMediaSync;

    this.queries.forEach((item: BreakpointMediaQueryItem) => {
      const listener = resolveMediaQuery(item.condition);
      const callback = (result: mediaquery.MediaQueryResult): void => {
        if (result.matches) {
          this.applyBreakpoint(item.breakpoint);
        }
      };
      listener.on('change', callback);
      this.listeners.push(new BreakpointListenerItem(listener, item.breakpoint));
      if (listener.matches) {
        this.applyBreakpoint(item.breakpoint);
      }
    });
  }

  private applyBreakpoint(breakpoint: ArkPilotBreakpoint): void {
    AppStorage.set<ArkPilotBreakpoint>(ARK_PILOT_BREAKPOINT_STORAGE_KEY, breakpoint);
  }
}

export const breakpointManager = new ArkPilotBreakpointManager();
