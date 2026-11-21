import 'dart:convert';

/// Apuluokka metatietojen merkistövirheiden (Mojibake, UTF-16BE, PDF-oktaalit, HTML-entiteetit) korjaamiseen.
class TextEncodingHelper {
  /// Korjaa tekstin merkistövirheet monipuolisesti:
  /// - Poistaa UTF-16BE BOM-merkit (\uFEFF, þÿ) ja tulkkaa UTF-16BE tavut
  /// - Poistaa tyhjät null-merkit (\x00)
  /// - Purkaa HTML-entiteetit (&auml;, &#228;, &amp; jne.)
  /// - Korjaa UTF-8 Mojibake -merkit (Ã¤ -> ä, Ã¶ -> ö, Ã¥ -> å jne.)
  static String korjaaMerkistovirheet(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';

    String text = raw.trim();

    // 1. Karsitaan alusta ja lopusta lainausmerkit
    if ((text.startsWith('"') && text.endsWith('"')) || (text.startsWith("'") && text.endsWith("'"))) {
      if (text.length >= 2) {
        text = text.substring(1, text.length - 1).trim();
      }
    }

    // 2. Jos teksti alkaa UTF-16BE BOM:lla (þÿ tai \uFEFF)
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1);
    } else if (text.startsWith('þÿ') ||
        (text.length >= 2 && text.codeUnitAt(0) == 0xFE && text.codeUnitAt(1) == 0xFF)) {
      try {
        final codeUnits = <int>[];
        for (int i = 2; i + 1 < text.length; i += 2) {
          final hi = text.codeUnitAt(i) & 0xFF;
          final lo = text.codeUnitAt(i + 1) & 0xFF;
          codeUnits.add((hi << 8) | lo);
        }
        text = String.fromCharCodes(codeUnits);
      } catch (_) {
        text = text.replaceFirst('þÿ', '');
      }
    }

    // 3. Poistetaan haitalliset null-merkit
    if (text.contains('\x00')) {
      text = text.replaceAll('\x00', '');
    }

    // 4. Puretaan HTML-entiteetit (yleisiä EPUB-metatiedoissa)
    text = puraHtmlEntiteetit(text);

    // 5. Korjataan UTF-8 Mojibake (kun UTF-8 on luettu vahingossa Latin1 / Windows-1252:na)
    text = korjaaMojibake(text);

    // Siistitään ylimääräiset moninkertaiset välilyönnit ja rivinvaihdot
    text = text.replaceAll(RegExp(r'\s+'), ' ');

    return text.trim();
  }

  /// Korjaa UTF-8 Mojibake -merkistövirheet
  static String korjaaMojibake(String text) {
    if (!text.contains('Ã') && !text.contains('Â') && !text.contains('â€')) {
      return text;
    }

    // Yritetään ensin täyttä uudelleendekoodausta Latin1 -> UTF-8 turvallisesti ilman poikkeuksia
    try {
      if (text.codeUnits.every((c) => c <= 255)) {
        final decoded = utf8.decode(text.codeUnits, allowMalformed: false);
        if (decoded.isNotEmpty) {
          return decoded;
        }
      }
    } catch (_) {
      // Jos teksti sisältää sekaisin oikeita merkkejä ja mojibakea,
      // korvataan tunnetuimmat esiintymät alla
    }

    // Korvataan tunnetut suomen kielen ja pohjoismaiset Mojibake-parit
    return text
        .replaceAll('Ã¤', 'ä')
        .replaceAll('Ã¶', 'ö')
        .replaceAll('Ã¥', 'å')
        .replaceAll('Ã„', 'Ä')
        .replaceAll('Ã–', 'Ö')
        .replaceAll('Ã…', 'Å')
        .replaceAll('Ã©', 'é')
        .replaceAll('Ã¨', 'è')
        .replaceAll('Ã¼', 'ü')
        .replaceAll('Ãœ', 'Ü')
        .replaceAll('ÃŸ', 'ß')
        .replaceAll('â€“', '–')
        .replaceAll('â€”', '—')
        .replaceAll('â€™', '’')
        .replaceAll('â€œ', '“')
        .replaceAll('â€\u{9d}', '”')
        .replaceAll('â€¢', '•')
        .replaceAll('â€¦', '…')
        .replaceAll('Â ', ' ')
        .replaceAll('Â', '');
  }

  /// Purkaa HTML / XML -entiteetit tekstistä
  static String puraHtmlEntiteetit(String text) {
    if (!text.contains('&')) return text;

    String result = text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&auml;', 'ä')
        .replaceAll('&Auml;', 'Ä')
        .replaceAll('&ouml;', 'ö')
        .replaceAll('&Ouml;', 'Ö')
        .replaceAll('&aring;', 'å')
        .replaceAll('&Aring;', 'Å')
        .replaceAll('&eacute;', 'é')
        .replaceAll('&Eacute;', 'É')
        .replaceAll('&uuml;', 'ü')
        .replaceAll('&Uuml;', 'Ü')
        .replaceAll('&ndash;', '–')
        .replaceAll('&mdash;', '—')
        .replaceAll('&hellip;', '…');

    // Desimaalientiteetit: &#228; -> ä
    result = result.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final code = int.tryParse(match.group(1)!);
      if (code != null && code > 0 && code < 65536) {
        return String.fromCharCode(code);
      }
      return match.group(0)!;
    });

    // Heksadesimaalientiteetit: &#xE4; -> ä
    result = result.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
      final code = int.tryParse(match.group(1)!, radix: 16);
      if (code != null && code > 0 && code < 65536) {
        return String.fromCharCode(code);
      }
      return match.group(0)!;
    });

    return result;
  }

  /// PDFDocEncoding -erikoismerkkien kartoitus (ISO 32000-1 Annex D, Table D.2)
  static const Map<int, String> _pdfDocEncodingMap = {
    0x18: '\u02D8', // breve
    0x19: '\u02C7', // caron
    0x1A: '\u02C6', // circumflex
    0x1B: '\u02D9', // dotaccent
    0x1C: '\u02DD', // hungarumlaut
    0x1D: '\u02DB', // ogonek
    0x1E: '\u02DA', // ring
    0x1F: '\u02DC', // tilde
    0x80: '€',
    0x82: '‚',
    0x83: 'ƒ',
    0x84: '„',
    0x85: '…',
    0x86: '†',
    0x87: '‡',
    0x88: 'ˆ',
    0x89: '‰',
    0x8A: 'Š',
    0x8B: '‹',
    0x8C: 'Œ',
    0x8E: 'Ž',
    0x91: '‘',
    0x92: '’',
    0x93: '“',
    0x94: '”',
    0x95: '•',
    0x96: '–', // en-dash
    0x97: '—', // em-dash
    0x98: '˜',
    0x99: '™',
    0x9A: 'š',
    0x9B: '›',
    0x9C: 'œ',
    0x9E: 'ž',
    0x9F: 'Ÿ',
    0xA0: '€',
  };

  /// Purkaa PDF-spesifit merkkijonot (oktaalipaikat, heksadesimaalit, UTF-16BE BOM ja erikoismerkit)
  static String puraPdfMerkkijono(String raw) {
    if (raw.trim().isEmpty) return '';

    String cleaned = raw.trim();

    // 1. Poistetaan PDF-rivinjatkot (\ heti ennen rivinvaihtoa)
    cleaned = cleaned.replaceAll(RegExp(r'\\\r?\n'), '');

    // 2. Tarkistetaan onko kyseessä PDF-heksamerkkijono: <FEFF004B0069...> tai <4B6172707061>
    if (cleaned.startsWith('<') && cleaned.endsWith('>')) {
      var hex = cleaned.substring(1, cleaned.length - 1).replaceAll(RegExp(r'\s+'), '');
      if (hex.length % 2 != 0) {
        // PDF-standardi: pariton heksadesimaalijono täydennetään '0':lla lopusta
        hex += '0';
      }
      if (hex.isNotEmpty) {
        try {
          final bytes = <int>[];
          for (int i = 0; i < hex.length; i += 2) {
            bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
          }

          // UTF-16BE BOM:lla (<FEFF...>)
          if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
            final codeUnits = <int>[];
            for (int i = 2; i + 1 < bytes.length; i += 2) {
              codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
            }
            return korjaaMerkistovirheet(String.fromCharCodes(codeUnits));
          }

          // UTF-16BE ilman BOM:ia (vuorotellen nollatavu: esim. <004B0061...>)
          if (bytes.length >= 4 &&
              ((bytes[0] == 0 && bytes[2] == 0) || (bytes[1] == 0 && bytes[3] == 0))) {
            final isBE = bytes[0] == 0;
            final codeUnits = <int>[];
            for (int i = 0; i + 1 < bytes.length; i += 2) {
              codeUnits.add(isBE ? ((bytes[i] << 8) | bytes[i + 1]) : ((bytes[i + 1] << 8) | bytes[i]));
            }
            return korjaaMerkistovirheet(String.fromCharCodes(codeUnits));
          }

          // Yritetään UTF-8
          try {
            return korjaaMerkistovirheet(utf8.decode(bytes));
          } catch (_) {
            return korjaaMerkistovirheet(latin1.decode(bytes));
          }
        } catch (_) {}
      }
    }

    // 3. Puretaan PDF-oktaaliesitykset: \344 -> ä (228), \376\377 -> BOM jne.
    cleaned = cleaned.replaceAllMapped(RegExp(r'\\([0-7]{1,3})'), (m) {
      final octalStr = m.group(1)!;
      final charCode = int.parse(octalStr, radix: 8) & 0xFF;
      return String.fromCharCode(charCode);
    });

    // 4. Puretaan PDF-ohjausmerkit ja korvausmerkit
    cleaned = cleaned
        .replaceAll(r'\)', ')')
        .replaceAll(r'\(', '(')
        .replaceAll(r'\\', r'\')
        .replaceAll(r'\n', ' ')
        .replaceAll(r'\r', ' ')
        .replaceAll(r'\t', ' ')
        .replaceAll(r'\b', '')
        .replaceAll(r'\f', '');

    // 5. Tarkistetaan onko tekstissä UTF-16BE BOM (\uFEFF tai \xFE\xFF / þÿ)
    if (cleaned.length >= 2 &&
        (cleaned.startsWith('\uFEFF') ||
         (cleaned.codeUnitAt(0) == 0xFE && cleaned.codeUnitAt(1) == 0xFF))) {
      final start = cleaned.startsWith('\uFEFF') ? 1 : 2;
      final codeUnits = <int>[];
      for (int i = start; i + 1 < cleaned.length; i += 2) {
        final hi = cleaned.codeUnitAt(i) & 0xFF;
        final lo = cleaned.codeUnitAt(i + 1) & 0xFF;
        codeUnits.add((hi << 8) | lo);
      }
      return korjaaMerkistovirheet(String.fromCharCodes(codeUnits));
    }

    // 6. Tarkistetaan onko UTF-16BE ilman BOM:ia (nollatavut vuorotellen)
    if (cleaned.length >= 4 &&
        ((cleaned.codeUnitAt(0) == 0 && cleaned.codeUnitAt(2) == 0) ||
         (cleaned.codeUnitAt(1) == 0 && cleaned.codeUnitAt(3) == 0))) {
      final isBE = cleaned.codeUnitAt(0) == 0;
      final codeUnits = <int>[];
      for (int i = 0; i + 1 < cleaned.length; i += 2) {
        final c1 = cleaned.codeUnitAt(i) & 0xFF;
        final c2 = cleaned.codeUnitAt(i + 1) & 0xFF;
        codeUnits.add(isBE ? ((c1 << 8) | c2) : ((c2 << 8) | c1));
      }
      return korjaaMerkistovirheet(String.fromCharCodes(codeUnits));
    }

    // 7. Jos teksti on puhdasta UTF-8:aa tavuina (koodit 0..255)
    if (cleaned.codeUnits.any((c) => c > 127 && c <= 255)) {
      try {
        final bytes = cleaned.codeUnits.map((c) => c & 0xFF).toList();
        final decoded = utf8.decode(bytes, allowMalformed: false);
        if (decoded.isNotEmpty) {
          return korjaaMerkistovirheet(decoded);
        }
      } catch (_) {}
    }

    // 8. Sovelletaan PDFDocEncoding -erikoismerkkejä (0x80-0x9F, mm. ajatusviivat – ja —)
    final sb = StringBuffer();
    for (int i = 0; i < cleaned.length; i++) {
      final cu = cleaned.codeUnitAt(i);
      final mapped = _pdfDocEncodingMap[cu];
      if (mapped != null) {
        sb.write(mapped);
      } else {
        sb.writeCharCode(cu);
      }
    }
    cleaned = sb.toString();

    return korjaaMerkistovirheet(cleaned);
  }
}
