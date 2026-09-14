export type ArkPilotBreakpoint = 'xs' | 'sm' | 'md' | 'lg';

export const ARK_PILOT_BREAKPOINT_STORAGE_KEY: string = 'arkPilotBreakpoint';

export function resolveArkPilotBreakpoint(widthVp: number): ArkPilotBreakpoint {
  if (widthVp < 320) {
    return 'xs';
  }
  if (widthVp < 600) {
    return 'sm';
  }
  if (widthVp < 840) {
    return 'md';
  }
  return 'lg';
}
