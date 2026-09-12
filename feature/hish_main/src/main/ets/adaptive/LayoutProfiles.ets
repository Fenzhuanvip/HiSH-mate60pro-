import { ArkPilotBreakpoint } from './BreakpointTypes';

export type ArkPilotLayoutMode = 'phone' | 'tablet' | 'desktop';

export class ArkPilotLayoutProfile {
  mode: ArkPilotLayoutMode;
  leftPanelPersistent: boolean;
  rightPanelPersistent: boolean;
  leftPanelWidth: number;
  rightPanelWidth: number;
  dialogWidth: number;

  constructor(
    mode: ArkPilotLayoutMode,
    leftPanelPersistent: boolean,
    rightPanelPersistent: boolean,
    leftPanelWidth: number,
    rightPanelWidth: number,
    dialogWidth: number
  ) {
    this.mode = mode;
    this.leftPanelPersistent = leftPanelPersistent;
    this.rightPanelPersistent = rightPanelPersistent;
    this.leftPanelWidth = leftPanelWidth;
    this.rightPanelWidth = rightPanelWidth;
    this.dialogWidth = dialogWidth;
  }
}

export function getArkPilotLayoutProfile(breakpoint: ArkPilotBreakpoint): ArkPilotLayoutProfile {
  if (breakpoint === 'lg') {
    return new ArkPilotLayoutProfile('desktop', true, true, 300, 360, 480);
  }
  if (breakpoint === 'md') {
    return new ArkPilotLayoutProfile('tablet', true, false, 280, 360, 420);
  }
  if (breakpoint === 'xs') {
    return new ArkPilotLayoutProfile('phone', false, false, 288, 288, 288);
  }
  return new ArkPilotLayoutProfile('phone', false, false, 300, 320, 360);
}

export function getArkPilotLayoutMode(breakpoint: ArkPilotBreakpoint): ArkPilotLayoutMode {
  return getArkPilotLayoutProfile(breakpoint).mode;
}
