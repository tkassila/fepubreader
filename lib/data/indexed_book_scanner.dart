import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pdf_thumbnail/pdf_thumbnail.dart';
import 'package:epubx/epubx.dart';

import 'dart:convert'; // Tarjoaa: utf8
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import '../data/book_model.dart';

class IndexedBook {
  final String title;
  final String path;
  final bool isPdf;
  final String thumbnailPath;
  int lastReadPage;
  int lastReadTimestamp;
  int fileModifiedTimestamp; // UUSI: Tiedoston muokkausaika (Import-aika)
  String publishDateText;     // UUSI: Kirjan sisäinen julkaisuaika metadatasta

  IndexedBook({
    required this.title,
    required this.path,
    required this.isPdf,
    required this.thumbnailPath,
    this.lastReadPage = 1,
    this.lastReadTimestamp = 0,
    this.fileModifiedTimestamp = 0, // Oletus 0
    this.publishDateText = 'Tuntematon', // Oletus
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'path': path,
    'isPdf': isPdf,
    'thumbnailPath': thumbnailPath,
    'lastReadPage': lastReadPage,
    'lastReadTimestamp': lastReadTimestamp,
    'fileModifiedTimestamp': fileModifiedTimestamp,
    'publishDateText': publishDateText,
  };

  factory IndexedBook.fromJson(Map<String, dynamic> json) => IndexedBook(
    title: json['title'],
    path: json['path'],
    isPdf: json['isPdf'],
    thumbnailPath: json['thumbnailPath'],
    lastReadPage: json['lastReadPage'] ?? 1,
    lastReadTimestamp: json['lastReadTimestamp'] ?? 0,
    fileModifiedTimestamp: json['fileModifiedTimestamp'] ?? 0,
    publishDateText: json['publishDateText'] ?? 'Tuntematon',
  );
}

class IndexedBookScanner {
  // Luodaan tiedostopolusta uniikki MD5-tunniste kuvan nimeksi
  static String _getCacheKey(String filePath) {
    return md5.convert(utf8.encode(filePath)).toString();
  }

  // Lukee indeksitiedoston (JSON) sisällön levyltä
  static Future<List<IndexedBook>> _lueIndeksi() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final indeksiTiedosto = File('${docDir.path}/kirja_indeksi.json');
      if (!await indeksiTiedosto.exists()) return [];

      final String sisalto = await indeksiTiedosto.readAsString();
      final List<dynamic> jsonLista = jsonDecode(sisalto);
      return jsonLista.map((item) => IndexedBook.fromJson(item)).toList();
    } catch (e) {
      return [];
    }
  }

  // Tallentaa indeksin takaisin levylle
  static Future<void> _tallennaIndeksi(List<IndexedBook> kirjat) async {
    final docDir = await getApplicationDocumentsDirectory();
    final indeksiTiedosto = File('${docDir.path}/kirja_indeksi.json');
    final String jsonSisalto = jsonEncode(kirjat.map((k) => k.toJson()).toList());
    await indeksiTiedosto.writeAsString(jsonSisalto);
  }

  // Haetaan kirjalista nopeasti välimuistista
  static Future<List<IndexedBook>> haeKirjat(String kirjakansioPolku) async {
    List<IndexedBook> indeksi = await _lueIndeksi();
    if (indeksi.isNotEmpty) {
      indeksi.sort((a, b) {
        if (b.lastReadTimestamp == a.lastReadTimestamp) {
          return a.title.compareTo(b.title);
        }
        return b.lastReadTimestamp.compareTo(a.lastReadTimestamp);
      });
      return indeksi;
    }
    return odotaUudelleenSkannaus(kirjakansioPolku);
  }

  // Päivittää yksittäisen kirjan sivun ja aikaleiman lennosta
  static Future<void> paivitaLukutilanne(String tiedostoPolku, int sivu) async {
    List<IndexedBook> nykyisetKirjat = await _lueIndeksi();
    int indeksi = nykyisetKirjat.indexWhere((k) => k.path == tiedostoPolku);

    if (indeksi != -1) {
      nykyisetKirjat[indeksi].lastReadPage = sivu;
      nykyisetKirjat[indeksi].lastReadTimestamp = DateTime.now().millisecondsSinceEpoch;
      await _tallennaIndeksi(nykyisetKirjat);
    }
  }

  // Älykäs taustamuutosten tarkistus
  static Future<bool> tarkistaMuutoksetTaustalla(String kirjakansioPolku, List<IndexedBook> nykyinenIndeksi) async {
    final dir = Directory(kirjakansioPolku);
    if (!await dir.exists()) return false;

    // Haetaan kaikki kansiossa parhaillaan olevat tiedostopolut
    final List<FileSystemEntity> entities = dir.listSync(recursive: false);
    final List<String> tiedostotLevylla = entities
        .where((e) => e is File && (p.extension(e.path).toLowerCase() == '.pdf' || p.extension(e.path).toLowerCase() == '.epub'))
        .map((e) => e.path)
        .toList();

    // Haetaan indeksissä olevat tiedostopolut
    final List<String> tiedostotIndeksissa = nykyinenIndeksi.map((k) => k.path).toList();

    if (tiedostotLevylla.length != tiedostotIndeksissa.length) {
      return true;
    }

    // Tarkistetaan täsmäävätkö kaikki tiedostopolut
    for (String polku in tiedostotLevylla) {
      if (!tiedostotIndeksissa.contains(polku)) {
        return true; // Löytyi uusi tiedosto, jota ei ole indeksissä
      }
    }

    return false; // Kaikki täsmää, ei muutoksia
  }

  // Täysi hakemiston skannaus ja esikatselukuvien generointi
  static Future<List<IndexedBook>> odotaUudelleenSkannaus(String kirjakansioPolku) async {
    List<IndexedBook> vanhaIndeksi = await _lueIndeksi();
    List<IndexedBook> uusiLista = [];

    final dir = Directory(kirjakansioPolku);
    if (!await dir.exists()) return [];

    final cacheDir = await getTemporaryDirectory(); // Välimuistikansio kuville
    List<FileSystemEntity> entities = dir.listSync(recursive: false);

    for (var entity in entities) {
      if (entity is File) {
        String ext = p.extension(entity.path).toLowerCase();
        if (ext == '.pdf' || ext == '.epub') {
          String title = p.basenameWithoutExtension(entity.path);
          String kuvaNimi = '${_getCacheKey(entity.path)}.png';
          String kuvaPolku = '${cacheDir.path}/$kuvaNimi';
          File kuvaTiedosto = File(kuvaPolku);

          int muokkausaika = entity.statSync().modified.millisecondsSinceEpoch;

          final vanhaKirja = vanhaIndeksi.firstWhere((k) => k.path == entity.path,
              orElse: () => IndexedBook(title: title, path: entity.path, isPdf: ext == '.pdf', thumbnailPath: '')
          );

          String julkaisuPaiva = vanhaKirja.publishDateText;

          if (julkaisuPaiva == 'Tuntematon') {
            try {
              if (ext == '.epub') {
                List<int> epubTavut = await entity.readAsBytes();
                EpubBook epub = await EpubReader.readBook(epubTavut);
                var dates = epub.Schema?.Package?.Metadata?.Dates;
                if (dates != null && dates.isNotEmpty) {
                  julkaisuPaiva = dates.first.Date ?? 'Tuntematon';
                }
              } else {
                julkaisuPaiva = entity.statSync().modified.year.toString();
              }
            } catch (e) {
              julkaisuPaiva = 'Tuntematon';
            }
          }

          if (!await kuvaTiedosto.exists()) {
            try {
              if (ext == '.pdf') {
                // Generoidaan PDF-thumbnail pdf_thumbnail pluginilla
                await PdfThumbnail.fromFile(
                  entity.path,
                  currentPage: 1,
                  height: 200,
                  backgroundColor: Colors.white10,
                );
              } else {
                Uint8List? tavut;
                List<int> epubTavut = await entity.readAsBytes();
                EpubBook epub = await EpubReader.readBook(epubTavut);
                if (epub.CoverImage != null) {
                  tavut = Uint8List.fromList(epub.CoverImage! as List<int>);
                }
                if (tavut != null) {
                  await kuvaTiedosto.writeAsBytes(tavut);
                }
              }
            } catch (e) {
              print("Virhe thumbnailin luonnissa ($title): $e");
            }
          }

          uusiLista.add(IndexedBook(
            title: title,
            path: entity.path,
            thumbnailPath: kuvaTiedosto.existsSync() ? kuvaPolku : '',
            lastReadPage: vanhaKirja.lastReadPage,
            lastReadTimestamp: vanhaKirja.lastReadTimestamp,
            fileModifiedTimestamp: muokkausaika,
            publishDateText: julkaisuPaiva,
            isPdf: ext == '.pdf',
          ));
        }
      }
    }

    await _tallennaIndeksi(uusiLista);
    return uusiLista;
  }
}
