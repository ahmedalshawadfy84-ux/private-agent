import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/agent_action.dart';

class AiResponse {
  final String content;
  final int totalTokens;

  AiResponse(this.content, this.totalTokens);
}

class AiService {
  static const String _defaultBaseUrl = 'https://api.deepseek.com';
  static const String _defaultModel = 'deepseek-chat';

  static const String nvidiaBaseUrl = 'https://integrate.api.nvidia.com/v1';
  static const String nvidiaDefaultModel = 'z-ai/glm-5.2';

  /// Free, general-purpose chat endpoints verified in NVIDIA's NIM catalog.
  static const List<String> nvidiaFreeChatModels = [
    'z-ai/glm-5.2',
    'nvidia/nemotron-3-nano-30b-a3b',
    'nvidia/nemotron-3-super-120b-a12b',
    'nvidia/nemotron-3-ultra-550b-a55b',
    'nvidia/nvidia-nemotron-nano-9b-v2',
    'openai/gpt-oss-20b',
    'openai/gpt-oss-120b',
    'meta/llama-3.3-70b-instruct',
    'meta/llama-3.2-3b-instruct',
    'meta/llama-3.1-8b-instruct',
    'meta/llama-3.1-70b-instruct',
    'mistralai/mistral-nemotron',
    'deepseek-ai/deepseek-v4-flash',
    'deepseek-ai/deepseek-v4-pro',
  ];

  static bool isNvidiaBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    return uri?.host.toLowerCase() == 'integrate.api.nvidia.com';
  }

  static List<String> filterNvidiaFreeModels(Iterable<String> models) {
    final availableModels = models.toSet();

    return nvidiaFreeChatModels
        .where(availableModels.contains)
        .toList(growable: false);
  }

  String? _apiKey;
  String _baseUrl = _defaultBaseUrl;
  String _model = _defaultModel;

  int _maxSteps = 15;
  bool _disableMaxSteps = false;

  double _temperature = 1.0;
  int _maxTokens = 1024;

  bool _useScreenCompression = true;
  bool _useSystemPrompt = true;

  final List<Map<String, String>> _conversationHistory = [];

  /// General assistant/router prompt.
  ///
  /// Important:
  /// This prompt must NOT be pure vision mode.
  /// Vision mode belongs inside TaskExecutor only.
  static const String _systemPrompt = '''
You are PrivateAgent, a helpful AI assistant that controls an Android phone. You can perform device actions and also have normal conversations.

When the user wants to perform a device action, you MUST respond with ONLY a JSON object, no markdown, no code fences, no extra text, in this exact format:

{
  "action": "action_name",
  "params": {"key": "value"},
  "response": "What you say to the user in the same language as the user"
}

Available actions and their params:

SIMPLE ACTIONS:

- open_app: {"app_name": "YouTube"} - ONLY use this when the user JUST wants to open an app and nothing else.
- make_call: {"contact_name": "Mom"} OR {"phone_number": "1234567890"} - Makes a phone call.
- send_sms: {"contact_name": "John", "message": "Hello"} OR {"phone_number": "123", "message": "Hi"} - Sends SMS.
- search_contact: {"query": "John"} - Searches contacts.
- set_alarm: {"hour": 7, "minute": 30, "label": "Wake up"} - Sets an alarm.
- set_volume: {"level": 50} - Sets volume from 0 to 100.
- set_brightness: {"level": 50} - Sets brightness from 0 to 100.
- read_screen: {} - Read what is currently on the screen.
- press_back: {} - Press Android back button.

MULTI-STEP TASK:

- execute_task: {"goal": "description of the full task"} - Use this for anything that requires more than one UI action. It automatically reads the screen, opens apps, taps, scrolls, types, and navigates step by step.

CRITICAL RULES:

1. If the user request contains multiple steps such as open + search, open + type, open + send, open + click, open + find, or any task using "and/then/ثم/و/واكتب/وابحث", you MUST use execute_task.
2. NEVER use open_app for a request like "Open YouTube and search for flowers". Use execute_task instead.
3. Games are also executed using execute_task. The TaskExecutor will choose visual game mode automatically.
4. For casual conversation, greetings, questions, explanations, writing help, or anything that does NOT require controlling the phone, respond with natural plain text, not JSON.
5. Always reply in the same language used by the user.

Examples:

User: "Open YouTube"
Assistant:
{
  "action": "open_app",
  "params": {"app_name": "YouTube"},
  "response": "Opening YouTube."
}

User: "افتح اليوتيوب وابحث عن الأزهار"
Assistant:
{
  "action": "execute_task",
  "params": {"goal": "افتح اليوتيوب وابحث عن الأزهار"},
  "response": "حسنًا، سأفتح يوتيوب وأبحث عن الأزهار."
}

User: "افتح لعبة Subway Surfers واضغط Start"
Assistant:
{
  "action": "execute_task",
  "params": {"goal": "افتح لعبة Subway Surfers واضغط Start"},
  "response": "حسنًا، سأفتح اللعبة وأضغط Start."
}

User: "مرحبا"
Assistant:
"مرحبًا! كيف يمكنني مساعدتك؟"
''';

  static const String _chatSystemPrompt = '''
You are PrivateAgent, a helpful conversational AI assistant.

Provide direct, natural, and friendly text responses.
You cannot perform device actions or run tools in this mode.

Always answer in the same language used by the user.
''';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    _apiKey = prefs.getString('api_key');
    _baseUrl = prefs.getString('api_base_url') ?? _defaultBaseUrl;
    _model = prefs.getString('api_model') ?? _defaultModel;

    _maxSteps = prefs.getInt('api_max_steps') ?? 15;
    _disableMaxSteps = prefs.getBool('api_disable_max_steps') ?? false;

    _temperature = prefs.getDouble('api_temperature') ?? 1.0;
    _maxTokens = prefs.getInt('api_max_tokens') ?? 1024;

    _useScreenCompression =
        prefs.getBool('api_use_screen_compression') ?? true;
    _useSystemPrompt = prefs.getBool('api_use_system_prompt') ?? true;
  }

  Future<void> saveSettings({
    required String apiKey,
    String? baseUrl,
    String? model,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    String cleanApiKey = apiKey.trim();

    if (cleanApiKey.toLowerCase().startsWith('bearer ')) {
      cleanApiKey = cleanApiKey.substring(7).trim();
    }

    _apiKey = cleanApiKey;
    await prefs.setString('api_key', cleanApiKey);

    if (baseUrl != null && baseUrl.isNotEmpty) {
      _baseUrl = baseUrl.trim();
      await prefs.setString('api_base_url', _baseUrl);
    }

    if (model != null && model.isNotEmpty) {
      _model = model.trim();
      await prefs.setString('api_model', _model);
    }
  }

  Future<void> saveMaxSteps(int steps) async {
    final prefs = await SharedPreferences.getInstance();

    _maxSteps = steps;
    await prefs.setInt('api_max_steps', steps);
  }

  Future<void> saveDisableMaxSteps(bool disable) async {
    final prefs = await SharedPreferences.getInstance();

    _disableMaxSteps = disable;
    await prefs.setBool('api_disable_max_steps', disable);
  }

  Future<void> saveAdvancedSettings({
    required double temperature,
    required int maxTokens,
    required bool useScreenCompression,
    required bool useSystemPrompt,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    _temperature = temperature;
    _maxTokens = maxTokens;
    _useScreenCompression = useScreenCompression;
    _useSystemPrompt = useSystemPrompt;

    await prefs.setDouble('api_temperature', temperature);
    await prefs.setInt('api_max_tokens', maxTokens);
    await prefs.setBool('api_use_screen_compression', useScreenCompression);
    await prefs.setBool('api_use_system_prompt', useSystemPrompt);
  }

  bool get isConfigured => _apiKey != null && _apiKey!.isNotEmpty;

  String get baseUrl => _baseUrl;
  String get model => _model;
  String get apiKey => _apiKey ?? '';

  int get maxSteps => _disableMaxSteps ? 999 : _maxSteps;
  int get rawMaxSteps => _maxSteps;
  bool get disableMaxSteps => _disableMaxSteps;

  double get temperature => _temperature;
  int get maxTokens => _maxTokens;

  bool get useScreenCompression => _useScreenCompression;
  bool get useSystemPrompt => _useSystemPrompt;

  int get _effectiveMaxTokens {
    /// GLM is a reasoning model. With 1024 tokens it may spend all budget
    /// reasoning and return no visible answer.
    if (isNvidiaBaseUrl(_baseUrl) &&
        _model == nvidiaDefaultModel &&
        _maxTokens < 4096) {
      return 4096;
    }

    return _maxTokens;
  }

  void clearHistory() {
    _conversationHistory.clear();
  }

  void addHistoryMessage(String role, String content) {
    _conversationHistory.add({
      'role': role,
      'content': content,
    });

    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }
  }

  String _buildChatCompletionsUrl([String? customBaseUrl]) {
    String requestUrl = (customBaseUrl ?? _baseUrl).trim();

    if (!requestUrl.endsWith('/chat/completions')) {
      if (requestUrl.endsWith('/')) {
        requestUrl = '${requestUrl}chat/completions';
      } else {
        requestUrl = '$requestUrl/chat/completions';
      }
    }

    return requestUrl;
  }

  String _stripThinkBlocks(String text) {
    return text
        .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
        .trim();
  }

  String _decodeApiError(String responseBody) {
    String errorMessage = responseBody;

    try {
      final decoded = jsonDecode(responseBody);

      if (decoded is Map<String, dynamic>) {
        if (decoded['error'] is Map<String, dynamic>) {
          errorMessage =
              decoded['error']['message']?.toString() ?? responseBody;
        } else if (decoded['error'] is String) {
          errorMessage = decoded['error'];
        }
      }
    } catch (_) {}

    return errorMessage;
  }

  String _toImageDataUrl(String base64Image) {
    final trimmed = base64Image.trim();

    if (trimmed.startsWith('data:image/')) {
      return trimmed;
    }

    return 'data:image/png;base64,$trimmed';
  }

  /// Send a message to the AI and get a full response.
  ///
  /// Used for:
  /// - normal chat
  /// - deciding whether to call execute_task/open_app/etc.
  Future<String> sendMessage(
    String message, {
    bool isAgentMode = true,
  }) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('API Key is not configured. Please go to Settings.');
    }

    _conversationHistory.add({
      'role': 'user',
      'content': message,
    });

    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }

    try {
      final systemPrompt = isAgentMode ? _systemPrompt : _chatSystemPrompt;

      final messages = <Map<String, dynamic>>[
        if (_useSystemPrompt)
          {
            'role': 'system',
            'content': systemPrompt,
          },
        ..._conversationHistory.map((m) => Map<String, dynamic>.from(m)),
      ];

      final requestUrl = _buildChatCompletionsUrl();

      final requestBody = jsonEncode({
        'model': _model,
        'messages': messages,
        'temperature': _temperature,
        'max_tokens': _effectiveMaxTokens,
      });

      developer.log(
        'API Request: $requestUrl\n$requestBody',
        name: 'AiService',
      );

      final response = await http
          .post(
            Uri.parse(requestUrl),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $_apiKey',
              'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
              'X-Title': 'PrivateAgent',
            },
            body: requestBody,
          )
          .timeout(const Duration(minutes: 30));

      final responseBody = utf8.decode(response.bodyBytes);

      developer.log(
        'API Response [${response.statusCode}]: $responseBody',
        name: 'AiService',
      );

      if (response.statusCode != 200) {
        throw Exception(
          'API error (${response.statusCode}): ${_decodeApiError(responseBody)}',
        );
      }

      final data = jsonDecode(responseBody);

      if (data is! Map<String, dynamic> || !data.containsKey('choices')) {
        throw Exception('Unexpected API response format: $data');
      }

      String assistantMessage =
          data['choices'][0]['message']['content'] as String;

      assistantMessage = _stripThinkBlocks(assistantMessage);

      if (assistantMessage.trim().isEmpty) {
        throw Exception('API returned an empty response.');
      }

      _conversationHistory.add({
        'role': 'assistant',
        'content': assistantMessage,
      });

      return assistantMessage;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Network error: $e');
    }
  }

  /// Send a message and stream the response chunk by chunk.
  Stream<String> sendMessageStream(
    String message, {
    bool isAgentMode = true,
  }) async* {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('API Key is not configured. Please go to Settings.');
    }

    _conversationHistory.add({
      'role': 'user',
      'content': message,
    });

    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }

    final client = http.Client();

    try {
      final systemPrompt = isAgentMode ? _systemPrompt : _chatSystemPrompt;

      final messages = <Map<String, dynamic>>[
        if (_useSystemPrompt)
          {
            'role': 'system',
            'content': systemPrompt,
          },
        ..._conversationHistory.map((m) => Map<String, dynamic>.from(m)),
      ];

      final requestUrl = _buildChatCompletionsUrl();

      final request = http.Request('POST', Uri.parse(requestUrl));

      request.headers.addAll({
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'Bearer $_apiKey',
        'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
        'X-Title': 'PrivateAgent',
      });

      request.body = jsonEncode({
        'model': _model,
        'messages': messages,
        'temperature': _temperature,
        'max_tokens': _effectiveMaxTokens,
        'stream': true,
      });

      final response =
          await client.send(request).timeout(const Duration(minutes: 30));

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();

        throw Exception(
          'API error (${response.statusCode}): ${_decodeApiError(body)}',
        );
      }

      final accumulatedContent = StringBuffer();
      bool inThinkBlock = false;

      final lineStream =
          response.stream.transform(utf8.decoder).transform(const LineSplitter());

      await for (final line in lineStream) {
        final trimmedLine = line.trim();

        if (trimmedLine.isEmpty) continue;

        if (!trimmedLine.startsWith('data:')) continue;

        final dataStr = trimmedLine.substring(5).trim();

        if (dataStr == '[DONE]') break;

        try {
          final decodedChunk = jsonDecode(dataStr);

          if (decodedChunk is Map && decodedChunk['choices'] is List) {
            final choices = decodedChunk['choices'] as List;

            if (choices.isEmpty) continue;

            final choice = choices[0];

            if (choice is! Map) continue;

            final rawDelta = choice['delta'];
            final delta = rawDelta is Map ? rawDelta : const {};

            final rawContent = delta['content'];

            if (rawContent is String && rawContent.isNotEmpty) {
              final content = rawContent;

              accumulatedContent.write(content);

              if (content.contains('<think>')) {
                inThinkBlock = true;

                final parts = content.split('<think>');

                if (parts[0].isNotEmpty) {
                  yield parts[0];
                }
              } else if (content.contains('</think>')) {
                inThinkBlock = false;

                final parts = content.split('</think>');

                if (parts.length > 1 && parts[1].isNotEmpty) {
                  yield parts[1];
                }
              } else if (!inThinkBlock) {
                yield content;
              }
            }

            if (choice['finish_reason'] != null) {
              break;
            }
          }
        } catch (_) {
          /// Ignore malformed/incomplete streaming chunks.
        }
      }

      String finalResponse = accumulatedContent.toString().trim();
      finalResponse = _stripThinkBlocks(finalResponse);

      if (finalResponse.isEmpty) {
        throw Exception(
          'The model finished without a visible answer. Increase Max Tokens or try another model.',
        );
      }

      _conversationHistory.add({
        'role': 'assistant',
        'content': finalResponse,
      });
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Network error: $e');
    } finally {
      client.close();
    }
  }

  /// Send a task execution message.
  ///
  /// This is used by TaskExecutor.
  ///
  /// Text mode:
  /// sendTaskMessage(systemPrompt, prompt)
  ///
  /// Visual game mode:
  /// sendTaskMessage(systemPrompt, prompt, base64Image: image)
  Future<AiResponse> sendTaskMessage(
    String systemPrompt,
    String prompt, {
    String? base64Image,
  }) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('API Key is not configured. Please go to Settings.');
    }

    int maxRetries = 4;
    int currentTry = 0;

    while (true) {
      try {
        currentTry++;

        dynamic userContent;

        if (base64Image != null && base64Image.trim().isNotEmpty) {
          userContent = [
            {
              'type': 'text',
              'text': prompt,
            },
            {
              'type': 'image_url',
              'image_url': {
                'url': _toImageDataUrl(base64Image),
              },
            },
          ];
        } else {
          userContent = prompt;
        }

        final messages = <Map<String, dynamic>>[
          if (_useSystemPrompt)
            {
              'role': 'system',
              'content': systemPrompt,
            },
          {
            'role': 'user',
            'content': userContent,
          },
        ];

        final requestUrl = _buildChatCompletionsUrl();

        final requestBody = jsonEncode({
          'model': _model,
          'messages': messages,
          'temperature': _temperature,
          'max_tokens': _effectiveMaxTokens,
        });

        developer.log(
          'Task API Request: $requestUrl\n$requestBody',
          name: 'AiService',
        );

        final response = await http
            .post(
              Uri.parse(requestUrl),
              headers: {
                'Content-Type': 'application/json; charset=utf-8',
                'Authorization': 'Bearer $_apiKey',
                'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
                'X-Title': 'PrivateAgent',
              },
              body: requestBody,
            )
            .timeout(const Duration(minutes: 30));

        final responseBody = utf8.decode(response.bodyBytes);

        developer.log(
          'Task API Response [${response.statusCode}]: $responseBody',
          name: 'AiService',
        );

        if (response.statusCode != 200) {
          throw Exception(
            'API error (${response.statusCode}): ${_decodeApiError(responseBody)}',
          );
        }

        final data = jsonDecode(responseBody);

        if (data is! Map<String, dynamic> || !data.containsKey('choices')) {
          throw Exception('Unexpected API response format: $data');
        }

        String content = data['choices'][0]['message']['content'] as String;
        content = _stripThinkBlocks(content);

        if (content.trim().isEmpty) {
          throw Exception('API returned an empty response.');
        }

        int tokens = 0;

        if (data.containsKey('usage') && data['usage'] is Map) {
          final usage = data['usage'] as Map;

          if (usage['total_tokens'] is int) {
            tokens = usage['total_tokens'] as int;
          }
        }

        return AiResponse(content, tokens);
      } catch (e) {
        if (currentTry > maxRetries) {
          if (e is Exception) rethrow;
          throw Exception('Network error after $maxRetries retries: $e');
        }

        final delaySeconds = 3 * currentTry;

        developer.log(
          'Task API call failed ($e), retrying $currentTry/$maxRetries in $delaySeconds seconds...',
          name: 'PrivateAgent',
        );

        await Future.delayed(Duration(seconds: delaySeconds));
      }
    }
  }

  String _extractJson(String response) {
    final trimmed = response.trim();

    final codeBlockRegex = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
    final match = codeBlockRegex.firstMatch(trimmed);

    if (match != null) {
      return match.group(1)!;
    }

    final startIndex = trimmed.indexOf('{');
    final endIndex = trimmed.lastIndexOf('}');

    if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
      return trimmed.substring(startIndex, endIndex + 1);
    }

    return trimmed;
  }

  /// Parse the AI response to check if it is an action or plain text.
  AgentAction? parseAction(String response) {
    try {
      String jsonStr = _extractJson(response);

      if (jsonStr.startsWith('{') && !jsonStr.endsWith('}')) {
        jsonStr += '\n}';
      }

      if (jsonStr.startsWith('{') && jsonStr.contains('"action"')) {
        try {
          final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

          if (decoded.containsKey('action')) {
            return AgentAction.fromJson(decoded);
          }
        } catch (e) {
          if (e.toString().contains('Unexpected end of input')) {
            jsonStr += '\n}';

            final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

            if (decoded.containsKey('action')) {
              return AgentAction.fromJson(decoded);
            }
          }
        }
      }
    } catch (_) {
      /// Not JSON. It is probably a normal chat response.
    }

    return null;
  }

  /// Fetches available models from the provider's /models endpoint.
  Future<List<String>> fetchAvailableModels(
    String baseUrl,
    String apiKey,
  ) async {
    try {
      String cleanBaseUrl = baseUrl.trim();

      if (cleanBaseUrl.endsWith('/chat/completions')) {
        cleanBaseUrl = cleanBaseUrl.replaceAll('/chat/completions', '');
      }

      final response = await http.get(
        Uri.parse('$cleanBaseUrl/models'),
        headers: {
          'Authorization': 'Bearer $apiKey',
        },
      );

      if (response.statusCode == 200) {
        final responseBody = utf8.decode(response.bodyBytes);
        final data = jsonDecode(responseBody);

        List<String> models;

        if (data is Map && data.containsKey('data')) {
          final modelsList = data['data'] as List;

          models = modelsList
              .map((m) {
                if (m is Map && m['id'] != null) {
                  return m['id'].toString();
                }

                return '';
              })
              .where((id) => id.isNotEmpty)
              .toList();
        } else if (data is List) {
          models = data
              .map((m) {
                if (m is Map && m['id'] != null) {
                  return m['id'].toString();
                }

                return '';
              })
              .where((id) => id.isNotEmpty)
              .toList();
        } else {
          return [];
        }

        if (isNvidiaBaseUrl(cleanBaseUrl)) {
          return filterNvidiaFreeModels(models);
        }

        models.sort();
        return models;
      }

      return [];
    } catch (e) {
      developer.log(
        'Error fetching models: $e',
        name: 'AiService',
      );

      return [];
    }
  }
}
