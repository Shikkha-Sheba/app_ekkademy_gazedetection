# ekkademy_gazedetection

Standalone, camera-based attentiveness/gaze detection for Flutter. Not tied
to any particular screen — use it from a video player, live class, audio
player, quiz, whatever.

Detects, on-device via ML Kit:

- Looking away (yaw/pitch beyond a threshold)
- Eyes closed
- No face in frame (learner left / camera covered)
- Multiple faces in frame (someone else is watching too)

## Install

This package isn't published to pub.dev, so depend on it as a local or git
package from your app's `pubspec.yaml`:

```yaml
dependencies:
  ekkademy_gazedetection:
    path: ../ekkademy_gazedetection   # adjust to wherever you place it
    # or, if you push it to its own git repo:
    # git:
    #   url: https://github.com/your-org/ekkademy_gazedetection.git
```

Then:

```dart
import 'package:ekkademy_gazedetection/ekkademy_gazedetection.dart';
```

## Platform setup

**iOS** — `ios/Runner/Info.plist`:
```xml
<key>NSCameraUsageDescription</key>
<string>Used to check you're still engaged with the lesson.</string>
```

**Android** — `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.CAMERA" />
```
`minSdkVersion 21` or higher (required by ML Kit).

If you use `AttentivenessConfig.enableSoundAlert` with an
`alertSoundAsset`, declare that asset under `flutter: assets:` in your
**app's** pubspec — packages don't bundle runtime assets for consumers.

## Basic usage (works anywhere)

```dart
import 'package:ekkademy_gazedetection/ekkademy_gazedetection.dart';

final monitor = AttentivenessMonitor(config: AttentivenessConfig.relaxed);

monitor.onBecameInattentive = (result) {
  debugPrint('Learner distracted: ${result.status}');
};
monitor.onBecameAttentive = (result) {
  debugPrint('Learner back on track');
};
monitor.onFaceMissing = (result) {
  debugPrint('Learner left the frame');
};

await monitor.start();

// later
await monitor.dispose();
```

Wrap `monitor.start()` in a try/catch — it throws a `StateError` if camera
permission is denied, so decide up front whether that should silently
disable the feature or show your own permission-rationale UI.

## Integration: video player

```dart
late final AttentivenessMonitor _attentivenessMonitor;

@override
void initState() {
  super.initState();
  _attentivenessMonitor = AttentivenessMonitor(config: AttentivenessConfig.strict)
    ..onBecameInattentive = (_) => _handleInattentive()
    ..onFaceMissing = (_) => _handleInattentive();
  _attentivenessMonitor.start().catchError((_) {
    // camera denied — just skip the feature rather than blocking playback
  });
}

Future<void> _handleInattentive() async {
  if (_checkpointDialogOpen || !mounted) return;
  _videoController?.pause();
  final res = await showAttentivenessPrompt(context: context);
  await _attentivenessMonitor.stopAlertSound();
  if (res?.dontShowAgain ?? false) {
    await _attentivenessMonitor.dismissForSession();
  }
  if (mounted && res?.confirmed == true) {
    _videoController?.play();
  }
}

@override
void dispose() {
  _attentivenessMonitor.dispose();
  super.dispose();
}
```

## Integration: live class screen

Instead of pausing local playback you'd likely just log it or surface a
lightweight in-UI badge — you don't want to interrupt a live session for
everyone:

```dart
final monitor = AttentivenessMonitor(config: AttentivenessConfig.relaxed)
  ..onBecameInattentive = (r) => _analytics.logAttentionDrop(sessionId, r.timestamp)
  ..onBecameAttentive = (r) => _analytics.logAttentionResume(sessionId, r.timestamp);
await monitor.start();
```

Use `monitor.status` (a `ValueNotifier<AttentivenessStatus>`) to drive a
small "you seem distracted" indicator instead of a blocking dialog, if
you'd rather not interrupt.

## Integration: audio-only screen

Works identically — the module never assumes there's a video surface:

```dart
void _onPlaybackStarted() => _attentivenessMonitor.start();
void _onPlaybackPaused() => _attentivenessMonitor.pause();
```

## Restyling the dialog

`showAttentivenessPrompt` takes an optional `theme:` parameter
(`AttentivenessDialogTheme`) so you can match your app's colors/typography
without forking the widget:

```dart
await showAttentivenessPrompt(
  context: context,
  theme: AttentivenessDialogTheme(
    primaryColor: AppColors.primary,
    errorColor: AppColors.error,
    titleStyle: AppTextStyles.bold14,
    messageStyle: AppTextStyles.medium12,
  ),
);
```

## Notes & caveats

- **Battery/CPU**: frame processing is throttled by
  `AttentivenessConfig.sampleInterval` (default ~1.4 fps). Raise it if you
  want to be gentler on battery; lower it for snappier detection.
- **Privacy**: this runs entirely on-device via ML Kit — no frames leave
  the phone unless you explicitly add that. Still, camera access for
  attention-monitoring is a meaningful privacy surface — get explicit
  opt-in (a settings toggle, a first-run explainer) rather than silently
  turning the camera on.
- **False positives**: front-camera face angle detection struggles with
  poor lighting, glasses glare, and phones propped at extreme angles.
  `AttentivenessConfig.relaxed` exists for this reason.
- **`_toInputImage`** in `attentiveness_service.dart` is the one part
  that's genuinely device/OS-sensitive (image plane layout varies slightly
  across Android vendors). It follows the standard ML Kit + `camera`
  plugin pattern, but test on a couple of real Android devices, not just
  iOS/simulator.

## What changed from the original in-app module

This package was extracted from an app-internal module that imported the
host app's design system (`AppText`, `AppColors`, `flutter_screenutil`
extensions) and logger directly. For a standalone, reusable package:

- The dialog was rewritten with plain Material widgets plus an
  `AttentivenessDialogTheme` you can pass in to restyle it.
- Internal logging now goes through `debugPrint` instead of an app-specific
  logger.
- `AttentivenessConfig` (referenced by the original files but not part of
  the handoff) was reconstructed from how `AttentivenessService` and
  `AttentivenessMonitor` use it — double check the default thresholds
  (`maxHeadYawDegrees`, grace periods, etc.) against whatever your original
  `attentiveness_config.dart` actually had, in case values drifted.
