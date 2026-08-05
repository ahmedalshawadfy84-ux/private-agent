import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'ai_service.dart';
import 'screen_automation_service.dart';
import 'app_launcher_service.dart';
import 'notification_service.dart';
import 'task_history_logger.dart';
import 'shizuku_service.dart';
import 'recovery_engine.dart';

class TaskExecutor {
  final AiService _aiService;
  final ScreenAutomationService _screenService;
  final AppLauncherService _appLauncher;
  final ShizukuService _shizukuService;
  final NotificationService _notificationService = NotificationService();
  final RecoveryEngine _recoveryEngine = RecoveryEngine();
  final void Function(String message)? onProgress;

  bool _cancelled = false;
  Completer<void>? _cancelCompleter;

  TaskExecutor({
    required AiService aiService,
    required ScreenAutomationService screenService,
    required AppLauncherService appLauncher,
    required ShizukuService shizukuService,
    this.onProgress,
  })  : _aiService = aiService,
        _screenService = screenService,
        _appLauncher = appLauncher,
        _shizukuService = shizukuService;

  void cancel() {
    _cancelled = true;
    if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
      _cancelCompleter!.complete();
    }
  }

  // System Prompt مخصص لألعاب Unity والرؤية البصرية والتطبيقات
  static const String _unityTaskSystemPrompt = '''
You are a visual mobile gaming and application automation agent.
You are provided with a visual SCREENSHOT of a mobile app or game (Unity/Vulkan/OpenGL canvas).

IMPORTANT RULES:
1. Game/App UIs may NOT expose readable text accessibility nodes. You MUST analyze the image visually.
2. ALWAYS use `click_at` with exact (x, y) visual screen coordinates based on the pixel layout of the provided screenshot.
3. For drag-and-drop or puzzle movements, use `swipe` with precise start and end coordinates.
4. CRITICAL: If the user request contains multiple actions (e.g. "open app AND search/type/click"), NEVER set "is_complete": true on an `open_app` action. Set "is_complete": false so you can process the newly opened screen in the next step.

Respond with ONLY a JSON object (no markdown, no code fences):
{
  "action": "action_name",
  "params": {"key": "value"},
  "reasoning": "visual reason for choosing this action",
  "is_complete": false
}

Available actions:
- click_at: {"x": 540, "y": 960} - Click at target visual screen coordinates (x, y).
- swipe: {"startX": 540, "startY": 1500, "endX": 540, "endY": 800} - Swipe/drag from start to end coordinates.
- type_text: {"text": "name"} - Type text if a native input/keyboard is active.
- press_back: {} - Press back button.
- press_home: {} - Press home button.
- open_app: {"app_name": "GameName"} - Open the target game or app.
- wait: {} - Wait for animations, game loading, or screen transitions (1-3 seconds).
- done: {} - Goal/Level completed.
''';

  String _extractJson(String text) {
    final codeBlockRegex = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
    final match = codeBlockRegex.firstMatch(text);
    if (match != null) return match.group(1)!;

    final startIndex = text.indexOf('{');
    final endIndex = text.lastIndexOf('}');
    if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
      return text.substring(startIndex, endIndex + 1);
    }
    return text.trim();
  }

  Future<String> executeTask(String userGoal) async {
    _cancelled = false;
    final isRunning = await _screenService.isServiceRunning();
    if (!isRunning) {
      return 'Accessibility service is not enabled.';
    }

    _report('Starting Visual Task: $userGoal');
    String lastAction = '';
    int totalTokens = 0;

    for (int step = 0; step < _aiService.maxSteps; step++) {
      if (_cancelled) return 'Task cancelled by user.';

      // إعطاء وقت كافٍ للعبة أو التطبيق للتحريك وتنفيذ الرسم
      int delay = 1500;
      if (lastAction == 'open_app') delay = 4000;
      else if (lastAction == 'swipe') delay = 2000;

      await Future.delayed(Duration(milliseconds: delay));

      // التقاط الشاشة البصرية كصورة (Screenshot)
      final String? base64Image = await _screenService.takeScreenshot();
      if (base64Image == null || base64Image.isEmpty) {
        _report('Failed to capture screenshot. Retrying...');
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      final prompt = '''TASK: $userGoal
Step ${step + 1}/${_aiService.maxSteps}. Analyze the visual screenshot image carefully. Determine the exact coordinates (x, y) to click, text to type, or swipe next.''';

      String response;
      try {
        _cancelCompleter = Completer<void>();
        final aiFuture = _aiService.sendTaskMessage(
          _unityTaskSystemPrompt, 
          prompt, 
          base64Image: base64Image
        );

        final result = await Future.any([
          aiFuture.then((r) => r),
          _cancelCompleter!.future.then((_) => null),
        ]);

        if (result == null || _cancelled) return 'Task cancelled.';
        final aiResponse = result as AiResponse;
        response = aiResponse.content;
        totalTokens += aiResponse.totalTokens;
      } catch (e) {
        return 'AI Vision Service failed: $e';
      }

      Map<String, dynamic> actionJson;
      try {
        actionJson = jsonDecode(_extractJson(response)) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      final action = actionJson['action'] as String? ?? 'wait';
      final params = actionJson['params'] as Map<String, dynamic>? ?? {};
      final reasoning = actionJson['reasoning'] as String? ?? '';
      bool isComplete = actionJson['is_complete'] == true;

      _report('Step ${step + 1}: $reasoning');
      lastAction = action;

      switch (action) {
        case 'click_at':
          final x = (params['x'] as num?)?.toDouble() ?? 0;
          final y = (params['y'] as num?)?.toDouble() ?? 0;
          await _screenService.clickAt(x, y);
          break;

        case 'swipe':
          final startX = (params['startX'] as num?)?.toDouble() ?? 540;
          final startY = (params['startY'] as num?)?.toDouble() ?? 1000;
          final endX = (params['endX'] as num?)?.toDouble() ?? 540;
          final endY = (params['endY'] as num?)?.toDouble() ?? 500;
          await _performSwipe(startX, startY, endX, endY);
          break;

        case 'type_text':
          final text = params['text'] as String? ?? '';
          await _screenService.typeText(text);
          break;

        case 'open_app':
          final appName = params['app_name'] as String? ?? '';
          await _appLauncher.openApp(appName);
          // تجاهل إشارة إكمال المهمة المبكرة فور فتح التطبيق لاستكمال باقي الأوامر
          isComplete = false; 
          break;

        case 'wait':
          await Future.delayed(const Duration(seconds: 2));
          break;

        case 'done':
          await _notificationService.showTaskCompleteNotification('Task Complete', reasoning);
          return reasoning;
      }

      if (isComplete && action != 'open_app') {
        await _notificationService.showTaskCompleteNotification('Task Complete', reasoning);
        return reasoning;
      }
    }

    return 'Task reached maximum step limit.';
  }

  void _report(String message) => onProgress?.call(message);

  Future<bool> _performSwipe(double startX, double startY, double endX, double endY) async {
    if (await _screenService.swipe(startX, startY, endX, endY)) return true;
    final result = await _shizukuService.runCommand(
      'input swipe ${startX.toInt()} ${startY.toInt()} ${endX.toInt()} ${endY.toInt()} 400',
    );
    return !result.toLowerCase().contains('error');
  }
}
