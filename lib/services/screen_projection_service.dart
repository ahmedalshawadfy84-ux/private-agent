import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/services.dart';

/// Dart bridge to the native MediaProjection foreground service.
///
/// `ScreenCaptureService` (Kotlin) owns the live screen capture and a
/// persistent privacy indicator. This class coordinates consent, lifecycle,
/// and explicit user cancellation from the Flutter side.
class ScreenProjectionService {
  static const MethodChannel _channel =
      MethodChannel('com.privateagent/screen_projection');
  static const EventChannel _events =
      EventChannel('com.privateagent/screen_projection_events');

  bool _capturing = false;
  bool _consentPending = false;

  /// Broadcast stream of native events ("started", "stopped", "error:...",
  /// "consent|granted", "consent|denied").
  Stream<String> get events => _events
      .receiveBroadcastStream()
      .map((dynamic event) => event?.toString() ?? '');

  bool get isCapturing => _capturing;
  bool get hasPendingConsent => _consentPending;

  /// Request MediaProjection consent from the user. The native side fires
  /// the system screen-capture dialog and pushes the result back through
  /// the [events] stream ("consent|granted" / "consent|denied").
  ///
  /// Returns `true` if the consent flow was launched (the user still has
  /// to confirm), `false` if the platform refused to start the prompt.
  Future<bool> requestConsent() async {
    if (_consentPending) return true;
    _consentPending = true;
    try {
      final launched = await _channel.invokeMethod<bool>('requestConsent');
      return launched ?? false;
    } on PlatformException catch (e) {
      developer.log(
        'MediaProjection consent request failed: ${e.message}',
        name: 'ScreenProjectionService',
      );
      _consentPending = false;
      return false;
    }
  }

  /// Mark the service as active (called from a "consent|granted" listener).
  void markStarted() {
    _capturing = true;
    _consentPending = false;
  }

  /// Mark the service as inactive (called from a "stopped" / "error" /
  /// "consent|denied" listener).
  void markStopped() {
    _capturing = false;
    _consentPending = false;
  }

  /// Stop the foreground service and tear down the MediaProjection session.
  /// Safe to call even if the service is not running.
  Future<void> stop({String reason = 'requested by Flutter'}) async {
    try {
      await _channel.invokeMethod<bool>('stop', {'reason': reason});
    } on PlatformException catch (_) {
      // ignore — we still want to mark the local state as stopped
    }
    _capturing = false;
    _consentPending = false;
  }

  /// Whether the foreground service is currently active.
  Future<bool> isRunning() async {
    try {
      final result = await _channel.invokeMethod<bool>('isRunning');
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Whether a frame is cached and ready to be pulled (debug/preview only).
  Future<String?> latestFrame() async {
    try {
      return await _channel.invokeMethod<String>('latestFrame');
    } on PlatformException catch (_) {
      return null;
    }
  }

  void dispose() {
    _capturing = false;
    _consentPending = false;
  }
}
