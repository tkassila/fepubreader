import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:epub_plus/epub_plus.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import '../util/mobi_to_epub_converter.dart';
import '../util/screen_wake_helper.dart';
import '../util/text_encoding_helper.dart';

/// Reaaliaikainen tapahtuma kirjahyllyn taustaskannauksesta.
class BookScanEvent {
  final List<IndexedBook> books;
  final IndexedBook? latestScannedBook;
  final int current;
  final int total;
  final String currentBookName;
  final String statusText;
  final bool isScanning;

  const BookScanEvent({
    required this.books,
    this.latestScannedBook,
    required this.current,
    required this.total,
    required this.currentBookName,
    required this.statusText,
    required this.isScanning,
  });

  double get progressRatio => total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;
  int get progressPercent => (progressRatio * 100).toInt();
}

class _EpubScanRequest {
  final String filePath;
  final String kuvaPolku;
  final bool pitaaPaivittaaKuva;
  final bool pitaaLukeaMetatiedot;
  final String tiedostoNimi;
  final String nykyinenNimi;
  final String nykyinenKirjailija;
  final String nykyinenKustantaja;
  final String nykyinenJulkaisuaika;
  final int nykyinenJulkaisuvuosi;
  final List<String> nykyisetTagit;
  final String nykyinenSarja;
  final String nykyinenSarjanumero;
  final bool pakotaUudelleenSkannaus;

  const _EpubScanRequest({
    required this.filePath,
    required this.kuvaPolku,
    required this.pitaaPaivittaaKuva,
    required this.pitaaLukeaMetatiedot,
    required this.tiedostoNimi,
    required this.nykyinenNimi,
    required this.nykyinenKirjailija,
    required this.nykyinenKustantaja,
    required this.nykyinenJulkaisuaika,
    required this.nykyinenJulkaisuvuosi,
    required this.nykyisetTagit,
    required this.nykyinenSarja,
    required this.nykyinenSarjanumero,
    required this.pakotaUudelleenSkannaus,
  });
}

class _ScannedBookMeta {
  final String title;
  final String author;
  final String publisher;
  final String publishDateText;
  final int publishYear;
  final List<String> tags;
  final String series;
  final String seriesNumber;
  final bool coverSaved;

  const _ScannedBookMeta({
    required this.title,
    required this.author,
    required this.publisher,
    required this.publishDateText,
    required this.publishYear,
    required this.tags,
    required this.series,
    required this.seriesNumber,
    required this.coverSaved,
  });
}

/// Purkaa EPUB-metatiedot ja kansikuvan taustasäikeessä (Isolate) pääsäiettä lukitsematta.
Future<_ScannedBookMeta> _skannaaEpubIsolatessa(_EpubScanRequest req) async {
  String kirjanNimi = req.nykyinenNimi;
  String kirjailija = req.nykyinenKirjailija;
  String kustantaja = req.nykyinenKustantaja;
  String julkaisuaikaTeksti = req.nykyinenJulkaisuaika;
  int julkaisuvuosi = req.nykyinenJulkaisuvuosi;
  List<String> tagit = List<String>.from(req.nykyisetTagit);
  String sarja = req.nykyinenSarja;
  String sarjanumero = req.nykyinenSarjanumero;
  bool coverSaved = File(req.kuvaPolku).existsSync();

  final List<int> epubTavut = await File(req.filePath).readAsBytes();
  final EpubBook epub = await EpubReader.readBook(epubTavut);

  if (req.pitaaPaivittaaKuva && epub.coverImage != null) {
    img.Image cover = epub.coverImage!;
    if (cover.width > 320) {
      cover = img.copyResize(cover, width: 320);
    }
    final Uint8List pngTavut = Uint8List.fromList(img.encodePng(cover));
    File(req.kuvaPolku).writeAsBytesSync(pngTavut);
    coverSaved = true;
  }

  if (req.pitaaLukeaMetatiedot) {
    if (epub.title != null &&
        epub.title!.trim().isNotEmpty &&
        (kirjanNimi == req.tiedostoNimi || kirjanNimi.isEmpty || req.pakotaUudelleenSkannaus)) {
      kirjanNimi = epub.title!.trim();
    }
    if (epub.author != null &&
        epub.author!.trim().isNotEmpty &&
        (kirjailija == 'Tuntematon' || req.pakotaUudelleenSkannaus)) {
      kirjailija = epub.author!.trim();
    } else if (epub.authors.isNotEmpty &&
        epub.authors.first != null &&
        (kirjailija == 'Tuntematon' || req.pakotaUudelleenSkannaus)) {
      kirjailija = epub.authors.whereType<String>().join(', ').trim();
    }
    if (epub.schema?.package?.metadata?.publishers.isNotEmpty ?? false) {
      if (kustantaja == 'Tuntematon' || req.pakotaUudelleenSkannaus) {
        kustantaja = epub.schema!.package!.metadata!.publishers.join(', ').trim();
      }
    }
    if (epub.schema?.package?.metadata?.dates.isNotEmpty ?? false) {
      if (julkaisuaikaTeksti == 'Tuntematon' || req.pakotaUudelleenSkannaus) {
        julkaisuaikaTeksti = epub.schema!.package!.metadata!.dates.first.date ?? 'Tuntematon';
      }
    }
    final yearMatch = RegExp(r'\b(18|19|20)\d{2}\b').firstMatch(julkaisuaikaTeksti);
    if (yearMatch != null && (julkaisuvuosi == 0 || req.pakotaUudelleenSkannaus)) {
      julkaisuvuosi = int.tryParse(yearMatch.group(0)!) ?? 0;
    }
    if ((epub.schema?.package?.metadata?.subjects.isNotEmpty ?? false) &&
        (tagit.isEmpty || req.pakotaUudelleenSkannaus)) {
      tagit = epub.schema!.package!.metadata!.subjects
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    if (epub.schema?.package?.metadata?.metaItems.isNotEmpty ?? false) {
      for (final meta in epub.schema!.package!.metadata!.metaItems) {
        final mName = meta.name?.toLowerCase() ?? '';
        final mProp = meta.property?.toLowerCase() ?? '';
        if ((sarja.isEmpty || req.pakotaUudelleenSkannaus) &&
            (mName == 'calibre:series' || mProp == 'belongs-to-collection')) {
          sarja = meta.content ?? '';
        }
        if ((sarjanumero.isEmpty || req.pakotaUudelleenSkannaus) &&
            (mName == 'calibre:series_index' || mProp == 'group-position')) {
          sarjanumero = meta.content ?? '';
        }
      }
    }
  }

  return _ScannedBookMeta(
    title: TextEncodingHelper.korjaaMerkistovirheet(kirjanNimi),
    author: TextEncodingHelper.korjaaMerkistovirheet(kirjailija),
    publisher: TextEncodingHelper.korjaaMerkistovirheet(kustantaja),
    publishDateText: julkaisuaikaTeksti,
    publishYear: julkaisuvuosi,
    tags: tagit.map(TextEncodingHelper.korjaaMerkistovirheet).where((s) => s.isNotEmpty).toList(),
    series: TextEncodingHelper.korjaaMerkistovirheet(sarja),
    seriesNumber: sarjanumero,
    coverSaved: coverSaved,
  );
}

class _DiscoveredBookFile {
  final String path;
  final String ext;
  final int muokkausaika;
  final String kuvaNimi;
  final String kuvaPolku;
  final bool kuvaOlemassa;

  const _DiscoveredBookFile({
    required this.path,
    required this.ext,
    required this.muokkausaika,
    required this.kuvaNimi,
    required this.kuvaPolku,
    required this.kuvaOlemassa,
  });
}

/// Listaa hakemiston .pdf- ja .epub-tiedostot sekä lukee niiden muokkausajat
/// taustasäikeessä (Isolate), jotta Androidin FUSE-tiedostojärjestelmä ei tuki pääsäiettä.
List<_DiscoveredBookFile> _listaaKirjaTiedostotIsolatessa(
  String dirPolku,
  String thumbnailsDirPolku,
) {
  final dir = Directory(dirPolku);
  final List<_DiscoveredBookFile> tulokset = [];
  List<FileSystemEntity> entities = [];
  try {
    entities = dir.listSync(recursive: true);
  } catch (_) {
    return tulokset;
  }

  for (final entity in entities) {
    if (entity is! File) continue;
    final String ext = p.extension(entity.path).toLowerCase();
    if (ext != '.pdf' && ext != '.epub') continue;
    try {
      final int muokkausaika = entity.statSync().modified.millisecondsSinceEpoch;
      final String cacheKey = md5.convert(utf8.encode(entity.path)).toString();
      final String kuvaNimi = '$cacheKey.png';
      final String kuvaPolku =
          thumbnailsDirPolku.isNotEmpty ? p.join(thumbnailsDirPolku, kuvaNimi) : '';
      final bool kuvaOlemassa =
          kuvaPolku.isNotEmpty && File(kuvaPolku).existsSync();
      tulokset.add(_DiscoveredBookFile(
        path: entity.path,
        ext: ext,
        muokkausaika: muokkausaika,
        kuvaNimi: kuvaNimi,
        kuvaPolku: kuvaPolku,
        kuvaOlemassa: kuvaOlemassa,
      ));
    } catch (_) {}
  }

  return tulokset;
}

/// Listaa hakemiston .mobi/.prc-tiedostopolut taustasäikeessä (Isolate).
List<String> _listaaMobiPolutIsolatessa(String dirPolku) {
  final dir = Directory(dirPolku);
  final List<String> tulokset = [];
  try {
    final entities = dir.listSync(recursive: true);
    for (final entity in entities) {
      if (entity is File && MobiToEpubConverter.onkoMobiTiedosto(entity.path)) {
        tulokset.add(entity.path);
      }
    }
  } catch (_) {}
  return tulokset;
}

class IndexedBook {
  String title;
  final String path;
  final bool isPdf;
  String thumbnailPath; // Tallennettu polku tai nimi
  int lastReadPage;
  double lastReadScrollRatio;
  int lastReadTimestamp;
  int fileModifiedTimestamp;
  int fileAddedTimestamp; // Import- / lisäysajankohta
  String author;          // Kirjailija
  String publisher;       // Kustantaja
  String publishDateText; // Julkaisuaika tekstinä
  int publishYear;        // Julkaisuvuosi lajittelua varten
  List<String> tags;      // Tagit / aihealueet
  String series;          // Kirjan sarja
  String seriesNumber;    // Sarjan osanumero
  bool hasCustomMetadata; // Onko käyttäjä muokannut/tallentanut metatiedot

  IndexedBook({
    required this.title,
    required this.path,
    required this.isPdf,
    required this.thumbnailPath,
    this.lastReadPage = 1,
    this.lastReadScrollRatio = 0.0,
    this.lastReadTimestamp = 0,
    this.fileModifiedTimestamp = 0,
    this.fileAddedTimestamp = 0,
    this.author = 'Tuntematon',
    this.publisher = 'Tuntematon',
    this.publishDateText = 'Tuntematon',
    this.publishYear = 0,
    this.tags = const [],
    this.series = '',
    this.seriesNumber = '',
    this.hasCustomMetadata = false,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'path': path,
    'isPdf': isPdf,
    'thumbnailPath': thumbnailPath,
    'lastReadPage': lastReadPage,
    'lastReadScrollRatio': lastReadScrollRatio,
    'lastReadTimestamp': lastReadTimestamp,
    'fileModifiedTimestamp': fileModifiedTimestamp,
    'fileAddedTimestamp': fileAddedTimestamp,
    'author': author,
    'publisher': publisher,
    'publishDateText': publishDateText,
    'publishYear': publishYear,
    'tags': tags,
    'series': series,
    'seriesNumber': seriesNumber,
    'hasCustomMetadata': hasCustomMetadata,
  };

  factory IndexedBook.fromJson(Map<String, dynamic> json) => IndexedBook(
    title: TextEncodingHelper.korjaaMerkistovirheet(json['title'] ?? ''),
    path: json['path'] ?? '',
    isPdf: json['isPdf'] ?? false,
    thumbnailPath: json['thumbnailPath'] ?? '',
    lastReadPage: json['lastReadPage'] ?? 1,
    lastReadScrollRatio: (json['lastReadScrollRatio'] as num?)?.toDouble() ?? 0.0,
    lastReadTimestamp: json['lastReadTimestamp'] ?? 0,
    fileModifiedTimestamp: json['fileModifiedTimestamp'] ?? 0,
    fileAddedTimestamp: json['fileAddedTimestamp'] ?? json['fileModifiedTimestamp'] ?? 0,
    author: TextEncodingHelper.korjaaMerkistovirheet(json['author'] ?? 'Tuntematon'),
    publisher: TextEncodingHelper.korjaaMerkistovirheet(json['publisher'] ?? 'Tuntematon'),
    publishDateText: TextEncodingHelper.korjaaMerkistovirheet(json['publishDateText'] ?? 'Tuntematon'),
    publishYear: json['publishYear'] ?? 0,
    tags: (json['tags'] as List<dynamic>?)
            ?.map((e) => TextEncodingHelper.korjaaMerkistovirheet(e.toString()))
            .where((e) => e.isNotEmpty)
            .toList() ??
        const [],
    series: TextEncodingHelper.korjaaMerkistovirheet(json['series'] ?? ''),
    seriesNumber: json['seriesNumber']?.toString() ?? '',
    hasCustomMetadata: json['hasCustomMetadata'] == true,
  );

  /// Palauttaa kansikuvan polun synkronisesti välimuistista ilman levy- tai
  /// MethodChannel-kutsuja, jotta kirjahyllyn rakennus pysyy sulavana.
  String? getCachedThumbnailPath() {
    if (thumbnailPath.isEmpty) return null;
    final String? thumbsDir = IndexedBookScanner._cachedThumbnailsDirPath;
    if (thumbsDir == null) return null;
    final String baseName =
        (thumbnailPath.contains('/') || thumbnailPath.contains('\\'))
            ? p.basename(thumbnailPath)
            : thumbnailPath;
    if (IndexedBookScanner._thumbnailsCacheInitialized &&
        !IndexedBookScanner._existingThumbnailFiles.contains(baseName)) {
      return null;
    }
    return p.join(thumbsDir, baseName);
  }

  // Palauttaa absoluuttisen polun thumbnailiin sovelluksen files/thumbnails-kansiosta
  Future<String> getFullThumbnailPath() async {
    if (thumbnailPath.isEmpty) return '';
    if (thumbnailPath.contains('/') || thumbnailPath.contains('\\')) {
      thumbnailPath = p.basename(thumbnailPath);
    }
    final filesDir = await IndexedBookScanner.haeSovelluksenFilesHakemisto();
    final thumbFile = File(p.join(filesDir.path, 'thumbnails', thumbnailPath));
    if (await thumbFile.exists()) {
      IndexedBookScanner._existingThumbnailFiles.add(thumbnailPath);
      return thumbFile.path;
    }
    // Toissijainen fallback aiempaan temp-välimuistiin
    final tempDir = await getTemporaryDirectory();
    return p.join(tempDir.path, thumbnailPath);
  }
}

class _BookScanCandidate {
  final File file;
  final String ext;
  final String kuvaNimi;
  final String kuvaPolku;
  final int muokkausaika;
  final IndexedBook? vanhaKirja;
  final bool pitaaPaivittaaKuva;
  final bool pitaaLukeaMetatiedot;

  const _BookScanCandidate({
    required this.file,
    required this.ext,
    required this.kuvaNimi,
    required this.kuvaPolku,
    required this.muokkausaika,
    required this.vanhaKirja,
    required this.pitaaPaivittaaKuva,
    required this.pitaaLukeaMetatiedot,
  });
}

class IndexedBookScanner {
  static String? _cachedThumbnailsDirPath;
  static final Set<String> _existingThumbnailFiles = {};
  static bool _thumbnailsCacheInitialized = false;

  static final StreamController<BookScanEvent> _scanEventController =
      StreamController<BookScanEvent>.broadcast();

  /// Reaaliaikainen tapahtumavirta skannatuista kirjoista ja edistymisestä.
  static Stream<BookScanEvent> get scanEvents => _scanEventController.stream;

  /// Viimeisin taustaskannauksen edistymistila.
  static final ValueNotifier<BookScanEvent?> scanProgressNotifier =
      ValueNotifier<BookScanEvent?>(null);

  static void _lahetaScanEvent(BookScanEvent event) {
    scanProgressNotifier.value = event.isScanning ? event : null;
    if (!_scanEventController.isClosed) {
      _scanEventController.add(event);
    }
  }

  static List<IndexedBook> _jarjestaKirjat(Iterable<IndexedBook> kirjat) {
    final list = kirjat.toList();
    list.sort((a, b) {
      int cmp = b.lastReadTimestamp.compareTo(a.lastReadTimestamp);
      if (cmp == 0) return a.title.compareTo(b.title);
      return cmp;
    });
    return list;
  }

  static Future<void> _paivitaThumbnailValimuisti(String thumbsPath) async {
    _cachedThumbnailsDirPath = thumbsPath;
    try {
      final dir = Directory(thumbsPath);
      if (await dir.exists()) {
        final names = await Isolate.run(() {
          return dir
              .listSync()
              .whereType<File>()
              .map((f) => p.basename(f.path))
              .toSet();
        });
        _existingThumbnailFiles
          ..clear()
          ..addAll(names);
      } else {
        _existingThumbnailFiles.clear();
      }
      _thumbnailsCacheInitialized = true;
    } catch (_) {}
  }

  /// Hakee sovelluksen oman 'files'-datahakemiston, jonne tallennetaan
  /// kirja_indeksi.json sekä kansikuvat (thumbnails).
  static Future<Directory> haeSovelluksenFilesHakemisto() async {
    Directory filesDir;
    try {
      filesDir = await getApplicationSupportDirectory();
    } catch (_) {
      filesDir = await getApplicationDocumentsDirectory();
    }

    if (!await filesDir.exists()) {
      await filesDir.create(recursive: true);
    }
    _cachedThumbnailsDirPath ??= p.join(filesDir.path, 'thumbnails');
    return filesDir;
  }

  static Future<List<IndexedBook>> lueIndeksi() => _lueIndeksi();

  static Future<List<IndexedBook>> _lueIndeksi() async {
    try {
      final filesDir = await haeSovelluksenFilesHakemisto();
      final thumbsPath = p.join(filesDir.path, 'thumbnails');
      _cachedThumbnailsDirPath = thumbsPath;
      if (!_thumbnailsCacheInitialized) {
        await _paivitaThumbnailValimuisti(thumbsPath);
      }

      final indeksiTiedosto = File('${filesDir.path}/kirja_indeksi.json');
      if (!await indeksiTiedosto.exists()) {
        // Tarkistetaan vanha documents-hakemisto migraatiota varten
        final docDir = await getApplicationDocumentsDirectory();
        final vanhaTiedosto = File('${docDir.path}/kirja_indeksi.json');
        if (await vanhaTiedosto.exists()) {
          final String vanhaSisalto = await vanhaTiedosto.readAsString();
          await indeksiTiedosto.writeAsString(vanhaSisalto);
          final List<dynamic> jsonLista = jsonDecode(vanhaSisalto);
          return jsonLista.map((item) => IndexedBook.fromJson(item)).toList();
        }
        return [];
      }

      final String sisalto = await indeksiTiedosto.readAsString();
      final List<dynamic> jsonLista = jsonDecode(sisalto);
      return jsonLista.map((item) => IndexedBook.fromJson(item)).toList();
    } catch (e) {
      return [];
    }
  }

  static Future<void> _tallennaIndeksi(List<IndexedBook> kirjat, {Directory? filesDir}) async {
    final dir = filesDir ?? await haeSovelluksenFilesHakemisto();
    final indeksiTiedosto = File('${dir.path}/kirja_indeksi.json');
    final String jsonSisalto = jsonEncode(kirjat.map((k) => k.toJson()).toList());
    await indeksiTiedosto.writeAsString(jsonSisalto);
  }

  /// Muuntaa hakemistossa olevat .mobi/.prc-tiedostot EPUB-muotoon taustasäikeessä.
  static Future<void> _muunnaMobiTiedostotEpubiksiTaustalla(Directory dir) async {
    final String dirPath = dir.path;
    final List<String> mobiPolut =
        await Isolate.run(() => _listaaMobiPolutIsolatessa(dirPath));

    for (final mobiPolku in mobiPolut) {
      try {
        final String epubPolku = p.setExtension(mobiPolku, '.epub');
        if (!await File(epubPolku).exists()) {
          await Isolate.run(() async {
            await MobiToEpubConverter.muunnaEpubiksi(
              File(mobiPolku),
              kohdeEpubPolku: epubPolku,
            );
          }).timeout(const Duration(seconds: 20));
        }
        if (await File(epubPolku).exists()) {
          await File(mobiPolku).delete();
        }
      } catch (_) {}
    }
  }

  /// Poistaa kirjahyllyn indeksitiedoston sekä kansikuvat levyltä
  static Future<void> tyhjennaIndeksi() async {
    try {
      final filesDir = await haeSovelluksenFilesHakemisto();
      final indeksiTiedosto = File('${filesDir.path}/kirja_indeksi.json');
      if (await indeksiTiedosto.exists()) {
        await indeksiTiedosto.delete();
      }
      final thumbsDir = Directory(p.join(filesDir.path, 'thumbnails'));
      if (await thumbsDir.exists()) {
        await thumbsDir.delete(recursive: true);
      }
      _existingThumbnailFiles.clear();
      _thumbnailsCacheInitialized = true;
    } catch (_) {}
  }

  /// Tyhjentää Kirjat-kansion kaikista tiedostoista ja nollaa kirjahyllyn indeksin
  static Future<int> tyhjennaKirjakansio(String kirjakansioPolku) async {
    int poistettu = 0;
    try {
      final dir = Directory(kirjakansioPolku);
      if (await dir.exists()) {
        final entities = dir.listSync(recursive: true);
        for (final entity in entities) {
          try {
            if (entity is File) {
              await entity.delete();
              poistettu++;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}

    await tyhjennaIndeksi();
    return poistettu;
  }

  /// Poistaa yksittäisen kirjan levyltä, sen kansikuvan sekä metatiedoista
  static Future<bool> poistaYksittainenKirja(IndexedBook kirja) async {
    bool tiedostoPoistettu = false;
    try {
      final file = File(kirja.path);
      if (await file.exists()) {
        await file.delete();
        tiedostoPoistettu = true;
      }
    } catch (e) {
      debugPrint('Virhe kirjatiedoston poistossa: $e');
    }

    // Poistetaan kansikuva
    try {
      final thumbPath = await kirja.getFullThumbnailPath();
      if (thumbPath.isNotEmpty) {
        final thumbFile = File(thumbPath);
        if (await thumbFile.exists()) {
          await thumbFile.delete();
        }
        _existingThumbnailFiles.remove(p.basename(thumbPath));
      }
    } catch (_) {}

    // Poistetaan metatiedoista
    try {
      List<IndexedBook> nykyiset = await _lueIndeksi();
      nykyiset.removeWhere((k) => k.path == kirja.path);
      await _tallennaIndeksi(nykyiset);
    } catch (_) {}

    return tiedostoPoistettu;
  }

  /// Hakee kirjat ja synkronoi levyn tiedostot (/Books) ja metatietolistauksen.
  /// Jos hakemistosta löytyy kirjatiedosto, jolle ei ole vielä tehty metatietoja,
  /// luodaan metatiedot ja päivitetään indeksi automaattisesti.
  static Future<List<IndexedBook>> synkronoiKirjahakemisto(
    String kirjakansioPolku, {
    void Function(int current, int total, String bookName, String phase)? onProgress,
  }) async {
    await ScreenWakeHelper.asetaNayttoPaalle(true);
    try {
      Directory dir = Directory(kirjakansioPolku);
      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {}
      }
      if (!await dir.exists() && Platform.isAndroid) {
        final alt = Directory('/sdcard/Books');
        if (await alt.exists()) {
          dir = alt;
        }
      }

      // 0. Muunnetaan suoraan /Books-kansioon kopioidut .mobi/.prc-tiedostot automaattisesti EPUBiksi
      await _muunnaMobiTiedostotEpubiksiTaustalla(dir);

      final List<IndexedBook> indeksi = await _lueIndeksi();

      // 1. Luetaan kirjahakemiston tiedostot levyltä taustasäikeessä (Isolate)
      final String dirPath = dir.path;
      final List<_DiscoveredBookFile> tiedostotLevylla = await Isolate.run(
        () => _listaaKirjaTiedostotIsolatessa(dirPath, ''),
      );

      final Map<String, int> levynMuokkausajat = {
        for (final f in tiedostotLevylla) f.path: f.muokkausaika,
      };
      final Set<String> indeksoidutPolut = indeksi.map((k) => k.path).toSet();
      final Set<String> levynPolut = levynMuokkausajat.keys.toSet();

      // 2. Verrataan listoja: onko uusia kirjoja ilman metatietoja tai poistettuja tiedostoja?
      final bool onUusiaKirjoja = levynPolut.any((polku) => !indeksoidutPolut.contains(polku));
      final bool onPoistettuja = indeksoidutPolut.any((polku) => !levynPolut.contains(polku));

      // 3. Onko tiedostoja muokattu? (Käyttäjän tallentamia kirjoja ei katsota muuttuneiksi)
      bool onMuuttuneita = false;
      for (final kirja in indeksi) {
        if (kirja.hasCustomMetadata) continue;
        final int? mtime = levynMuokkausajat[kirja.path];
        if (mtime != null && mtime > kirja.fileModifiedTimestamp) {
          onMuuttuneita = true;
          break;
        }
      }

      // Jos havaitaan uusia tiedostoja, poistettuja tiedostoja tai muokkauksia,
      // luodaan/päivitetään puuttuvat metatiedot
      if (onUusiaKirjoja || onPoistettuja || onMuuttuneita || indeksi.isEmpty) {
        if (tiedostotLevylla.isEmpty && onPoistettuja) {
          await tyhjennaIndeksi();
          _lahetaScanEvent(const BookScanEvent(
            books: [],
            current: 0,
            total: 0,
            currentBookName: '',
            statusText: 'Kirjasto tyhjä',
            isScanning: false,
          ));
          return [];
        }
        return await odotaUudelleenSkannaus(
          kirjakansioPolku,
          pakotaUudelleenSkannaus: false,
          onProgress: onProgress,
        );
      }

      final lajiteltu = _jarjestaKirjat(indeksi);
      _lahetaScanEvent(BookScanEvent(
        books: List.unmodifiable(lajiteltu),
        current: lajiteltu.length,
        total: lajiteltu.length,
        currentBookName: '',
        statusText: 'Kirjasto ajan tasalla',
        isScanning: false,
      ));

      return lajiteltu;
    } finally {
      await ScreenWakeHelper.asetaNayttoPaalle(false);
    }
  }

  static Future<List<IndexedBook>> haeKirjat(String kirjakansioPolku) async {
    return await synkronoiKirjahakemisto(kirjakansioPolku);
  }

  static Future<void> paivitaLukutilanne(String tiedostoPolku, int sivu, {double scrollRatio = 0.0}) async {
    List<IndexedBook> nykyisetKirjat = await _lueIndeksi();
    int indeksi = nykyisetKirjat.indexWhere((k) => k.path == tiedostoPolku);

    if (indeksi != -1) {
      nykyisetKirjat[indeksi].lastReadPage = sivu;
      nykyisetKirjat[indeksi].lastReadScrollRatio = scrollRatio;
      nykyisetKirjat[indeksi].lastReadTimestamp = DateTime.now().millisecondsSinceEpoch;
      await _tallennaIndeksi(nykyisetKirjat);
    }
  }

  static Future<void> paivitaKirjanTiedot(IndexedBook paivitettyKirja) async {
    List<IndexedBook> nykyisetKirjat = await _lueIndeksi();
    int indeksi = nykyisetKirjat.indexWhere((k) => k.path == paivitettyKirja.path);

    if (indeksi != -1) {
      paivitettyKirja.hasCustomMetadata = true;
      try {
        final f = File(paivitettyKirja.path);
        if (f.existsSync()) {
          paivitettyKirja.fileModifiedTimestamp = f.lastModifiedSync().millisecondsSinceEpoch;
        }
      } catch (_) {}
      nykyisetKirjat[indeksi] = paivitettyKirja;
      await _tallennaIndeksi(nykyisetKirjat);
    }
  }

  /// Päivittää kirjan otsikon (metaotsikko) ja tallentaa sen
  static Future<bool> paivitaKirjanOtsikko(String tiedostoPolku, String uusiOtsikko) async {
    final cleanTitle = uusiOtsikko.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleanTitle.isEmpty) return false;

    List<IndexedBook> nykyisetKirjat = await _lueIndeksi();
    int indeksi = nykyisetKirjat.indexWhere((k) => k.path == tiedostoPolku);

    if (indeksi != -1) {
      final kirja = nykyisetKirjat[indeksi];
      kirja.title = cleanTitle;
      kirja.hasCustomMetadata = true;
      try {
        final f = File(kirja.path);
        if (f.existsSync()) {
          kirja.fileModifiedTimestamp = f.lastModifiedSync().millisecondsSinceEpoch;
        }
      } catch (_) {}
      await _tallennaIndeksi(nykyisetKirjat);
      return true;
    }
    return false;
  }

  static Future<bool> tarkistaMuutoksetTaustalla(String kirjakansioPolku, List<IndexedBook> nykyinenIndeksi) async {
    Directory dir = Directory(kirjakansioPolku);
    if (!await dir.exists() && Platform.isAndroid) {
      final alt = Directory('/sdcard/Books');
      if (await alt.exists()) dir = alt;
    }
    if (!await dir.exists()) return false;

    final filesDir = await haeSovelluksenFilesHakemisto();
    final String thumbsPath = p.join(filesDir.path, 'thumbnails');
    final String dirPath = dir.path;

    final List<_DiscoveredBookFile> tiedostotLevylla = await Isolate.run(
      () => _listaaKirjaTiedostotIsolatessa(dirPath, thumbsPath),
    );

    // 1. Määrä on muuttunut
    if (tiedostotLevylla.length != nykyinenIndeksi.length) return true;

    final Map<String, _DiscoveredBookFile> levynKartta = {
      for (final f in tiedostotLevylla) f.path: f,
    };

    // 2. Tarkistetaan onko tiedostoja muokattu tai onko thumbnail poistettu
    for (final kirja in nykyinenIndeksi) {
      final diskFile = levynKartta[kirja.path];
      if (diskFile == null) return true; // Tiedosto kadonnut

      if (diskFile.muokkausaika > kirja.fileModifiedTimestamp) return true;

      if (kirja.thumbnailPath.isNotEmpty && !diskFile.kuvaOlemassa) return true;
    }

    return false;
  }

  static String? _cleanPdfString(String? raw) {
    if (raw == null) return null;
    return TextEncodingHelper.puraPdfMerkkijono(raw);
  }

  /// Poimii PDF-sanakirjasisällöstä avaimen arvon ottaen huomioon tasapainotetut sulut ja heksajonot
  static String? _extractPdfDictEntry(String content, String key) {
    final keyPattern = RegExp('/$key(?=[\\s(/<])');
    final matches = keyPattern.allMatches(content);
    if (matches.isEmpty) return null;

    for (final match in matches) {
      int idx = match.end;
      while (idx < content.length &&
          (content[idx] == ' ' ||
           content[idx] == '\t' ||
           content[idx] == '\r' ||
           content[idx] == '\n')) {
        idx++;
      }
      if (idx >= content.length) continue;

      if (content[idx] == '(') {
        // Luetaan merkkijonoliteraali (...) ottaen huomioon tasapainotetut ja paetut sulut
        int depth = 0;
        bool escaped = false;
        final int start = idx + 1;
        for (int i = idx; i < content.length; i++) {
          final c = content[i];
          if (escaped) {
            escaped = false;
            continue;
          }
          if (c == '\\') {
            escaped = true;
            continue;
          }
          if (c == '(') {
            depth++;
          } else if (c == ')') {
            depth--;
            if (depth == 0) {
              final raw = content.substring(start, i);
              final cleaned = _cleanPdfString(raw);
              if (cleaned != null && cleaned.trim().isNotEmpty) {
                return cleaned.trim();
              }
              break;
            }
          }
        }
      } else if (content[idx] == '<' && idx + 1 < content.length && content[idx + 1] != '<') {
        // Heksadesimaalimerkkijono <...>
        final end = content.indexOf('>', idx);
        if (end != -1) {
          final raw = content.substring(idx, end + 1);
          final cleaned = _cleanPdfString(raw);
          if (cleaned != null && cleaned.trim().isNotEmpty) {
            return cleaned.trim();
          }
        }
      }
    }
    return null;
  }

  /// Suodattaa ja siistii PDF-metatiedoista poimitun otsikon.
  /// Hylkää geneeriset roskanimikkeet (Untitled, Document1, Chapter 1, Cover jne.),
  /// jotta selkeä tiedostonimi ei tule ylikirjoitetuksi huonolla metatiedolla.
  static String? _siistiPdfOtsikko(String? rawTitle, String tiedostoNimi) {
    if (rawTitle == null) return null;
    String title = TextEncodingHelper.korjaaMerkistovirheet(rawTitle).trim();
    if (title.isEmpty) return null;

    // 1. Poistetaan "Microsoft Word - " etuliite
    if (title.toLowerCase().startsWith('microsoft word - ')) {
      title = title.substring(17).trim();
    }
    // Poistetaan LibreOffice / OpenOffice etuliitteet
    if (title.toLowerCase().startsWith('libreoffice ') || title.toLowerCase().startsWith('openoffice ')) {
      title = title.replaceFirst(RegExp(r'^(?:libreoffice|openoffice)\s+[\d.]*\s*[-–—:]*\s*', caseSensitive: false), '').trim();
    }

    // 2. Poistetaan tiedostopääte otsikon lopusta, jos sellainen on jäänyt
    title = title.replaceFirst(RegExp(r'\.(?:pdf|docx?|odt|rtf|epub|txt)$', caseSensitive: false), '').trim();

    // 3. Poistetaan hakemistopolku, jos otsikko olikin tiedostopolku
    if (title.contains('/') || title.contains(r'\')) {
      title = p.basenameWithoutExtension(title).trim();
    }

    // 4. Poistetaan ympäröivät lainausmerkit tai sulut
    if ((title.startsWith('"') && title.endsWith('"')) ||
        (title.startsWith("'") && title.endsWith("'")) ||
        (title.startsWith('(') && title.endsWith(')'))) {
      if (title.length >= 2) {
        title = title.substring(1, title.length - 1).trim();
      }
    }

    if (title.isEmpty) return null;

    // 5. Tarkistetaan onko kyseessä roskanimike (junk title)
    // Jos pelkkiä numeroita tai erikoismerkkejä
    if (RegExp(r'^\d+$').hasMatch(title) || RegExp(r'^[^a-zA-Z0-9äöåÄÖÅ]+$').hasMatch(title)) {
      return null;
    }

    final lower = title.toLowerCase();

    // Tunnetut geneeriset roskanimikkeet
    const roskat = {
      'untitled',
      'nimetön',
      'ei nimeä',
      'no title',
      'unknown',
      'tuntematon',
      'adobe pdf',
      'pdf document',
      'portable document format',
      'scan',
      'scanner',
      'scanned',
      'skannaus',
      'skannattu',
      'skannattu asiakirja',
      'document',
      'asiakirja',
      'uusi asiakirja',
      'print',
      'tuloste',
      'tulostus',
      'output',
      'temp',
      'temporary',
      'merged',
      'yhdistetty',
      'cover',
      'kansi',
      'etukansi',
      'takakansi',
      'contents',
      'table of contents',
      'sisällys',
      'sisällysluettelo',
      'chapter',
      'luku',
      'osa',
      'introduction',
      'johdanto',
      'alkusanat',
      'preface',
      'foreword',
      'index',
      'hakemisto',
      'appendix',
      'liite',
      'pdf',
      'test',
    };

    if (roskat.contains(lower)) return null;

    // Tarkistetaan numeroidut roskat (esim. "Document1", "Chapter 1", "Luku 1", "Slide 1")
    if (RegExp(r'^(?:document|doc|asiakirja|slide|dia|page|sivu|chapter|luku|osa)\s*\d+$', caseSensitive: false).hasMatch(title)) {
      return null;
    }

    return title;
  }

  /// Suodattaa pois geneeriset kirjailijat (esim. "Administrator", "User", "Scanner")
  static String? _siistiPdfKirjailija(String? rawAuthor) {
    if (rawAuthor == null) return null;
    final author = TextEncodingHelper.korjaaMerkistovirheet(rawAuthor).trim();
    if (author.isEmpty) return null;

    final lower = author.toLowerCase();
    const roskat = {
      'administrator',
      'admin',
      'user',
      'kayttaja',
      'käyttäjä',
      'owner',
      'scanner',
      'hp scanner',
      'epson scanner',
      'canon',
      'unknown',
      'tuntematon',
      'root',
    };
    if (roskat.contains(lower)) return null;
    return author;
  }

  static Map<String, dynamic> _extractPdfMetadata(File file, {String tiedostoNimi = ''}) {
    try {
      final length = file.lengthSync();
      final headerLength = length < 131072 ? length : 131072;
      final raf = file.openSync(mode: FileMode.read);
      final headerBytes = raf.readSync(headerLength);
      List<int> tailBytes = [];
      if (length > 131072) {
        final tailStart = length > 262144 ? length - 131072 : headerLength;
        raf.setPositionSync(tailStart);
        tailBytes = raf.readSync(length - tailStart);
      }

      // 1. Luetaan XMP-metatietopakkaus (jos olemassa, aina standardi UTF-8)
      String? xmpTitle;
      String? xmpAuthor;
      String? xmpPublisher;
      try {
        final allBytes = [...headerBytes, ...tailBytes];
        final xmpSample = utf8.decode(allBytes, allowMalformed: true);
        if (xmpSample.contains('<x:xmpmeta') || xmpSample.contains('<?xpacket')) {
          // dc:title
          final xTitleLi = RegExp(r'<dc:title[^>]*>[\s\S]*?<rdf:li[^>]*>([\s\S]*?)</rdf:li>', caseSensitive: false).firstMatch(xmpSample);
          String? rawXmpTitle = xTitleLi?.group(1);
          if (rawXmpTitle == null) {
            final xTitleSimple = RegExp(r'<dc:title[^>]*>([\s\S]*?)</dc:title>', caseSensitive: false).firstMatch(xmpSample);
            rawXmpTitle = xTitleSimple?.group(1);
          }
          if (rawXmpTitle == null) {
            final pdfTitle = RegExp(r'<pdf:Title[^>]*>([\s\S]*?)</pdf:Title>', caseSensitive: false).firstMatch(xmpSample);
            rawXmpTitle = pdfTitle?.group(1);
          }
          if (rawXmpTitle != null) {
            final cleaned = rawXmpTitle.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '').trim();
            xmpTitle = _siistiPdfOtsikko(cleaned, tiedostoNimi);
          }

          // dc:creator / author
          final xAuthLi = RegExp(r'<dc:creator[^>]*>[\s\S]*?<rdf:li[^>]*>([\s\S]*?)</rdf:li>', caseSensitive: false).firstMatch(xmpSample);
          String? rawXmpAuth = xAuthLi?.group(1);
          if (rawXmpAuth == null) {
            final xAuthSimple = RegExp(r'<dc:creator[^>]*>([\s\S]*?)</dc:creator>', caseSensitive: false).firstMatch(xmpSample);
            rawXmpAuth = xAuthSimple?.group(1);
          }
          if (rawXmpAuth != null) {
            final cleaned = rawXmpAuth.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '').trim();
            xmpAuthor = _siistiPdfKirjailija(cleaned);
          }

          // dc:publisher
          final xPubLi = RegExp(r'<dc:publisher[^>]*>[\s\S]*?<rdf:li[^>]*>([\s\S]*?)</rdf:li>', caseSensitive: false).firstMatch(xmpSample);
          String? rawXmpPub = xPubLi?.group(1);
          if (rawXmpPub == null) {
            final xPubSimple = RegExp(r'<dc:publisher[^>]*>([\s\S]*?)</dc:publisher>', caseSensitive: false).firstMatch(xmpSample);
            rawXmpPub = xPubSimple?.group(1);
          }
          if (rawXmpPub != null) {
            xmpPublisher = TextEncodingHelper.korjaaMerkistovirheet(rawXmpPub.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '').trim());
          }
        }
      } catch (_) {}

      // 2. Luetaan PDF Info Dictionary (/Title, /Author jne.)
      String sample = latin1.decode(headerBytes, allowInvalid: true) +
          (tailBytes.isNotEmpty ? latin1.decode(tailBytes, allowInvalid: true) : '');

      // Etsitään Info-objekti: /Info X 0 R
      String? infoDictContent;
      final infoRefMatch = RegExp(r'/Info\s+(\d+)\s+(\d+)\s+R').firstMatch(sample);
      if (infoRefMatch != null) {
        final objNum = infoRefMatch.group(1)!;
        final objGen = infoRefMatch.group(2)!;
        final objPattern = RegExp('$objNum\\s+$objGen\\s+obj\\s*<<([\\s\\S]*?)>>\\s*(?:endobj|stream)');
        var objMatch = objPattern.firstMatch(sample);

        // Jos Info-objekti ei osunut alku- tai loppupalaseen, mutta tiedosto on suurempi,
        // etsitään xref-taulun avulla tai luetaan objektin sijainti suoraan
        if (objMatch == null && length > 262144) {
          try {
            final startXrefMatch = RegExp(r'startxref\s+(\d+)\s+%%EOF').firstMatch(sample);
            if (startXrefMatch != null) {
              final xrefOffset = int.tryParse(startXrefMatch.group(1)!);
              final targetObjIndex = int.tryParse(objNum);
              if (xrefOffset != null && targetObjIndex != null && xrefOffset < length) {
                raf.setPositionSync(xrefOffset);
                final xrefBytes = raf.readSync(4096);
                final xrefSample = latin1.decode(xrefBytes, allowInvalid: true);
                final xrefLinePattern = RegExp(r'(\d{10})\s+(\d{5})\s+[nf]');
                final matches = xrefLinePattern.allMatches(xrefSample).toList();
                if (matches.length > targetObjIndex) {
                  final targetOffset = int.tryParse(matches[targetObjIndex].group(1)!);
                  if (targetOffset != null && targetOffset > 0 && targetOffset < length) {
                    raf.setPositionSync(targetOffset);
                    final objBytes = raf.readSync(4096);
                    final objStr = latin1.decode(objBytes, allowInvalid: true);
                    final directMatch = RegExp(r'<<([\s\S]*?)>>').firstMatch(objStr);
                    if (directMatch != null) {
                      infoDictContent = directMatch.group(1);
                    }
                  }
                }
              }
            }
          } catch (_) {}
        } else if (objMatch != null) {
          infoDictContent = objMatch.group(1);
        }
      }

      // Jos Info-sanakirjaa ei löytynyt spesifisti, etsitään /Info << ... >> suoraan
      if (infoDictContent == null) {
        final directInfoMatch = RegExp(r'/Info\s*<<([\s\S]*?)>>').firstMatch(sample);
        if (directInfoMatch != null) {
          infoDictContent = directInfoMatch.group(1);
        }
      }

      raf.closeSync();

      // Poimitaan arvot: käytetään ensisijaisesti Info-sanakirjaa
      String? title;
      String? author;
      String? publisher;
      String? dateText;
      int year = 0;
      List<String> tags = [];

      if (infoDictContent != null) {
        final rawTitle = _extractPdfDictEntry(infoDictContent, 'Title');
        title = _siistiPdfOtsikko(rawTitle, tiedostoNimi);

        final rawAuthor = _extractPdfDictEntry(infoDictContent, 'Author');
        author = _siistiPdfKirjailija(rawAuthor);

        publisher = _extractPdfDictEntry(infoDictContent, 'Producer') ??
            _extractPdfDictEntry(infoDictContent, 'Creator');

        final creationDate = _extractPdfDictEntry(infoDictContent, 'CreationDate');
        if (creationDate != null) {
          final ym = RegExp(r'D:(\d{4})').firstMatch(creationDate);
          if (ym != null) {
            year = int.tryParse(ym.group(1)!) ?? 0;
            dateText = year > 0 ? year.toString() : null;
          }
        }

        final kw = _extractPdfDictEntry(infoDictContent, 'Keywords');
        if (kw != null && kw.isNotEmpty) {
          tags = kw.split(RegExp(r'[,;]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        }
      }

      // Jos Info-sanakirjassa ei ollut otsikkoa, kokeillaan XMP-otsikkoa
      if (title == null || title.isEmpty) {
        title = xmpTitle;
      }

      // Jos vieläkään ei löytynyt otsikkoa, etsitään sanakirjoista, jotka EIVÄT ole kirjanmerkkejä (ei /Parent tai /Dest)
      if (title == null || title.isEmpty) {
        final allDicts = RegExp(r'<<([\s\S]*?)>>').allMatches(sample);
        for (final dMatch in allDicts) {
          final dictStr = dMatch.group(1)!;
          // Ohitetaan outline- ja linkkisanakirjat
          if (dictStr.contains('/Parent') ||
              dictStr.contains('/Dest') ||
              dictStr.contains('/Next') ||
              dictStr.contains('/Prev') ||
              dictStr.contains('/A ') ||
              dictStr.contains('/Type /Annot')) {
            continue;
          }
          if (dictStr.contains('/Title')) {
            final candidateTitle = _extractPdfDictEntry(dictStr, 'Title');
            final cleaned = _siistiPdfOtsikko(candidateTitle, tiedostoNimi);
            if (cleaned != null && cleaned.isNotEmpty) {
              title = cleaned;
              break;
            }
          }
        }
      }

      if (author == null || author.isEmpty) author = xmpAuthor;
      if (publisher == null || publisher.isEmpty) publisher = xmpPublisher;

      return {
        if (title != null && title.isNotEmpty) 'title': title,
        if (author != null && author.isNotEmpty) 'author': author,
        if (publisher != null && publisher.isNotEmpty) 'publisher': publisher,
        if (dateText != null && dateText.isNotEmpty) 'publishDateText': dateText,
        if (year > 0) 'publishYear': year,
        if (tags.isNotEmpty) 'tags': tags,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<IndexedBook> _skannaaYksittainenKirja(
    _BookScanCandidate candidate, {
    required bool pakotaUudelleenSkannaus,
  }) async {
    final String entityPath = candidate.file.path;
    final String tiedostoNimi = p.basenameWithoutExtension(entityPath);
    final IndexedBook? vanhaKirja = candidate.vanhaKirja;
    final File kuvaTiedosto = File(candidate.kuvaPolku);

    String kirjanNimi =
        (!pakotaUudelleenSkannaus && vanhaKirja?.title.isNotEmpty == true)
            ? vanhaKirja!.title
            : tiedostoNimi;
    String kirjailija = (!pakotaUudelleenSkannaus && vanhaKirja != null)
        ? vanhaKirja.author
        : 'Tuntematon';
    String kustantaja = (!pakotaUudelleenSkannaus && vanhaKirja != null)
        ? vanhaKirja.publisher
        : 'Tuntematon';
    String julkaisuaikaTeksti = (!pakotaUudelleenSkannaus && vanhaKirja != null)
        ? vanhaKirja.publishDateText
        : 'Tuntematon';
    int julkaisuvuosi =
        (!pakotaUudelleenSkannaus && vanhaKirja != null) ? vanhaKirja.publishYear : 0;
    List<String> tagit = (!pakotaUudelleenSkannaus && vanhaKirja?.tags != null)
        ? List<String>.from(vanhaKirja!.tags)
        : [];
    String sarja =
        (!pakotaUudelleenSkannaus && vanhaKirja != null) ? vanhaKirja.series : '';
    String sarjanumero = (!pakotaUudelleenSkannaus && vanhaKirja != null)
        ? vanhaKirja.seriesNumber
        : '';
    final int importAika =
        vanhaKirja?.fileAddedTimestamp != null && vanhaKirja!.fileAddedTimestamp > 0
            ? vanhaKirja.fileAddedTimestamp
            : candidate.muokkausaika;

    if (candidate.ext == '.pdf') {
      if (candidate.pitaaPaivittaaKuva) {
        try {
          final document = await PdfDocument.openFile(entityPath);
          try {
            if (document.pages.isNotEmpty) {
              final page = document.pages[0];
              const int targetWidth = 300;
              final int targetHeight = page.width > 0
                  ? (targetWidth * (page.height / page.width)).round().clamp(100, 800)
                  : 420;
              final pageImage = await page.render(
                width: targetWidth,
                height: targetHeight,
              );
              if (pageImage != null) {
                final Uint8List bgraPixels;
                final int w;
                final int h;
                try {
                  bgraPixels = Uint8List.fromList(pageImage.pixels);
                  w = pageImage.width;
                  h = pageImage.height;
                } finally {
                  pageImage.dispose();
                }

                // Pakataan PDF-kansikuva PNG:ksi taustasäikeessä (ei pääsäikeen ui.Image-lukitusta)
                final String kohdeKuvaPolku = candidate.kuvaPolku;
                await Isolate.run(() {
                  final image = img.Image.fromBytes(
                    width: w,
                    height: h,
                    bytes: bgraPixels.buffer,
                    numChannels: 4,
                    order: img.ChannelOrder.bgra,
                  );
                  final pngBytes = Uint8List.fromList(img.encodePng(image));
                  File(kohdeKuvaPolku).writeAsBytesSync(pngBytes);
                });
                IndexedBookScanner._existingThumbnailFiles.add(candidate.kuvaNimi);
                await FileImage(kuvaTiedosto).evict();
              }
            }
          } finally {
            await document.dispose();
          }
        } catch (_) {
          if (kuvaTiedosto.existsSync()) kuvaTiedosto.deleteSync();
          IndexedBookScanner._existingThumbnailFiles.remove(candidate.kuvaNimi);
        }
      }

      // Haetaan PDF-metatiedot taustasäikeessä
      if (candidate.pitaaLukeaMetatiedot) {
        final meta = await Isolate.run(() => _extractPdfMetadata(File(entityPath), tiedostoNimi: tiedostoNimi));
        if (meta['title'] != null &&
            (kirjanNimi == tiedostoNimi ||
                kirjanNimi.isEmpty ||
                pakotaUudelleenSkannaus)) {
          kirjanNimi = meta['title'];
        }
        if (meta['author'] != null &&
            (kirjailija == 'Tuntematon' || pakotaUudelleenSkannaus)) {
          kirjailija = meta['author'];
        }
        if (meta['publisher'] != null &&
            (kustantaja == 'Tuntematon' || pakotaUudelleenSkannaus)) {
          kustantaja = meta['publisher'];
        }
        if (meta['publishDateText'] != null &&
            (julkaisuaikaTeksti == 'Tuntematon' || pakotaUudelleenSkannaus)) {
          julkaisuaikaTeksti = meta['publishDateText'];
        }
        if (meta['publishYear'] != null &&
            (julkaisuvuosi == 0 || pakotaUudelleenSkannaus)) {
          julkaisuvuosi = meta['publishYear'];
        }
        if (meta['tags'] != null && (tagit.isEmpty || pakotaUudelleenSkannaus)) {
          tagit = List<String>.from(meta['tags']);
        }
      }
    } else if (candidate.ext == '.epub') {
      try {
        final request = _EpubScanRequest(
          filePath: entityPath,
          kuvaPolku: candidate.kuvaPolku,
          pitaaPaivittaaKuva: candidate.pitaaPaivittaaKuva,
          pitaaLukeaMetatiedot: candidate.pitaaLukeaMetatiedot,
          tiedostoNimi: tiedostoNimi,
          nykyinenNimi: kirjanNimi,
          nykyinenKirjailija: kirjailija,
          nykyinenKustantaja: kustantaja,
          nykyinenJulkaisuaika: julkaisuaikaTeksti,
          nykyinenJulkaisuvuosi: julkaisuvuosi,
          nykyisetTagit: tagit,
          nykyinenSarja: sarja,
          nykyinenSarjanumero: sarjanumero,
          pakotaUudelleenSkannaus: pakotaUudelleenSkannaus,
        );
        final meta = await Isolate.run(() => _skannaaEpubIsolatessa(request));
        if (meta.coverSaved) {
          IndexedBookScanner._existingThumbnailFiles.add(candidate.kuvaNimi);
          if (candidate.pitaaPaivittaaKuva) {
            await FileImage(kuvaTiedosto).evict();
          }
        }
        kirjanNimi = meta.title;
        kirjailija = meta.author;
        kustantaja = meta.publisher;
        julkaisuaikaTeksti = meta.publishDateText;
        julkaisuvuosi = meta.publishYear;
        tagit = meta.tags;
        sarja = meta.series;
        sarjanumero = meta.seriesNumber;
      } catch (_) {
        if (candidate.pitaaPaivittaaKuva && kuvaTiedosto.existsSync()) {
          kuvaTiedosto.deleteSync();
          IndexedBookScanner._existingThumbnailFiles.remove(candidate.kuvaNimi);
        }
      }
    }

    kirjanNimi = TextEncodingHelper.korjaaMerkistovirheet(kirjanNimi);
    kirjailija = TextEncodingHelper.korjaaMerkistovirheet(kirjailija);
    kustantaja = TextEncodingHelper.korjaaMerkistovirheet(kustantaja);
    sarja = TextEncodingHelper.korjaaMerkistovirheet(sarja);
    tagit = tagit
        .map(TextEncodingHelper.korjaaMerkistovirheet)
        .where((s) => s.isNotEmpty)
        .toList();

    final bool kuvaOlemassa = await kuvaTiedosto.exists();
    if (kuvaOlemassa) {
      IndexedBookScanner._existingThumbnailFiles.add(candidate.kuvaNimi);
    }

    return IndexedBook(
      title: kirjanNimi.isNotEmpty ? kirjanNimi : tiedostoNimi,
      path: entityPath,
      thumbnailPath: kuvaOlemassa ? candidate.kuvaNimi : '',
      lastReadPage: vanhaKirja?.lastReadPage ?? 1,
      lastReadScrollRatio: vanhaKirja?.lastReadScrollRatio ?? 0.0,
      lastReadTimestamp: vanhaKirja?.lastReadTimestamp ?? 0,
      fileModifiedTimestamp: candidate.muokkausaika,
      fileAddedTimestamp: importAika,
      author: kirjailija,
      publisher: kustantaja,
      publishDateText: julkaisuaikaTeksti,
      publishYear: julkaisuvuosi,
      tags: tagit,
      series: sarja,
      seriesNumber: sarjanumero,
      hasCustomMetadata: (vanhaKirja?.hasCustomMetadata ?? false) && !pakotaUudelleenSkannaus,
      isPdf: candidate.ext == '.pdf',
    );
  }

  static Future<List<IndexedBook>> odotaUudelleenSkannaus(
    String kirjakansioPolku, {
    bool pakotaUudelleenSkannaus = false,
    void Function(int current, int total, String bookName, String phase)? onProgress,
  }) async {
    await ScreenWakeHelper.asetaNayttoPaalle(true);
    try {
      final List<IndexedBook> vanhaIndeksi = await _lueIndeksi();
      Directory dir = Directory(kirjakansioPolku);
      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {}
      }
      if (!await dir.exists() && Platform.isAndroid) {
        final alt = Directory('/sdcard/Books');
        if (await alt.exists()) dir = alt;
      }
      if (!await dir.exists()) {
        _lahetaScanEvent(const BookScanEvent(
          books: [],
          current: 0,
          total: 0,
          currentBookName: '',
          statusText: 'Kirjakansiota ei löydy',
          isScanning: false,
        ));
        return [];
      }

      final filesDir = await haeSovelluksenFilesHakemisto();
      final thumbnailsDir = Directory(p.join(filesDir.path, 'thumbnails'));
      if (!await thumbnailsDir.exists()) {
        await thumbnailsDir.create(recursive: true);
      }
      await _paivitaThumbnailValimuisti(thumbnailsDir.path);

      // Muunnetaan mahdolliset .mobi/.prc-tiedostot ensin EPUBiksi (taustasäikeessä)
      await _muunnaMobiTiedostotEpubiksiTaustalla(dir);

      final String dirPath = dir.path;
      final String thumbsPath = thumbnailsDir.path;
      final List<_DiscoveredBookFile> discoveredFiles = await Isolate.run(
        () => _listaaKirjaTiedostotIsolatessa(dirPath, thumbsPath),
      );

      final Map<String, IndexedBook> vanhatKirjatMap = {
        for (final k in vanhaIndeksi) k.path: k,
      };

      // Pohjalista olemassa olevista indeksoiduista kirjoista, jotka löytyvät yhä levyltä
      final Map<String, IndexedBook> valmiitKirjat = {};
      final List<_BookScanCandidate> skannattavat = [];

      for (final fileInfo in discoveredFiles) {
        final IndexedBook? vanhaKirja = vanhatKirjatMap[fileInfo.path];

        final bool pitaaPaivittaaKuva = pakotaUudelleenSkannaus ||
            vanhaKirja == null ||
            fileInfo.muokkausaika > vanhaKirja.fileModifiedTimestamp ||
            (vanhaKirja.thumbnailPath.isNotEmpty && !fileInfo.kuvaOlemassa);

        final bool pitaaLukeaMetatiedot = (pakotaUudelleenSkannaus ||
            vanhaKirja == null ||
            fileInfo.muokkausaika > vanhaKirja.fileModifiedTimestamp) &&
            !(vanhaKirja?.hasCustomMetadata == true && !pakotaUudelleenSkannaus);

        if (vanhaKirja != null) {
          valmiitKirjat[fileInfo.path] = vanhaKirja;
        }

        if (pitaaPaivittaaKuva || pitaaLukeaMetatiedot) {
          skannattavat.add(_BookScanCandidate(
            file: File(fileInfo.path),
            ext: fileInfo.ext,
            kuvaNimi: fileInfo.kuvaNimi,
            kuvaPolku: fileInfo.kuvaPolku,
            muokkausaika: fileInfo.muokkausaika,
            vanhaKirja: vanhaKirja,
            pitaaPaivittaaKuva: pitaaPaivittaaKuva,
            pitaaLukeaMetatiedot: pitaaLukeaMetatiedot,
          ));
        }
      }

      if (skannattavat.isEmpty) {
        final lopullinenLista = _jarjestaKirjat(valmiitKirjat.values);
        await _tallennaIndeksi(lopullinenLista, filesDir: filesDir);
        _lahetaScanEvent(BookScanEvent(
          books: List.unmodifiable(lopullinenLista),
          current: 0,
          total: 0,
          currentBookName: '',
          statusText: 'Kirjahylly ajan tasalla',
          isScanning: false,
        ));
        return lopullinenLista;
      }

      final int totalToScan = skannattavat.length;
      _lahetaScanEvent(BookScanEvent(
        books: List.unmodifiable(_jarjestaKirjat(valmiitKirjat.values)),
        current: 0,
        total: totalToScan,
        currentBookName: '',
        statusText: 'Skannataan kirjoja (0 / $totalToScan)...',
        isScanning: true,
      ));

      for (int i = 0; i < totalToScan; i++) {
        final candidate = skannattavat[i];
        final String tiedostoNimi = p.basenameWithoutExtension(candidate.file.path);

        _lahetaScanEvent(BookScanEvent(
          books: List.unmodifiable(_jarjestaKirjat(valmiitKirjat.values)),
          current: i + 1,
          total: totalToScan,
          currentBookName: tiedostoNimi,
          statusText: 'Luetaan metatietoja (${i + 1} / $totalToScan)...',
          isScanning: true,
        ));
        onProgress?.call(
          i + 1,
          totalToScan,
          tiedostoNimi,
          'Käsitellään kirjaa ${i + 1} / $totalToScan...',
        );

        // Pieni vuoronvaihtotauko pitää Androidin UI-säikeen täysin responsiivisena
        await Future.delayed(const Duration(milliseconds: 25));

        IndexedBook skannattuKirja;
        try {
          skannattuKirja = await _skannaaYksittainenKirja(
            candidate,
            pakotaUudelleenSkannaus: pakotaUudelleenSkannaus,
          ).timeout(const Duration(seconds: 12));
        } catch (e) {
          debugPrint('Kirjan skannaus epäonnistui (${candidate.file.path}): $e');
          final IndexedBook? vanha = candidate.vanhaKirja;
          skannattuKirja = IndexedBook(
            title: vanha?.title.isNotEmpty == true ? vanha!.title : tiedostoNimi,
            path: candidate.file.path,
            thumbnailPath:
                File(candidate.kuvaPolku).existsSync() ? candidate.kuvaNimi : '',
            lastReadPage: vanha?.lastReadPage ?? 1,
            lastReadScrollRatio: vanha?.lastReadScrollRatio ?? 0.0,
            lastReadTimestamp: vanha?.lastReadTimestamp ?? 0,
            fileModifiedTimestamp: candidate.muokkausaika,
            fileAddedTimestamp: vanha?.fileAddedTimestamp ?? candidate.muokkausaika,
            author: vanha?.author ?? 'Tuntematon',
            publisher: vanha?.publisher ?? 'Tuntematon',
            publishDateText: vanha?.publishDateText ?? 'Tuntematon',
            publishYear: vanha?.publishYear ?? 0,
            tags: vanha?.tags ?? const [],
            series: vanha?.series ?? '',
            seriesNumber: vanha?.seriesNumber ?? '',
            isPdf: candidate.ext == '.pdf',
          );
        }

        valmiitKirjat[candidate.file.path] = skannattuKirja;
        final paivitettyLista = _jarjestaKirjat(valmiitKirjat.values);

        // Tallennetaan levyindeksi harvennettuna (joka 5. kirja + lopuksi)
        if ((i + 1) % 5 == 0) {
          await _tallennaIndeksi(paivitettyLista, filesDir: filesDir);
        }

        // Lähetetään heti reaaliaikainen tapahtuma kirjahyllyyn
        _lahetaScanEvent(BookScanEvent(
          books: List.unmodifiable(paivitettyLista),
          latestScannedBook: skannattuKirja,
          current: i + 1,
          total: totalToScan,
          currentBookName: skannattuKirja.title,
          statusText: 'Skannattu (${i + 1} / $totalToScan): ${skannattuKirja.title}',
          isScanning: true,
        ));
      }

      final lopullinenLista = _jarjestaKirjat(valmiitKirjat.values);
      await _tallennaIndeksi(lopullinenLista, filesDir: filesDir);

      _lahetaScanEvent(BookScanEvent(
        books: List.unmodifiable(lopullinenLista),
        current: totalToScan,
        total: totalToScan,
        currentBookName: '',
        statusText: 'Skannaus valmis',
        isScanning: false,
      ));

      return lopullinenLista;
    } finally {
      await ScreenWakeHelper.asetaNayttoPaalle(false);
    }
  }
}
