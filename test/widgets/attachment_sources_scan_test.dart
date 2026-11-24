import 'package:beecount_business_ui/beecount_business_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('scanner appears beside camera and gallery when supplied',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BeeAttachmentSources(
                cameraLabel: 'Camera',
                galleryLabel: 'Gallery',
                scanLabel: 'Scan document',
                onCamera: () {},
                onGallery: () {},
                onScan: () => calls++))));
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Scan document'), findsOneWidget);
    await tester.tap(find.text('Scan document'));
    expect(calls, 1);
  });
}
