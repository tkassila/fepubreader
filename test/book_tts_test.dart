import 'package:flutter_test/flutter_test.dart';
import 'package:fepubreader/util/book_tts_service.dart';

void main() {
  group('BookTtsService tekstin esikäsittely puhetta varten', () {
    test('korvaa taulukot ilmoituksella taulukko ja tauoilla', () {
      const html = '''
        <p>Ennen taulukkoa tekstiä.</p>
        <table border="1">
          <tr><th>Otsikko 1</th><th>Otsikko 2</th></tr>
          <tr><td>Data 1</td><td>Data 2</td></tr>
        </table>
        <p>Taulukon jälkeinen teksti.</p>
      ''';

      final puheTeksti = BookTtsService.valmisteleTekstiPuheeksi(html);

      expect(puheTeksti, contains('taulukko'));
      expect(puheTeksti, isNot(contains('Otsikko 1')));
      expect(puheTeksti, isNot(contains('Data 1')));
      expect(puheTeksti, contains('Ennen taulukkoa'));
      expect(puheTeksti, contains('Taulukon jälkeinen'));
    });

    test('korvaa kuvat ilmoituksella kuva ja tauoilla', () {
      const html = '''
        <p>Tässä on kappale.</p>
        <img src="images/kuva1.jpg" alt="Maisema" />
        <p>Jatkuu kuvan jälkeen.</p>
      ''';

      final puheTeksti = BookTtsService.valmisteleTekstiPuheeksi(html);

      expect(puheTeksti, contains('kuva'));
      expect(puheTeksti, isNot(contains('images/kuva1.jpg')));
      expect(puheTeksti, contains('Tässä on kappale'));
      expect(puheTeksti, contains('Jatkuu kuvan jälkeen'));
    });

    test('korjaa entiteetit ja merkit', () {
      const html = '<p>T&auml;m&auml; on testi &amp; esimerkki.</p>';
      final puheTeksti = BookTtsService.valmisteleTekstiPuheeksi(html);
      expect(puheTeksti, contains('Tämä on testi & esimerkki'));
    });
  });

  group('BookTtsService tekstin pätkintä (chunking)', () {
    test('palauttaa tyhjän listan tyhjälle tekstille', () {
      final chunks = BookTtsService.jaaTekstiOsiin('');
      expect(chunks, isEmpty);
    });

    test('palauttaa yhden osan lyhyelle tekstille', () {
      const teksti = 'Tämä on lyhyt lause.';
      final chunks = BookTtsService.jaaTekstiOsiin(teksti, maxChunkLength: 100);
      expect(chunks.length, equals(1));
      expect(chunks[0].text, equals(teksti));
      expect(chunks[0].startOffset, equals(0));
      expect(chunks[0].endOffset, equals(teksti.length));
    });

    test('jakaa pitkän tekstin luonnollisiin lauserajoihin alle maksimipituuden', () {
      final lause1 = 'Ensimmäinen lause on tässä. ';
      final lause2 = 'Toinen lause jatkaa tarinaa. ';
      final lause3 = 'Kolmas lause päättää kappaleen.';
      final pitkaTeksti = '$lause1$lause2$lause3';

      final chunks = BookTtsService.jaaTekstiOsiin(pitkaTeksti, maxChunkLength: 40);
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.text.length, lessThanOrEqualTo(40));
      }
      expect(chunks.first.text, contains('Ensimmäinen lause'));
      expect(chunks.last.text, contains('Kolmas lause'));
    });
  });

  group('BookTtsService kielen tunnistus (language detection)', () {
    test('tunnistaa suomenkielisen tekstin', () {
      const fi = 'Tämä on suomenkielinen kirja, jossa kerrotaan tarinaa ja se on mielenkiintoinen.';
      expect(BookTtsService.tunnistaTekstinKieli(fi), equals('fi-FI'));
    });

    test('tunnistaa englanninkielisen tekstin', () {
      const en = 'This is an English book with a great story and it was very interesting to read.';
      expect(BookTtsService.tunnistaTekstinKieli(en), equals('en-US'));
    });

    test('tunnistaa ruotsinkielisen tekstin', () {
      const sv = 'Detta är en svensk bok som handlar om ett stort äventyr och det var spännande.';
      expect(BookTtsService.tunnistaTekstinKieli(sv), equals('sv-SE'));
    });

    test('tunnistaa saksankielisen tekstin', () {
      const de = 'Dies ist ein deutsches Buch mit einer wunderbaren Geschichte und das ist schön.';
      expect(BookTtsService.tunnistaTekstinKieli(de), equals('de-DE'));
    });

    test('tunnistaa ranskankielisen tekstin', () {
      const fr = 'Ceci est un livre en français avec une histoire magnifique et il est très beau.';
      expect(BookTtsService.tunnistaTekstinKieli(fr), equals('fr-FR'));
    });

    test('tunnistaa espanjankielisen tekstin', () {
      const es = 'Este es un libro en español con una historia maravillosa y es muy bueno para leer.';
      expect(BookTtsService.tunnistaTekstinKieli(es), equals('es-ES'));
    });

    test('tunnistaa italiankielisen tekstin', () {
      const it = 'Questo è un libro in italiano con una bellissima storia ed è molto interessante.';
      expect(BookTtsService.tunnistaTekstinKieli(it), equals('it-IT'));
    });
  });

  group('BookTtsService lauseen alun etsintä (pause -> jatka)', () {
    test('palauttaa pysäytyssanan lauseen alun keskeltä tekstiä', () {
      const teksti = 'Ensimmäinen lause päättyy tähän. Toinen lause alkaa tästä ja jatkuu pitkään. Kolmas lause.';
      final sananOffset = teksti.indexOf('jatkuu');
      final lauseenAlku = BookTtsService.etsiLauseenTaiSananAlku(teksti, sananOffset);

      expect(teksti.substring(lauseenAlku), startsWith('Toinen lause alkaa'));
    });

    test('palauttaa tekstin ensimmäisen lauseen alun, kun pysäytys on ensimmäisessä lauseessa', () {
      const teksti = 'Ensimmäinen lause on tässä kesken. Toinen lause.';
      final sananOffset = teksti.indexOf('kesken');
      final lauseenAlku = BookTtsService.etsiLauseenTaiSananAlku(teksti, sananOffset);

      expect(lauseenAlku, equals(0));
      expect(teksti.substring(lauseenAlku), startsWith('Ensimmäinen lause'));
    });

    test('palauttaa pysäytyssanan alun, jos lauserajaa ei ole kohtuullisella etäisyydellä', () {
      final pitkaListaIlmanPisteita = List.generate(40, (i) => 'sana$i').join(' ');
      final kohdeSana = 'sana35';
      final sananOffset = pitkaListaIlmanPisteita.indexOf(kohdeSana);

      final tulos = BookTtsService.etsiLauseenTaiSananAlku(
        pitkaListaIlmanPisteita,
        sananOffset,
        maxEtsintaMatka: 30,
      );

      expect(tulos, equals(sananOffset));
      expect(pitkaListaIlmanPisteita.substring(tulos), startsWith('sana35'));
    });

    test('palauttaa suoraan pysäytyssanan alun, kun jatketaan pysäytyssanasta', () {
      const teksti = 'Ensimmäinen lause päättyy tähän. Toinen lause alkaa tästä ja jatkuu pitkään.';
      final sananOffset = teksti.indexOf('jatkuu');
      // Testataan sekä suoraan sanan alusta että sanan keskeltä
      expect(
        teksti.substring(BookTtsService.etsiPysaytyssananAlku(teksti, sananOffset)),
        startsWith('jatkuu pitkään.'),
      );
      expect(
        teksti.substring(BookTtsService.etsiPysaytyssananAlku(teksti, sananOffset + 3)),
        startsWith('jatkuu pitkään.'),
      );
    });

    test('muotoilee puhenopeuden selkeästi', () {
      expect(BookTtsService.muotoilePuhenopeus(0.5), equals('1.0x (100%)'));
      expect(BookTtsService.muotoilePuhenopeus(0.75), equals('1.5x (150%)'));
      expect(BookTtsService.muotoilePuhenopeus(0.25), equals('0.5x (50%)'));
    });

    test('laskee 3 sanaa taaksepäin ja 3 sanaa eteenpäin oikein', () {
      const teksti = 'Yksi kaksi kolme . \n neljä viisi kuusi seitsemän kahdeksan';
      final viisiOffset = teksti.indexOf('viisi');

      final taaksepain = BookTtsService.laskeSanaSiirtyma(teksti, viisiOffset, -3);
      expect(taaksepain, isNotNull);
      expect(taaksepain!.word, equals('kaksi'));
      expect(teksti.substring(taaksepain.start), startsWith('kaksi kolme'));

      final eteenpain = BookTtsService.laskeSanaSiirtyma(teksti, viisiOffset, 3);
      expect(eteenpain, isNotNull);
      expect(eteenpain!.word, equals('kahdeksan'));
      expect(teksti.substring(eteenpain.start), startsWith('kahdeksan'));
    });
  });
}
