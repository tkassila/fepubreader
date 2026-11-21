import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/indexed_book_scanner.dart';

/// Yksittäisen kirjan tallennettu lukukohta
class ReadingPosition {
  final String bookPath;
  final int pageNumber;
  final double scrollOffsetRatio;
  final int timestamp;

  const ReadingPosition({
    required this.bookPath,
    required this.pageNumber,
    this.scrollOffsetRatio = 0.0,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'bookPath': bookPath,
    'pageNumber': pageNumber,
    'scrollOffsetRatio': scrollOffsetRatio,
    'timestamp': timestamp,
  };

  factory ReadingPosition.fromJson(Map<String, dynamic> json) => ReadingPosition(
    bookPath: json['bookPath'] as String? ?? '',
    pageNumber: json['pageNumber'] as int? ?? 1,
    scrollOffsetRatio: (json['scrollOffsetRatio'] as num?)?.toDouble() ?? 0.0,
    timestamp: json['timestamp'] as int? ?? 0,
  );
}

/// Kirjakohtainen lukukohdan hallintapalvelu.
///
/// LUKEMISEN AIKANA: Lukukohtaa päivitetään vain RAM-muistissa (0 levykirjoitusta),
/// jotta vieritys ja sivunkäännöt pysyvät täysin sulavina ja levy ei kulu.
///
/// LEVYLLE KIRJOITUS: Tiedot kirjoitetaan SharedPreferencesiin ja kirja_indeksi.jsoniin
/// VASTA KUN KIRJASTA POISTUTAAN ULOS tai sovellus siirtyy taustalle.
class ReadingPositionService {
  // Välimuisti aktiiviselle lukukohdalle muistissa
  static ReadingPosition? _muistissaOlevaKohta;
  static bool _muistissaOliPdf = true;
  static bool _onTallennettavaaLevylle = false;

  static String _hashPath(String path) {
    return sha256.convert(utf8.encode(path)).toString().substring(0, 32);
  }

  /// Hakee kyseisen kirjan viimeisimmän tallennetun lukukohdan.
  /// Tarkistaa ensin nopean muistivälimuistin, sitten SharedPreferencesin ja lopuksi kirjahyllyn indeksin.
  static Future<ReadingPosition> haeLukukohta(
    String bookPath, {
    int oletusSivu = 1,
    double oletusScrollRatio = 0.0,
  }) async {
    // 1. Tarkistetaan muistivälimuisti
    if (_muistissaOlevaKohta != null && _muistissaOlevaKohta!.bookPath == bookPath) {
      return _muistissaOlevaKohta!;
    }

    // 2. Haetaan SharedPreferencesistä
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _hashPath(bookPath);

      final page = prefs.getInt('readpos_page_$key');
      final scroll = prefs.getDouble('readpos_scroll_$key');
      final time = prefs.getInt('readpos_time_$key');

      if (page != null && page > 0) {
        final pos = ReadingPosition(
          bookPath: bookPath,
          pageNumber: page,
          scrollOffsetRatio: scroll ?? oletusScrollRatio,
          timestamp: time ?? 0,
        );
        _muistissaOlevaKohta = pos;
        return pos;
      }
    } catch (_) {}

    // 3. Toissijainen haku indeksoiduista kirjoista
    try {
      final indeksi = await IndexedBookScanner.lueIndeksi();
      final kirja = indeksi.cast<IndexedBook?>().firstWhere(
            (k) => k?.path == bookPath,
            orElse: () => null,
          );
      if (kirja != null && kirja.lastReadPage > 0) {
        final pos = ReadingPosition(
          bookPath: bookPath,
          pageNumber: kirja.lastReadPage,
          scrollOffsetRatio: kirja.lastReadScrollRatio,
          timestamp: kirja.lastReadTimestamp,
        );
        _muistissaOlevaKohta = pos;
        return pos;
      }
    } catch (_) {}

    return ReadingPosition(
      bookPath: bookPath,
      pageNumber: oletusSivu > 0 ? oletusSivu : 1,
      scrollOffsetRatio: oletusScrollRatio,
      timestamp: 0,
    );
  }

  /// Päivittää lukukohdan AINOASTAAN RAM-muistissa lukemisen aikana (0 levykirjoitusta).
  /// Tämä takaa viiveettömän lukukokemuksen ja estää levyn kuormittamisen.
  static void paivitaLukukohtaMuistissa({
    required String bookPath,
    required int pageNumber,
    double scrollOffsetRatio = 0.0,
    required bool isPdf,
  }) {
    final clampedRatio = scrollOffsetRatio.clamp(0.0, 1.0);
    final clampedPage = pageNumber > 0 ? pageNumber : 1;

    _muistissaOlevaKohta = ReadingPosition(
      bookPath: bookPath,
      pageNumber: clampedPage,
      scrollOffsetRatio: clampedRatio,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _muistissaOliPdf = isPdf;
    _onTallennettavaaLevylle = true;
  }

  /// Yhteensopivuusmetodi aiemmille kutsuille: päivittää vain RAM-muistiin.
  static void tallennaLukukohtaDebounced({
    required String bookPath,
    required int pageNumber,
    double scrollOffsetRatio = 0.0,
    required bool isPdf,
    Duration delay = const Duration(milliseconds: 500),
  }) {
    paivitaLukukohtaMuistissa(
      bookPath: bookPath,
      pageNumber: pageNumber,
      scrollOffsetRatio: scrollOffsetRatio,
      isPdf: isPdf,
    );
  }

  /// Yhteensopivuusmetodi: ohjaa muistipäivitykseen (tai levylle vain jos erikseen pyydetään).
  static Future<void> tallennaLukukohta({
    required String bookPath,
    required int pageNumber,
    double scrollOffsetRatio = 0.0,
    required bool isPdf,
    bool paivitaIndeksiTiedosto = false,
  }) async {
    paivitaLukukohtaMuistissa(
      bookPath: bookPath,
      pageNumber: pageNumber,
      scrollOffsetRatio: scrollOffsetRatio,
      isPdf: isPdf,
    );

    if (paivitaIndeksiTiedosto) {
      await tallennaLevylle();
    }
  }

  /// Kirjoittaa lukukohdan levylle (SharedPreferences + kirja_indeksi.json)
  /// VASTA KUN KIRJASTA POISTUTAAN tai sovellus siirtyy taustalle.
  static Future<void> tallennaLevylle({
    String? bookPath,
    int? pageNumber,
    double? scrollOffsetRatio,
    bool? isPdf,
  }) async {
    if (bookPath != null && pageNumber != null) {
      paivitaLukukohtaMuistissa(
        bookPath: bookPath,
        pageNumber: pageNumber,
        scrollOffsetRatio: scrollOffsetRatio ?? 0.0,
        isPdf: isPdf ?? _muistissaOliPdf,
      );
    }

    if (_muistissaOlevaKohta == null || !_onTallennettavaaLevylle) return;

    final pos = _muistissaOlevaKohta!;
    final path = pos.bookPath;
    final page = pos.pageNumber;
    final ratio = pos.scrollOffsetRatio;
    final now = DateTime.now().millisecondsSinceEpoch;
    final oliPdf = isPdf ?? _muistissaOliPdf;

    _onTallennettavaaLevylle = false;

    // 1. Kirjoitetaan SharedPreferences levylle
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _hashPath(path);

      await prefs.setInt('readpos_page_$key', page);
      await prefs.setDouble('readpos_scroll_$key', ratio);
      await prefs.setInt('readpos_time_$key', now);

      await prefs.setString('viimeksi_luettu_polku', path);
      await prefs.setInt('viimeksi_luettu_sivu', page);
      await prefs.setDouble('viimeksi_luettu_offset', ratio);
      await prefs.setBool('viimeksi_luettu_olipdf', oliPdf);
      await prefs.setInt('viimeksi_luettu_aikaleima', now);
    } catch (_) {}

    // 2. Päivitetään kirjahyllyn kirja_indeksi.json levylle
    try {
      await IndexedBookScanner.paivitaLukutilanne(
        path,
        page,
        scrollRatio: ratio,
      );
    } catch (_) {}
  }

  /// Huuhtelee muistitilan ja kirjoittaa levylle heti poistuttaessa.
  static Future<void> huuhteleJaTallenna({
    required String bookPath,
    required int pageNumber,
    double scrollOffsetRatio = 0.0,
    required bool isPdf,
  }) async {
    await tallennaLevylle(
      bookPath: bookPath,
      pageNumber: pageNumber,
      scrollOffsetRatio: scrollOffsetRatio,
      isPdf: isPdf,
    );
  }

  /// Poistaa kirjan tallennetun lukukohdan SharedPreferencesistä ja muistista
  static Future<void> poistaLukukohta(String bookPath) async {
    if (_muistissaOlevaKohta != null && _muistissaOlevaKohta!.bookPath == bookPath) {
      _muistissaOlevaKohta = null;
      _onTallennettavaaLevylle = false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _hashPath(bookPath);
      await prefs.remove('readpos_page_$key');
      await prefs.remove('readpos_scroll_$key');
      await prefs.remove('readpos_time_$key');

      final viimeisin = prefs.getString('viimeksi_luettu_polku');
      if (viimeisin == bookPath) {
        await prefs.remove('viimeksi_luettu_polku');
        await prefs.remove('viimeksi_luettu_sivu');
        await prefs.remove('viimeksi_luettu_offset');
        await prefs.remove('viimeksi_luettu_olipdf');
        await prefs.remove('viimeksi_luettu_aikaleima');
      }
    } catch (_) {}
  }
}
