import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_ai_kit/flutter_ai_kit.dart';
import 'package:flutter_ai_kit_zhipu/flutter_ai_kit_zhipu.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Client extends Mock implements Dio {}

class _Task extends AITask<String, String> {
  @override
  String get taskType => 'chat';
  @override
  String get input => 'Analyze the supplied payment image.';
  @override
  Map<String, dynamic> toJson() => {'prompt': input};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(Options());
  late Directory directory;
  late _Client client;
  Map? payload;
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('beecount-media-integrity-');
    client = _Client();
    payload = null;
    when(() => client.post<dynamic>(any(),
        data: any(named: 'data'),
        options: any(named: 'options'))).thenAnswer((call) async {
      payload = call.namedArguments[#data] as Map;
      return Response<dynamic>(
          requestOptions: RequestOptions(path: '/synthetic'),
          data: {
            'choices': [
              {
                'message': {'content': '[]'}
              }
            ],
            'usage': {'total_tokens': 1}
          });
    });
  });
  tearDown(() async => directory.delete(recursive: true));
  for (final sample in [
    ('image/png', 'wrong.jpg', [137, 80, 78, 71, 13, 10, 26, 10]),
    ('image/jpeg', 'wrong.png', [255, 216, 255, 224]),
    ('image/webp', 'wrong.jpg', [82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80]),
    ('image/gif', 'wrong.png', [71, 73, 70, 56, 57, 97]),
  ]) {
    test('built-in vision declares encoded format ${sample.$1}', () async {
      final file =
          await File('${directory.path}/${sample.$2}').writeAsBytes(sample.$3);
      final provider = ZhipuGLMProvider(
          apiKey: 'synthetic', imageFile: file, client: client);
      expect((await provider.execute(_Task())).success, isTrue);
      final content = payload!['messages'][0]['content'] as List;
      final image =
          content.singleWhere((entry) => entry['type'] == 'image_url') as Map;
      expect(
          image['image_url']['url'], startsWith('data:${sample.$1};base64,'));
    });
  }
  for (final missing in [true, false]) {
    test(
        'missing/empty image never degrades into a prompt-only request: $missing',
        () async {
      final file = File('${directory.path}/missing-or-empty.png');
      if (!missing) await file.writeAsBytes([]);
      final provider = ZhipuGLMProvider(
          apiKey: 'synthetic', imageFile: file, client: client);
      expect((await provider.execute(_Task())).success, isFalse);
      expect(payload, isNull,
          reason:
              'Do not let the model extract prompt examples without the image');
    });
  }
  test('missing audio never degrades into a prompt-only request', () async {
    final provider = ZhipuGLMProvider(
        apiKey: 'synthetic',
        audioFile: File('${directory.path}/missing.wav'),
        client: client);
    expect((await provider.execute(_Task())).success, isFalse);
    expect(payload, isNull);
  });
}
