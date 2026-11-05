import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../ide_button.dart';

/// The source revision is embedded by tool/build_windows.dart in release builds.
abstract final class DocumentPreviewNotices {
  static const upstreamRevision = '43be834d892541d3fda51cab6e5496371331e341';
  static const sourceRevision = String.fromEnvironment(
    'BAOCODE_SOURCE_REVISION',
    defaultValue: 'fix/codex-parity-windows-20261101',
  );
  static final upstream = Uri.parse(
    'https://github.com/CrazyFigure/NoteBoard/tree/$upstreamRevision/plugins',
  );
  static final source = Uri.parse(
    'https://github.com/jiah0231/baocode/tree/$sourceRevision/tool/office_preview',
  );

  static Future<void> show(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final notices = rootBundle.loadString(
      'assets/office_preview/THIRD_PARTY_NOTICES.txt',
    );
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: zh ? '关闭' : 'Close',
      barrierColor: const Color(0x80000000),
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => Center(
        child: Container(
          width: 760,
          height: MediaQuery.sizeOf(context).height * .8,
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.partBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DefaultTextStyle(
            style: TextStyle(color: AppColors.text, fontSize: 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  zh ? 'NoteBoard 预览器与第三方许可' : 'NoteBoard viewer licenses',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: FutureBuilder<String>(
                    future: notices,
                    builder: (context, snapshot) => SingleChildScrollView(
                      child: SelectableText(
                        snapshot.data ??
                            (snapshot.hasError
                                ? (zh
                                      ? '无法读取打包的许可文件，请查看对应源码。'
                                      : 'The bundled notices could not be read. See the corresponding source.')
                                : (zh ? '正在读取…' : 'Loading…')),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: IdeButton(
                    label: zh ? '关闭' : 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
