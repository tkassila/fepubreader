import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../data/indexed_book_scanner.dart';
import 'mobi_to_epub_converter.dart';
import 'screen_wake_helper.dart';
import 'text_encoding_helper.dart';

/// Hylätyn / ohitetun kirjan tiedot tuonnin aikana
class SkippedBook {
  final String title;
  final String reason;
  SkippedBook(this.title, this.reason);
}

/// Tuonnin vaiheet
enum ImportPhase { copying, indexing, completed, error }

/// Tuonnin reaaliaikainen edistymistila
class BookImportProgress {
  final ImportPhase phase;
  final int current;
  final int total;
  final String currentItemName;
  final String statusText;
  final bool isRunning;
  final List<SkippedBook> skipped;
  final int importedCount;

  const BookImportProgress({
    required this.phase,
    required this.current,
    required this.total,
    required this.currentItemName,
    required this.statusText,
    required this.isRunning,
    this.skipped = const [],
    this.importedCount = 0,
  });

  double get progressRatio => total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;
  int get progressPercent => (progressRatio * 100).toInt();
}

/// Tuontioperaation lopputulos
class BookImportResult {
  final int importedCount;
  final List<SkippedBook> skipped;
  final List<IndexedBook> updatedBooks;

  const BookImportResult({
    required this.importedCount,
    required this.skipped,
    required this.updatedBooks,
  });
}

/// GUI:sta riippumaton kirjojen massatuontipalvelu (Singleton).
///
/// Hoitaa tiedostojen kopioinnin, duplikaattitarkistukset sekä
/// IndexedBookScanner-metatieto- ja kansikuvaskannauksen taustalla
/// käyttöliittymää jumiuttamatta.
class BookImportService {
  BookImportService._();
  static final BookImportService instance = BookImportService._();

  final ValueNotifier<BookImportProgress?> progressNotifier = ValueNotifier(null);

  bool _peruutettu = false;

  bool get isImporting => progressNotifier.value?.isRunning ?? false;

  /// Nollaa edistymisilmoituksen (esim. kun käyttäjä sulkee bannerin)
  void nollaaTila() {
    if (!isImporting) {
      progressNotifier.value = null;
    }
  }

  /// Keskeyttää meneillään olevan tuonnin
  void peruuta() {
    _peruutettu = true;
  }

  /// Tuo valitut tiedostopolut kohdehakemistoon
  Future<BookImportResult> tuoTiedostot({
    required List<String> tiedostoPolut,
    required String kohdeHakemisto,
    List<IndexedBook>? nykyisetKirjat,
  }) async {
    if (isImporting) {
      return BookImportResult(
        importedCount: 0,
        skipped: [SkippedBook('Kaikki', 'Tuonti on jo käynnissä')],
        updatedBooks: nykyisetKirjat ?? [],
      );
    }

    _peruutettu = false;
    final List<SkippedBook> skipped = [];
    int lisatytMaara = 0;
    final int totalFiles = tiedostoPolut.length;

    if (totalFiles == 0) {
      return BookImportResult(importedCount: 0, skipped: [], updatedBooks: nykyisetKirjat ?? []);
    }

    await ScreenWakeHelper.asetaNayttoPaalle(true);
    try {
      // Varmistetaan että kohdehakemisto on olemassa
      final kohdeDir = Directory(kohdeHakemisto);
      if (!await kohdeDir.exists()) {
        await kohdeDir.create(recursive: true);
      }

      // Haetaan nykyiset kirjat duplikaattitarkistusta varten
      List<IndexedBook> vertailuKirjat = nykyisetKirjat ?? await IndexedBookScanner.lueIndeksi();

      // ── VAIHE 1: Tiedostojen tarkistus ja kopiointi ──
      for (int i = 0; i < totalFiles; i++) {
        if (_peruutettu) {
          skipped.add(SkippedBook('Loput tiedostot', 'Käyttäjä keskeytti tuonnin'));
          break;
        }

        final lahdePolku = tiedostoPolut[i];
        final bool onMobi = MobiToEpubConverter.onkoMobiTiedosto(lahdePolku);
        final fileName = p.basename(lahdePolku);
        final nimiIlmanPaatetta = TextEncodingHelper.korjaaMerkistovirheet(p.basenameWithoutExtension(fileName));
        // Jos tiedosto on MOBI, kohdetiedosto tallennetaan suoraan EPUB-muodossa
        final kohdePolku = onMobi
            ? p.join(kohdeHakemisto, '$nimiIlmanPaatetta.epub')
            : p.join(kohdeHakemisto, fileName);

        progressNotifier.value = BookImportProgress(
          phase: ImportPhase.copying,
          current: i + 1,
          total: totalFiles,
          currentItemName: fileName,
          statusText: onMobi
              ? 'Muunnetaan MOBI -> EPUB (${i + 1} / $totalFiles)...'
              : 'Kopioidaan tiedostoja (${i + 1} / $totalFiles)...',
          isRunning: true,
          skipped: List.unmodifiable(skipped),
          importedCount: lisatytMaara,
        );

        // Duplikaattitarkistus kirjastosta
        final bool onJoListalla = vertailuKirjat.any((k) =>
            k.path == kohdePolku ||
            k.title.toLowerCase() == nimiIlmanPaatetta.toLowerCase());

        if (onJoListalla) {
          skipped.add(SkippedBook(nimiIlmanPaatetta, 'Kirja on jo kirjastossa'));
          continue;
        }

        // Duplikaattitarkistus levyltä
        final File kohdeTiedosto = File(kohdePolku);
        if (await kohdeTiedosto.exists()) {
          skipped.add(SkippedBook(nimiIlmanPaatetta, 'Tiedosto on jo olemassa'));
          continue;
        }

        // Fyysinen käsittely: MOBI muunnetaan suoraan EPUBiksi, muut kopioidaan
        try {
          if (onMobi) {
            await MobiToEpubConverter.muunnaEpubiksi(
              File(lahdePolku),
              kohdeEpubPolku: kohdePolku,
            );
          } else {
            await File(lahdePolku).copy(kohdePolku);
          }
          lisatytMaara++;
        } catch (e) {
          skipped.add(SkippedBook(nimiIlmanPaatetta, onMobi ? 'MOBI-muunnos epäonnistui: $e' : 'Kopiointivirhe: $e'));
        }

        // Anna GUI-säikeelle tilaa piirtää kehys sulavasti
        await Future.delayed(const Duration(milliseconds: 10));
      }

      // ── VAIHE 2: Indeksointi ja kansikuvien generointi ──
      List<IndexedBook> paivitetytKirjat = vertailuKirjat;

      if (lisatytMaara > 0 || await IndexedBookScanner.tarkistaMuutoksetTaustalla(kohdeHakemisto, vertailuKirjat)) {
        progressNotifier.value = BookImportProgress(
          phase: ImportPhase.indexing,
          current: 0,
          total: totalFiles,
          currentItemName: '',
          statusText: 'Luodaan kansikuvia ja luetaan tietoja...',
          isRunning: true,
          skipped: List.unmodifiable(skipped),
          importedCount: lisatytMaara,
        );

        paivitetytKirjat = await IndexedBookScanner.odotaUudelleenSkannaus(
          kohdeHakemisto,
          onProgress: (current, total, bookName, phase) {
            progressNotifier.value = BookImportProgress(
              phase: ImportPhase.indexing,
              current: current,
              total: total,
              currentItemName: bookName,
              statusText: 'Käsitellään kirjaa $current / $total...',
              isRunning: true,
              skipped: List.unmodifiable(skipped),
              importedCount: lisatytMaara,
            );
          },
        );
      }

      // ── VAIHE 3: Valmis ──
      final result = BookImportResult(
        importedCount: lisatytMaara,
        skipped: skipped,
        updatedBooks: paivitetytKirjat,
      );

      progressNotifier.value = BookImportProgress(
        phase: ImportPhase.completed,
        current: totalFiles,
        total: totalFiles,
        currentItemName: '',
        statusText: lisatytMaara > 0
            ? 'Valmis: $lisatytMaara uutta kirjaa tuotu onnistuneesti!'
            : 'Valmis: Ei uusia tuotuja kirjoja.',
        isRunning: false,
        skipped: List.unmodifiable(skipped),
        importedCount: lisatytMaara,
      );

      return result;
    } finally {
      await ScreenWakeHelper.asetaNayttoPaalle(false);
    }
  }

  /// Tuo kokonaisen kansion kaikki .pdf, .epub ja .mobi -kirjat
  Future<BookImportResult> tuoKansiosta({
    required String lahdeKansio,
    required String kohdeHakemisto,
    List<IndexedBook>? nykyisetKirjat,
  }) async {
    final dir = Directory(lahdeKansio);
    if (!await dir.exists()) {
      return BookImportResult(
        importedCount: 0,
        skipped: [SkippedBook(lahdeKansio, 'Kansiota ei löydy')],
        updatedBooks: nykyisetKirjat ?? [],
      );
    }

    final List<String> loydetytPolut = [];
    try {
      final entities = dir.listSync(recursive: true);
      for (var e in entities) {
        if (e is File) {
          final ext = p.extension(e.path).toLowerCase();
          if (ext == '.pdf' || ext == '.epub' || ext == '.mobi' || ext == '.prc') {
            loydetytPolut.add(e.path);
          }
        }
      }
    } catch (e) {
      return BookImportResult(
        importedCount: 0,
        skipped: [SkippedBook(lahdeKansio, 'Virhe kansion lukemisessa: $e')],
        updatedBooks: nykyisetKirjat ?? [],
      );
    }

    return tuoTiedostot(
      tiedostoPolut: loydetytPolut,
      kohdeHakemisto: kohdeHakemisto,
      nykyisetKirjat: nykyisetKirjat,
    );
  }
}
