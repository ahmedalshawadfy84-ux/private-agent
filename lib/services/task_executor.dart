import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'ai_service.dart';
import 'screen_automation_service.dart';
import 'app_launcher_service.dart';
import 'notification_service.dart';
import 'task_history_logger.dart';
import 'shizuku_service.dart';
import 'skill_memory_service.dart';
import 'recovery_engine.dart';
import '../models/saved_skill.dart';

/// Executes multi-step UI automation tasks using LLM-guided screen reading.
class TaskExecutor {
  final AiService _aiService;
  final ScreenAutomationService _screenService;
  final AppLauncherService _appLauncher;
  final ShizukuService _shizukuService;
  final NotificationService _notificationService = NotificationService();
  final SkillMemoryService _skillMemory = SkillMemoryService();
  final RecoveryEngine _recoveryEngine = RecoveryEngine();

  /// Callback to report progress messages to the UI
  final void Function(String message)? onProgress;

  /// Set to true to cancel the running task
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

  static const String _taskSystemPrompt = '''
You are a visual phone automation agent. You are given a TASK and a SCREENSHOT of the current phone screen.
You must analyze the image visual layout and decide what single action to take next to accomplish the task.

Respond with ONLY a JSON object (no markdown, no code fences):
{
  "action": "action_name",
  "params": {"key": "value"},
  "reasoning": "why you chose this action",
  "is_complete": false
}

Available actions:
- click_at: {"x": 540, "y": 960} - Click at exact visual screen coordinates (x, y) based on the image pixel location.
- type_text: {"text": "hello"} - Type into the currently focused edit field or text box.
- press_enter: {} - Press the Enter/Search key on the keyboard to submit.
- scroll: {"direction": "down"} - Scroll down/up on the current view.
- swipe: {"startX": 540, "startY": 2000, "endX": 540, "endY": 500} - Swipe from start to end coordinates.
- press_back: {} - Press the back button.
- press_home: {} - Press the home button.
- open_app: {"app_name": "WhatsApp"} - Open an application directly.
- wait: {} - Wait a moment for content to load.
- done: {} - Task is complete.

CRITICAL RULES:
- Read the entire TASK carefully. If the task contains multiple instructions (e.g., "Open YouTube AND write/search for trees"), opening the app is ONLY STEP 1!
- NEVER set is_complete=true or action="done" right after opening an app if there are remaining steps like typing or clicking search!
- Multi-step tasks MUST continue until the text is typed and searched on screen.
- Keep reasoning very brief (1 sentence).
''';

  String _extractJson(String text) {
    if (text.isEmpty) return '{}';
    final codeBlockRegex = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```', caseSensitive: false);
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
    await ScreenAutomationService.logToNative("[TaskExecutor] executeTask(): $userGoal");
    _cancelled = false;

    // 1. معالجة التحيات والمحادثات العادية بدون تشغيل أتمتة الشاشة
    final cleanGoal = userGoal.trim().toLowerCase();
    final conversationalGreetings = [
      'السلام عليكم', 'مرحبا', 'أهلا', 'اهلا', 'صباح الخير', 'مساء الخير',
      'hello', 'hi', 'hey', 'كيف حالك'
    ];
    if (conversationalGreetings.any((g) => cleanGoal.startsWith(g) || cleanGoal == g)) {
      if (cleanGoal.contains('السلام عليكم')) {
        return 'وعليكم السلام ورحمة الله وبركاته! كيف يمكنني مساعدتك اليوم في هاتفك؟';
      }
      return 'أهلاً بك! أنا جاهز لمساعدتك في أتمتة المهام والتحكم بالهاتف.';
    }

    final isRunning = await _screenService.isServiceRunning();
    if (!isRunning) {
      return 'إمكانية الوصول غير مفعلة. يرجى تفعيل PrivateAgent Screen Control من إعدادات إمكانية الوصول.';
    }

    final results = <String>[];
    results.add('Starting task: $userGoal');
    _report('Starting task: $userGoal');

    // 2. التحقق من ذاكرة المهارات (فقط للمهام ذات الخطوات المكتملة)
    final savedSkill = await _skillMemory.findSkill(userGoal);
    if (savedSkill != null && savedSkill.isReliable && savedSkill.steps.length > 1) {
      _report('Found saved skill! Replaying ${savedSkill.steps.length} steps...');
      final replaySuccess = await _replaySkill(savedSkill, results);
      if (replaySuccess) {
        results.add('Task complete via skill memory.');
        _report('Task complete (via skill memory).');
        await _notificationService.showTaskCompleteNotification('Task Completed', 'Agent finished goal via memory.');
        await TaskHistoryLogger.logTask(userGoal, 'Success', 0, savedSkill.steps.length, results);
        await _screenService.showToast('Task Complete! (Memory)');
        return 'Done.';
      } else {
        await _skillMemory.recordFailure(savedSkill.id);
      }
    }

    // 3. الاختصارات الذكية (تستخدم فقط إذا لم تكن المهمة مركبة وتحتوي على كتابة/بحث)
    final shortcut = _getNavigationShortcut(userGoal);
    String lastAction = '';
    int sameActionCount = 0;
    int consecutiveFailures = 0;
    String lastFailedAction = '';
    int totalTokens = 0;
    final List<ActionStep> executedSteps = [];

    if (shortcut != null && shortcut.isNotEmpty) {
      _report('Using navigation shortcut...');
      for (final step in shortcut) {
        if (_cancelled) break;
        bool success = false;
        if (step.action == 'open_app') {
          final appName = step.params['app_name'] as String? ?? '';
          final res = await _appLauncher.openApp(appName);
          success = res.startsWith('Opened');
          await Future.delayed(const Duration(milliseconds: 3000));
        }
        if (success) {
          executedSteps.add(step);
          lastAction = step.action;
        } else {
          break;
        }
      }
    } else {
      final currentPkg = await _screenService.getCurrentPackage();
      if (currentPkg == 'com.orailnoor.privateagent') {
        _report('Moving to background...');
        await _screenService.pressHome();
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    }

    // 4. حلقة أتمتة الذكاء الاصطناعي (AI Automation Loop)
    for (int step = 0; step < _aiService.maxSteps; step++) {
      if (_cancelled) {
        return await _handleCancellation(userGoal, totalTokens, step, results);
      }

      int delay = 1200;
      if (lastAction == 'open_app') delay = 3000;
      else if (lastAction == 'type_text') delay = 2000;
      else if (lastAction == 'click_text' || lastAction == 'click_at') delay = 1500;
      await Future.delayed(Duration(milliseconds: delay));

      final String? base64Image = await _screenService.takeScreenshot();
      final prevResultStr = step > 0 && results.isNotEmpty ? '\nPREVIOUS ACTION RESULT: ${results.last}\n' : '';

      final prompt = '''TASK: $userGoal
$prevResultStr
Step ${step + 1}/${_aiService.maxSteps}. Analyze the screenshot visual elements. What is the next action?''';

      String response;
      try {
        _cancelCompleter = Completer<void>();
        final aiFuture = _aiService.sendTaskMessage(_taskSystemPrompt, prompt, base64Image: base64Image);
        final result = await Future.any([aiFuture.then((r) => r), _cancelCompleter!.future.then((_) => null)]);

        if (result == null || _cancelled) {
          return await _handleCancellation(userGoal, totalTokens, step, results);
        }

        final aiResponse = result as AiResponse;
        response = aiResponse.content;
        totalTokens += aiResponse.totalTokens;
      } catch (e) {
        if (_cancelled) return await _handleCancellation(userGoal, totalTokens, step, results);
        return 'I could not complete the task because the AI service failed: $e';
      }

      Map<String, dynamic>? actionJson;
      try {
        String jsonStr = _extractJson(response);
        actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
      } catch (_) {
        _report('Retrying step ${step + 1}...');
        await Future.delayed(const Duration(seconds: 2));
        try {
          final retryResponse = await _aiService.sendTaskMessage(_taskSystemPrompt, prompt, base64Image: base64Image);
          totalTokens += retryResponse.totalTokens;
          actionJson = jsonDecode(_extractJson(retryResponse.content)) as Map<String, dynamic>;
        } catch (e) {
          return 'I could not understand the AI response.';
        }
      }

      final action = actionJson['action'] as String? ?? 'done';
      final params = actionJson['params'] as Map<String, dynamic>? ?? {};
      final reasoning = actionJson['reasoning'] as String? ?? '';
      final isComplete = actionJson['is_complete'] == true;

      _report('Step ${step + 1}: $reasoning');

      sameActionCount = action == lastAction ? sameActionCount + 1 : 1;
      if (sameActionCount > (action == 'scroll' ? 3 : 1000)) {
        consecutiveFailures = 3;
        continue;
      }
      lastAction = action;

      bool success = false;
      String actionResult = '';
      switch (action) {
        case 'click_text':
          final text = params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          actionResult = success ? 'Clicked "$text"' : 'Could not find "$text"';
          break;
        case 'click_at':
          final x = (params['x'] as num?)?.toDouble() ?? 0;
          final y = (params['y'] as num?)?.toDouble() ?? 0;
          success = await _screenService.clickAt(x, y);
          actionResult = success ? 'Clicked at ($x, $y)' : 'Click failed';
          break;
        case 'type_text':
          final text = params['text'] as String? ?? '';
          success = await _screenService.typeText(text);
          actionResult = success ? 'Typed "$text"' : 'Could not type text';
          break;
        case 'press_enter':
          success = await _submitKeyboardAction();
          actionResult = success ? 'Submitted enter key' : 'Failed to press enter';
          break;
        case 'swipe':
        case 'scroll':
          final direction = params['direction'] as String? ?? 'down';
          success = await _performScroll(direction);
          actionResult = success ? 'Scrolled $direction' : 'Scroll failed';
          break;
        case 'press_back':
          success = await _screenService.pressBack();
          actionResult = 'Pressed back';
          break;
        case 'press_home':
          success = await _screenService.pressHome();
          actionResult = 'Pressed home';
          break;
        case 'open_app':
          final appName = params['app_name'] as String? ?? '';
          actionResult = await _appLauncher.openApp(appName);
          success = actionResult.startsWith('Opened');
          break;
        case 'wait':
          await Future.delayed(const Duration(seconds: 1));
          actionResult = 'Waited';
          success = true;
          break;
        case 'done':
          results.add('Task complete: $reasoning');
          _report('Task complete: $reasoning');
          await _notificationService.showTaskCompleteNotification('Task Completed', reasoning);
          return reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();
        default:
          actionResult = 'Unknown action: $action';
      }

      if (!success) {
        consecutiveFailures++;
        if (consecutiveFailures >= 5) {
          return 'I could not complete the task after repeated attempts.';
        }
        final recovery = await _recoveryEngine.diagnose(action, base64Image ?? "");
        if (recovery.action == 'press_back') await _screenService.pressBack();
        continue;
      } else {
        consecutiveFailures = 0;
        executedSteps.add(ActionStep(action: action, params: params));
      }

      results.add('Step ${step + 1}: $actionResult ($reasoning)');

      if (isComplete) {
        results.add('Task complete.');
        _report('Task complete.');
        await _notificationService.showTaskCompleteNotification('Task Completed', 'Agent finished its goal.');
        
        // حفظ المهارة فقط إذا كانت تشتمل على أكثر من خطوة واحدة (تمنع حفظ فتح التطبيق كمهارة كاملة)
        if (executedSteps.length > 1) {
          await _skillMemory.saveSkill(userGoal, executedSteps);
        }
        await _screenService.showToast('Task Complete!');
        await Future.delayed(const Duration(seconds: 2));
        return reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();
      }
    }

    return 'I could not complete the task within the allowed steps.';
  }

  Future<String> _handleCancellation(String userGoal, int totalTokens, int step, List<String> results) async {
    results.add('Task cancelled by user.');
    _report('Task cancelled.');
    await _notificationService.showTaskCompleteNotification('Task Cancelled', 'Task was stopped by the user.');
    await TaskHistoryLogger.logTask(userGoal, 'Cancelled', totalTokens, step, results);
    return 'Task cancelled.';
  }

  void _report(String message) => onProgress?.call(message);

  Future<bool> _submitKeyboardAction() async {
    if (await _screenService.pressEnter()) return true;
    final result = await _shizukuService.runCommand('input keyevent 66');
    return !result.toLowerCase().contains('error');
  }

  Future<bool> _performScroll(String direction) async {
    if (await _screenService.scroll(direction)) return true;
    final isDown = direction.toLowerCase() == 'down';
    return _performSwipe(540, isDown ? 1800 : 600, 540, isDown ? 600 : 1800);
  }

  Future<bool> _performSwipe(double startX, double startY, double endX, double endY) async {
    if (await _screenService.swipe(startX, startY, endX, endY)) return true;
    final result = await _shizukuService.runCommand(
      'input swipe ${startX.toInt()} ${startY.toInt()} ${endX.toInt()} ${endY.toInt()} 600',
    );
    return !result.toLowerCase().contains('error');
  }

  Future<bool> _replaySkill(SavedSkill skill, List<String> results) async {
    for (int i = 0; i < skill.steps.length; i++) {
      if (_cancelled) return false;
      final step = skill.steps[i];
      _report('Replaying step ${i + 1}/${skill.steps.length}: ${step.action}');
      await Future.delayed(const Duration(milliseconds: 1500));

      bool success = false;
      if (step.action == 'open_app') {
        final appName = step.params['app_name'] as String? ?? '';
        final res = await _appLauncher.openApp(appName);
        success = res.startsWith('Opened');
      } else if (step.action == 'click_text') {
        success = await _screenService.clickByText(step.params['text'] as String? ?? '');
      } else if (step.action == 'click_at') {
        success = await _screenService.clickAt(
          (step.params['x'] as num).toDouble(),
          (step.params['y'] as num).toDouble(),
        );
      } else if (step.action == 'type_text') {
        success = await _screenService.typeText(step.params['text'] as String? ?? '');
      } else if (step.action == 'press_enter') {
        success = await _submitKeyboardAction();
      }
      if (!success) return false;
    }
    return true;
  }

  List<ActionStep>? _getNavigationShortcut(String goal) {
    final lower = goal.toLowerCase();

    // إلغاء الاختصار السريع إذا كانت المهمة تحتوي على كلمات دالة على خطوات متعددة (مثل اكتب، ابحث، ثم)
    final multiStepKeywords = ['واكتب', 'اكتب', 'ثم', 'ابحث', 'ارسل', 'انقر', 'type', 'search', 'write', 'click'];
    if (multiStepKeywords.any((k) => lower.contains(k))) {
      return null;
    }

    final appPatterns = <String, List<String>>{
      'YouTube': ['youtube'],
      'WhatsApp': ['whatsapp'],
      'Chrome': ['chrome'],
      'Settings': ['settings'],
    };

    for (final entry in appPatterns.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) {
          return [ActionStep(action: 'open_app', params: {'app_name': entry.key})];
        }
      }
    }
    return null;
  }
}
