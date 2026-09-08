export interface VirtualKeyMetrics {
  margin: number
  padding: number
  height: number
  width: number
  fontSize: number
  radius: number
}

export function getVirtualKeyMetrics(deviceType: string): VirtualKeyMetrics {
  return {
    margin: 1,
    padding: 2,
    height: 28,
    width: 42,
    fontSize: 10,
    radius: 5
  }
}

export interface FunctionKeySequencesMap {
  F1: string
  F2: string
  F3: string
  F4: string
  F5: string
  F6: string
  F7: string
  F8: string
  F9: string
  F10: string
  F11: string
  F12: string
}

export const FunctionKeyOrder: string[] = ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12']

export const FunctionKeySequences: FunctionKeySequencesMap = {
  F1: '\x1bOP',
  F2: '\x1bOQ',
  F3: '\x1bOR',
  F4: '\x1bOS',
  F5: '\x1b[15~',
  F6: '\x1b[17~',
  F7: '\x1b[18~',
  F8: '\x1b[19~',
  F9: '\x1b[20~',
  F10: '\x1b[21~',
  F11: '\x1b[23~',
  F12: '\x1b[24~'
}

export interface NormalKeySequencesMap {
  ESC: string
  TAB: string
  PGUP: string
  HOME: string
  HOME_APP: string
  UP: string
  UP_APP: string
  END: string
  END_APP: string
  PGDN: string
  LEFT: string
  LEFT_APP: string
  DOWN: string
  DOWN_APP: string
  RIGHT: string
  RIGHT_APP: string
}

export const NormalKeySequences: NormalKeySequencesMap = {
  ESC: '\x1b',
  TAB: '\t',
  PGUP: '\x1b[5~',
  HOME: '\x1b[H',
  HOME_APP: '\x1b[1~',
  UP: '\x1b[A',
  UP_APP: '\x1bOA',
  END: '\x1b[F',
  END_APP: '\x1b[4~',
  PGDN: '\x1b[6~',
  LEFT: '\x1b[D',
  LEFT_APP: '\x1bOD',
  DOWN: '\x1b[B',
  DOWN_APP: '\x1bOB',
  RIGHT: '\x1b[C',
  RIGHT_APP: '\x1bOC'
}

// 带修饰键的方向键序列（xterm 风格），用于 TUI 应用的选择/跳转
export interface ModifiedArrowSequences {
  SHIFT_UP: string
  SHIFT_DOWN: string
  SHIFT_RIGHT: string
  SHIFT_LEFT: string
  CTRL_UP: string
  CTRL_DOWN: string
  CTRL_RIGHT: string
  CTRL_LEFT: string
  SHIFT_TAB: string
  CTRL_TAB: string
}

export const modifiedArrowSequences: ModifiedArrowSequences = {
  SHIFT_UP: '\x1b[1;2A',
  SHIFT_DOWN: '\x1b[1;2B',
  SHIFT_RIGHT: '\x1b[1;2C',
  SHIFT_LEFT: '\x1b[1;2D',
  CTRL_UP: '\x1b[1;5A',
  CTRL_DOWN: '\x1b[1;5B',
  CTRL_RIGHT: '\x1b[1;5C',
  CTRL_LEFT: '\x1b[1;5D',
  SHIFT_TAB: '\x1b[Z',
  CTRL_TAB: '\x1b[1;5Z'
}

export interface InputModifierResult {
  data: string
  shouldResetCtrl: boolean
  ctrlConverted: boolean
  shiftConverted: boolean
}

/**
 * 应用 Ctrl/Shift 修饰键到输入数据。
 * @param data 原始按键数据
 * @param ctrlPressed Ctrl 是否按下
 * @param shiftPressed Shift 是否按下
 * @param keyName 可选的按键标识，用于方向键/Tab 等多字节序列的修饰键处理
 */
export function applyVirtualKeyModifiers(data: string, ctrlPressed: boolean, shiftPressed: boolean,
  keyName?: string): InputModifierResult {
  let output = data
  let ctrlConverted = false
  let shiftConverted = false
  let shouldResetCtrl = false

  // 多字节控制序列（方向键、Tab、Home/End 等）的修饰键处理
  if (keyName) {
    const upperKey = keyName.toUpperCase()
    const isArrow = upperKey === 'UP' || upperKey === 'DOWN' || upperKey === 'LEFT' || upperKey === 'RIGHT'

    if (ctrlPressed && isArrow) {
      switch (upperKey) {
        case 'UP': output = modifiedArrowSequences.CTRL_UP; break
        case 'DOWN': output = modifiedArrowSequences.CTRL_DOWN; break
        case 'LEFT': output = modifiedArrowSequences.CTRL_LEFT; break
        case 'RIGHT': output = modifiedArrowSequences.CTRL_RIGHT; break
      }
      ctrlConverted = true
      shouldResetCtrl = true
    } else if (shiftPressed && isArrow) {
      switch (upperKey) {
        case 'UP': output = modifiedArrowSequences.SHIFT_UP; break
        case 'DOWN': output = modifiedArrowSequences.SHIFT_DOWN; break
        case 'LEFT': output = modifiedArrowSequences.SHIFT_LEFT; break
        case 'RIGHT': output = modifiedArrowSequences.SHIFT_RIGHT; break
      }
      shiftConverted = true
    } else if (ctrlPressed && upperKey === 'TAB') {
      output = modifiedArrowSequences.CTRL_TAB
      ctrlConverted = true
      shouldResetCtrl = true
    } else if (shiftPressed && upperKey === 'TAB') {
      output = modifiedArrowSequences.SHIFT_TAB
      shiftConverted = true
    }
  }

  // 单字符的 Ctrl/Shift 处理（字母键）
  if (ctrlPressed && output.length === 1) {
    const char = output.charAt(0)
    if (char >= 'a' && char <= 'z') {
      output = String.fromCharCode(char.charCodeAt(0) - 'a'.charCodeAt(0) + 1)
      ctrlConverted = true
    }
    shouldResetCtrl = true
  }

  if (shiftPressed && output.length === 1) {
    const char = output.charAt(0)
    if (char >= 'a' && char <= 'z') {
      output = char.toUpperCase()
      shiftConverted = true
    }
  }

  return {
    data: output,
    shouldResetCtrl: shouldResetCtrl,
    ctrlConverted: ctrlConverted,
    shiftConverted: shiftConverted
  }
}
