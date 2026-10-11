export interface EnterKeyPolicyInput {
    isMobile: boolean;
    isDesktopExpanded: boolean;
    enterToSend: boolean;
    enterToSendConfigured: boolean;
    shiftKey: boolean;
    ctrlKey: boolean;
    metaKey: boolean;
}

export const shouldSubmitEnter = (input: EnterKeyPolicyInput): boolean => {
    const isCtrlEnter = input.ctrlKey || input.metaKey;
    if (input.isMobile) return isCtrlEnter;
    if (input.isDesktopExpanded) return isCtrlEnter;

    const enterSendsByDefault = !input.isMobile;
    if (!input.enterToSendConfigured) {
        return !input.shiftKey && (enterSendsByDefault || isCtrlEnter);
    }
    const enterSends = input.enterToSend;
    const sendsWithEnter = enterSends
        ? !input.shiftKey
        : input.shiftKey;

    return isCtrlEnter || sendsWithEnter;
};

export interface EnterModifierState {
    shiftKey: boolean;
    ctrlKey: boolean;
    metaKey: boolean;
}

export const restoreDeferredEnterModifiers = (
    event: EnterModifierState,
    modifiers: EnterModifierState,
    preserveShift = true,
): void => {
    if (preserveShift && modifiers.shiftKey) {
        Object.defineProperty(event, 'shiftKey', { value: true });
    }
    if (modifiers.ctrlKey) Object.defineProperty(event, 'ctrlKey', { value: true });
    if (modifiers.metaKey) Object.defineProperty(event, 'metaKey', { value: true });
};

interface GhostTextKey {
    key: string;
    shiftKey: boolean;
    altKey: boolean;
    ctrlKey: boolean;
    metaKey: boolean;
}

/**
 * What a key does while ghost text is visible and no picker is open. Plain Tab
 * accepts and Escape dismisses, and both stop there; a printable character
 * dismisses and then does what it always does. Everything else, Shift+Tab
 * included, leaves the ghost text alone.
 */
export const ghostTextKeyAction = (event: GhostTextKey): 'accept' | 'dismiss' | 'dismiss-and-continue' | null => {
    const modified = event.altKey || event.ctrlKey || event.metaKey;
    if (event.key === 'Tab') return modified || event.shiftKey ? null : 'accept';
    if (event.key === 'Escape') return 'dismiss';
    if (event.key.length === 1 && !event.ctrlKey && !event.metaKey) return 'dismiss-and-continue';
    return null;
};
