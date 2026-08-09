// attentiveness_prompt_dialog.dart
//
// Generic "are you still with us?" dialog. Not tied to video — usable from
// a live-class screen or an audio player too.
//
// This is a plain-Material implementation with no dependency on any host
// app's design system, so it drops into any Flutter app unmodified. Pass
// an [AttentivenessDialogTheme] to restyle it to match your app.

import 'package:flutter/material.dart';

/// What the learner did with the prompt.
class AttentivenessPromptResult {
  /// True if they tapped "I'm here". False/absent (dialog dismissed some
  /// other way) should be treated the same as false by callers — pause
  /// content, don't auto-resume — unless you want to allow silent dismissal.
  /// When true, pass this to `AttentivenessMonitor.markAttentive()`.
  final bool confirmed;

  /// True if they tapped "Ignore" instead of confirming. Monitoring keeps
  /// running in the background — pass this to
  /// `AttentivenessMonitor.ignoreInattentiveness()`, which suppresses this
  /// dialog from firing again for the same inattentive stretch but keeps
  /// notifying via `onInattentiveWhileIgnoring` /
  /// `onBecameAttentiveWhileIgnoring`. Mutually exclusive with [confirmed].
  final bool ignoreFuturePromptsForVideo;

  const AttentivenessPromptResult({
    required this.confirmed,
    required this.ignoreFuturePromptsForVideo,
  });
}

/// Visual customization for [AttentivenessPromptDialog]. Defaults fall back
/// to the ambient [Theme] so the dialog looks reasonable out of the box.
class AttentivenessDialogTheme {
  final Color? primaryColor;
  final Color? errorColor;
  final Color? secondaryTextColor;
  final BorderRadius borderRadius;
  final TextStyle? titleStyle;
  final TextStyle? messageStyle;

  const AttentivenessDialogTheme({
    this.primaryColor,
    this.errorColor,
    this.secondaryTextColor,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.titleStyle,
    this.messageStyle,
  });

  static const AttentivenessDialogTheme defaultTheme =
      AttentivenessDialogTheme();
}

/// Tracks the currently-open prompt (if any) so a new call to
/// [showAttentivenessPrompt] can dismiss it before showing the next one,
/// instead of stacking dialogs on top of each other. Module-private —
/// there's only ever one attentiveness prompt on screen at a time by
/// design, since [AttentivenessMonitor] re-fires `onBecameInattentive`
/// periodically (e.g. every 30s) for as long as the learner stays
/// inattentive.
BuildContext? _openPromptContext;
Future<AttentivenessPromptResult?>? _openPromptFuture;

/// Shows a blocking prompt asking the learner to confirm they're still
/// paying attention (or, with [showMultiplePersonsWarning], that only they
/// are in frame).
///
/// If a previous prompt from this function is still on screen (e.g.
/// [AttentivenessMonitor.onBecameInattentive] fired again 30s later while
/// the learner never responded), that old prompt is dismissed first and
/// this one takes its place — the dialog never stacks. The awaited call
/// from that earlier, now-replaced prompt resolves to `null` (dismissed
/// without an explicit response) once it's popped.
Future<AttentivenessPromptResult?> showAttentivenessPrompt({
  required BuildContext context,
  String title = 'You Are Distracted!',
  String message = 'You are not paying attention to the lesson.',
  bool showDontShowAgainOption = false,
  bool showMultiplePersonsWarning = false,
  bool showIgnoreOption = true,
  AttentivenessDialogTheme theme = AttentivenessDialogTheme.defaultTheme,
}) async {
  // Dismiss whichever prompt is currently showing, and wait for it to
  // actually finish popping before pushing the new one — pushing while a
  // pop is still resolving can otherwise race the navigator.
  final ctx = _openPromptContext;
  final previousFuture = _openPromptFuture;
  if (ctx != null && previousFuture != null) {
    if (ctx.mounted && Navigator.of(ctx, rootNavigator: true).canPop()) {
      Navigator.of(ctx, rootNavigator: true).pop();
    }
    await previousFuture;
  }

  final future = showGeneralDialog<AttentivenessPromptResult>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black87,
    transitionDuration: const Duration(milliseconds: 250),
    transitionBuilder: (ctx, anim, _, child) =>
        FadeTransition(opacity: anim, child: child),
    pageBuilder: (ctx, _, __) {
      _openPromptContext = ctx;
      return AttentivenessPromptDialog(
        title: title,
        message: message,
        showDontShowAgainOption: showDontShowAgainOption,
        showMultiplePersonsWarning: showMultiplePersonsWarning,
        theme: theme,
      );
    },
  );
  _openPromptFuture = future;

  final result = await future;
  if (identical(_openPromptFuture, future)) {
    _openPromptContext = null;
    _openPromptFuture = null;
  }
  return result;
}

class AttentivenessPromptDialog extends StatefulWidget {
  final String title;
  final String message;
  final bool showDontShowAgainOption;

  /// Swaps the icon to a "group" icon — use this when the dialog is being
  /// shown because `AttentivenessStatus.multiplePersonsDetected` fired,
  /// rather than a plain distraction/away check.
  final bool showMultiplePersonsWarning;

  final AttentivenessDialogTheme theme;

  const AttentivenessPromptDialog({
    super.key,
    required this.title,
    required this.message,
    required this.showDontShowAgainOption,
    this.showMultiplePersonsWarning = false,

    this.theme = AttentivenessDialogTheme.defaultTheme,
  });

  @override
  State<AttentivenessPromptDialog> createState() =>
      _AttentivenessPromptDialogState();
}

class _AttentivenessPromptDialogState extends State<AttentivenessPromptDialog> {
  bool _dontShowAgain = false;

  void _toggleDontShowAgain(bool? value) {
    setState(() => _dontShowAgain = value ?? false);
  }

  void _confirm() {
    Navigator.pop(
      context,
      AttentivenessPromptResult(
        confirmed: !_dontShowAgain,
        ignoreFuturePromptsForVideo: _dontShowAgain,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = widget.theme.primaryColor ?? scheme.primary;
    final error = widget.theme.errorColor ?? scheme.error;
    final secondaryText =
        widget.theme.secondaryTextColor ??
        Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7) ??
        Colors.black54;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      shape: RoundedRectangleBorder(borderRadius: widget.theme.borderRadius),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.showMultiplePersonsWarning
                  ? Icons.cancel_outlined
                  : Icons.error_outline_outlined,
              color: error,
              size: 36,
            ),
            const SizedBox(height: 12),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style:
                  widget.theme.titleStyle ??
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              widget.message,
              textAlign: TextAlign.center,
              style:
                  widget.theme.messageStyle ??
                  TextStyle(fontSize: 12, color: secondaryText),
            ),
            if (widget.showDontShowAgainOption) ...[
              const SizedBox(height: 16),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _toggleDontShowAgain(!_dontShowAgain),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _dontShowAgain,
                      activeColor: primary,
                      onChanged: _toggleDontShowAgain,
                    ),
                    Flexible(
                      child: Text(
                        "Don't show again for this video",
                        style: TextStyle(fontSize: 12, color: secondaryText),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _confirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text(
                  widget.showDontShowAgainOption ? 'Ok' : 'Sorry',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
