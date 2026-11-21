import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'text_encoding_helper.dart';

/// MOBI-kirjasta puretut metatiedot
class MobiMetadata {
  final String title;
  final String author;
  final String publisher;
  final String description;
  final String publishDate;
  final Uint8List? coverBytes;
  final String coverMimeType;

  MobiMetadata({
    required this.title,
    this.author = 'Tuntematon',
    this.publisher = 'Tuntematon',
    this.description = '',
    this.publishDate = '',
    this.coverBytes,
    this.coverMimeType = 'image/jpeg',
  });
}

/// Purettu kuva MOBI-tiedostosta
class _MobiImage {
  final Uint8List bytes;
  final String mimeType;
  final String extension;
  final String filename;

  _MobiImage({
    required this.bytes,
    required this.mimeType,
    required this.extension,
    required this.filename,
  });
}

/// Palm Database (PDB) -tietueen osoitetiedot
class _PdbRecord {
  final int offset;
  final int attributes;
  final int uniqueId;

  _PdbRecord(this.offset, this.attributes, this.uniqueId);
}

/// Muuntaa DRM-vapaat .mobi / .prc -e-kirjat standardeiksi .epub-tiedostoiksi puhtaalla Dartilla.
class MobiToEpubConverter {
  MobiToEpubConverter._();

  /// Tarkistaa onko tiedosto .mobi / .prc / .azw
  static bool onkoMobiTiedosto(String tiedostoPolku) {
    final ext = p.extension(tiedostoPolku).toLowerCase();
    return ext == '.mobi' || ext == '.prc' || ext == '.azw';
  }

  /// Lukee vain metatiedot ja kansikuvan MOBI-tiedostosta nopeasti ilman koko kirjan muuntamista.
  static Future<MobiMetadata> lueMetatiedot(File mobiTiedosto) async {
    final bytes = await mobiTiedosto.readAsBytes();
    return _puraMetatiedot(bytes, p.basenameWithoutExtension(mobiTiedosto.path));
  }

  /// Muuntaa .mobi-tiedoston .epub-tiedostoksi.
  /// Jos [kohdeEpubPolku] ei ole annettu, luo saman nimisen .epub-tiedoston samaan kansioon.
  /// Palauttaa luodun EPUB-tiedoston File-olion.
  static Future<File> muunnaEpubiksi(
    File mobiTiedosto, {
    String? kohdeEpubPolku,
    void Function(String vaihe, double edistys)? onProgress,
  }) async {
    final String fallbackNimi = p.basenameWithoutExtension(mobiTiedosto.path);
    final String kohdePolku = kohdeEpubPolku ?? p.setExtension(mobiTiedosto.path, '.epub');

    onProgress?.call('Luetaan MOBI-tiedostoa...', 0.1);
    final bytes = await mobiTiedosto.readAsBytes();

    onProgress?.call('Puretaan metatiedot ja teksti...', 0.3);
    final epubBytes = await konvertoiMobiBytesEpubiksi(
      bytes,
      fallbackNimi: fallbackNimi,
      onProgress: onProgress,
    );

    onProgress?.call('Tallennetaan EPUB-tiedostoa...', 0.9);
    final epubTiedosto = File(kohdePolku);
    await epubTiedosto.writeAsBytes(epubBytes);

    onProgress?.call('Valmis', 1.0);
    return epubTiedosto;
  }

  /// Pääkonversio tavuista EPUB-tavuiksi
  static Future<Uint8List> konvertoiMobiBytesEpubiksi(
    Uint8List mobiBytes, {
    String fallbackNimi = 'Kirja',
    void Function(String vaihe, double edistys)? onProgress,
  }) async {
    final data = ByteData.sublistView(mobiBytes);
    if (mobiBytes.length < 78) {
      throw const FormatException('Tiedosto on liian lyhyt ollakseen kelvollinen MOBI/PDB-tiedosto');
    }

    // 1. Luetaan Palm Database (PDB) otsikko
    final int numRecords = data.getUint16(76, Endian.big);
    if (numRecords == 0 || mobiBytes.length < 78 + numRecords * 8) {
      throw const FormatException('MOBI-tiedoston tietuelista on korruptoitunut');
    }

    final List<_PdbRecord> records = [];
    for (int i = 0; i < numRecords; i++) {
      final int recordEntryOffset = 78 + (i * 8);
      final int offset = data.getUint32(recordEntryOffset, Endian.big);
      final int attr = mobiBytes[recordEntryOffset + 4];
      final int uid = (mobiBytes[recordEntryOffset + 5] << 16) |
          (mobiBytes[recordEntryOffset + 6] << 8) |
          mobiBytes[recordEntryOffset + 7];
      records.add(_PdbRecord(offset, attr, uid));
    }

    // 2. Puretaan Record 0 (PalmDOC ja MOBI Header)
    final Uint8List record0 = _haeTietue(mobiBytes, records, 0);
    if (record0.length < 16) {
      throw const FormatException('Record 0 on liian lyhyt');
    }
    final ByteData r0Data = ByteData.sublistView(record0);

    final int compression = r0Data.getUint16(0, Endian.big);
    final int textLength = r0Data.getUint32(4, Endian.big);
    final int recordCount = r0Data.getUint16(8, Endian.big);
    final int encryptionType = r0Data.getUint16(12, Endian.big);

    if (encryptionType != 0) {
      throw const FormatException(
        'Tiedosto on DRM-suojattu tai salattu (Amazon Kindle). '
        'Vain DRM-vapaat .mobi-tiedostot ovat tuettuja.',
      );
    }

    // Tarkistetaan MOBI-otsikko (alkaa offsetistä 16)
    int textEncoding = 1252; // Oletus cp1252
    int firstImageIndex = numRecords;
    int exthFlags = 0;
    int extraFlags = 0;
    int mobiHeaderLength = 0;
    String mobiTitle = fallbackNimi;

    if (record0.length >= 40 &&
        record0[16] == 0x4D &&
        record0[17] == 0x4F &&
        record0[18] == 0x42 &&
        record0[19] == 0x49) {
      // Löytyi "MOBI"
      mobiHeaderLength = r0Data.getUint32(20, Endian.big);
      textEncoding = r0Data.getUint32(28, Endian.big);

      if (record0.length >= 16 + 76) {
        final int titleOffset = r0Data.getUint32(16 + 68, Endian.big);
        final int titleLen = r0Data.getUint32(16 + 72, Endian.big);
        if (titleOffset + titleLen <= record0.length && titleLen > 0) {
          final titleBytes = record0.sublist(titleOffset, titleOffset + titleLen);
          mobiTitle = (textEncoding == 65001 ? utf8.decode(titleBytes, allowMalformed: true) : latin1.decode(titleBytes));
        }
      }

      if (record0.length >= 16 + 112) {
        firstImageIndex = r0Data.getUint32(16 + 92, Endian.big);
        exthFlags = r0Data.getUint32(16 + 112, Endian.big);
      }

      if (mobiHeaderLength >= 228 && record0.length >= 16 + 242) {
        extraFlags = r0Data.getUint16(16 + 240, Endian.big);
      }
    }

    // 3. Luetaan EXTH-metatiedot
    String author = 'Tuntematon';
    String publisher = 'Tuntematon';
    String description = '';
    String publishDate = '';
    int? coverOffset;

    if ((exthFlags & 0x40) != 0 && mobiHeaderLength > 0) {
      final int exthStart = 16 + mobiHeaderLength;
      if (record0.length >= exthStart + 12 &&
          record0[exthStart] == 0x45 &&
          record0[exthStart + 1] == 0x58 &&
          record0[exthStart + 2] == 0x54 &&
          record0[exthStart + 3] == 0x48) {
        final ByteData exthData = ByteData.sublistView(record0, exthStart);
        final int exthCount = exthData.getUint32(8, Endian.big);
        int pos = exthStart + 12;

        for (int i = 0; i < exthCount; i++) {
          if (pos + 8 > record0.length) break;
          final int rType = r0Data.getUint32(pos, Endian.big);
          final int rLen = r0Data.getUint32(pos + 4, Endian.big);
          if (rLen < 8 || pos + rLen > record0.length) break;

          final recordPayload = record0.sublist(pos + 8, pos + rLen);
          final String strVal = utf8.decode(recordPayload, allowMalformed: true);

          switch (rType) {
            case 100: // Author
              if (strVal.trim().isNotEmpty) author = strVal.trim();
              break;
            case 101: // Publisher
              if (strVal.trim().isNotEmpty) publisher = strVal.trim();
              break;
            case 103: // Description
              description = strVal.trim();
              break;
            case 106: // Publishing date
              publishDate = strVal.trim();
              break;
            case 201: // Cover offset
              if (recordPayload.length >= 4) {
                coverOffset = ByteData.sublistView(recordPayload).getUint32(0, Endian.big);
              }
              break;
            case 503: // Updated Title
              if (strVal.trim().isNotEmpty) mobiTitle = strVal.trim();
              break;
          }
          pos += rLen;
        }
      }
    }

    mobiTitle = TextEncodingHelper.korjaaMerkistovirheet(mobiTitle);
    author = TextEncodingHelper.korjaaMerkistovirheet(author);
    publisher = TextEncodingHelper.korjaaMerkistovirheet(publisher);

    onProgress?.call('Puretaan kirjan tekstiä ja kuvia...', 0.5);

    // 4. Puretaan tekstisisältö kaikista tekstilohkoista (Record 1 .. recordCount)
    final List<int> allTextBytes = [];
    final int safeRecordCount = recordCount < numRecords ? recordCount : numRecords - 1;

    for (int r = 1; r <= safeRecordCount; r++) {
      final Uint8List chunk = _haeTietue(mobiBytes, records, r);
      if (chunk.isEmpty) continue;

      if (compression == 1) {
        // Ei pakkausta
        allTextBytes.addAll(chunk);
      } else if (compression == 2) {
        // PalmDOC LZ77 -pakkaus
        final int trailingBytesCount = _laskeTrailingBytes(chunk, extraFlags);
        final int validLen = chunk.length - trailingBytesCount;
        final Uint8List compressedPart = validLen > 0 ? chunk.sublist(0, validLen) : chunk;
        final decompressed = _puraPalmDocLz77(compressedPart);
        allTextBytes.addAll(decompressed);
      } else {
        throw FormatException('Tuntematon pakkausmuoto: $compression (HUFF/CDIC ei tuettu)');
      }

      if (textLength > 0 && allTextBytes.length >= textLength) {
        break;
      }
    }

    // Rajataan täsmälliseen tekstin pituuteen
    final int lopullinenPituus = (textLength > 0 && allTextBytes.length > textLength)
        ? textLength
        : allTextBytes.length;
    final Uint8List textBytes = Uint8List.fromList(allTextBytes.sublist(0, lopullinenPituus));

    String rawHtml = (textEncoding == 65001)
        ? utf8.decode(textBytes, allowMalformed: true)
        : latin1.decode(textBytes);
    rawHtml = TextEncodingHelper.korjaaMerkistovirheet(rawHtml);

    // 5. Puretaan kuvat tietueista (firstImageIndex .. numRecords - 1)
    final Map<int, _MobiImage> kuvat = {};
    _MobiImage? kansiKuva;

    if (firstImageIndex > 0 && firstImageIndex < numRecords) {
      int imageNumber = 1;
      for (int i = firstImageIndex; i < numRecords; i++) {
        final Uint8List imgBytes = _haeTietue(mobiBytes, records, i);
        if (imgBytes.length > 4) {
          final String? mime = _tunnistaKuvaMime(imgBytes);
          if (mime != null) {
            final ext = mime == 'image/png'
                ? 'png'
                : mime == 'image/gif'
                    ? 'gif'
                    : 'jpg';
            final filename = 'image_$imageNumber.$ext';
            final mobiImg = _MobiImage(
              bytes: imgBytes,
              mimeType: mime,
              extension: ext,
              filename: filename,
            );
            kuvat[i] = mobiImg;

            // Tarkistetaan onko kyseessä kansikuva
            if (coverOffset != null && i == (firstImageIndex + coverOffset)) {
              kansiKuva = mobiImg;
            } else if (kansiKuva == null && imageNumber == 1) {
              // Jos kansikuvaa ei ole erikseen merkitty, käytetään ensimmäistä kuvaa
              kansiKuva = mobiImg;
            }

            imageNumber++;
          }
        }
      }
    }

    onProgress?.call('Muotoillaan EPUB-lukukappaleet...', 0.7);

    // 6. Korvataan MOBI-kuvalinkit (<img recindex="1" /> -> <img src="images/image_1.jpg" />)
    String kasiteltyHtml = _korjaaKuvaTagit(rawHtml, firstImageIndex, kuvat);

    // 7. Jaetaan HTML lukukappaleiksi (mbp:pagebreak tai otsikot)
    final List<String> kappaleet = _jaaKappaleisiin(kasiteltyHtml, mobiTitle);

    onProgress?.call('Pakataan EPUB-arkistoa...', 0.85);

    // 8. Luodaan standardi EPUB-tiedosto (ZIP-arkisto)
    return _rakennaEpub(
      title: mobiTitle,
      author: author,
      publisher: publisher,
      description: description,
      publishDate: publishDate,
      kappaleet: kappaleet,
      kuvat: kuvat.values.toList(),
      kansiKuva: kansiKuva,
    );
  }

  /// Pura nopeat metatiedot
  static MobiMetadata _puraMetatiedot(Uint8List mobiBytes, String fallbackNimi) {
    if (mobiBytes.length < 78) {
      return MobiMetadata(title: fallbackNimi);
    }
    final data = ByteData.sublistView(mobiBytes);
    final int numRecords = data.getUint16(76, Endian.big);
    if (numRecords == 0 || mobiBytes.length < 78 + numRecords * 8) {
      return MobiMetadata(title: fallbackNimi);
    }

    final int r0Offset = data.getUint32(78, Endian.big);
    final int r1Offset = numRecords > 1 ? data.getUint32(86, Endian.big) : mobiBytes.length;
    final int r0Len = r1Offset - r0Offset;
    if (r0Len < 16 || r0Offset + r0Len > mobiBytes.length) {
      return MobiMetadata(title: fallbackNimi);
    }

    final Uint8List record0 = mobiBytes.sublist(r0Offset, r0Offset + r0Len);
    final ByteData r0Data = ByteData.sublistView(record0);

    String mobiTitle = fallbackNimi;
    String author = 'Tuntematon';
    String publisher = 'Tuntematon';
    String description = '';
    String publishDate = '';
    int? coverOffset;
    int firstImageIndex = 0;

    int textEncoding = 1252;
    int mobiHeaderLength = 0;
    int exthFlags = 0;

    if (record0.length >= 40 &&
        record0[16] == 0x4D &&
        record0[17] == 0x4F &&
        record0[18] == 0x42 &&
        record0[19] == 0x49) {
      mobiHeaderLength = r0Data.getUint32(20, Endian.big);
      textEncoding = r0Data.getUint32(28, Endian.big);

      if (record0.length >= 16 + 76) {
        final int titleOffset = r0Data.getUint32(16 + 68, Endian.big);
        final int titleLen = r0Data.getUint32(16 + 72, Endian.big);
        if (titleOffset + titleLen <= record0.length && titleLen > 0) {
          final tBytes = record0.sublist(titleOffset, titleOffset + titleLen);
          mobiTitle = textEncoding == 65001 ? utf8.decode(tBytes, allowMalformed: true) : latin1.decode(tBytes);
        }
      }

      if (record0.length >= 16 + 112) {
        firstImageIndex = r0Data.getUint32(16 + 92, Endian.big);
        exthFlags = r0Data.getUint32(16 + 112, Endian.big);
      }
    }

    if ((exthFlags & 0x40) != 0 && mobiHeaderLength > 0) {
      final int exthStart = 16 + mobiHeaderLength;
      if (record0.length >= exthStart + 12 &&
          record0[exthStart] == 0x45 &&
          record0[exthStart + 1] == 0x58 &&
          record0[exthStart + 2] == 0x54 &&
          record0[exthStart + 3] == 0x48) {
        final ByteData exthData = ByteData.sublistView(record0, exthStart);
        final int exthCount = exthData.getUint32(8, Endian.big);
        int pos = exthStart + 12;

        for (int i = 0; i < exthCount; i++) {
          if (pos + 8 > record0.length) break;
          final int rType = r0Data.getUint32(pos, Endian.big);
          final int rLen = r0Data.getUint32(pos + 4, Endian.big);
          if (rLen < 8 || pos + rLen > record0.length) break;

          final recordPayload = record0.sublist(pos + 8, pos + rLen);
          final String strVal = utf8.decode(recordPayload, allowMalformed: true);

          switch (rType) {
            case 100:
              if (strVal.trim().isNotEmpty) author = strVal.trim();
              break;
            case 101:
              if (strVal.trim().isNotEmpty) publisher = strVal.trim();
              break;
            case 103:
              description = strVal.trim();
              break;
            case 106:
              publishDate = strVal.trim();
              break;
            case 201:
              if (recordPayload.length >= 4) {
                coverOffset = ByteData.sublistView(recordPayload).getUint32(0, Endian.big);
              }
              break;
            case 503:
              if (strVal.trim().isNotEmpty) mobiTitle = strVal.trim();
              break;
          }
          pos += rLen;
        }
      }
    }

    // Haetaan kansikuva
    Uint8List? coverBytes;
    String coverMime = 'image/jpeg';
    if (coverOffset != null && firstImageIndex > 0) {
      final int coverRecIndex = firstImageIndex + coverOffset;
      if (coverRecIndex < numRecords) {
        final int cOffset = data.getUint32(78 + (coverRecIndex * 8), Endian.big);
        final int cNext = coverRecIndex + 1 < numRecords
            ? data.getUint32(78 + ((coverRecIndex + 1) * 8), Endian.big)
            : mobiBytes.length;
        if (cOffset < cNext && cNext <= mobiBytes.length) {
          final cBytes = mobiBytes.sublist(cOffset, cNext);
          final mime = _tunnistaKuvaMime(cBytes);
          if (mime != null) {
            coverBytes = cBytes;
            coverMime = mime;
          }
        }
      }
    }

    return MobiMetadata(
      title: TextEncodingHelper.korjaaMerkistovirheet(mobiTitle),
      author: TextEncodingHelper.korjaaMerkistovirheet(author),
      publisher: TextEncodingHelper.korjaaMerkistovirheet(publisher),
      description: description,
      publishDate: publishDate,
      coverBytes: coverBytes,
      coverMimeType: coverMime,
    );
  }

  /// Noutaa tietueen sisällön
  static Uint8List _haeTietue(Uint8List mobiBytes, List<_PdbRecord> records, int index) {
    if (index >= records.length) return Uint8List(0);
    final int start = records[index].offset;
    final int end = (index + 1 < records.length) ? records[index + 1].offset : mobiBytes.length;
    if (start >= end || end > mobiBytes.length) return Uint8List(0);
    return mobiBytes.sublist(start, end);
  }

  /// Laskee poistettavat trailing data -tavut
  static int _laskeTrailingBytes(Uint8List recordData, int extraFlags) {
    if (extraFlags == 0 || recordData.isEmpty) return 0;
    int pos = recordData.length;

    for (int bit = 1; bit < 16; bit++) {
      if ((extraFlags & (1 << bit)) != 0) {
        if (pos <= 0) break;
        int vSize = 0;
        int shift = 0;
        while (pos > 0) {
          int b = recordData[--pos];
          vSize |= (b & 0x7F) << shift;
          shift += 7;
          if ((b & 0x80) != 0 || shift >= 28) break;
        }
        pos -= (vSize - (shift ~/ 7));
        if (pos < 0) {
          pos = 0;
          break;
        }
      }
    }

    if ((extraFlags & 1) != 0 && pos > 0) {
      int b = recordData[--pos];
      int mbCount = b & 3;
      pos -= mbCount;
      if (pos < 0) pos = 0;
    }

    return recordData.length - pos;
  }

  /// PalmDOC LZ77 -pakkauksen purkaja
  static List<int> _puraPalmDocLz77(Uint8List data) {
    final List<int> out = [];
    int i = 0;
    while (i < data.length) {
      final int b = data[i++];
      if (b >= 1 && b <= 8) {
        // 1..8 literaalitavua
        for (int k = 0; k < b && i < data.length; k++) {
          out.add(data[i++]);
        }
      } else if (b < 128) {
        // b == 0 tai 9..127: yksi literaalitavu
        out.add(b);
      } else if (b >= 192) {
        // 192..255: välilyönti + merkki
        out.add(32); // ' '
        out.add(b ^ 0x80);
      } else {
        // 128..191: etäisyys & pituus
        if (i >= data.length) break;
        final int b2 = data[i++];
        final int distance = ((b & 0x07) << 8) | b2;
        final int length = ((b >> 3) & 0x1F) + 3;
        final int start = out.length - distance;
        for (int k = 0; k < length; k++) {
          if (start + k >= 0 && start + k < out.length) {
            out.add(out[start + k]);
          }
        }
      }
    }
    return out;
  }

  /// Tunnistaa kuvatiedoston tyypin tiedoston alun perusteella
  static String? _tunnistaKuvaMime(Uint8List bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return 'image/gif';
    }
    return null;
  }

  /// Korvaa MOBI-kuvatagit standardeiksi HTML-kuvatageiksi
  static String _korjaaKuvaTagit(String html, int firstImageIndex, Map<int, _MobiImage> kuvat) {
    // 1. Korvataan <img recindex="1" /> tai <image recindex="0001" />
    final regRecindex = RegExp(r'<(?:img|image)[^>]*recindex="0*([0-9]+)"[^>]*>', caseSensitive: false);
    String result = html.replaceAllMapped(regRecindex, (match) {
      final int? recNo = int.tryParse(match.group(1) ?? '');
      if (recNo != null) {
        final int targetRecord = firstImageIndex + recNo - 1;
        final img = kuvat[targetRecord];
        if (img != null) {
          return '<p style="text-align: center;"><img src="images/${img.filename}" alt="Kuva" /></p>';
        }
      }
      return '';
    });

    // 2. Poistetaan mobipocket-erikoistagit kuten <mbp:frameset>
    result = result.replaceAll(RegExp(r'</?mbp:[^>]*>', caseSensitive: false), '');

    return result;
  }

  /// Jakaa puretun tekstin lukukappaleiksi (chapter_1.xhtml jne.)
  static List<String> _jaaKappaleisiin(String html, String bookTitle) {
    // Jaetaan ensisijaisesti sivunvaihtojen perusteella
    List<String> rawParts = html.split(RegExp(r'<mbp:pagebreak\s*/?>|<div\s+class="pagebreak"\s*/?>', caseSensitive: false));

    // Jos sivunvaihtoja ei löytynyt, kokeillaan otsikkotageja <h1> tai <h2>
    if (rawParts.length <= 1) {
      final hSplit = html.split(RegExp(r'(?=<h[12][^>]*>)', caseSensitive: false));
      if (hSplit.length > 1) {
        rawParts = hSplit;
      }
    }

    // Jos kyseessä on edelleen yksi jättimäinen teksti (> 40 KB), jaetaan kappaleiden välistä
    if (rawParts.length <= 1 && html.length > 40000) {
      final pSplit = html.split('</p>');
      List<String> chunkit = [];
      StringBuffer sb = StringBuffer();
      for (var p in pSplit) {
        sb.write(p);
        sb.write('</p>');
        if (sb.length > 25000) {
          chunkit.add(sb.toString());
          sb.clear();
        }
      }
      if (sb.isNotEmpty) chunkit.add(sb.toString());
      if (chunkit.isNotEmpty) rawParts = chunkit;
    }

    final List<String> validKappaleet = [];
    for (var part in rawParts) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) {
        validKappaleet.add(trimmed);
      }
    }

    if (validKappaleet.isEmpty) {
      validKappaleet.add('<p>${html.isEmpty ? 'Ei tekstiä' : html}</p>');
    }

    return validKappaleet;
  }

  /// Kokoaa standardin EPUB (ZIP) -tiedoston
  static Uint8List _rakennaEpub({
    required String title,
    required String author,
    required String publisher,
    required String description,
    required String publishDate,
    required List<String> kappaleet,
    required List<_MobiImage> kuvat,
    _MobiImage? kansiKuva,
  }) {
    final archive = Archive();

    // 1. mimetype (TÄYTYY OLLA ENSIMMÄINEN JA PAKKAAMATON!)
    final mimetypeBytes = utf8.encode('application/epub+zip');
    archive.addFile(ArchiveFile.noCompress('mimetype', mimetypeBytes.length, mimetypeBytes));

    // 2. META-INF/container.xml
    const containerXml = '''<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
    final containerBytes = utf8.encode(containerXml);
    archive.addFile(ArchiveFile('META-INF/container.xml', containerBytes.length, containerBytes));

    // 3. Lukukappaleet (OEBPS/chapter_1.xhtml jne.)
    final List<String> chapterFiles = [];
    for (int i = 0; i < kappaleet.length; i++) {
      final chapterFileName = 'chapter_${i + 1}.xhtml';
      chapterFiles.add(chapterFileName);

      final chapterHtml = '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>${_htmlEscape(title)}</title>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <style type="text/css">
    body { margin: 4%; text-align: justify; font-size: 1.05em; line-height: 1.5; }
    p { margin-bottom: 0.8em; text-indent: 1em; }
    img { max-width: 100%; height: auto; display: block; margin: 1em auto; }
    h1, h2, h3 { text-align: center; margin-top: 1.2em; margin-bottom: 0.8em; }
  </style>
</head>
<body>
  ${kappaleet[i]}
</body>
</html>''';

      final chBytes = utf8.encode(chapterHtml);
      archive.addFile(ArchiveFile('OEBPS/$chapterFileName', chBytes.length, chBytes));
    }

    // 4. Kuvat (OEBPS/images/...)
    for (var img in kuvat) {
      archive.addFile(ArchiveFile('OEBPS/images/${img.filename}', img.bytes.length, img.bytes));
    }

    // 5. OEBPS/content.opf
    final opfBuffer = StringBuffer();
    opfBuffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    opfBuffer.writeln('<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">');
    opfBuffer.writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">');
    opfBuffer.writeln('    <dc:title>${_htmlEscape(title)}</dc:title>');
    opfBuffer.writeln('    <dc:creator>${_htmlEscape(author)}</dc:creator>');
    opfBuffer.writeln('    <dc:publisher>${_htmlEscape(publisher)}</dc:publisher>');
    if (description.isNotEmpty) {
      opfBuffer.writeln('    <dc:description>${_htmlEscape(description)}</dc:description>');
    }
    if (publishDate.isNotEmpty) {
      opfBuffer.writeln('    <dc:date>${_htmlEscape(publishDate)}</dc:date>');
    }
    opfBuffer.writeln('    <dc:language>fi</dc:language>');
    opfBuffer.writeln('    <dc:identifier id="BookId">urn:uuid:${DateTime.now().millisecondsSinceEpoch}</dc:identifier>');
    if (kansiKuva != null) {
      opfBuffer.writeln('    <meta name="cover" content="cover-image"/>');
    }
    opfBuffer.writeln('  </metadata>');
    opfBuffer.writeln('  <manifest>');
    opfBuffer.writeln('    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>');

    // Manifest: kappaleet
    for (int i = 0; i < chapterFiles.length; i++) {
      opfBuffer.writeln('    <item id="chapter_${i + 1}" href="${chapterFiles[i]}" media-type="application/xhtml+xml"/>');
    }

    // Manifest: kuvat
    for (int i = 0; i < kuvat.length; i++) {
      final img = kuvat[i];
      final isCover = (kansiKuva != null && img.filename == kansiKuva.filename);
      final id = isCover ? 'cover-image' : 'img_${i + 1}';
      opfBuffer.writeln('    <item id="$id" href="images/${img.filename}" media-type="${img.mimeType}"/>');
    }
    opfBuffer.writeln('  </manifest>');

    // Spine
    opfBuffer.writeln('  <spine toc="ncx">');
    for (int i = 0; i < chapterFiles.length; i++) {
      opfBuffer.writeln('    <itemref idref="chapter_${i + 1}"/>');
    }
    opfBuffer.writeln('  </spine>');
    opfBuffer.writeln('</package>');

    final opfBytes = utf8.encode(opfBuffer.toString());
    archive.addFile(ArchiveFile('OEBPS/content.opf', opfBytes.length, opfBytes));

    // 6. OEBPS/toc.ncx
    final ncxBuffer = StringBuffer();
    ncxBuffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    ncxBuffer.writeln('<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">');
    ncxBuffer.writeln('  <head>');
    ncxBuffer.writeln('    <meta name="dtb:uid" content="urn:uuid:${DateTime.now().millisecondsSinceEpoch}"/>');
    ncxBuffer.writeln('    <meta name="dtb:depth" content="1"/>');
    ncxBuffer.writeln('    <meta name="dtb:totalPageCount" content="0"/>');
    ncxBuffer.writeln('    <meta name="dtb:maxPageNumber" content="0"/>');
    ncxBuffer.writeln('  </head>');
    ncxBuffer.writeln('  <docTitle><text>${_htmlEscape(title)}</text></docTitle>');
    ncxBuffer.writeln('  <navMap>');
    for (int i = 0; i < chapterFiles.length; i++) {
      ncxBuffer.writeln('    <navPoint id="navPoint-${i + 1}" playOrder="${i + 1}">');
      ncxBuffer.writeln('      <navLabel><text>Osa ${i + 1}</text></navLabel>');
      ncxBuffer.writeln('      <content src="${chapterFiles[i]}"/>');
      ncxBuffer.writeln('    </navPoint>');
    }
    ncxBuffer.writeln('  </navMap>');
    ncxBuffer.writeln('</ncx>');

    final ncxBytes = utf8.encode(ncxBuffer.toString());
    archive.addFile(ArchiveFile('OEBPS/toc.ncx', ncxBytes.length, ncxBytes));

    // Pakataan ZIP
    final zipEncoder = ZipEncoder();
    final List<int> encoded = zipEncoder.encode(archive);
    return Uint8List.fromList(encoded);
  }

  static String _htmlEscape(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
