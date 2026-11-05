import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import 'document_model.dart';

Never documentTooLarge(String detail) => throw DocumentParseException(
  'Document exceeds the preview limit: $detail.',
  code: 'tooLarge',
);

Never documentCorrupt(String detail) =>
    throw DocumentParseException('This document cannot be previewed: $detail.');

/// In-memory OPC package. The central AND local directory are validated before
/// archive sees the bytes, including symlinks (which it can eagerly inflate).
/// archive >=4.6.0 also bounds actual inflation by each declared size; the
/// post-read equality check is an additional integrity check, not the bound.
class DocumentPackage {
  DocumentPackage(Uint8List bytes, this.limits) {
    final declared = _validateZip(bytes, limits);
    final archive = ZipDecoder(filenameEncoding: utf8)
        .decodeBytes(bytes, verify: true);
    for (final file in archive.files) {
      if (!file.isFile) {
        continue;
      }
      if (file.isSymbolicLink || declared[file.name] != file.size) {
        documentCorrupt('invalid ZIP entry');
      }
      _files[file.name] = file;
    }
  }

  final DocumentPreviewLimits limits;
  final Map<String, ArchiveFile> _files = {};
  final Map<String, Uint8List> _bytes = {};
  final Map<String, XmlDocument> _xml = {};
  final Set<String> warnings = {};
  int _readBytes = 0;
  int _xmlBytes = 0;
  int _xmlNodes = 0;
  int _textChars = 0;
  int _cells = 0;
  int _blocks = 0;
  int _images = 0;
  int _imageBytes = 0;
  int _imagePixels = 0;

  bool contains(String path) => _files.containsKey(path);

  void checkTextUnit(int length) {
    if (length > limits.maxTextUnitChars) {
      documentTooLarge('paragraph or cell text length');
    }
  }

  String text(String value) {
    checkTextUnit(value.length);
    _textChars += value.length;
    if (_textChars > limits.maxTextChars) {
      documentTooLarge('text');
    }
    return value;
  }

  void countCell() {
    if (++_cells > limits.maxCells) {
      documentTooLarge('cell count');
    }
  }

  void countBlock() {
    if (++_blocks > limits.maxBlocks) {
      documentTooLarge('content blocks');
    }
  }

  Uint8List? bytes(String path) {
    if (_bytes[path] case final cached?) {
      return cached;
    }
    final file = _files[path];
    if (file == null) {
      return null;
    }
    if (file.size > limits.maxEntryBytes) {
      documentTooLarge('ZIP entry');
    }
    final result = file.readBytes();
    if (result == null || result.length != file.size) {
      documentCorrupt('incorrect inflated size');
    }
    _readBytes += result.length;
    if (_readBytes > limits.maxInflatedBytes) {
      documentTooLarge('inflated data');
    }
    _bytes[path] = result;
    return result;
  }

  XmlDocument? xml(String path, {bool required = false}) {
    if (_xml[path] case final cached?) {
      return cached;
    }
    final data = bytes(path);
    if (data == null) {
      if (required) {
        documentCorrupt('missing document part');
      }
      return null;
    }
    _xmlBytes += data.length;
    if (_xmlBytes > limits.maxXmlBytes) {
      documentTooLarge('XML data');
    }
    final source = decodeDocumentText(data);
    // OOXML needs no DTD. Reject it before the parser can inspect declarations.
    if (RegExp(
      r'<!\s*(DOCTYPE|ENTITY)',
      caseSensitive: false,
    ).hasMatch(source)) {
      documentCorrupt('XML entity declarations are not supported');
    }
    var depth = 0;
    for (final event in parseEvents(source, validateNesting: true)) {
      if (++_xmlNodes > limits.maxXmlNodes) {
        documentTooLarge('XML nodes');
      }
      if (event is XmlStartElementEvent) {
        if (depth + 1 > limits.maxXmlDepth) {
          documentTooLarge('XML nesting');
        }
        if (!event.isSelfClosing) {
          depth++;
        }
      } else if (event is XmlEndElementEvent) {
        depth--;
      } else if (event is XmlDoctypeEvent) {
        documentCorrupt('XML document type declarations');
      }
    }
    final result = XmlDocument.parse(source);
    _xml[path] = result;
    return result;
  }

  /// OPC target paths are resolved only within this archive. No URI ever
  /// leaves this class, and no relationship opens a local or network file.
  Map<String, DocumentRelationship> relationships(String part) {
    final slash = part.lastIndexOf('/');
    final folder = slash < 0 ? '' : part.substring(0, slash + 1);
    final name = part.substring(slash + 1);
    final relPath = part.isEmpty ? '_rels/.rels' : '${folder}_rels/$name.rels';
    final doc = xml(relPath);
    if (doc == null) {
      return const {};
    }
    final result = <String, DocumentRelationship>{};
    for (final node in elements(doc, 'Relationship')) {
      final id = attr(node, 'Id');
      final target = attr(node, 'Target');
      if (id == null || target == null) {
        continue;
      }
      if (result.containsKey(id)) {
        documentCorrupt('duplicate relationship');
      }
      if (attr(node, 'TargetMode')?.toLowerCase() == 'external') {
        warnings.add('External links and linked resources are not loaded.');
        continue;
      }
      final path = _resolvePart(folder, target);
      if (path == null) {
        warnings.add('External or invalid resource paths were omitted.');
        continue;
      }
      result[id] = DocumentRelationship(path, attr(node, 'Type') ?? '');
    }
    return result;
  }

  String mainPart(String fallback, String prefix) {
    for (final relation in relationships('').values) {
      if (relation.type.endsWith('/officeDocument')) {
        if (!relation.path.startsWith('$prefix/')) {
          documentCorrupt('unexpected main document part');
        }
        return relation.path;
      }
    }
    return fallback;
  }

  DocumentImage? image(
    DocumentRelationship? relation, {
    double? width,
    double? height,
  }) {
    if (relation == null || !relation.type.endsWith('/image')) {
      return null;
    }
    final path = relation.path;
    if (!RegExp(r'^(word|ppt)/media/').hasMatch(path)) {
      return null;
    }
    final file = _files[path];
    if (file == null) {
      return null;
    }
    if (file.size > limits.maxImageBytes) {
      documentTooLarge('embedded image');
    }
    final data = bytes(path)!;
    final size = _rasterSize(data);
    if (size == null) {
      warnings.add('Some embedded image formats are not supported.');
      return null;
    }
    if (size.$1 <= 0 ||
        size.$2 <= 0 ||
        size.$1 > 8192 ||
        size.$2 > 8192 ||
        size.$1 * size.$2 > limits.maxImagePixels) {
      documentTooLarge('image dimensions');
    }
    _imagePixels += size.$1 * size.$2;
    if (_imagePixels > limits.maxTotalImagePixels) {
      documentTooLarge('total decoded image dimensions');
    }
    if (++_images > limits.maxImages) {
      documentTooLarge('embedded image count');
    }
    _imageBytes += data.length;
    if (_imageBytes > limits.maxTotalImageBytes) {
      documentTooLarge('embedded image data');
    }
    return DocumentImage(
      bytes: data,
      name: path.split('/').last,
      pixelWidth: size.$1,
      pixelHeight: size.$2,
      width: width ?? size.$1.toDouble(),
      height: height ?? size.$2.toDouble(),
    );
  }
}

class DocumentRelationship {
  const DocumentRelationship(this.path, this.type);
  final String path, type;
}

Iterable<XmlElement> elements(XmlNode node, String local) => node.descendants
    .whereType<XmlElement>()
    .where((e) => e.name.local == local);
Iterable<XmlElement> children(XmlNode node, String local) =>
    node.children.whereType<XmlElement>().where((e) => e.name.local == local);
XmlElement? firstElement(XmlNode? node, String local) =>
    node == null ? null : elements(node, local).firstOrNull;
String? attr(XmlElement? node, String local) =>
    node?.attributes.where((a) => a.name.local == local).firstOrNull?.value;

String decodeDocumentText(Uint8List data) {
  if (data.length >= 2 &&
      ((data[0] == 0xff && data[1] == 0xfe) ||
          (data[0] == 0xfe && data[1] == 0xff))) {
    if (data.length.isOdd) {
      documentCorrupt('truncated UTF-16 text');
    }
    final little = data[0] == 0xff;
    final units = Uint16List((data.length - 2) ~/ 2);
    for (var i = 2; i < data.length; i += 2) {
      units[(i - 2) ~/ 2] = little
          ? data[i] | (data[i + 1] << 8)
          : (data[i] << 8) | data[i + 1];
    }
    return String.fromCharCodes(units);
  }
  return utf8.decode(data).replaceFirst(RegExp('^\uFEFF'), '');
}

String? _resolvePart(String folder, String target) {
  String decoded;
  try {
    decoded = Uri.decodeComponent(target);
  } catch (_) {
    return null;
  }
  if (decoded.contains(RegExp(r'[\\:\x00-\x1f?#]')) ||
      decoded.startsWith('//')) {
    return null;
  }
  final parts = <String>[];
  for (final part
      in (decoded.startsWith('/') ? decoded.substring(1) : '$folder$decoded')
          .split('/')) {
    if (part.isEmpty || part == '.') {
      continue;
    }
    if (part == '..') {
      if (parts.isEmpty) {
        return null;
      }
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.isEmpty ? null : parts.join('/');
}

Map<String, int> _validateZip(Uint8List bytes, DocumentPreviewLimits limits) {
  if (bytes.length > limits.maxCompressedBytes) {
    documentTooLarge('file size');
  }
  if (bytes.length < 22) {
    documentCorrupt('truncated ZIP');
  }
  final data = ByteData.sublistView(bytes);
  int u16(int at) => data.getUint16(at, Endian.little);
  int u32(int at) => data.getUint32(at, Endian.little);
  void checkExtra(int start, int length) {
    final stop = start + length;
    var offset = start;
    while (offset < stop) {
      if (offset + 4 > stop) {
        documentCorrupt('truncated ZIP extension');
      }
      final type = u16(offset), size = u16(offset + 2);
      offset += 4;
      if (offset + size > stop) {
        documentCorrupt('truncated ZIP extension');
      }
      // Neither ZIP64 nor an alternate Unicode filename is needed for these
      // small UTF-8 packages. Refuse a second interpretation of checked data.
      if (type == 0x0001 || type == 0x7075) {
        documentCorrupt('unsupported ZIP extension');
      }
      if (type == 0x9901) {
        throw const DocumentParseException(
          'Password-protected documents are not supported.',
          code: 'encrypted',
        );
      }
      offset += size;
    }
  }

  var end = -1;
  for (
    var at = bytes.length - 22;
    at >= math.max(0, bytes.length - 65557);
    at--
  ) {
    if (u32(at) == 0x06054b50 && at + 22 + u16(at + 20) == bytes.length) {
      end = at;
      break;
    }
  }
  if (end < 0) {
    documentCorrupt('missing ZIP directory');
  }
  if (u16(end + 4) != 0 || u16(end + 6) != 0 || u16(end + 8) != u16(end + 10)) {
    documentCorrupt('multi-volume ZIP is not supported');
  }
  final count = u16(end + 10), directorySize = u32(end + 12);
  final directoryOffset = u32(end + 16);
  if (count == 65535 ||
      directoryOffset == 0xffffffff ||
      directorySize == 0xffffffff) {
    documentCorrupt('ZIP64 is not supported');
  }
  if (count > limits.maxEntries) {
    documentTooLarge('ZIP entry count');
  }
  if (directoryOffset + directorySize != end) {
    documentCorrupt('ZIP directory bounds');
  }
  var at = directoryOffset, total = 0, xmlTotal = 0;
  final result = <String, int>{};
  final ranges = <(int, int)>[];
  for (var index = 0; index < count; index++) {
    if (at + 46 > end || u32(at) != 0x02014b50) {
      documentCorrupt('ZIP entry');
    }
    final flags = u16(at + 8), method = u16(at + 10);
    final compressed = u32(at + 20), inflated = u32(at + 24);
    final nameLength = u16(at + 28), extraLength = u16(at + 30);
    final commentLength = u16(at + 32), local = u32(at + 42);
    final next = at + 46 + nameLength + extraLength + commentLength;
    if (next > end || nameLength == 0 || nameLength > 1024) {
      documentCorrupt('ZIP filename');
    }
    if ((flags & 0x41) != 0 || method == 99) {
      throw const DocumentParseException(
        'Password-protected documents are not supported.',
        code: 'encrypted',
      );
    }
    if (method != 0 && method != 8) {
      documentCorrupt('ZIP compression method');
    }
    if (u16(at + 34) != 0 ||
        compressed == 0xffffffff ||
        inflated == 0xffffffff ||
        local == 0xffffffff) {
      documentCorrupt('ZIP64 or split entry');
    }
    checkExtra(at + 46 + nameLength, extraLength);
    final mode = u32(at + 38) >> 16;
    if ((mode & 0xf000) == 0xa000) {
      documentCorrupt('symbolic ZIP links');
    }
    final name = utf8.decode(
      Uint8List.sublistView(bytes, at + 46, at + 46 + nameLength),
    );
    if (name.startsWith('/') ||
        name.contains(RegExp(r'[\\:\x00-\x1f]')) ||
        name.split('/').any((p) => p == '..' || p == '.') ||
        result.containsKey(name)) {
      documentCorrupt('unsafe or duplicate ZIP path');
    }
    if (inflated > limits.maxEntryBytes) {
      documentTooLarge('ZIP entry');
    }
    total += inflated;
    if (total > limits.maxInflatedBytes) {
      documentTooLarge('inflated data');
    }
    if (name.toLowerCase().endsWith('.xml') ||
        name.toLowerCase().endsWith('.rels')) {
      xmlTotal += inflated;
      if (xmlTotal > limits.maxXmlBytes) {
        documentTooLarge('XML data');
      }
    }
    if (local + 30 > directoryOffset || u32(local) != 0x04034b50) {
      documentCorrupt('ZIP local header');
    }
    final localNameLength = u16(local + 26), localExtraLength = u16(local + 28);
    final start = local + 30 + localNameLength + localExtraLength;
    if (start + compressed > directoryOffset ||
        localNameLength != nameLength ||
        u16(local + 6) != flags ||
        u16(local + 8) != method) {
      documentCorrupt('ZIP local bounds');
    }
    checkExtra(local + 30 + localNameLength, localExtraLength);
    for (var i = 0; i < nameLength; i++) {
      if (bytes[local + 30 + i] != bytes[at + 46 + i]) {
        documentCorrupt('ZIP filename mismatch');
      }
    }
    if ((flags & 8) == 0 &&
        (u32(local + 18) != compressed ||
            u32(local + 22) != inflated ||
            u32(local + 14) != u32(at + 16))) {
      documentCorrupt('ZIP size mismatch');
    }
    ranges.add((local, start + compressed));
    result[name] = inflated;
    at = next;
  }
  if (at != end) {
    documentCorrupt('ZIP directory length');
  }
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  for (var i = 1; i < ranges.length; i++) {
    if (ranges[i].$1 < ranges[i - 1].$2) {
      documentCorrupt('overlapping ZIP entries');
    }
  }
  return result;
}

/// Only static raster formats with bounded dimensions enter Flutter's codec.
/// SVG/metafiles and animated GIF/WebP are deliberately not interpreted here.
(int, int)? _rasterSize(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  if (bytes.length >= 24 &&
      d.getUint32(0) == 0x89504e47 &&
      d.getUint32(4) == 0x0d0a1a0a &&
      d.getUint32(12) == 0x49484452) {
    // Animated PNG can allocate one frame per chunk despite a small canvas.
    for (var at = 8; at + 12 <= bytes.length;) {
      final length = d.getUint32(at);
      if (at + 12 + length > bytes.length) {
        return null;
      }
      if (d.getUint32(at + 4) == 0x6163544c) {
        return null;
      }
      at += 12 + length;
    }
    return (d.getUint32(16), d.getUint32(20));
  }
  if (bytes.length >= 26 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
    if (d.getUint32(14, Endian.little) < 40) {
      return null;
    }
    return (
      d.getInt32(18, Endian.little).abs(),
      d.getInt32(22, Endian.little).abs(),
    );
  }
  if (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    var at = 2;
    while (at + 4 <= bytes.length) {
      if (bytes[at++] != 0xff) {
        return null;
      }
      while (at < bytes.length && bytes[at] == 0xff) {
        at++;
      }
      if (at >= bytes.length) {
        return null;
      }
      final marker = bytes[at++];
      if (marker == 0xda || marker == 0xd9) {
        return null;
      }
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
        continue;
      }
      if (at + 2 > bytes.length) {
        return null;
      }
      final length = d.getUint16(at);
      if (length < 2 || at + length > bytes.length) {
        return null;
      }
      if ({
        0xc0,
        0xc1,
        0xc2,
        0xc3,
        0xc5,
        0xc6,
        0xc7,
        0xc9,
        0xca,
        0xcb,
        0xcd,
        0xce,
        0xcf,
      }.contains(marker)) {
        if (length < 7) {
          return null;
        }
        return (d.getUint16(at + 5), d.getUint16(at + 3));
      }
      at += length;
    }
  }
  return null;
}
