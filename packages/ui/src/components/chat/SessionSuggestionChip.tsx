import React from 'react';
import { Icon } from '@/components/icon/Icon';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip';
import { Button } from '@/components/ui/button';
import { withoutAssistSuggestions } from '@/lib/sessionAssistMetadata';
import { patchSessionMetadata } from '@/sync/session-actions';
import { useI18n } from '@/lib/i18n';

interface SessionSuggestionChipProps {
  sessionId: string | null;
  /** The current continuation suggestion (`useSessionAssistState`). */
  suggestion: string | null;
  /** The current reply options; empty when there are none. */
  options: readonly string[];
  /** The composer already has content — the suggestion must stay out of the way. */
  hidden: boolean;
  /**
   * Show a continuation suggestion as a row. Layouts with a hardware keyboard
   * show it as ghost text in the editor instead; reply options are chips on
   * every layout.
   */
  showContinuation: boolean;
  onApply: (text: string) => void;
}

// A suggested follow-up, or the reply options to the agent's closing
// question, rendered as the composer's own top row (inside the box, and
// inside the mobile pill). Tapping one fills the composer (no auto-send); the
// X patches both out of the session metadata so they stay dismissed
// everywhere.
export const SessionSuggestionChip: React.FC<SessionSuggestionChipProps> = React.memo(({ sessionId, suggestion, options, hidden, showContinuation, onApply }) => {
  const { t } = useI18n();
  const [dismissing, setDismissing] = React.useState(false);

  const handleDismiss = React.useCallback(async (event: React.MouseEvent) => {
    event.stopPropagation();
    if (!sessionId || dismissing) return;
    setDismissing(true);
    try {
      await patchSessionMetadata(sessionId, undefined, withoutAssistSuggestions);
    } catch (error) {
      console.warn('Failed to dismiss suggestion:', error);
    } finally {
      setDismissing(false);
    }
  }, [sessionId, dismissing]);

  const continuation = showContinuation ? suggestion : null;
  if (hidden) {
    return null;
  }

  const dismissButton = (
    <Button
      type="button"
      variant="ghost"
      size="icon"
      onClick={(event) => void handleDismiss(event)}
      onMouseDown={(event) => event.preventDefault()}
      aria-label={t('chat.suggestion.dismissAria')}
      title={t('chat.suggestion.dismissAria')}
      className="size-7 shrink-0 rounded-lg text-muted-foreground hover:!bg-transparent hover:text-foreground active:!bg-transparent"
    >
      <Icon name="close" className="size-4" />
    </Button>
  );

  if (options.length > 0) {
    return (
      <div
        role="group"
        aria-label={t('chat.suggestion.optionsAria')}
        className="flex h-10 items-center gap-1 border-b border-border/60 pl-3 pr-1.5"
      >
        <Icon name="pencil-ai-2" className="size-3.5 shrink-0 text-muted-foreground opacity-70" />
        <div className="scrollbar-none flex min-w-0 flex-1 items-center gap-1.5 overflow-x-auto pl-1">
          {options.map((option) => (
            <Button
              key={option}
              type="button"
              variant="outline"
              size="xs"
              onClick={() => onApply(option)}
              onMouseDown={(event) => event.preventDefault()}
              title={option}
              className="min-w-0 max-w-[18rem] shrink font-normal normal-case text-muted-foreground hover:text-foreground"
            >
              <span className="truncate">{option}</span>
            </Button>
          ))}
        </div>
        {dismissButton}
      </div>
    );
  }

  if (!continuation) {
    return null;
  }

  return (
    <div className="flex h-10 items-center gap-1 border-b border-border/60 pl-3 pr-1.5">
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => onApply(continuation)}
              onMouseDown={(event) => event.preventDefault()}
              aria-label={t('chat.suggestion.applyAria')}
              className="min-w-0 flex-1 shrink justify-start px-0 text-sm font-normal normal-case text-muted-foreground hover:!bg-transparent hover:text-foreground has-[>svg]:px-0"
            >
              <Icon name="pencil-ai-2" className="size-3.5 shrink-0 opacity-70 transition-opacity group-hover:opacity-100" />
              <span className="truncate">{continuation}</span>
            </Button>
          </TooltipTrigger>
          <TooltipContent className="max-w-sm whitespace-pre-wrap">
            {continuation}
          </TooltipContent>
        </Tooltip>
        {dismissButton}
    </div>
  );
});

SessionSuggestionChip.displayName = 'SessionSuggestionChip';
