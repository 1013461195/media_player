import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_video_play/main.dart';

void main() {
  testWidgets('shows server landing page', (WidgetTester tester) async {
    await tester.pumpWidget(const NasPlayerApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('影视服务器'), findsWidgets);
    expect(find.text('媒体库'), findsOneWidget);
    expect(find.text('文件源'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
