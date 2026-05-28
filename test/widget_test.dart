import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_video_play/main.dart';

void main() {
  testWidgets('shows NAS connection form', (WidgetTester tester) async {
    await tester.pumpWidget(const NasPlayerApp());

    expect(find.text('连接 NAS'), findsOneWidget);
    expect(find.text('NAS 地址'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
  });
}
