import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:epub_plus/epub_plus.dart';
import 'package:fepubreader/util/mobi_to_epub_converter.dart';

/// Luo testikäyttöön pienen PalmDOC LZ77 -pakatun MOBI-binaarin
Uint8List createTestMobiBytes({
  required String title,
  required String author,
  required String htmlContent,
}) {
  final htmlBytes = utf8.encode(htmlContent);
  final uncompressedTextLen = htmlBytes.length;

  // PalmDOC LZ77 kompressio (yksinkertainen literaaleina testiä varten)
  final List<int> compressedText = [];
  int idx = 0;
  while (idx < htmlBytes.length) {
    int chunk = (htmlBytes.length - idx).clamp(1, 8);
    compressedText.add(chunk); // b in 1..8
    for (int c = 0; c < chunk; c++) {
      compressedText.add(htmlBytes[idx++]);
    }
  }

  // Luodaan Record 0
  final List<int> r0 = [];
  // PalmDOC header (16 bytes)
  r0.addAll([0, 2]); // compression = 2 (PalmDOC LZ77)
  r0.addAll([0, 0]); // unused
  final ByteData lenData = ByteData(4)..setUint32(0, uncompressedTextLen, Endian.big);
  r0.addAll(lenData.buffer.asUint8List());
  r0.addAll([0, 1]); // recordCount = 1
  r0.addAll([16, 0]); // recordSize = 4096
  r0.addAll([0, 0]); // encryption = 0 (none)
  r0.addAll([0, 0]); // unused

  // MOBI header (starts at 16)
  final mobiHeaderStart = r0.length;
  r0.addAll(utf8.encode('MOBI')); // identifier
  final mobiLenData = ByteData(4)..setUint32(0, 232, Endian.big); // header length
  r0.addAll(mobiLenData.buffer.asUint8List());
  r0.addAll([0, 0, 0, 2]); // mobiType = 2 (book)
  r0.addAll([0, 0, 253, 233]); // textEncoding = 65001 (UTF-8)
  r0.addAll(List.filled(12, 0)); // uniqueID & fileVersion

  // Fill up to offset 68 (Title offset)
  while (r0.length - mobiHeaderStart < 68) {
    r0.add(0);
  }
  final titleBytes = utf8.encode(title);
  // Title will be appended after EXTH
  final int titleRelOffset = 16 + 232 + 48; // placeholder
  final ByteData tOffData = ByteData(4)..setUint32(0, titleRelOffset, Endian.big);
  r0.addAll(tOffData.buffer.asUint8List());
  final ByteData tLenData = ByteData(4)..setUint32(0, titleBytes.length, Endian.big);
  r0.addAll(tLenData.buffer.asUint8List());

  // Fill up to offset 92 (firstImageIndex)
  while (r0.length - mobiHeaderStart < 92) {
    r0.add(0);
  }
  r0.addAll([0, 0, 0, 2]); // firstImageIndex = 2

  // Fill up to offset 112 (exthFlags)
  while (r0.length - mobiHeaderStart < 112) {
    r0.add(0);
  }
  r0.addAll([0, 0, 0, 0x40]); // exthFlags bit 6 (0x40)

  // Fill remainder of MOBI header up to 232 bytes
  while (r0.length - mobiHeaderStart < 232) {
    r0.add(0);
  }

  // EXTH header
  r0.addAll(utf8.encode('EXTH'));
  final authorBytes = utf8.encode(author);
  final int exthLen = 12 + (8 + authorBytes.length) + (8 + titleBytes.length);
  final ByteData exthLenData = ByteData(4)..setUint32(0, exthLen, Endian.big);
  r0.addAll(exthLenData.buffer.asUint8List());
  r0.addAll([0, 0, 0, 2]); // 2 records: author (100) and title (503)

  // EXTH record 100: author
  r0.addAll([0, 0, 0, 100]);
  final ByteData aLenData = ByteData(4)..setUint32(0, 8 + authorBytes.length, Endian.big);
  r0.addAll(aLenData.buffer.asUint8List());
  r0.addAll(authorBytes);

  // EXTH record 503: updated title
  r0.addAll([0, 0, 1, 247]); // 503
  final ByteData tRecLenData = ByteData(4)..setUint32(0, 8 + titleBytes.length, Endian.big);
  r0.addAll(tRecLenData.buffer.asUint8List());
  r0.addAll(titleBytes);

  // PDB file header (78 bytes) + 2 record entries (16 bytes)
  final int totalPdbHeaders = 78 + (2 * 8);
  final int r0Offset = totalPdbHeaders;
  final int r1Offset = r0Offset + r0.length;

  final List<int> pdb = [];
  // DB Name (32 bytes)
  final dbNameBytes = utf8.encode('TestBook');
  pdb.addAll(dbNameBytes);
  while (pdb.length < 32) {
    pdb.add(0);
  }
  // Attributes, version, dates etc.
  while (pdb.length < 76) {
    pdb.add(0);
  }
  // numRecords = 2
  pdb.addAll([0, 2]);

  // Record 0 entry (offset + attr/uid)
  final ByteData r0OffData = ByteData(4)..setUint32(0, r0Offset, Endian.big);
  pdb.addAll(r0OffData.buffer.asUint8List());
  pdb.addAll([0, 0, 0, 0]);

  // Record 1 entry (offset + attr/uid)
  final ByteData r1OffData = ByteData(4)..setUint32(0, r1Offset, Endian.big);
  pdb.addAll(r1OffData.buffer.asUint8List());
  pdb.addAll([0, 0, 0, 1]);

  // Combine PDB headers + Record 0 + Record 1 (compressed text)
  return Uint8List.fromList([...pdb, ...r0, ...compressedText]);
}

void main() {
  test('MobiToEpubConverter muuntaa test-MOBI-tiedoston kelvolliseksi EPUBiksi', () async {
    const testTitle = 'Mobi Testikirja Ääkkösillä';
    const testAuthor = 'Mikael Kirjailija';
    const testHtml = '<h1>Ensimmäinen Luku</h1><p>Tervehdys kaikille lukijoille! Ääkköset toimivat: ä, ö, å.</p><mbp:pagebreak/><h1>Toinen Luku</h1><p>Tässä on toinen luku ja toinen kappale.</p>';

    final mobiBytes = createTestMobiBytes(
      title: testTitle,
      author: testAuthor,
      htmlContent: testHtml,
    );

    expect(MobiToEpubConverter.onkoMobiTiedosto('kirja.mobi'), isTrue);
    expect(MobiToEpubConverter.onkoMobiTiedosto('kirja.prc'), isTrue);
    expect(MobiToEpubConverter.onkoMobiTiedosto('kirja.epub'), isFalse);

    // Muunnetaan EPUBiksi
    final epubBytes = await MobiToEpubConverter.konvertoiMobiBytesEpubiksi(mobiBytes);
    expect(epubBytes.isNotEmpty, isTrue);

    // Varmistetaan että epub_plus osaa avata luodun EPUB-tiedoston!
    final epubBook = await EpubReader.readBook(epubBytes);
    expect(epubBook.title, equals(testTitle));
    expect(epubBook.author, equals(testAuthor));
    expect(epubBook.chapters, isNotNull);
    expect(epubBook.chapters.length, equals(2));
    expect(epubBook.chapters[0].htmlContent, contains('Ensimmäinen Luku'));
    expect(epubBook.chapters[1].htmlContent, contains('Toinen Luku'));
  });
}
