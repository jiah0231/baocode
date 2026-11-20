import 'package:baocode/chat/widgets/preview_click.dart';
import 'package:baocode/chat/widgets/step_header.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('preview presses and selection do not toggle the fold', (
    tester,
  ) async {
    var toggles = 0;
    var previews = 0;
    const previewKey = Key('preview');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StepHeader(
              verb: 'Details',
              onToggle: () => toggles++,
              trailing: PreviewClick(
                onOpen: () => previews++,
                child: const SizedBox(
                  key: previewKey,
                  width: 24,
                  height: 16,
                  child: ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final header = find.text('Details');
    final preview = find.byKey(previewKey);
    await tester.tapAt(tester.getCenter(header), kind: PointerDeviceKind.mouse);
    expect(toggles, 1);

    await tester.tapAt(tester.getCenter(preview), kind: PointerDeviceKind.mouse);
    expect(previews, 1);
    expect(toggles, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    try {
      await tester.tapAt(tester.getCenter(header), kind: PointerDeviceKind.mouse);
      await tester.tapAt(tester.getCenter(preview), kind: PointerDeviceKind.mouse);
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.dragFrom(
      tester.getCenter(header),
      const Offset(30, 0),
      kind: PointerDeviceKind.mouse,
    );
    expect(toggles, 1);
    expect(previews, 1);
  });
}
