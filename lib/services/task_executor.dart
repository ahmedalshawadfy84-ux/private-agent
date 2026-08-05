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

  /// Cancel the currently running task — takes effect immediately
  void cancel() {
    _cancelled = true;
    if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
      _cancelCompleter!.complete();
    }
  }

  static const String _taskSystemPrompt = '''
You are a phone automation agent. You are given a TASK and the current SCREEN content.
You must decide what single action to take next to accomplish the task.

Respond with ONLY a JSON object (no markdown, no code fences):
{
  "action": "action_name",
  "params": {"key": "value"},
  "reasoning": "why you chose this action",
  "is_complete": false
}

Available actions:
- click_text: {"text": "exact text to click"} - Click an element by its visible text
- click_at: {"x": 540, "y": 960} - Click at screen coordinates (use bounds from screen dump)
- type_text: {"text": "hello", "field_hint": "optional hint"} - Type into the focused/first edit field
- press_enter: {} - Press the Enter/Search key on the keyboard to submit a search/form
- scroll: {"direction": "down"} - Scroll down/up on the current view
- swipe: {"startX": 540, "startY": 2000, "endX": 540, "endY": 500} - Swipe from start to end coordinates
- press_back: {} - Press the back button
- press_home: {} - Press the home button
- open_app: {"app_name": "WhatsApp"} - Open an app
- wait: {} - Wait a moment for content to load
- done: {} - Task is complete

CRITICAL MULTI-STEP RULES:
- Read the entire TASK carefully. If the task requires typing or searching (e.g. "Open YouTube AND write/search trees"), opening the app is ONLY STEP 1!
- NEVER set is_complete=true or action="done" immediately after opening an app if there are remaining instructions like typing or clicking search!
- Continue taking actions until the search is performed or text is typed on screen.
- Keep reasoning very brief (1 sentence).
''';

  /// Extract JSON safely even if wrapped in markdown or conversational text
  String _extractJson(String text) {
    final codeBlockRegex = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
    final match = codeBlockRegex.firstMatch(text);
    if (match != null) {
      return match.group(1)!;
    }
    final startIndex = text.indexOf('{');
    final endIndex = text.lastIndexOf('}');
    if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
      return text.substring(startIndex, endIndex + 1);
    }
    return text.trim();
  }

  /// Execute a multi-step task with LLM guidance
  Future<String> executeTask(String userGoal) async {
    await ScreenAutomationService.logToNative(
      "[TaskExecutor] executeTask() CALLED with goal: $userGoal",
    );
    _cancelled = false;

    // 1. المعالجة الفورية للتحيات والردود الحوارية بدون أتمتة أو إشعارات اكتمال
    final cleanGoal = userGoal.trim().toLowerCase();
    final conversationalGreetings = [
      'السلام عليكم', 'مرحبا', 'أهلا', 'اهلا', 'صباح الخير', 'مساء الخير',
      'hello', 'hi', 'hey', 'كيف حالك'
    ];
    if (conversationalGreetings.any((g) => cleanGoal.startsWith(g) || cleanGoal == g)) {
      if (cleanGoal.contains('السلام عليكم')) {
        return 'وعليكم السلام ورحمة الله وبركاته! كيف يمكنني مساعدتك في هاتفك اليوم؟';
      }
      return 'أهلاً بك! أنا جاهز لمساعدتك في تنفيذ المهام على هاتفك.';
    }

    final isRunning = await _screenService.isServiceRunning();
    if (!isRunning) {
      return 'Accessibility service is not enabled. Go to Settings \u2192 Accessibility \u2192 PrivateAgent Screen Control and enable it.';
    }

    final results = <String>[];
    results.add('Starting task: $userGoal');
    _report('Starting task: $userGoal');

    // 2. التحقق من ذاكرة المهارات (فقط للمهام ذات الخطوات المتعددة المركبة)
    final savedSkill = await _skillMemory.findSkill(userGoal);
    if (savedSkill != null && savedSkill.isReliable && savedSkill.steps.length > 1) {
      _report(
        'Found saved skill! Replaying ${savedSkill.steps.length} steps...',
      );
      final replaySuccess = await _replaySkill(savedSkill, results);
      if (replaySuccess) {
        results.add('Task complete via skill memory.');
        _report('Task complete (via skill memory).');
        await _notificationService.showTaskCompleteNotification(
          'Task Completed',
          'Agent finished its goal using memory.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Success',
          0,
          savedSkill.steps.length,
          results,
        );
        await _screenService.showToast('Task Complete! (Memory)');
        return 'Done.';
      } else {
        _report('Replay failed, falling back to AI...');
        await _skillMemory.recordFailure(savedSkill.id);
      }
    }

    // 3. الاختصارات الذكية (تُستثنى منها الجمل التي تحتوي على كلمات ربط أو خطوات إضافية)
    final shortcut = _getNavigationShortcut(userGoal);
    String lastAction = '';
    int sameActionCount = 0;
    int consecutiveFailures = 0;
    String lastFailedAction = '';
    int totalTokens = 0;
    final List<ActionStep> executedSteps = [];

    if (shortcut != null && shortcut.isNotEmpty) {
      results.add('Using navigation shortcut: ${shortcut.length} steps');
      _report('Using navigation shortcut...');
      for (final step in shortcut) {
        if (_cancelled) break;
        bool success = false;
        if (step.action == 'open_app') {
          final appName = step.params['app_name'] as String? ?? '';
          final res = await _appLauncher.openApp(appName);
          success = res.startsWith('Opened');
          await Future.delayed(const Duration(milliseconds: 3000));
        } else if (step.action == 'click_text') {
          final text = step.params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          await Future.delayed(const Duration(milliseconds: 1500));
        }
        if (success) {
          executedSteps.add(step);
          lastAction = step.action;
        } else {
          break; // Fall back to AI if shortcut step fails
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

    // 4. حلقة الأتمتة الرئيسية
    for (int step = 0; step < _aiService.maxSteps; step++) {
      if (_cancelled) {
        results.add('Task cancelled by user.');
        _report('Task cancelled.');
        await _notificationService.showTaskCompleteNotification(
          'Task Cancelled',
          'Task was stopped by the user.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Cancelled',
          totalTokens,
          step,
          results,
        );
        await _screenService.showToast('Task Cancelled');
        return 'Task cancelled.';
      }

      int delay = 1200;
      if (lastAction == 'open_app') {
        delay = 3000;
      } else if (lastAction == 'type_text') {
        delay = 2000;
      } else if (lastAction == 'click_text' || lastAction == 'click_at') {
        delay = 1500;
      } else if (lastAction == 'scroll') {
        delay = 1000;
      }
      await Future.delayed(Duration(milliseconds: delay));

      final screenContent = _aiService.useScreenCompression
          ? await _screenService.getCompressedScreenDescription(userGoal)
          : await _screenService.getScreenDescription();

      final prevResultStr = step > 0 && results.isNotEmpty
          ? '\nPREVIOUS ACTION RESULT: ${results.last}\n'
          : '';

      String failureHint = '';
      if (consecutiveFailures >= 3) {
        failureHint =
            '\n\nWARNING: You have failed $consecutiveFailures times in a row with the same approach. You MUST try a completely different action.';
      }

      final prompt =
          '''TASK: $userGoal
CURRENT SCREEN TEXT DUMP:
$screenContent$prevResultStr$failureHint
Step ${step + 1}/${_aiService.maxSteps}. Look at the text dump and coordinates. What is the next action?''';

      String response;
      try {
        _cancelCompleter = Completer<void>();
        final aiFuture = _aiService.sendTaskMessage(_taskSystemPrompt, prompt);
        final result = await Future.any([
          aiFuture.then((r) => r),
          _cancelCompleter!.future.then((_) => null),
        ]);
        if (result == null || _cancelled) {
          results.add('Task cancelled by user.');
          _report('Task cancelled.');
          return 'Task cancelled.';
        }
        final aiResponse = result as AiResponse;
        response = aiResponse.content;
        totalTokens += aiResponse.totalTokens;
      } catch (e) {
        if (_cancelled) return 'Task cancelled.';
        return 'I could not complete the task because the AI service failed.';
      }

      Map<String, dynamic>? actionJson;
      try {
        String jsonStr = _extractJson(response);
        actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
      } catch (firstError) {
        _report('Retrying step ${step + 1}...');
        await Future.delayed(const Duration(seconds: 2));
        try {
          final retryResponse = await _aiService.sendTaskMessage(
            _taskSystemPrompt,
            prompt,
          );
          totalTokens += retryResponse.totalTokens;
          String jsonStr = _extractJson(retryResponse.content);
          actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
        } catch (e) {
          return 'I could not understand the AI response. Please try again.';
        }
      }

      final action = actionJson['action'] as String? ?? 'done';
      final params = actionJson['params'] as Map<String, dynamic>? ?? {};
      final reasoning = actionJson['reasoning'] as String? ?? '';
      final isComplete = actionJson['is_complete'] == true;

      _report('Step ${step + 1}: $reasoning');

      sameActionCount = action == lastAction ? sameActionCount + 1 : 1;
      final repeatLimit = action == 'press_enter'
          ? 2
          : (action == 'scroll' || action == 'swipe' ? 3 : 1000);
      if (sameActionCount > repeatLimit) {
        consecutiveFailures = 3;
        lastFailedAction = action;
        lastAction = action;
        continue;
      }
      lastAction = action;

      bool success = false;
      String actionResult = '';
      switch (action) {
        case 'click_text':
          final text = params['text'] as String? ?? '';
          success = await _screenService.clickByText(text);
          actionResult = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';
          break;
        case 'click_at':
          final x = (params['x'] as num?)?.toDouble() ?? 0;
          final y = (params['y'] as num?)?.toDouble() ?? 0;
          success = await _screenService.clickAt(x, y);
          actionResult = success ? 'Clicked at ($x, $y)' : 'Click failed';
          break;
        case 'type_text':
          final text = params['text'] as String? ?? '';
          final hint = params['field_hint'] as String?;
          success = await _screenService.typeText(text, fieldHint: hint);
          actionResult = success ? 'Typed "$text"' : 'Could not type text';
          break;
        case 'press_enter':
          success = await _submitKeyboardAction();
          actionResult = success
              ? 'Submitted the focused search/form field'
              : 'Could not submit the focused field';
          break;
        case 'swipe':
          final startX = (params['startX'] as num?)?.toDouble() ?? 540;
          final startY = (params['startY'] as num?)?.toDouble() ?? 2000;
          final endX = (params['endX'] as num?)?.toDouble() ?? 540;
          final endY = (params['endY'] as num?)?.toDouble() ?? 500;
          success = await _performSwipe(startX, startY, endX, endY);
          actionResult = 'Swiped from ($startX,$startY) to ($endX,$endY)';
          break;
        case 'scroll':
          final direction = params['direction'] as String? ?? 'down';
          success = await _performScroll(direction);
          actionResult = success
              ? 'Scrolled $direction'
              : 'Could not scroll $direction';
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
          await _notificationService.showTaskCompleteNotification(
            'Task Completed',
            reasoning.trim().isEmpty ? 'Agent finished its goal.' : reasoning,
          );
          await _screenService.showToast('Task completed');
          return reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();
        default:
          actionResult = 'Unknown action: $action';
      }

      if (!success) {
        if (action == lastFailedAction) {
          consecutiveFailures++;
        } else {
          consecutiveFailures = 1;
          lastFailedAction = action;
        }
        if (consecutiveFailures >= 5) {
          return 'I could not complete the task. Please try again.';
        }
        final recovery = await _recoveryEngine.diagnose(action, screenContent);
        if (recovery.action == 'press_back') await _screenService.pressBack();
        continue;
      } else {
        consecutiveFailures = 0;
        lastFailedAction = '';
        executedSteps.add(ActionStep(action: action, params: params));
      }

      results.add('Step ${step + 1}: $actionResult ($reasoning)');

      if (isComplete) {
        results.add('Task complete.');
        _report('Task complete.');
        await _notificationService.showTaskCompleteNotification(
          'Task Completed',
          'Agent finished its goal.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Success',
          totalTokens,
          step,
          results,
        );
        
        // حفظ المهارة فقط عند تنفيذ أكثر من خطوة واحدة لضمان عدم حفظ فتح التطبيق المفرد كمهارة مكتملة
        if (executedSteps.length > 1) {
          await _skillMemory.saveSkill(userGoal, executedSteps);
        }
        await _screenService.showToast('Task Complete!');
        await Future.delayed(const Duration(seconds: 4));
        return reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();
      }
    }

    return 'I could not complete the task within the allowed steps.';
  }

  void _report(String message) {
    onProgress?.call(message);
  }

  Future<bool> _submitKeyboardAction() async {
    if (await _screenService.pressEnter()) return true;
    final shizukuAvailable = await _shizukuService.checkAvailability();
    if (!shizukuAvailable) return false;
    final result = await _shizukuService.runCommand('input keyevent 66');
    final normalized = result.toLowerCase();
    return !normalized.contains('not running') &&
        !normalized.contains('permission denied') &&
        !normalized.startsWith('error');
  }

  Future<bool> _performScroll(String direction) async {
    if (await _screenService.scroll(direction)) return true;
    final isDown = direction.toLowerCase() == 'down';
    return _performSwipe(540, isDown ? 1800 : 600, 540, isDown ? 600 : 1800);
  }

  Future<bool> _performSwipe(
    double startX,
    double startY,
    double endX,
    double endY,
  ) async {
    if (await _screenService.swipe(startX, startY, endX, endY)) return true;
    final shizukuAvailable = await _shizukuService.checkAvailability();
    if (!shizukuAvailable) return false;
    final result = await _shizukuService.runCommand(
      'input swipe ${startX.toInt()} ${startY.toInt()} '
      '${endX.toInt()} ${endY.toInt()} 600',
    );
    final normalized = result.toLowerCase();
    return !normalized.contains('not running') &&
        !normalized.contains('permission denied') &&
        !normalized.startsWith('error');
  }

  Future<bool> _replaySkill(SavedSkill skill, List<String> results) async {
    for (int i = 0; i < skill.steps.length; i++) {
      if (_cancelled) return false;
      final step = skill.steps[i];
      _report('Replaying step ${i + 1}/${skill.steps.length}: ${step.action}');
      int delay = 1200;
      if (step.action == 'open_app') delay = 3000;
      else if (step.action == 'type_text') delay = 2000;
      else if (step.action == 'click_text' || step.action == 'click_at') delay = 1500;
      await Future.delayed(Duration(milliseconds: delay));

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
        success = await _screenService.typeText(
          step.params['text'] as String? ?? '',
          fieldHint: step.params['field_hint'] as String?,
        );
      } else if (step.action == 'press_enter') {
        success = await _submitKeyboardAction();
      }
      if (!success) return false;
    }
    return true;
  }

  /// Returns predefined navigation steps for common tasks
  List<ActionStep>? _getNavigationShortcut(String goal) {
    final lower = goal.toLowerCase();

    // إلغاء الاختصارات السريعة فوراً إذا كانت الجملة مركبة وتتضمن إجراءات كتابة/بحث/نقر
    final multiStepKeywords = ['واكتب', 'اكتب', 'ثم', 'ابحث', 'ارسل', 'انقر', 'type', 'search', 'write', 'click', 'and'];
    if (multiStepKeywords.any((k) => lower.contains(k))) {
      return null;
    }

    final appPatterns = <String, List<String>>{
      'Settings': ['settings', 'brightness', 'display', 'notification'],
      'YouTube': ['youtube'],
      'WhatsApp': ['whatsapp'],
      'Chrome': ['chrome', 'browse', 'search google'],
    };

    for (final entry in appPatterns.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) {
          return [
            ActionStep(action: 'open_app', params: {'app_name': entry.key}),
          ];
        }
      }
    }
    return null;
  }
}
