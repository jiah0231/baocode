import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../ide_hover.dart';
import 'document_model.dart';
import 'document_strings.dart';

Color _paper(bool original) => original ? Colors.white : AppColors.surface;
Color _ink(bool original) =>
    original ? const Color(0xff202020) : AppColors.text;

/// Flow content stays lazy even when a Word file contains many paragraphs.
class DocumentFlowView extends StatelessWidget {
  const DocumentFlowView({
    super.key,
    required this.sections,
    required this.zoom,
    required this.originalColors,
  });
  final List<DocumentSection> sections;
  final double zoom;
  final bool originalColors;

  @override
  Widget build(BuildContext context) {
    final ends = <int>[];
    var count = 0;
    for (final section in sections) {
      count += section.blocks.length + 1;
      ends.add(count);
    }
    return ListView.builder(
      key: PageStorageKey(('document-flow', key)),
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: count,
      itemBuilder: (context, index) {
        var sectionIndex = 0;
        while (index >= ends[sectionIndex]) {
          sectionIndex++;
        }
        final start = sectionIndex == 0 ? 0 : ends[sectionIndex - 1];
        final blockIndex = index - start - 1;
        final section = sections[sectionIndex];
        return Center(
          child: Container(
            width: 860 * zoom,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: EdgeInsets.fromLTRB(24, blockIndex < 0 ? 24 : 0, 24, 12),
            color: _paper(originalColors),
            child: blockIndex < 0
                ? Text(
                    section.title,
                    style: TextStyle(
                      color: _ink(originalColors),
                      fontSize: 18 * zoom,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : DocumentBlockView(
                    block: section.blocks[blockIndex],
                    zoom: zoom,
                    originalColors: originalColors,
                  ),
          ),
        );
      },
    );
  }
}

class DocumentSectionView extends StatelessWidget {
  const DocumentSectionView({
    super.key,
    required this.section,
    required this.zoom,
    required this.originalColors,
    required this.slideLayout,
  });
  final DocumentSection section;
  final double zoom;
  final bool originalColors;
  final bool slideLayout;

  @override
  Widget build(BuildContext context) {
    if (!slideLayout || section.elements.isEmpty) {
      return DocumentFlowView(
        sections: [section],
        zoom: zoom,
        originalColors: originalColors,
      );
    }
    final width = section.slideWidth ?? 960;
    final height = section.slideHeight ?? 540;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = math.min(
          math.max(1, constraints.maxWidth - 32) / width,
          math.max(1, constraints.maxHeight - 32) / height,
        );
        final scale = fit * zoom;
        return SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: math.max(constraints.maxWidth, width * scale + 32),
              height: math.max(constraints.maxHeight, height * scale + 32),
              child: Center(
                child: SizedBox(
                  width: width * scale,
                  height: height * scale,
                  child: FittedBox(
                    fit: BoxFit.fill,
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: ColoredBox(
                        color: originalColors && section.backgroundColor != null
                            ? Color(section.backgroundColor!)
                            : _paper(originalColors),
                        child: ClipRect(
                          child: Stack(
                            children: [
                              for (final element in section.elements)
                                Positioned(
                                  left: element.x,
                                  top: element.y,
                                  width: element.width,
                                  height: element.height,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color:
                                          originalColors &&
                                              element.fillColor != null
                                          ? Color(element.fillColor!)
                                          : null,
                                      border: element.borderColor == null
                                          ? null
                                          : Border.all(
                                              color: originalColors
                                                  ? Color(element.borderColor!)
                                                  : AppColors.partBorder,
                                            ),
                                    ),
                                    child: ClipRect(
                                      child: DocumentBlockView(
                                        block: element.block,
                                        zoom: 1,
                                        originalColors: originalColors,
                                        positioned: true,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class DocumentBlockView extends StatelessWidget {
  const DocumentBlockView({
    super.key,
    required this.block,
    required this.zoom,
    required this.originalColors,
    this.positioned = false,
  });
  final DocumentBlock block;
  final double zoom;
  final bool originalColors;
  final bool positioned;

  @override
  Widget build(BuildContext context) {
    switch (block) {
      case DocumentParagraph(
        :final runs,
        :final alignment,
        :final headingLevel,
      ):
        final fontSize = headingLevel == null
            ? 14.0
            : (26.0 - headingLevel * 2).clamp(15.0, 26.0).toDouble();
        return SelectableText.rich(
          TextSpan(
            children: [
              for (final run in runs)
                TextSpan(
                  text: run.text,
                  style: TextStyle(
                    color: originalColors && run.color != null
                        ? Color(run.color!)
                        : _ink(originalColors),
                    fontWeight: run.bold || headingLevel != null
                        ? FontWeight.w600
                        : FontWeight.normal,
                    fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
                    decoration: run.underline
                        ? TextDecoration.underline
                        : TextDecoration.none,
                    fontSize:
                        (run.fontSize ?? fontSize)
                            .clamp(6.0, 144.0)
                            .toDouble() *
                        zoom,
                  ),
                ),
            ],
          ),
          textAlign: switch (alignment) {
            'center' => TextAlign.center,
            'right' || 'end' => TextAlign.right,
            'both' || 'justify' => TextAlign.justify,
            _ => TextAlign.left,
          },
          style: TextStyle(
            color: _ink(originalColors),
            fontSize: fontSize * zoom,
            height: positioned ? 1.15 : 1.55,
          ),
        );
      case DocumentImage(
        :final bytes,
        :final name,
        :final width,
        :final height,
      ):
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: positioned ? double.infinity : 640 * zoom,
          ),
          child: Image.memory(
            bytes,
            width: positioned
                ? double.infinity
                : width == null
                ? null
                : width * zoom,
            height: positioned
                ? double.infinity
                : height == null
                ? null
                : height * zoom,
            fit: BoxFit.contain,
            // Decode a bounded thumbnail; parsing also rejects excessive pixel dimensions.
            cacheWidth: 1600,
            semanticLabel: name,
            errorBuilder: (context, error, stack) => Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                DocumentStrings(context).imageError,
                style: TextStyle(color: _ink(originalColors)),
              ),
            ),
          ),
        );
      case DocumentTable(:final rows):
        if (rows.isEmpty) return const SizedBox.shrink();
        final columns = rows.fold<int>(
          0,
          (count, row) => math.max(count, row.length),
        );
        final table = DocumentSheet(
          name: '',
          rowCount: rows.length,
          columnCount: columns,
          rows: {
            for (var r = 0; r < rows.length; r++)
              r: {
                for (var c = 0; c < rows[r].length; c++)
                  c: DocumentCell(text: rows[r][c]),
              },
          },
        );
        return SizedBox(
          height: positioned
              ? null
              : math.min(420 * zoom, (rows.length + 1) * 38 * zoom),
          child: DocumentSheetView(
            sheet: table,
            zoom: zoom,
            originalColors: originalColors,
            showStatus: false,
          ),
        );
    }
  }
}

/// Both axes are virtualized. Spreadsheet dimensions do not create a dense
/// matrix, or thousands of offscreen cell widgets, for sparse workbooks.
class DocumentSheetView extends StatefulWidget {
  const DocumentSheetView({
    super.key,
    required this.sheet,
    required this.zoom,
    this.originalColors = false,
    this.showStatus = true,
  });
  final DocumentSheet sheet;
  final double zoom;
  final bool originalColors;
  final bool showStatus;

  @override
  State<DocumentSheetView> createState() => _DocumentSheetViewState();
}

class _DocumentSheetViewState extends State<DocumentSheetView> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  String _columnName(int index) {
    var number = index + 1;
    var name = '';
    while (number > 0) {
      number--;
      name = String.fromCharCode(65 + number % 26) + name;
      number ~/= 26;
    }
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet;
    if (sheet.rowCount == 0 || sheet.columnCount == 0) {
      return Center(child: Text(DocumentStrings(context).empty));
    }
    final cellWidth = 160.0 * widget.zoom;
    final rowHeight = 34.0 * widget.zoom;
    final indexWidth = 54.0 * widget.zoom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = math.max(
                constraints.maxWidth,
                indexWidth + sheet.columnCount * cellWidth,
              );
              return Scrollbar(
                controller: _horizontal,
                thumbVisibility: true,
                notificationPredicate: (notification) =>
                    notification.metrics.axis == Axis.horizontal,
                child: SingleChildScrollView(
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: totalWidth,
                    height: constraints.maxHeight,
                    child: AnimatedBuilder(
                      animation: _horizontal,
                      builder: (context, child) {
                        final offset = _horizontal.hasClients
                            ? _horizontal.offset
                            : 0.0;
                        final first = ((offset - indexWidth) / cellWidth)
                            .floor()
                            .clamp(0, sheet.columnCount - 1);
                        final last =
                            ((offset + constraints.maxWidth) / cellWidth)
                                .ceil()
                                .clamp(first + 1, sheet.columnCount);
                        Widget row(int index) => SizedBox(
                          height: rowHeight,
                          child: Stack(
                            children: [
                              Positioned(
                                left: 0,
                                width: indexWidth,
                                top: 0,
                                bottom: 0,
                                child: _cell(
                                  index < 0 ? '' : '${index + 1}',
                                  header: true,
                                ),
                              ),
                              for (var column = first; column < last; column++)
                                Positioned(
                                  left: indexWidth + column * cellWidth,
                                  width: cellWidth,
                                  top: 0,
                                  bottom: 0,
                                  child: _cell(
                                    index < 0
                                        ? _columnName(column)
                                        : sheet.cellAt(index, column)?.text ??
                                              '',
                                    header: index < 0,
                                    formula: index < 0
                                        ? null
                                        : sheet.cellAt(index, column)?.formula,
                                  ),
                                ),
                            ],
                          ),
                        );
                        return Column(
                          children: [
                            row(-1),
                            Expanded(
                              child: ListView.builder(
                                controller: _vertical,
                                itemExtent: rowHeight,
                                itemCount: sheet.rowCount,
                                itemBuilder: (context, index) => row(index),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (widget.showStatus)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: Text(
              DocumentStrings(context)
                  .sheetSize(sheet.rowCount, sheet.columnCount),
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _cell(String text, {bool header = false, String? formula}) {
    // A single very long value must not shape megabytes of offscreen text.
    final displayed = text.length <= 4096
        ? text
        : '${text.substring(0, 4096)}…';
    final shownFormula = formula == null || formula.length <= 4096
        ? formula
        : '${formula.substring(0, 4096)}…';
    final content = Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: header ? AppColors.hover : _paper(widget.originalColors),
        border: Border(
          right: BorderSide(color: AppColors.partBorder),
          bottom: BorderSide(color: AppColors.partBorder),
        ),
      ),
      child: header
          ? Text(
              displayed,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12 * widget.zoom,
              ),
            )
          : SelectableText(
              displayed,
              maxLines: 1,
              style: TextStyle(
                color: _ink(widget.originalColors),
                fontSize: 12 * widget.zoom,
              ),
            ),
    );
    return IdeHover(
      message: shownFormula == null ? displayed : '$displayed\n=$shownFormula',
      child: content,
    );
  }
}
