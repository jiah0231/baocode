import 'dart:convert';
import 'dart:typed_data';

import '../extensions/vsix/zip_writer.dart';

/// Small, deterministic OOXML packages. No Office installation or user files.
Uint8List documentZip(Map<String, String> files, {bool deflate = true}) =>
    buildZip({
      for (final MapEntry(:key, :value) in files.entries)
        key: utf8.encode(value),
    }, deflate: deflate);

const _types = 'http://schemas.openxmlformats.org/package/2006/content-types';
const _rels = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _office =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _word = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _drawing = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _presentation =
    'http://schemas.openxmlformats.org/presentationml/2006/main';
const _sheet = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';

String _xml(String text) => const HtmlEscape().convert(text);

String _contentTypes(String overrides) =>
    '<Types xmlns="$_types">'
    '<Default Extension="rels" '
    'ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '$overrides</Types>';

String _rootRelationships(String target) =>
    '<Relationships xmlns="$_rels">'
    '<Relationship Id="rId1" Type="$_office/officeDocument" '
    'Target="$target"/></Relationships>';

Uint8List wordDocument({
  String title = 'BaoCode 文档',
  String text = 'Hello 世界 & friends',
  String? body,
  Map<String, String> extraEntries = const {},
  bool deflate = true,
}) => documentZip({
  '[Content_Types].xml': _contentTypes(
    '<Override PartName="/word/document.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.'
    'wordprocessingml.document.main+xml"/>',
  ),
  '_rels/.rels': _rootRelationships('word/document.xml'),
  'word/document.xml':
      '<w:document xmlns:w="$_word" xmlns:r="$_office"><w:body>'
      '${body ?? '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
              '<w:r><w:t>${_xml(title)}</w:t></w:r></w:p>'
              '<w:p><w:r><w:t>${_xml(text)}</w:t></w:r></w:p>'
              '<w:tbl><w:tr>'
              '<w:tc><w:p><w:r><w:t>Item</w:t></w:r></w:p></w:tc>'
              '<w:tc><w:p><w:r><w:t>Count</w:t></w:r></w:p></w:tc>'
              '</w:tr><w:tr>'
              '<w:tc><w:p><w:r><w:t>Apples</w:t></w:r></w:p></w:tc>'
              '<w:tc><w:p><w:r><w:t>3</w:t></w:r></w:p></w:tc>'
              '</w:tr></w:tbl>'}'
      '<w:sectPr/></w:body></w:document>',
  ...extraEntries,
}, deflate: deflate);

/// Presentation order deliberately differs from filenames and ZIP entry order.
Uint8List slideDocument({
  String first = 'First slide 第一页',
  String second = 'Second slide 第二页',
  bool deflate = true,
}) => documentZip({
  '[Content_Types].xml': _contentTypes(
    '<Override PartName="/ppt/presentation.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.'
    'presentationml.presentation.main+xml"/>'
    '<Override PartName="/ppt/slides/slide7.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.'
    'presentationml.slide+xml"/>'
    '<Override PartName="/ppt/slides/slide2.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.'
    'presentationml.slide+xml"/>',
  ),
  '_rels/.rels': _rootRelationships('ppt/presentation.xml'),
  'ppt/presentation.xml':
      '<p:presentation xmlns:p="$_presentation" xmlns:r="$_office">'
      '<p:sldIdLst><p:sldId id="256" r:id="rIdFirst"/>'
      '<p:sldId id="257" r:id="rIdSecond"/></p:sldIdLst>'
      '<p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
  'ppt/_rels/presentation.xml.rels':
      '<Relationships xmlns="$_rels">'
      '<Relationship Id="rIdSecond" Type="$_office/slide" '
      'Target="slides/slide2.xml"/>'
      '<Relationship Id="rIdFirst" Type="$_office/slide" '
      'Target="slides/slide7.xml"/></Relationships>',
  'ppt/slides/slide2.xml': _slideXml(second),
  'ppt/slides/slide7.xml': _slideXml(first),
}, deflate: deflate);

String _slideXml(String text) =>
    '<p:sld xmlns:p="$_presentation" xmlns:a="$_drawing">'
    '<p:cSld><p:spTree><p:sp><p:nvSpPr>'
    '<p:cNvPr id="2" name="Title"/><p:cNvSpPr/>'
    '<p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/>'
    '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r>'
    '<a:t>${_xml(text)}</a:t>'
    '</a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>';

/// Workbook order, shared strings, sparse cells, and cached formula values.
Uint8List spreadsheetDocument({String? firstSheet, bool deflate = true}) =>
    documentZip({
      '[Content_Types].xml': _contentTypes(
        '<Override PartName="/xl/workbook.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.'
        'spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet9.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.'
        'spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.'
        'spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.'
        'spreadsheetml.sharedStrings+xml"/>',
      ),
      '_rels/.rels': _rootRelationships('xl/workbook.xml'),
      'xl/workbook.xml':
          '<workbook xmlns="$_sheet" xmlns:r="$_office"><sheets>'
          '<sheet name="预算 Budget" sheetId="9" r:id="rIdBudget"/>'
          '<sheet name="Notes" sheetId="1" r:id="rIdNotes"/>'
          '</sheets></workbook>',
      'xl/_rels/workbook.xml.rels':
          '<Relationships xmlns="$_rels">'
          '<Relationship Id="rIdNotes" Type="$_office/worksheet" '
          'Target="worksheets/sheet1.xml"/>'
          '<Relationship Id="rIdBudget" Type="$_office/worksheet" '
          'Target="worksheets/sheet9.xml"/>'
          '<Relationship Id="rIdStrings" Type="$_office/sharedStrings" '
          'Target="sharedStrings.xml"/></Relationships>',
      'xl/sharedStrings.xml':
          '<sst xmlns="$_sheet" count="2" uniqueCount="2">'
          '<si><t>收入 Revenue</t></si>'
          '<si><r><t>Rich </t></r><r><t>text</t></r></si></sst>',
      'xl/worksheets/sheet1.xml':
          '<worksheet xmlns="$_sheet"><sheetData><row r="1">'
          '<c r="A1" t="inlineStr"><is><t>Private notes</t></is></c>'
          '</row></sheetData></worksheet>',
      'xl/worksheets/sheet9.xml':
          firstSheet ??
          '<worksheet xmlns="$_sheet"><sheetData><row r="1">'
              '<c r="A1" t="s"><v>0</v></c><c r="C1"><v>42.5</v></c>'
              '<c r="D1" t="b"><v>1</v></c></row><row r="3">'
              '<c r="A3" t="s"><v>1</v></c>'
              '<c r="B3"><f>SUM(C1,1)</f><v>43.5</v></c>'
              '</row></sheetData></worksheet>',
    }, deflate: deflate);

Uint8List csvDocument(String text) => Uint8List.fromList(utf8.encode(text));
