import 'package:flutter_test/flutter_test.dart';
import 'package:fepubreader/util/text_encoding_helper.dart';

void main() {
  group('TextEncodingHelper tests', () {
    test('korjaa UTF-8 mojibake (Ã¤ -> ä, Ã¶ -> ö jne.)', () {
      expect(TextEncodingHelper.korjaaMerkistovirheet('KÃ¤yttÃ¤jÃ¤n opas'), 'Käyttäjän opas');
      expect(TextEncodingHelper.korjaaMerkistovirheet('TÃ¶itÃ¤ ja elÃ¤mÃ¤Ã¤'), 'Töitä ja elämää');
      expect(TextEncodingHelper.korjaaMerkistovirheet('Ã„iti ja Ã–ljy'), 'Äiti ja Öljy');
      expect(TextEncodingHelper.korjaaMerkistovirheet('PÃ¥ svenska'), 'På svenska');
    });

    test('korjaa HTML entiteetit (&auml;, &#228;, &amp;)', () {
      expect(TextEncodingHelper.korjaaMerkistovirheet('K&auml;ytt&auml;j&auml; &amp; yst&auml;v&auml;t'), 'Käyttäjä & ystävät');
      expect(TextEncodingHelper.korjaaMerkistovirheet('M&#246;kki'), 'Mökki');
      expect(TextEncodingHelper.korjaaMerkistovirheet('&#x00E4;kki&#xE4;'), 'äkkiä');
    });

    test('purkaa PDF oktaalipaoitukset', () {
      // \344 = ä, \366 = ö
      expect(TextEncodingHelper.puraPdfMerkkijono(r'K\344ytt\344j\344'), 'Käyttäjä');
      expect(TextEncodingHelper.puraPdfMerkkijono(r'T\366it\344'), 'Töitä');
    });

    test('purkaa PDF-tekstit suluilla ja PDFDocEncoding-viivoilla', () {
      // \226 = en-dash (–) PDFDocEncodingissa
      expect(TextEncodingHelper.puraPdfMerkkijono(r'Mika Waltari \226 Sinuhe (osa 1)'), 'Mika Waltari – Sinuhe (osa 1)');
      expect(TextEncodingHelper.puraPdfMerkkijono(r'Otsikko \(sulkeissa\)'), 'Otsikko (sulkeissa)');
    });

    test('purkaa PDF heksamerkkijonon UTF-16BE BOM:lla ja ilman', () {
      // FEFF004B00E400790074007400E4006A00E4 = "Käyttäjä"
      expect(TextEncodingHelper.puraPdfMerkkijono('<FEFF004B00E400790074007400E4006A00E4>'), 'Käyttäjä');
      // Ilman BOM:ia
      expect(TextEncodingHelper.puraPdfMerkkijono('<004B00E400790074007400E4006A00E4>'), 'Käyttäjä');
    });

    test('purkaa PDF-rivinjatkon (backslash + newline)', () {
      expect(TextEncodingHelper.puraPdfMerkkijono("Ensimmäinen osa \\\nToinen osa"), 'Ensimmäinen osa Toinen osa');
    });

    test('purkaa UTF-16BE BOM:lla varustetun literaalin (þÿ)', () {
      // þÿ + UTF-16BE tavut
      final bomLiteral = 'þÿ\x00K\x00ä\x00y\x00t\x00t\x00ä\x00j\x00ä';
      expect(TextEncodingHelper.korjaaMerkistovirheet(bomLiteral), 'Käyttäjä');
    });

    test('poistaa nollatavut ja siistii ylimääräiset välilyönnit', () {
      expect(TextEncodingHelper.korjaaMerkistovirheet('K\x00i\x00r\x00j\x00a   1  '), 'Kirja 1');
    });

    test('metaotsikon siistiminen poistaa turhat rivinvaihdot ja moninkertaiset välilyönnit', () {
      final input = "   Mika   Waltari:\nSinuhe   egyptiläinen  \n ";
      final clean = input.trim().replaceAll(RegExp(r'\s+'), ' ');
      expect(clean, 'Mika Waltari: Sinuhe egyptiläinen');
    });
  });
}
