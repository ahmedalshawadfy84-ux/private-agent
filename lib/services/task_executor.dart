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

/// Hybrid TaskExecutor:
/// - Text mode for normal Android apps using Accessibility Tree.
/// - Visual mode only for games / Unity / Canvas / OpenGL / Vulkan screens using screenshots.
class TaskExecutor {
  final AiService _aiService;
  final ScreenAutomationService _screenService;
  final AppLauncherService _appLauncher;
  final ShizukuService _shizukuService;

  final NotificationService _notificationService = NotificationService();
  final SkillMemoryService _skillMemory = SkillMemoryService();
  final RecoveryEngine _recoveryEngine = RecoveryEngine();

  /// Callback to report progress messages to the UI.
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

  /// Cancel the running task.
  void cancel() {
    _cancelled = true;

    if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
      _cancelCompleter!.complete();
    }
  }

  /// Text-mode system prompt for normal apps.
  static const String _textTaskSystemPrompt = '''
You are a phone automation agent. You are given a TASK and the current SCREEN content.

You must decide what single action to take next to accomplish the task.

Respond with ONLY a JSON object, no markdown, no code fences:

{
  "action": "action_name",
  "params": {"key": "value"},
  "reasoning": "brief reason",
  "is_complete": false
}

Available actions:

- click_text: {"text": "exact text to click"} - Click an element by its visible text.
- click_at: {"x": 540, "y": 960} - Click at screen coordinates.
- type_text: {"text": "hello", "field_hint": "optional hint"} - Type into focused/first edit field.
- press_enter: {} - Press Enter/Search key to submit a search/form.
- scroll: {"direction": "down"} - Scroll down/up.
- swipe: {"startX": 540, "startY": 2000, "endX": 540, "endY": 500} - Swipe.
- press_back: {} - Press back.
- press_home: {} - Press home.
- open_app: {"app_name": "YouTube"} - Open an app.
- wait: {} - Wait for loading.
- done: {} - Task is complete.

Rules:

- You will receive a TEXT DUMP of the accessibility tree with visible text and coordinates.
- ALWAYS use the text dump to decide your action.
- Prefer click_text for visible text. Use click_at only when no text exists.
- When typing in a search box or input field, click the field first, wait one step, then type.
- After typing a search query, use press_enter once. If nothing changes, click a visible suggestion/result.
- Do not repeat press_enter more than twice.
- Do not scroll/swipe more than three times in a row.
- If the user task contains multiple parts such as open app AND search/type/click, opening the app is NOT completion.
- Never use done just because the app is open.
- Use done only after the final requested result is visible or the requested typing/search/click has been completed.
- If stuck after 3 attempts, try a different action.
- Keep reasoning very brief.
''';

  /// Visual-mode system prompt for games only.
  static const String _visualGameSystemPrompt = '''
You are a visual mobile game automation agent.

You are provided with a SCREENSHOT of a mobile game or canvas-rendered UI, such as Unity, OpenGL, Vulkan, Canvas, or a UI with no useful accessibility nodes.

You must visually analyze the image and decide the next single action.

Respond with ONLY a JSON object, no markdown, no code fences:

{
  "action": "action_name",
  "params": {"key": "value"},
  "reasoning": "brief visual reason",
  "is_complete": false
}

Available actions:

- click_at: {"x": 540, "y": 960} - Tap exact visual coordinates.
- swipe: {"startX": 540, "startY": 1500, "endX": 540, "endY": 800} - Swipe or drag.
- type_text: {"text": "name"} - Type text if an input field is focused.
- press_enter: {} - Press Enter/Search/Done.
- press_back: {} - Press back.
- press_home: {} - Press home.
- open_app: {"app_name": "GameName"} - Open the requested game/app.
- wait: {} - Wait for animations/loading.
- done: {} - Goal completed.

Rules:

- This mode is for games only.
- Game UIs may not expose accessibility text. Use the screenshot visually.
- Use click_at and swipe for game controls, menus, buttons, puzzles, characters, items, and drag actions.
- If the task says open a game AND do another action, opening the game is NOT completion.
- Never set is_complete=true immediately after open_app if the task has more steps.
- Do not use done until the requested game action is completed.
- If a loading screen is visible, use wait.
- Keep reasoning very brief.
''';

  /// Safely extracts JSON from model output.
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

  /// Main entry point.
  Future<String> executeTask(String userGoal) async {
    await ScreenAutomationService.logToNative(
      '[TaskExecutor] executeTask() called with goal: $userGoal',
    );

    _cancelled = false;

    final isRunning = await _screenService.isServiceRunning();

    if (!isRunning) {
      return 'Accessibility service is not enabled. Go to Settings → Accessibility → PrivateAgent Screen Control and enable it.';
    }

    final results = <String>[];
    results.add('Starting task: $userGoal');

    final bool isGameTask = _isLikelyGameGoal(userGoal);

    if (isGameTask) {
      _report('Starting visual game task: $userGoal');
    } else {
      _report('Starting task: $userGoal');
    }

    int totalTokens = 0;
    String lastAction = '';
    int sameActionCount = 0;
    int consecutiveFailures = 0;
    String lastFailedAction = '';

    final List<ActionStep> executedSteps = [];

    /// Use skill memory only for normal app tasks.
    /// For games, recorded coordinates may be unreliable because game screens change.
    if (!isGameTask) {
      final savedSkill = await _skillMemory.findSkill(userGoal);

      if (savedSkill != null && savedSkill.isReliable) {
        _report('Found saved skill. Replaying ${savedSkill.steps.length} steps...');

        final replaySuccess = await _replaySkill(savedSkill, results);

        if (replaySuccess) {
          results.add('Task complete via skill memory.');
          _report('Task complete via memory.');

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

          await _screenService.showToast('Task Complete!');

          return 'Done.';
        } else {
          _report('Replay failed, falling back to AI...');
          await _skillMemory.recordFailure(savedSkill.id);
        }
      }
    }

    /// Shortcuts only for normal app tasks.
    if (!isGameTask) {
      final shortcut = _getNavigationShortcut(userGoal);

      if (shortcut != null && shortcut.isNotEmpty) {
        results.add('Using navigation shortcut: ${shortcut.length} steps');
        _report('Using navigation shortcut...');

        for (final step in shortcut) {
          if (_cancelled) break;

          final execution = await _executeAction(step.action, step.params);

          if (execution.success) {
            executedSteps.add(step);
            lastAction = step.action;
            await Future.delayed(_delayForAction(step.action));
          } else {
            break;
          }
        }
      } else {
        await _leavePrivateAgentIfNeeded();
      }
    } else {
      /// For visual game mode, leave PrivateAgent so screenshot does not show the chat.
      await _leavePrivateAgentIfNeeded();
    }

    for (int step = 0; step < _aiService.maxSteps; step++) {
      if (_cancelled) {
        return await _finishCancelled(
          userGoal: userGoal,
          totalTokens: totalTokens,
          step: step,
          results: results,
        );
      }

      await Future.delayed(_delayForAction(lastAction));

      final bool useVisualMode = isGameTask;

      String screenContent = '';
      String? base64Image;

      if (useVisualMode) {
        base64Image = await _screenService.takeScreenshot();

        if (base64Image == null || base64Image.isEmpty) {
          _report('Failed to capture game screenshot. Retrying...');
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
      } else {
        screenContent = _aiService.useScreenCompression
            ? await _screenService.getCompressedScreenDescription(userGoal)
            : await _screenService.getScreenDescription();

        developer.log(
          '=== TEXT SCREEN DUMP Step ${step + 1} ===\n$screenContent',
          name: 'PrivateAgent',
        );
      }

      final previousResultStr = step > 0 && results.isNotEmpty
          ? '\nPREVIOUS ACTION RESULT: ${results.last}\n'
          : '';

      String failureHint = '';

      if (consecutiveFailures >= 3) {
        failureHint = '''
        
WARNING: You failed $consecutiveFailures times in a row.
You MUST try a different action.
Do NOT repeat the same failed action.
If click_text failed, use click_at.
If open_app failed, press_home and look for the app.
''';
      }

      final String prompt = useVisualMode
          ? '''TASK: $userGoal

Step ${step + 1}/${_aiService.maxSteps}.

Analyze the provided game screenshot visually.
Choose the next action using exact coordinates if needed.
$previousResultStr$failureHint
'''
          : '''TASK: $userGoal

CURRENT SCREEN TEXT DUMP:

$screenContent
$previousResultStr
$failureHint

Step ${step + 1}/${_aiService.maxSteps}.
Look at the text dump and coordinates. What is the next action?
''';

      developer.log(
        '=== AI PROMPT Step ${step + 1} ===\n$prompt',
        name: 'PrivateAgent',
      );

      _AiActionResponse aiActionResponse;

      try {
        aiActionResponse = await _requestAiAction(
          systemPrompt: useVisualMode
              ? _visualGameSystemPrompt
              : _textTaskSystemPrompt,
          prompt: prompt,
          base64Image: base64Image,
          step: step,
        );

        totalTokens += aiActionResponse.totalTokens;
      } catch (e) {
        if (_cancelled) {
          return await _finishCancelled(
            userGoal: userGoal,
            totalTokens: totalTokens,
            step: step,
            results: results,
          );
        }

        results.add('AI error: $e');
        _report('AI error: $e');

        await _notificationService.showTaskCompleteNotification(
          'Task Error',
          'AI encountered an error.',
        );

        await TaskHistoryLogger.logTask(
          userGoal,
          'Failed',
          totalTokens,
          step,
          results,
        );

        await _screenService.showToast('AI Error');

        return 'I could not complete the task because the AI service failed.';
      }

      if (_cancelled) {
        return await _finishCancelled(
          userGoal: userGoal,
          totalTokens: totalTokens,
          step: step,
          results: results,
        );
      }

      final action = aiActionResponse.action;
      final params = aiActionResponse.params;
      final reasoning = aiActionResponse.reasoning;
      final isComplete = aiActionResponse.isComplete;

      developer.log(
        '=== PARSED ACTION Step ${step + 1} ===\n'
        'Mode: ${useVisualMode ? "VISUAL_GAME" : "TEXT"}\n'
        'Action: $action\n'
        'Params: $params\n'
        'Reasoning: $reasoning\n'
        'IsComplete: $isComplete',
        name: 'PrivateAgent',
      );

      _report('Step ${step + 1}: $reasoning');

      final String previousAction = lastAction;

      sameActionCount = action == lastAction ? sameActionCount + 1 : 1;

      final repeatLimit = action == 'press_enter'
          ? 2
          : (action == 'scroll' || action == 'swipe' ? 3 : 1000);

      if (sameActionCount > repeatLimit) {
        final blockedResult =
            'Blocked repeated $action action. Trying a different action.';

        results.add(blockedResult);
        _report(blockedResult);

        consecutiveFailures = 3;
        lastFailedAction = action;
        lastAction = action;

        continue;
      }

      lastAction = action;

      final bool requestedCompletion = action == 'done' || isComplete;

      _ExecutionResult execution;

      if (action == 'done') {
        execution = const _ExecutionResult(
          success: true,
          message: 'AI requested completion',
        );
      } else {
        execution = await _executeAction(action, params);
      }

      developer.log(
        '=== EXECUTION RESULT Step ${step + 1} ===\n${execution.message}',
        name: 'PrivateAgent',
      );

      if (!execution.success) {
        if (action == lastFailedAction) {
          consecutiveFailures++;
        } else {
          consecutiveFailures = 1;
          lastFailedAction = action;
        }

        if (consecutiveFailures >= 5) {
          results.add(
            'Agent is stuck after $consecutiveFailures consecutive failures.',
          );

          _report('Agent stuck. Stopping task.');

          await _notificationService.showTaskCompleteNotification(
            'Task Stuck',
            'Agent could not complete the task after repeated failures.',
          );

          await TaskHistoryLogger.logTask(
            userGoal,
            'Failed',
            totalTokens,
            step,
            results,
          );

          await _screenService.showToast('Agent stuck. Task stopped.');

          return 'I could not complete the task. Please try again.';
        }

        /// Recovery is mainly useful for text-mode Android apps.
        if (!useVisualMode) {
          final recovery = await _recoveryEngine.diagnose(action, screenContent);

          _report('Recovering: ${recovery.description}');

          if (recovery.action == 'wait') {
            await Future.delayed(const Duration(seconds: 2));
          } else if (recovery.action == 'press_back') {
            await _screenService.pressBack();
          } else if (recovery.action == 'scroll') {
            final dir = recovery.params['direction'] ?? 'down';

            if (dir == 'down') {
              await _shizukuService.runCommand(
                'input swipe 540 1800 540 600 600',
              );
            } else {
              await _shizukuService.runCommand(
                'input swipe 540 600 540 1800 600',
              );
            }
          } else if (recovery.action == 'press_home') {
            await _screenService.pressHome();
          }

          results.add('Recovery step: ${recovery.description}');
        } else {
          results.add('Visual action failed: ${execution.message}');
          await Future.delayed(const Duration(seconds: 1));
        }

        continue;
      } else {
        consecutiveFailures = 0;
        lastFailedAction = '';

        if (action != 'done') {
          executedSteps.add(
            ActionStep(
              action: action,
              params: Map<String, dynamic>.from(params),
            ),
          );
        }
      }

      results.add('Step ${step + 1}: ${execution.message} ($reasoning)');

      /// Important guard against premature completion.
      if (requestedCompletion) {
        final canComplete = _canAcceptCompletion(
          action: action,
          isComplete: isComplete,
          userGoal: userGoal,
          step: step,
          previousAction: previousAction,
          executedSteps: executedSteps,
        );

        if (!canComplete) {
          results.add('Ignored premature completion request.');
          _report('Ignoring premature completion. Continuing...');
          await Future.delayed(const Duration(milliseconds: 1200));
          continue;
        }

        results.add('Task complete.');
        _report('Task complete.');

        await _notificationService.showTaskCompleteNotification(
          'Task Completed',
          reasoning.trim().isEmpty ? 'Agent finished its goal.' : reasoning,
        );

        await TaskHistoryLogger.logTask(
          userGoal,
          'Success',
          totalTokens,
          step + 1,
          results,
        );

        /// Save skills only for normal app tasks.
        if (!isGameTask && executedSteps.isNotEmpty) {
          await _skillMemory.saveSkill(userGoal, executedSteps);
        }

        await _screenService.showToast('Task Complete!');

        return reasoning.trim().isEmpty ? 'Done.' : reasoning.trim();
      }

      if ((step + 1) % 3 == 0) {
        await _screenService.showToast('Working... Step ${step + 1}');
      }
    }

    results.add(
      'Reached maximum steps (${_aiService.maxSteps}). Task may be incomplete.',
    );

    _report('Reached maximum steps.');

    await _notificationService.showTaskCompleteNotification(
      'Task Stopped',
      'Reached maximum steps (${_aiService.maxSteps}).',
    );

    await TaskHistoryLogger.logTask(
      userGoal,
      'Failed',
      totalTokens,
      _aiService.maxSteps,
      results,
    );

    await _screenService.showToast('Reached maximum steps.');

    return 'I could not complete the task within the allowed steps.';
  }

  Future<_AiActionResponse> _requestAiAction({
    required String systemPrompt,
    required String prompt,
    required int step,
    String? base64Image,
  }) async {
    String response;
    int totalTokens = 0;

    try {
      _cancelCompleter = Completer<void>();

      final aiFuture = _aiService.sendTaskMessage(
        systemPrompt,
        prompt,
        base64Image: base64Image,
      );

      final result = await Future.any([
        aiFuture.then((r) => r),
        _cancelCompleter!.future.then((_) => null),
      ]);

      if (result == null || _cancelled) {
        throw Exception('Task cancelled.');
      }

      final aiResponse = result as AiResponse;
      response = aiResponse.content;
      totalTokens += aiResponse.totalTokens;

      developer.log(
        '=== RAW AI RESPONSE Step ${step + 1} ===\n$response',
        name: 'PrivateAgent',
      );
    } catch (e) {
      rethrow;
    }

    try {
      return _parseAiAction(response, totalTokens);
    } catch (firstError) {
      developer.log(
        '=== JSON PARSE FAILED Step ${step + 1}, RETRYING ===\n'
        'Error: $firstError\nRaw: $response',
        name: 'PrivateAgent',
      );

      _report('Retrying step ${step + 1} due to formatting error...');

      await Future.delayed(const Duration(seconds: 2));

      final retryResponse = await _aiService.sendTaskMessage(
        systemPrompt,
        prompt,
        base64Image: base64Image,
      );

      totalTokens += retryResponse.totalTokens;

      developer.log(
        '=== RETRY AI RESPONSE Step ${step + 1} ===\n${retryResponse.content}',
        name: 'PrivateAgent',
      );

      return _parseAiAction(retryResponse.content, totalTokens);
    }
  }

  _AiActionResponse _parseAiAction(String response, int totalTokens) {
    final jsonStr = _extractJson(response);
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

    final rawParams = decoded['params'];
    final params = rawParams is Map
        ? Map<String, dynamic>.from(rawParams)
        : <String, dynamic>{};

    return _AiActionResponse(
      action: decoded['action'] as String? ?? 'wait',
      params: params,
      reasoning: decoded['reasoning'] as String? ?? '',
      isComplete: decoded['is_complete'] == true,
      totalTokens: totalTokens,
    );
  }

  Future<_ExecutionResult> _executeAction(
    String action,
    Map<String, dynamic> params,
  ) async {
    bool success = false;
    String message = '';

    switch (action) {
      case 'click_text':
        final text = params['text'] as String? ?? '';
        success = await _screenService.clickByText(text);
        message = success ? 'Clicked "$text"' : 'Could not find "$text"';
        break;

      case 'click_at':
        final x = (params['x'] as num?)?.toDouble() ?? 0;
        final y = (params['y'] as num?)?.toDouble() ?? 0;
        success = await _screenService.clickAt(x, y);
        message = success ? 'Clicked at ($x, $y)' : 'Click failed';
        break;

      case 'type_text':
        final text = params['text'] as String? ?? '';
        final hint = params['field_hint'] as String?;
        success = await _screenService.typeText(text, fieldHint: hint);
        message = success ? 'Typed "$text"' : 'Could not type text';
        break;

      case 'press_enter':
        success = await _submitKeyboardAction();
        message = success
            ? 'Submitted the focused field'
            : 'Could not submit the focused field';
        break;

      case 'scroll':
        final direction = params['direction'] as String? ?? 'down';
        success = await _performScroll(direction);
        message = success ? 'Scrolled $direction' : 'Could not scroll';
        break;

      case 'swipe':
        final startX = (params['startX'] as num?)?.toDouble() ?? 540;
        final startY = (params['startY'] as num?)?.toDouble() ?? 1800;
        final endX = (params['endX'] as num?)?.toDouble() ?? 540;
        final endY = (params['endY'] as num?)?.toDouble() ?? 600;

        success = await _performSwipe(startX, startY, endX, endY);
        message = success
            ? 'Swiped from ($startX, $startY) to ($endX, $endY)'
            : 'Swipe failed';
        break;

      case 'press_back':
        success = await _screenService.pressBack();
        message = 'Pressed back';
        break;

      case 'press_home':
        success = await _screenService.pressHome();
        message = 'Pressed home';
        break;

      case 'open_app':
        final appName = params['app_name'] as String? ?? '';
        message = await _appLauncher.openApp(appName);
        success = message.startsWith('Opened');
        break;

      case 'wait':
        await Future.delayed(const Duration(seconds: 1));
        success = true;
        message = 'Waited';
        break;

      default:
        success = false;
        message = 'Unknown action: $action';
        break;
    }

    return _ExecutionResult(success: success, message: message);
  }

  Future<String> _finishCancelled({
    required String userGoal,
    required int totalTokens,
    required int step,
    required List<String> results,
  }) async {
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

  void _report(String message) {
    onProgress?.call(message);
  }

  Future<void> _leavePrivateAgentIfNeeded() async {
    final currentPkg = await _screenService.getCurrentPackage();

    if (currentPkg == 'com.orailnoor.privateagent') {
      _report('Moving PrivateAgent to background...');
      await _screenService.pressHome();
      await Future.delayed(const Duration(milliseconds: 1500));
    }
  }

  Duration _delayForAction(String action) {
    if (action == 'open_app') {
      return const Duration(milliseconds: 3500);
    }

    if (action == 'type_text') {
      return const Duration(milliseconds: 1800);
    }

    if (action == 'click_text' || action == 'click_at') {
      return const Duration(milliseconds: 1500);
    }

    if (action == 'swipe') {
      return const Duration(milliseconds: 1800);
    }

    if (action == 'scroll') {
      return const Duration(milliseconds: 1000);
    }

    return const Duration(milliseconds: 1200);
  }

  Future<bool> _submitKeyboardAction() async {
    if (await _screenService.pressEnter()) {
      return true;
    }

    final shizukuAvailable = await _shizukuService.checkAvailability();

    if (!shizukuAvailable) {
      return false;
    }

    final result = await _shizukuService.runCommand('input keyevent 66');
    final normalized = result.toLowerCase();

    return !normalized.contains('not running') &&
        !normalized.contains('permission denied') &&
        !normalized.startsWith('error');
  }

  Future<bool> _performScroll(String direction) async {
    if (await _screenService.scroll(direction)) {
      return true;
    }

    final isDown = direction.toLowerCase() == 'down';

    return _performSwipe(
      540,
      isDown ? 1800 : 600,
      540,
      isDown ? 600 : 1800,
    );
  }

  Future<bool> _performSwipe(
    double startX,
    double startY,
    double endX,
    double endY,
  ) async {
    if (await _screenService.swipe(startX, startY, endX, endY)) {
      return true;
    }

    final shizukuAvailable = await _shizukuService.checkAvailability();

    if (!shizukuAvailable) {
      return false;
    }

    final result = await _shizukuService.runCommand(
      'input swipe ${startX.toInt()} ${startY.toInt()} '
      '${endX.toInt()} ${endY.toInt()} 600',
    );

    final normalized = result.toLowerCase();

    return !normalized.contains('not running') &&
        !normalized.contains('permission denied') &&
        !normalized.startsWith('error');
  }

  bool _isLikelyGameGoal(String goal) {
    final lower = goal.toLowerCase();

    final gameKeywords = <String>[
      'game',
      'games',
      'gaming',
      'unity',
      'level',
      'puzzle',
      'player',
      'character',
      'joystick',
      'coins',
      'enemy',
      'mission',
      'stage',
      'لعبة',
      'اللعبة',
      'العاب',
      'الألعاب',
      'الالعاب',
      'مرحلة',
      'مستوى',
      'لغز',
      'ألغاز',
      'الغاز',
      'لاعب',
      'شخصية',
      'عدو',
      'مهمة',
      'اجمع',
      'اقفز',
      'تحرك',
      'حرك',
      'حرّك',
      'اسحب داخل اللعبة',
      'اضغط داخل اللعبة',
      'subway surfers',
      'pubg',
      'free fire',
      'minecraft',
      'roblox',
      'candy crush',
      'clash of clans',
      'clash royale',
      'among us',
      'temple run',
      'call of duty',
      'mobile legends',
      'genshin',
      'fortnite',
    ];

    return gameKeywords.any((keyword) => lower.contains(keyword));
  }

  bool _goalHasMoreThanOpenApp(String goal) {
    final lower = goal.toLowerCase();

    final extraActionKeywords = <String>[
      'واكتب',
      'اكتب',
      'وابحث',
      'ابحث',
      'بحث',
      'وافتح ثم',
      'ثم',
      'واضغط',
      'اضغط',
      'واختر',
      'اختر',
      'ادخل',
      'اكتب في',
      'شغل ثم',
      'افتح ثم',
      'search',
      'type',
      'write',
      'click',
      'tap',
      'press',
      'then',
      'and search',
      'and type',
      'and click',
    ];

    return extraActionKeywords.any((keyword) => lower.contains(keyword));
  }

  bool _isOpenOnlyGoal(String goal) {
    final lower = goal.toLowerCase().trim();

    final startsWithOpen = lower.startsWith('open ') ||
        lower.startsWith('افتح ') ||
        lower.startsWith('شغل ') ||
        lower.startsWith('افتحي ') ||
        lower.startsWith('شغلي ');

    return startsWithOpen && !_goalHasMoreThanOpenApp(goal);
  }

  bool _goalRequiresTyping(String goal) {
    final lower = goal.toLowerCase();

    return lower.contains('اكتب') ||
        lower.contains('واكتب') ||
        lower.contains('type') ||
        lower.contains('write');
  }

  bool _goalRequiresSearchSubmit(String goal) {
    final lower = goal.toLowerCase();

    return lower.contains('ابحث') ||
        lower.contains('وابحث') ||
        lower.contains('بحث') ||
        lower.contains('search');
  }

  bool _canAcceptCompletion({
    required String action,
    required bool isComplete,
    required String userGoal,
    required int step,
    required String previousAction,
    required List<ActionStep> executedSteps,
  }) {
    final requestedCompletion = action == 'done' || isComplete;

    if (!requestedCompletion) {
      return false;
    }

    /// Opening an app can be completion only if the goal is just "open X".
    if (action == 'open_app') {
      return _isOpenOnlyGoal(userGoal);
    }

    /// If the previous action was opening an app and the task has more parts,
    /// do not accept completion immediately.
    if (previousAction == 'open_app' && _goalHasMoreThanOpenApp(userGoal)) {
      return false;
    }

    /// Do not accept completion too early for compound goals.
    if (step < 2 && _goalHasMoreThanOpenApp(userGoal)) {
      return false;
    }

    final actions = executedSteps.map((e) => e.action).toList();

    if (_goalRequiresTyping(userGoal) && !actions.contains('type_text')) {
      return false;
    }

    if (_goalRequiresSearchSubmit(userGoal)) {
      final hasTyped = actions.contains('type_text');
      final hasSubmitted = actions.contains('press_enter') ||
          actions.contains('click_text') ||
          actions.contains('click_at');

      if (!hasTyped || !hasSubmitted) {
        return false;
      }
    }

    return true;
  }

  Future<bool> _replaySkill(SavedSkill skill, List<String> results) async {
    for (int i = 0; i < skill.steps.length; i++) {
      if (_cancelled) {
        return false;
      }

      final step = skill.steps[i];

      _report('Replaying step ${i + 1}/${skill.steps.length}: ${step.action}');

      await Future.delayed(_delayForAction(step.action));

      final execution = await _executeAction(step.action, step.params);

      results.add('Memory Replay Step ${i + 1}: ${execution.message}');

      developer.log(
        '=== MEMORY REPLAY RESULT ===\n${execution.message}',
        name: 'PrivateAgent',
      );

      if (!execution.success) {
        return false;
      }
    }

    return true;
  }

  List<ActionStep>? _getNavigationShortcut(String goal) {
    final lower = goal.toLowerCase();

    if (lower.contains('dark mode') || lower.contains('dark theme')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(action: 'click_text', params: {'text': 'Display'}),
      ];
    }

    if (lower.contains('wifi') || lower.contains('wi-fi')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(
          action: 'click_text',
          params: {'text': 'Network & internet'},
        ),
      ];
    }

    if (lower.contains('bluetooth')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(action: 'click_text', params: {'text': 'Connected devices'}),
      ];
    }

    final appPatterns = <String, List<String>>{
      'Settings': [
        'settings',
        'brightness',
        'display',
        'notification',
        'الإعدادات',
        'اعدادات',
        'السطوع',
      ],
      'Play Store': [
        'play store',
        'playstore',
        'download',
        'install app',
        'google play',
        'متجر',
        'حمل تطبيق',
        'تثبيت تطبيق',
      ],
      'YouTube': [
        'youtube',
        'يوتيوب',
        'اليوتيوب',
      ],
      'WhatsApp': [
        'whatsapp',
        'واتساب',
        'واتس',
      ],
      'Chrome': [
        'chrome',
        'browse',
        'search google',
        'كروم',
        'جوجل',
        'متصفح',
      ],
      'Camera': [
        'camera',
        'take a photo',
        'take photo',
        'take a picture',
        'كاميرا',
        'صورة',
      ],
      'Gallery': [
        'gallery',
        'photos',
        'معرض',
        'الصور',
      ],
      'Messages': [
        'message',
        'sms',
        'text to',
        'رسالة',
        'رسائل',
      ],
      'Phone': [
        'call',
        'dial',
        'اتصل',
        'مكالمة',
        'الهاتف',
      ],
      'Gmail': [
        'gmail',
        'email',
        'ايميل',
        'بريد',
      ],
      'Maps': [
        'maps',
        'navigate to',
        'directions',
        'خرائط',
        'خريطة',
      ],
      'Clock': [
        'alarm',
        'timer',
        'stopwatch',
        'منبه',
        'مؤقت',
        'ساعة',
      ],
      'Calculator': [
        'calculator',
        'calculate',
        'calc',
        'حاسبة',
        'احسب',
      ],
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

    final openMatch = RegExp(r'^open\s+([a-zA-Z0-9 ]+)').firstMatch(lower);

    if (openMatch != null) {
      String app = openMatch.group(1)!.trim();

      if (app.isNotEmpty) {
        app = app[0].toUpperCase() + app.substring(1);

        return [
          ActionStep(action: 'open_app', params: {'app_name': app}),
        ];
      }
    }

    return null;
  }
}

class _AiActionResponse {
  final String action;
  final Map<String, dynamic> params;
  final String reasoning;
  final bool isComplete;
  final int totalTokens;

  const _AiActionResponse({
    required this.action,
    required this.params,
    required this.reasoning,
    required this.isComplete,
    required this.totalTokens,
  });
}

class _ExecutionResult {
  final bool success;
  final String message;

  const _ExecutionResult({
    required this.success,
    required this.message,
  });
}
