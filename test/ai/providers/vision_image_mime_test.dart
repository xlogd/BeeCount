import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:beecount/ai/core/ai_extraction_context.dart';
import 'package:beecount/ai/core/ai_extraction_engine.dart';
import 'package:beecount/ai/providers/ai_provider_config.dart';
import 'package:beecount/ai/providers/ai_provider_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('PNG crop encoded under a .jpg filename is sent as image/png', () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('beecount-vision-mime-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? transmittedUrl;
    try {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawPaint(ui.Paint()..color = const ui.Color(0xff123456));
      final picture = recorder.endRecording();
      final image = await picture.toImage(2, 2);
      final encoded = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final bytes = encoded.buffer
          .asUint8List(encoded.offsetInBytes, encoded.lengthInBytes);
      image.dispose();
      picture.dispose();
      final file = await File('${directory.path}/crop-with-wrong-extension.jpg')
          .writeAsBytes(bytes);
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        transmittedUrl =
            body['messages'][0]['content'][1]['image_url']['url'] as String;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': '[]'}
            }
          ]
        }));
        await request.response.close();
      });
      final provider = await AIProviderManager.addProvider(
          name: 'Local MIME test',
          apiKey: 'synthetic',
          baseUrl: 'http://127.0.0.1:${server.port}',
          visionModel: 'synthetic');
      await AIProviderManager.setCapabilityProvider(
          AICapabilityType.vision, provider.id);
      final bills = await HttpOverrides.runWithHttpOverrides(
          () => const DefaultAiExtractionEngine()
              .extractFromImage(file, AiExtractionContext.fallback),
          _RealHttp());
      expect(bills, isEmpty);
      expect(transmittedUrl, startsWith('data:image/png;base64,'));
      expect(base64Decode(transmittedUrl!.split(',').last), bytes);
    } finally {
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
}
