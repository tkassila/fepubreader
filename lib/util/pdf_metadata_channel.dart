import 'dart:io';
import 'package:flutter/services.dart';

/// PDFBox- ja juniversalchardet-kyselyn tulosluokka.
class PdfMetadataResult {
  final bool success;
  final String title;
  final String author;
  final String publisher;
  final String publishDateText;
  final int publishYear;
  final List<String> tags;
  final String detectedCharset;
  final bool savedToPdf;
  final String? error;

  const PdfMetadataResult({
    required this.success,
    this.title = '',
    this.author = '',
    this.publisher = '',
    this.publishDateText = '',
    this.publishYear = 0,
    this.tags = const [],
    this.detectedCharset = '',
    this.savedToPdf = false,
    this.error,
  });

  factory PdfMetadataResult.fromMap(Map<dynamic, dynamic> map) {
    final rawTags = map['tags'];
    List<String> tagsList = [];
    if (rawTags is List) {
      tagsList = rawTags.map((e) => e.toString()).toList();
    }
    return PdfMetadataResult(
      success: map['success'] == true,
      title: (map['title'] ?? '').toString(),
      author: (map['author'] ?? '').toString(),
      publisher: (map['publisher'] ?? '').toString(),
      publishDateText: (map['publishDateText'] ?? '').toString(),
      publishYear: (map['publishYear'] as num?)?.toInt() ?? 0,
      tags: tagsList,
      detectedCharset: (map['detectedCharset'] ?? '').toString(),
      savedToPdf: map['savedToPdf'] == true,
      error: map['error']?.toString(),
    );
  }
}

/// Kanava Android-puolen PDFBox- ja juniversalchardet-metatiedon erikoiskyselyyn.
class PdfMetadataChannel {
  static const MethodChannel _channel =
      MethodChannel('com.metait.fepubreader/pdf_metadata');

  /// Suorittaa PDFBox- ja juniversalchardet-metatiedon erikoiskyselyn.
  /// Lukee raakatavut suoraan COSDictionarysta, tunnistaa merkistön juniversalchardetilla
  /// ja haluttaessa tallentaa korjatut kentät takaisin PDF-tiedostoon standardissa UTF-16BE -muodossa.
  static Future<PdfMetadataResult?> extractPdfMetadata(
    String filePath, {
    bool saveBackToPdf = true,
  }) async {
    if (!Platform.isAndroid) {
      return const PdfMetadataResult(
        success: false,
        error: 'PDFBox-erikoiskysely on tuettu vain Android-alustalla.',
      );
    }

    try {
      final res = await _channel.invokeMethod<Map>('extractPdfMetadata', {
        'filePath': filePath,
        'saveBackToPdf': saveBackToPdf,
      });

      if (res == null) {
        return const PdfMetadataResult(
          success: false,
          error: 'Ei vastausta natiivikanavalta.',
        );
      }

      return PdfMetadataResult.fromMap(res);
    } catch (e) {
      return PdfMetadataResult(
        success: false,
        error: e.toString(),
      );
    }
  }
}
