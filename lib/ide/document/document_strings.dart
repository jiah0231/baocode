import 'package:flutter/widgets.dart';

/// Preview controls use the app's locale, with English as the fallback.
class DocumentStrings {
  DocumentStrings(BuildContext context)
    : zh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';

  final bool zh;
  String get loading => zh ? '正在读取文档…' : 'Loading document…';
  String get readOnly => zh ? '只读 · 本地解析' : 'Read only · Offline';
  String get reload => zh ? '重新加载' : 'Reload';
  String get retry => zh ? '重试' : 'Try again';
  String get openExternal => zh ? '用系统应用打开' : 'Open in default app';
  String get original => zh ? '原始颜色' : 'Original colors';
  String get themed => zh ? '主题颜色' : 'Theme colors';
  String get layout => zh ? '幻灯片布局' : 'Slide layout';
  String get reading => zh ? '阅读排版' : 'Reading view';
  String get previous => zh ? '上一页' : 'Previous';
  String get next => zh ? '下一页' : 'Next';
  String get zoomIn => zh ? '放大' : 'Zoom in';
  String get zoomOut => zh ? '缩小' : 'Zoom out';
  String get fit => zh ? '适合宽度' : 'Fit width';
  String get empty => zh ? '此文档没有可预览的内容。' : 'No previewable content.';
  String get imageError => zh ? '此图片无法预览' : 'This image cannot be previewed';
  String get unavailable => zh ? '无法预览此文档' : 'Document preview unavailable';
  String get fidelity => zh
      ? '离线只读预览。复杂版式、图表、动画、批注和公式计算可能不完整，请用原应用核对。'
      : 'Offline read-only preview. Complex layouts, charts, animation, comments and formula calculation may be incomplete. Check the original app for exact rendering.';
  String get revision => zh
      ? '不能预览此文档的历史版本或二进制差异。请打开当前文件。'
      : 'Historical versions and binary changes cannot be previewed. Open the current file instead.';
  String get legacy => zh
      ? '旧版 Office 二进制格式暂不支持。请用系统应用打开，或另存为 DOCX、PPTX、XLSX 后预览。'
      : 'Legacy Office binaries are not supported. Open this file in its default app, or save a copy as DOCX, PPTX or XLSX.';
  String get readError => zh
      ? '无法读取文件。请检查文件是否存在、权限和远程连接，然后重试。'
      : 'The file could not be read. Check that it exists, its permissions and the remote connection, then try again.';
  String page(int current, int total) => '$current / $total';
  String sheetSize(int rows, int columns) => zh
      ? '$rows 行 × $columns 列 · 使用已保存的公式结果'
      : '$rows rows × $columns columns · Saved formula results';
  String parseError(String code, String fallback) {
    if (!zh) return fallback;
    return switch (code) {
      'legacy' => legacy,
      'tooLarge' => '文档超过安全预览限制（文件最多 32 MB；解压大小、图片、表格和文字也有限制）。请用系统应用打开。',
      'encrypted' => '不支持预览加密或密码保护的 Office 文档，请用原应用打开。',
      'empty' => '此文档为空。',
      'read' => readError,
      'unsupported' => '暂不支持预览此文档格式。',
      _ => '文档已损坏或包含不支持的结构，请用原应用检查。',
    };
  }

  String warning(String value) {
    if (!zh) return value;
    return switch (value) {
      'External links and linked resources are not loaded.' => '不会加载外部链接或链接资源。',
      'External or invalid resource paths were omitted.' => '已忽略外部或无效资源路径。',
      'Some embedded image formats are not supported.' => '部分嵌入图片格式暂不支持。',
      'Images inside Word tables are not shown.' => '暂不显示 Word 表格内的图片。',
      'Embedded HTML content is not rendered.' => '不会执行或渲染嵌入 HTML。',
      'Reading preview: pagination, floating objects, headers, footers and advanced Word layout may differ.' =>
        '阅读预览：分页、浮动对象、页眉页脚和复杂 Word 排版可能与原文不同。',
      'Slide preview: charts, SmartArt, master artwork, animations, effects and some fonts are not reproduced.' =>
        '幻灯片预览：暂不还原图表、SmartArt、母版图形、动画、特效和部分字体。',
      'Rotated or flipped slide objects use a simplified layout.' =>
        '旋转或翻转的幻灯片对象使用简化布局。',
      'Some slide graphics are not shown.' => '部分幻灯片图形暂不显示。',
      'Merged cells are shown at their original anchor cell.' =>
        '合并单元格内容显示在其起始单元格。',
      'Hidden worksheets are omitted from this preview.' => '此预览省略了隐藏工作表。',
      'Data preview: formulas are not recalculated; displayed cached values may be out of date.' =>
        '数据预览：不重新计算公式，显示的是文件中保存的结果，可能已过期。',
      'Charts, drawings, conditional formatting and advanced number formats are not reproduced.' =>
        '暂不还原图表、绘图、条件格式和复杂数字格式。',
      'Charts, drawings and cell formatting are not reproduced. Dates and numbers may appear as raw stored values.' =>
        '暂不还原图表、绘图和单元格格式。日期和数字可能显示为原始存储值。',
      _ => value,
    };
  }
}
