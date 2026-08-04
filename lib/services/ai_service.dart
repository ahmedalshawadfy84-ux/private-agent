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

  static const String _systemPrompt = '''
You are PrivateAgent operating in Pure Vision Mode. You control an Android device by analyzing screenshot images only.

CRITICAL RULES:
1. Analyze the screenshot visually to detect buttons, icons, text, and interactive elements.
2. Respond with ONLY a valid JSON object (no markdown, no extra text).
3. Perform one action at a time.
4. Always respond and explain your reasoning in the SAME LANGUAGE as the user's input (e.g., if user speaks Arabic, write reasoning in Arabic).
5. If the user input is a casual conversation, greeting (like "مرحبا" or "hello"), or a general question that DOES NOT require clicking or interacting with the screen, use the "chat" action.
6. Set "is_complete": true ONLY when the ENTIRE user goal is fully achieved or when replying to a casual chat/greeting.
7. NEVER set is_complete=true after just opening an app or after a single tap for multi-step tasks.

AVAILABLE ACTIONS:
- chat: {"message": "Your text response to the user"} - Use for general conversation, greetings, or answers not requiring screen interaction.
- click_at: {"x": 540, "y": 960} - Tap at exact screen coordinates
- type_text: {"text": "hello"} - Type into the focused text field
- press_enter: {} - Press Enter/Search key
- scroll: {"direction": "down"} - Scroll up or down
- swipe: {"startX": 540, "startY": 1800, "endX": 540, "endY": 600} - Swipe from start to end
- press_back: {} - Press Android back button
- press_home: {} - Press Home button
- open_app: {"app_name": "WhatsApp"} - Open an app by name
- wait: {} - Wait a moment for the screen to load
- done: {} - Use only when a multi-step device task is completely finished

JSON RESPONSE FORMAT (strict):
{
  "action": "action_name",
  "params": {},
  "reasoning": "Explanation in user's language",
  "is_complete": false
}
''';

  static const String _chatSystemPrompt = '''
You are PrivateAgent, a helpful conversational AI assistant. 
Provide direct, natural, and friendly responses in the same language used by the user. You cannot perform device actions or run tools in this mode.
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
    _useScreenCompression = prefs.getBool('api_use_screen_compression') ?? true;
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
      _baseUrl = baseUrl;
      await prefs.setString('api_base_url', baseUrl);
    }
    if (model != null && model.isNotEmpty) {
      _model = model;
      await prefs.setString('api_model', model);
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
    _conversationHistory.add({'role': role, 'content': content});
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }
  }

  Future<String> sendMessage(String message, {bool isAgentMode = true}) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('API Key is not configured. Please go to Settings.');
    }
    _conversationHistory.add({'role': 'user', 'content': message});
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }
    try {
      final systemPrompt = isAgentMode ? _systemPrompt : _chatSystemPrompt;
      final messages = [
        if (_useSystemPrompt) {'role': 'system', 'content': systemPrompt},
        ..._conversationHistory,
      ];
      String requestUrl = _baseUrl;
      if (!requestUrl.endsWith('/chat/completions')) {
        if (requestUrl.endsWith('/')) {
          requestUrl = '${requestUrl}chat/completions';
        } else {
          requestUrl = '$requestUrl/chat/completions';
        }
      }
      final requestBody = jsonEncode({
        'model': _model,
        'messages': messages,
        'temperature': _temperature,
        'max_tokens': _effectiveMaxTokens,
      });

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

      if (response.statusCode != 200) {
        String errorMessage = responseBody;
        try {
          final decoded = jsonDecode(responseBody);
          if (decoded is Map<String, dynamic>) {
            if (decoded['error'] is Map<String, dynamic>) {
              errorMessage = decoded['error']['message']?.toString() ?? responseBody;
            } else if (decoded['error'] is String) {
              errorMessage = decoded['error'];
            }
          }
        } catch (_) {}
        throw Exception('API error (${response.statusCode}): $errorMessage');
      }

      final data = jsonDecode(responseBody);
      if (data is! Map<String, dynamic> || !data.containsKey('choices')) {
        throw Exception('Unexpected API response format: $data');
      }
      String assistantMessage =
          data['choices'][0]['message']['content'] as String;
      assistantMessage = assistantMessage
          .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
          .trim();

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

  Stream<String> sendMessageStream(
    String message, {
    bool isAgentMode = true,
  }) async* {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('API Key is not configured. Please go to Settings.');
    }
    _conversationHistory.add({'role': 'user', 'content': message});
    if (_conversationHistory.length > 20) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 20);
    }
    try {
      final systemPrompt = isAgentMode ? _systemPrompt : _chatSystemPrompt;
      final messages = [
        if (_useSystemPrompt) {'role': 'system', 'content': systemPrompt},
        ..._conversationHistory,
      ];
      String requestUrl = _baseUrl;
      if (!requestUrl.endsWith('/chat/completions')) {
        if (requestUrl.endsWith('/')) {
          requestUrl = '${requestUrl}chat/completions';
        } else {
          requestUrl = '$requestUrl/chat/completions';
        }
      }
      final client = http.Client();
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

      final response = await client
          .send(request)
          .timeout(const Duration(minutes: 30));

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        client.close();
        throw Exception('API error (${response.statusCode}): $body');
      }

      final accumulatedContent = StringBuffer();
      bool inThinkBlock = false;
      final lineStream = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lineStream) {
        final trimmedLine = line.trim();
        if (trimmedLine.isEmpty) continue;
        if (trimmedLine.startsWith('data:')) {
          final dataStr = trimmedLine.substring(5).trim();
          if (dataStr == '[DONE]') break;
          try {
            final json = jsonDecode(dataStr);
            if (json is Map && json['choices'] is List) {
              final choices = json['choices'] as List;
              if (choices.isNotEmpty) {
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
                    if (parts[0].isNotEmpty) yield parts[0];
                  } else if (content.contains('</think>')) {
                    inThinkBlock = false;
                    final parts = content.split('</think>');
                    if (parts.length > 1 && parts[1].isNotEmpty) yield parts[1];
                  } else if (!inThinkBlock) {
                    yield content;
                  }
                }
                if (choice['finish_reason'] != null) break;
              }
            }
          } catch (_) {}
        }
      }
      client.close();
      String finalResponse = accumulatedContent.toString().trim();
      finalResponse = finalResponse
          .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
          .trim();
      if (finalResponse.isEmpty) {
        throw Exception('The model finished without a visible answer.');
      }
      _conversationHistory.add({'role': 'assistant', 'content': finalResponse});
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Network error: $e');
    }
  }

  Future<AiResponse> sendTaskMessage(String systemPrompt, String prompt, {String? base64Image}) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('API Key is not configured. Please go to Settings.');
    }
    int maxRetries = 4;
    int currentTry = 0;
    while (true) {
      try {
        currentTry++;
        dynamic userContent;
        if (base64Image != null && base64Image.isNotEmpty) {
          userContent = [
            {'type': 'text', 'text': prompt},
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/png;base64,$base64Image'
              }
            }
          ];
        } else {
          userContent = prompt;
        }
        final messages = [
          if (_useSystemPrompt) {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userContent},
        ];
        String requestUrl = _baseUrl;
        if (!requestUrl.endsWith('/chat/completions')) {
          if (requestUrl.endsWith('/')) {
            requestUrl = '${requestUrl}chat/completions';
          } else {
            requestUrl = '$requestUrl/chat/completions';
          }
        }
        final response = await http
            .post(
              Uri.parse(requestUrl),
              headers: {
                'Content-Type': 'application/json; charset=utf-8',
                'Authorization': 'Bearer $_apiKey',
                'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
                'X-Title': 'PrivateAgent',
              },
              body: jsonEncode({
                'model': _model,
                'messages': messages,
                'temperature': _temperature,
                'max_tokens': _effectiveMaxTokens,
              }),
            )
            .timeout(const Duration(minutes: 30));

        final responseBody = utf8.decode(response.bodyBytes);

        if (response.statusCode != 200) {
          String errorMessage = responseBody;
          try {
            final decoded = jsonDecode(responseBody);
            if (decoded is Map<String, dynamic>) {
              if (decoded['error'] is Map<String, dynamic>) {
                errorMessage = decoded['error']['message'] ?? responseBody;
              } else if (decoded['error'] is String) {
                errorMessage = decoded['error'];
              }
            }
          } catch (_) {}
          throw Exception('API error (${response.statusCode}): $errorMessage');
        }

        final data = jsonDecode(responseBody);
        if (data is! Map<String, dynamic> || !data.containsKey('choices')) {
          throw Exception('Unexpected API response format: $data');
        }
        String content = data['choices'][0]['message']['content'] as String;
        content = content
            .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
            .trim();

        if (content.trim().isEmpty) {
          throw Exception('API returned an empty response.');
        }
        int tokens = 0;
        if (data.containsKey('usage') && data['usage']['total_tokens'] != null) {
          tokens = data['usage']['total_tokens'] as int;
        }
        return AiResponse(content, tokens);
      } catch (e) {
        if (currentTry > maxRetries) {
          if (e is Exception) rethrow;
          throw Exception('Network error after $maxRetries retries: $e');
        }
        int delaySeconds = 3 * currentTry;
        developer.log(
          'API call failed ($e), retrying $currentTry/$maxRetries in $delaySeconds seconds...',
          name: 'PrivateAgent',
        );
        await Future.delayed(Duration(seconds: delaySeconds));
      }
    }
  }

  AgentAction? parseAction(String response) {
    try {
      final trimmed = response.trim();
      String jsonStr = trimmed;
      if (trimmed.startsWith('```')) {
        final lines = trimmed.split('\n');
        lines.removeAt(0);
        if (lines.isNotEmpty && lines.last.trim() == '```') {
          lines.removeLast();
        }
        jsonStr = lines.join('\n').trim();
      }
      if (jsonStr.startsWith('{') && !jsonStr.endsWith('}')) {
        jsonStr += '\n}';
      }
      if (jsonStr.startsWith('{') && jsonStr.contains('"action"')) {
        try {
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          if (json.containsKey('action')) {
            return AgentAction.fromJson(json);
          }
        } catch (e) {
          if (e.toString().contains('Unexpected end of input')) {
            jsonStr += '\n}';
            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            if (json.containsKey('action')) {
              return AgentAction.fromJson(json);
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<String>> fetchAvailableModels(
    String baseUrl,
    String apiKey,
  ) async {
    try {
      String cleanBaseUrl = baseUrl;
      if (cleanBaseUrl.endsWith('/chat/completions')) {
        cleanBaseUrl = cleanBaseUrl.replaceAll('/chat/completions', '');
      }
      final response = await http.get(
        Uri.parse('$cleanBaseUrl/models'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );
      if (response.statusCode == 200) {
        final responseBody = utf8.decode(response.bodyBytes);
        final data = jsonDecode(responseBody);
        List<String> models;
        if (data is Map && data.containsKey('data')) {
          final modelsList = data['data'] as List;
          models = modelsList.map((m) => m['id'].toString()).toList();
        } else if (data is List) {
          models = data.map((m) => m['id'].toString()).toList();
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
      print('Error fetching models: $e');
      return [];
    }
  }
}
