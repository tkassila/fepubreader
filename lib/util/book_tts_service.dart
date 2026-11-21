import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'text_encoding_helper.dart';

enum BookTtsState { idle, playing, paused }

/// Tekstinpätkä (chunk) pitkän tekstin turvallista ja pätkittäistä TTS-lentoa varten.
/// Androidin TextToSpeech rajoittaa yksittäisen syötteen enintään 4000 merkkiin.
class TtsChunk {
  final String text;
  final int startOffset;
  final int endOffset;

  const TtsChunk({
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });
}

/// Tuettu TTS-kieli (Suomi, Englanti, Ruotsi, Saksa, Ranska, Espanja, Italia ja Automaattinen).
class TtsLanguage {
  final String code; // esim. 'auto', 'fi-FI', 'en-US', 'sv-SE', 'de-DE', 'fr-FR', 'es-ES', 'it-IT'
  final String name; // esim. 'Suomi', 'Englanti (English)'
  final String flag; // esim. '🇫🇮', '🇬🇧'

  const TtsLanguage({required this.code, required this.name, required this.flag});
}

const List<TtsLanguage> tuetutTtsKielet = [
  TtsLanguage(code: 'auto', name: 'Automaattinen tunnistus (suositus)', flag: '🌐'),
  TtsLanguage(code: 'fi-FI', name: 'Suomi', flag: '🇫🇮'),
  TtsLanguage(code: 'en-US', name: 'Englanti (English)', flag: '🇬🇧'),
  TtsLanguage(code: 'sv-SE', name: 'Ruotsi (Svenska)', flag: '🇸🇪'),
  TtsLanguage(code: 'de-DE', name: 'Saksa (Deutsch)', flag: '🇩🇪'),
  TtsLanguage(code: 'fr-FR', name: 'Ranska (Français)', flag: '🇫🇷'),
  TtsLanguage(code: 'es-ES', name: 'Espanja (Español)', flag: '🇪🇸'),
  TtsLanguage(code: 'it-IT', name: 'Italia (Italiano)', flag: '🇮🇹'),
];

/// Älykäs puhepalvelu e-kirjojen ääneen lukuun (TTS).
/// Tukee automaattista kielen tunnistusta (Suomi, Englanti, Ruotsi, Saksa, Ranska, Espanja, Italia),
/// taulukoiden ja kuvien tunnistusta, pause/jatka-tilojen hallintaa (jatkaa lauseen alusta),
/// puhenopeuden säätöä, lukukohdan muistamista sekä sanakohtaista edistymistä.
class BookTtsService {
  BookTtsService({this.onWordSpoken, this.onProgressRatio, this.onPageFinished}) {
    _initFuture = _initTts();
    speechRateNotifier.addListener(_onGlobalSpeechRateChanged);
  }

  final FlutterTts _flutterTts = FlutterTts();
  final ValueNotifier<BookTtsState> stateNotifier = ValueNotifier(BookTtsState.idle);
  final ValueNotifier<String> currentWordNotifier = ValueNotifier('');

  /// Globaali puhenopeuden tila (0.2 .. 1.0, jossa 0.5 = 1.0x normaalinopeus Androidissa).
  static const String _speechRatePrefKey = 'tts_speech_rate_global';
  static final ValueNotifier<double> speechRateNotifier = ValueNotifier<double>(0.5);
  static bool _speechRateLoaded = false;

  late final Future<void> _initFuture;
  bool _isInitialized = false;

  // Takaisinkutsut UI:lle
  final void Function(String word, int startOffset, int endOffset)? onWordSpoken;
  final void Function(double ratio, String word)? onProgressRatio;
  final VoidCallback? onPageFinished;

  String _currentFullText = '';
  List<TtsChunk> _chunks = [];
  int _currentChunkIndex = 0;
  int _currentChunkSubOffset = 0;
  int _currentWordStart = 0;
  int _currentWordEnd = 0;
  String _currentBookPath = '';
  int _currentPageNumber = 1;

  // Kielen hallinta
  String _selectedLanguageCode = 'auto'; // käyttäjän valinta ('auto' tai kielikoodi)
  String _activeLanguageCode = 'fi-FI';   // puhekoneelle tällä hetkellä asetettu kieli

  BookTtsState get state => stateNotifier.value;
  bool get isSpeechActive => state != BookTtsState.idle;
  bool get isPlaying => state == BookTtsState.playing;
  bool get isPaused => state == BookTtsState.paused;
  String get currentWord => currentWordNotifier.value;
  int get currentWordStart => _currentWordStart;
  int get currentWordEnd => _currentWordEnd;
  String get currentFullText => _currentFullText;
  int get currentPageNumber => _currentPageNumber;
  String get selectedLanguageCode => _selectedLanguageCode;
  String get activeLanguageCode => _activeLanguageCode;

  String get aktiivinenKieliNimi {
    final match = tuetutTtsKielet.firstWhere(
      (l) => l.code == _activeLanguageCode,
      orElse: () => TtsLanguage(code: _activeLanguageCode, name: _activeLanguageCode, flag: '🗣️'),
    );
    return '${match.flag} ${match.name}';
  }

  static String _hashPath(String path) {
    return sha256.convert(utf8.encode(path)).toString().substring(0, 32);
  }

  /// Hakee tallennetun puhenopeuden (oletus 0.5 = 1.0x normaali).
  static Future<double> haePuhenopeus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tallennettu = prefs.getDouble(_speechRatePrefKey);
      if (tallennettu != null) {
        final clamped = tallennettu.clamp(0.2, 1.0);
        speechRateNotifier.value = clamped;
        _speechRateLoaded = true;
        return clamped;
      }
    } catch (_) {}
    _speechRateLoaded = true;
    return speechRateNotifier.value;
  }

  /// Tallentaa uuden puhenopeuden (0.2 .. 1.0). Vaikuttaa heti seuraavaan TTS-puheeseen.
  static Future<void> asetaPuhenopeus(double uusiNopeus) async {
    final clamped = uusiNopeus.clamp(0.2, 1.0);
    speechRateNotifier.value = clamped;
    _speechRateLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_speechRatePrefKey, clamped);
    } catch (_) {}
  }

  /// Muotoilee puhenopeuden (0.2..1.0) selkeäksi kertoimeksi (esim. "1.0x (100%)").
  static String muotoilePuhenopeus(double rate) {
    final kerroin = rate * 2.0;
    final prosentti = (rate * 200).round();
    return '${kerroin.toStringAsFixed(1)}x ($prosentti%)';
  }

  void _onGlobalSpeechRateChanged() {
    if (_isInitialized) {
      _flutterTts.setSpeechRate(speechRateNotifier.value);
    }
  }

  /// Etsii suoraan pysäytyssanan (sananAlkuOffset) tarkan alun tekstistä.
  static int etsiPysaytyssananAlku(String teksti, int sananAlkuOffset) {
    if (teksti.isEmpty || sananAlkuOffset <= 0) return 0;
    if (sananAlkuOffset >= teksti.length) return 0;

    final RegExp valimerkkiTaiVali = RegExp(r'[\s.!?\n,;:\-\u2013\u2014]');

    int sananAlku = sananAlkuOffset;
    while (sananAlku < teksti.length && RegExp(r'\s').hasMatch(teksti[sananAlku])) {
      sananAlku++;
    }
    if (sananAlku >= teksti.length) {
      sananAlku = sananAlkuOffset;
    }
    while (sananAlku > 0 && !valimerkkiTaiVali.hasMatch(teksti[sananAlku - 1])) {
      sananAlku--;
    }

    return sananAlku.clamp(0, teksti.length);
  }

  /// Laskee uuden sanan sijainnin (start, end, word), kun siirrytään [sanamaara] sanaa
  /// taaksepäin (esim. -3) tai eteenpäin (esim. +3) nykyisestä kohdasta [nykyinenOffset].
  static ({int start, int end, String word})? laskeSanaSiirtyma(
    String teksti,
    int nykyinenOffset,
    int sanamaara,
  ) {
    if (teksti.trim().isEmpty) return null;

    final wordRegex = RegExp(r'[\p{L}\p{N}]+', unicode: true);
    final matches = wordRegex.allMatches(teksti).toList();
    if (matches.isEmpty) return null;

    final int clampedOffset = nykyinenOffset.clamp(0, teksti.length);

    // Etsitään nykyistä offsetia vastaava tai seuraava sana-indeksi
    int currentIdx = 0;
    for (int i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (clampedOffset >= m.start && clampedOffset <= m.end) {
        currentIdx = i;
        break;
      }
      if (m.start > clampedOffset) {
        currentIdx = i;
        break;
      }
      currentIdx = i;
    }

    final int targetIdx = (currentIdx + sanamaara).clamp(0, matches.length - 1);
    final Match targetMatch = matches[targetIdx];

    return (
      start: targetMatch.start,
      end: targetMatch.end,
      word: targetMatch.group(0) ?? '',
    );
  }

  /// Etsii annetun pysäytyssanan (sananAlkuOffset) lauseen alun tekstistä.
  /// Jos lauseen alkua ei löydy kohtuulliselta etäisyydeltä, palauttaa pysäytyssanan alun.
  static int etsiLauseenTaiSananAlku(
    String teksti,
    int sananAlkuOffset, {
    int maxEtsintaMatka = 350,
  }) {
    if (teksti.isEmpty || sananAlkuOffset <= 0) return 0;
    if (sananAlkuOffset >= teksti.length) return 0;

    final RegExp valimerkkiTaiVali = RegExp(r'[\s.!?\n,;:\-\u2013\u2014]');

    // 1. Varmistetaan että ollaan pysäytyssanan alussa
    int sananAlku = sananAlkuOffset;
    while (sananAlku < teksti.length && RegExp(r'\s').hasMatch(teksti[sananAlku])) {
      sananAlku++;
    }
    if (sananAlku >= teksti.length) {
      sananAlku = sananAlkuOffset;
    }
    while (sananAlku > 0 && !valimerkkiTaiVali.hasMatch(teksti[sananAlku - 1])) {
      sananAlku--;
    }

    if (sananAlku <= 0) return 0;

    // 2. Etsitään taaksepäin edellisen lauseen päättävä merkki (., !, ?, \n)
    final int alaraja = (sananAlku - maxEtsintaMatka) > 0 ? (sananAlku - maxEtsintaMatka) : 0;
    int lauseRaja = -1;

    for (int i = sananAlku - 1; i >= alaraja; i--) {
      final String c = teksti[i];
      if (c == '.' || c == '!' || c == '?' || c == '\n') {
        lauseRaja = i;
        break;
      }
    }

    int ehdokasAlku = -1;
    if (lauseRaja != -1) {
      ehdokasAlku = lauseRaja + 1;
    } else if (alaraja == 0) {
      // Ollaan tekstin ensimmäisessä lauseessa ja etäisyys alkuun <= maxEtsintaMatka
      ehdokasAlku = 0;
    }

    if (ehdokasAlku != -1) {
      // Siirrytään lauseen ensimmäisen varsinaisen sanan alkuun (ohitetaan välilyönnit ja pisteet)
      while (ehdokasAlku < sananAlku && valimerkkiTaiVali.hasMatch(teksti[ehdokasAlku])) {
        ehdokasAlku++;
      }
      if (ehdokasAlku >= 0 && ehdokasAlku <= sananAlku) {
        return ehdokasAlku;
      }
    }

    // Jos lauseen alkua ei löytynyt, aloitetaan suoraan pysäytyssanasta
    return sananAlku;
  }

  /// Tunnistaa tekstin kielen luonnollisten stop-sanojen esiintyvyyden perusteella.
  /// Tukee suomea, englantia, ruotsia, saksaa, ranskaa, espanjaa ja italiaa.
  static String tunnistaTekstinKieli(String teksti) {
    if (teksti.trim().isEmpty) return 'fi-FI';

    // Otetaan ensimmäiset 200 sanaa analyysiin
    final sanat = teksti
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\s]', unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((s) => s.length >= 2)
        .take(200)
        .toList();

    if (sanat.isEmpty) return 'fi-FI';

    int fiPisteet = 0;
    int enPisteet = 0;
    int svPisteet = 0;
    int dePisteet = 0;
    int frPisteet = 0;
    int esPisteet = 0;
    int itPisteet = 0;

    const fiStop = {'ja', 'on', 'ei', 'että', 'hän', 'oli', 'mutta', 'niin', 'kuin', 'joka', 'se', 'ovat', 'myös', 'vain', 'hänellä', 'tämä', 'kun', 'tai', 'jo', 'sitten'};
    const enStop = {'the', 'and', 'of', 'to', 'in', 'is', 'that', 'was', 'for', 'it', 'with', 'as', 'his', 'on', 'be', 'at', 'by', 'this', 'had', 'not', 'are', 'from', 'you'};
    const svStop = {'och', 'det', 'att', 'i', 'en', 'jag', 'hon', 'han', 'på', 'som', 'inte', 'med', 'var', 'ett', 'om', 'men', 'av', 'de', 'den', 'här'};
    const deStop = {'und', 'der', 'die', 'das', 'ist', 'in', 'nicht', 'ein', 'eine', 'mit', 'den', 'dem', 'zu', 'sie', 'es', 'ich', 'auf', 'so', 'aber', 'von'};
    const frStop = {'le', 'la', 'les', 'et', 'de', 'des', 'un', 'une', 'est', 'dans', 'que', 'qui', 'en', 'du', 'pour', 'avec', 'ce', 'pas', 'sur', 'au'};
    const esStop = {'el', 'la', 'los', 'las', 'de', 'en', 'y', 'a', 'que', 'un', 'una', 'es', 'por', 'con', 'no', 'para', 'su', 'al', 'lo', 'como'};
    const itStop = {'il', 'la', 'lo', 'i', 'gli', 'le', 'di', 'che', 'e', 'in', 'un', 'una', 'per', 'con', 'non', 'sono', 'da', 'ma', 'questo', 'come'};

    for (final s in sanat) {
      if (fiStop.contains(s)) fiPisteet++;
      if (enStop.contains(s)) enPisteet++;
      if (svStop.contains(s)) svPisteet++;
      if (deStop.contains(s)) dePisteet++;
      if (frStop.contains(s)) frPisteet++;
      if (esStop.contains(s)) esPisteet++;
      if (itStop.contains(s)) itPisteet++;
    }

    final pisteet = {
      'fi-FI': fiPisteet,
      'en-US': enPisteet,
      'sv-SE': svPisteet,
      'de-DE': dePisteet,
      'fr-FR': frPisteet,
      'es-ES': esPisteet,
      'it-IT': itPisteet,
    };

    final paras = pisteet.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return paras.value > 0 ? paras.key : 'fi-FI';
  }

  /// Jakaa pitkän tekstin pienempiin, luonnollisiin lause-/kappaleosiin (enintään ~1500 merkkiä).
  /// Tämä estää Androidin TextToSpeech 4000 merkin rajan ylittymisen ja mykistymisen.
  static List<TtsChunk> jaaTekstiOsiin(String fullText, {int maxChunkLength = 1500}) {
    if (fullText.trim().isEmpty) return [];
    if (fullText.length <= maxChunkLength) {
      return [TtsChunk(text: fullText, startOffset: 0, endOffset: fullText.length)];
    }

    final List<TtsChunk> chunks = [];
    int start = 0;

    while (start < fullText.length) {
      int end = (start + maxChunkLength < fullText.length)
          ? start + maxChunkLength
          : fullText.length;

      if (end < fullText.length) {
        // Etsitään lauseraja: piste, huutomerkki, kysymysmerkki tai rivinvaihto
        int splitIndex = -1;
        for (int i = end; i > start + (maxChunkLength ~/ 2); i--) {
          final c = fullText[i - 1];
          if (c == '.' || c == '!' || c == '?' || c == '\n') {
            splitIndex = i;
            break;
          }
        }

        // Jos ei lauserajaa löydy, etsitään pilkku, puolipiste tai väli
        if (splitIndex == -1) {
          for (int i = end; i > start + (maxChunkLength ~/ 3); i--) {
            final c = fullText[i - 1];
            if (c == ',' || c == ';' || c == ' ') {
              splitIndex = i;
              break;
            }
          }
        }

        if (splitIndex != -1) {
          end = splitIndex;
        }
      }

      final chunkText = fullText.substring(start, end);
      chunks.add(TtsChunk(
        text: chunkText,
        startOffset: start,
        endOffset: end,
      ));
      start = end;
      // Ohitetaan tyhjät tilat chunkin alusta
      while (start < fullText.length && fullText[start] == ' ') {
        start++;
      }
    }

    return chunks;
  }

  Future<void> _initTts() async {
    if (_isInitialized) return;
    try {
      // HUOM: Ei kutsuta setSilence(0), koska flutter_tts 4.2.5 Android-pluginissa
      // setSilence-haarasta puuttuu result.success(), mikä jumittaa Futuren ikuisesti!
      _flutterTts.setProgressHandler((String text, int start, int end, String word) {
        if (_chunks.isNotEmpty && _currentChunkIndex < _chunks.length) {
          final chunk = _chunks[_currentChunkIndex];
          final globalStart = chunk.startOffset + _currentChunkSubOffset + start;
          final globalEnd = chunk.startOffset + _currentChunkSubOffset + end;
          _currentWordStart = globalStart;
          _currentWordEnd = globalEnd;
          currentWordNotifier.value = word;
          onWordSpoken?.call(word, globalStart, globalEnd);

          if (_currentFullText.isNotEmpty) {
            final ratio = (globalStart / _currentFullText.length).clamp(0.0, 1.0);
            onProgressRatio?.call(ratio, word);
          }
        } else {
          _currentWordStart = start;
          _currentWordEnd = end;
          currentWordNotifier.value = word;
          onWordSpoken?.call(word, start, end);
        }
      });

      _flutterTts.setCompletionHandler(() {
        if (state == BookTtsState.playing) {
          // Siirrytään seuraavaan chunkiin, jos niitä on jäljellä
          if (_currentChunkIndex + 1 < _chunks.length) {
            _currentChunkIndex++;
            _puhuNykyinenChunk();
          } else {
            // Kaikki teksti luettu
            stateNotifier.value = BookTtsState.idle;
            currentWordNotifier.value = '';
            onPageFinished?.call();
          }
        }
      });

      _flutterTts.setErrorHandler((msg) {
        debugPrint('TTS Virheilmoitus: $msg');
        if (state == BookTtsState.playing) {
          stateNotifier.value = BookTtsState.idle;
        }
      });

      final rate = _speechRateLoaded ? speechRateNotifier.value : await haePuhenopeus();
      await _flutterTts.awaitSpeakCompletion(false);
      await _flutterTts.setSpeechRate(rate);
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setVolume(1.0);

      _isInitialized = true;
    } catch (e) {
      debugPrint('TTS Alustusvirhe: $e');
      _isInitialized = true;
    }
  }

  /// Päivittää puhekielen FlutterTts:lle tekstin ja käyttäjän valinnan mukaan
  Future<void> _paivitaKieliPuheelle({String? teksti}) async {
    String kohde = _selectedLanguageCode;
    if (kohde == 'auto') {
      kohde = (teksti != null && teksti.isNotEmpty)
          ? tunnistaTekstinKieli(teksti)
          : 'fi-FI';
    }
    _activeLanguageCode = kohde;

    try {
      // flutter_tts setLanguage tarkistaa sisäisesti isLanguageAvailable ja palauttaa 1 jos onnistui
      final res = await _flutterTts.setLanguage(kohde);
      if (res != 1) {
        final shortCode = kohde.split('-').first;
        final shortRes = await _flutterTts.setLanguage(shortCode);
        if (shortRes != 1 && kohde != 'en-US') {
          // Jos laitteelta puuttuu kyseinen kielipaketti kokonaan, kokeillaan en-US tai jätetään oletusääni
          await _flutterTts.setLanguage('en-US');
        }
      }
    } catch (e) {
      debugPrint('Kielen asetusvaroitus ($kohde): $e');
    }
  }

  /// Käyttäjän manuaalinen kielivalinta
  Future<void> asetaValittuKieli(String kieliKoodi, {String? teksti}) async {
    await _initFuture.timeout(const Duration(seconds: 2), onTimeout: () {});
    _selectedLanguageCode = kieliKoodi;
    await _paivitaKieliPuheelle(teksti: teksti ?? _currentFullText);
    await tallennaTila();
  }

  /// Avaa kielen ja puhenopeuden valintaikkunan käyttäjälle
  Future<String?> avaaKielivalikko(BuildContext context) async {
    final valittu = await avaaKielivalitsin(context, nykyinenKoodi: _selectedLanguageCode);
    if (valittu != null) {
      final bool wasPlaying = state == BookTtsState.playing;
      if (wasPlaying) {
        await pause();
      }
      await asetaValittuKieli(valittu);
      if (wasPlaying) {
        await resume();
      }
      return aktiivinenKieliNimi;
    }
    return null;
  }

  /// Rakennetaan uudelleenkäytettävä puhenopeuden säätöliukujana-widget (asetuksiin ja pikavalikkoon).
  static Widget rakennaPuhenopeusSaadin() {
    if (!_speechRateLoaded) {
      haePuhenopeus();
    }
    return ValueListenableBuilder<double>(
      valueListenable: speechRateNotifier,
      builder: (context, currentRate, _) {
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.teal.shade50.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.teal.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.speed, color: Colors.teal.shade800, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'TTS-puhenopeus',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade700,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      muotoilePuhenopeus(currentRate),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if ((currentRate - 0.5).abs() > 0.01) ...[
                    const SizedBox(width: 6),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => asetaPuhenopeus(0.5),
                      child: const Text('Palauta (1.0x)', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ],
              ),
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: Colors.teal.shade700,
                  thumbColor: Colors.teal.shade800,
                  overlayColor: Colors.teal.withValues(alpha: 0.15),
                ),
                child: Slider(
                  value: currentRate.clamp(0.2, 1.0),
                  min: 0.2,
                  max: 1.0,
                  divisions: 16,
                  label: muotoilePuhenopeus(currentRate),
                  onChanged: (double newVal) {
                    asetaPuhenopeus(newVal);
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Hidas (0.4x)', style: TextStyle(fontSize: 10.5, color: Colors.grey.shade700)),
                  Text('Normaali (1.0x)', style: TextStyle(fontSize: 10.5, color: Colors.grey.shade700)),
                  Text('Nopea (2.0x)', style: TextStyle(fontSize: 10.5, color: Colors.grey.shade700)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// Staattinen dialogi kielivalinnalle ja puhenopeudelle
  static Future<String?> avaaKielivalitsin(
    BuildContext context, {
    required String nykyinenKoodi,
  }) async {
    await haePuhenopeus();
    if (!context.mounted) return null;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.record_voice_over, color: Colors.blueAccent),
                    const SizedBox(width: 8),
                    const Text(
                      'Puheasetukset ja kieli (TTS)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
                child: rakennaPuhenopeusSaadin(),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: tuetutTtsKielet.length,
                  itemBuilder: (context, index) {
                    final item = tuetutTtsKielet[index];
                    final isSelected = item.code == nykyinenKoodi;
                    return ListTile(
                      dense: true,
                      leading: Text(item.flag, style: const TextStyle(fontSize: 22)),
                      title: Text(item.name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                      subtitle: item.code != 'auto'
                          ? Text(item.code, style: const TextStyle(fontSize: 11))
                          : const Text('Tunnistaa automaattisesti kirjan kielestä', style: TextStyle(fontSize: 11)),
                      trailing: isSelected ? const Icon(Icons.check, color: Colors.green) : null,
                      onTap: () => Navigator.pop(ctx, item.code),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Esikäsittelee HTML-tekstin puhetta varten käyttäjän vaatimusten mukaisesti:
  /// - Korvaa taulukot tekstillä "... taulukko ..." (pieni tauko ennen ja jälkeen)
  /// - Korvaa kuvat tekstillä "... kuva ..." (pieni tauko ennen ja jälkeen)
  /// - Muuntaa kappaleet ja otsikot luonnollisiin lauserytmeihin
  static String valmisteleTekstiPuheeksi(String rawHtml) {
    if (rawHtml.trim().isEmpty) return '';

    String text = rawHtml;

    // 1. Korvataan taulukot: pidä pieni tauko, sano "taulukko", pidä pieni tauko
    text = text.replaceAll(
      RegExp(r'<table[^>]*>[\s\S]*?</table>|<table[^>]*/>', caseSensitive: false),
      ' ... taulukko ... ',
    );

    // 2. Korvataan kuvat: pidä pieni tauko, sano "kuva", pidä pieni tauko
    text = text.replaceAll(
      RegExp(r'<(?:img|image)[^>]*>', caseSensitive: false),
      ' ... kuva ... ',
    );

    // 3. Muunnetaan lohkotagit (p, div, br, otsikot) pisteiksi ja rivinvaihdoiksi luonnollisia taukoja varten
    text = text.replaceAll(RegExp(r'</?(?:p|div|h[1-6]|li|blockquote|hr)[^>]*>', caseSensitive: false), ' . \n');
    text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' , ');

    // 4. Poistetaan kaikki loput HTML-tagit
    text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');

    // 5. Puretaan HTML-entiteetit ja korjataan merkistö
    text = TextEncodingHelper.korjaaMerkistovirheet(text);

    // 6. Siistitään ylimääräiset välimerkit ja tyhjät tilat
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n\s*\n+'), '\n');

    return text.trim();
  }

  /// Aloittaa tai jatkaa puhetta annetusta tekstistä
  Future<void> aloitaTaiJatkaPuhetta({
    required String teksti,
    required String bookPath,
    required int pageNumber,
    int aloitusOffset = 0,
  }) async {
    await _initFuture.timeout(const Duration(seconds: 2), onTimeout: () {});
    _currentBookPath = bookPath;
    _currentPageNumber = pageNumber;
    _currentFullText = teksti;

    if (teksti.trim().isEmpty) return;

    try {
      await _flutterTts.stop();
    } catch (_) {}

    // Asetetaan tuorein puhenopeus asetuksista
    final rate = await haePuhenopeus();
    await _flutterTts.setSpeechRate(rate);

    // Päivitetään kieli automaattisesti tekstin perusteella, jos valittuna on 'auto'
    await _paivitaKieliPuheelle(teksti: teksti);

    _chunks = jaaTekstiOsiin(teksti);
    if (_chunks.isEmpty) return;

    // Etsitään chunk, josta aloitetaan
    int chunkIdx = 0;
    int offsetInsideChunk = 0;
    if (aloitusOffset > 0 && aloitusOffset < teksti.length) {
      for (int i = 0; i < _chunks.length; i++) {
        if (aloitusOffset >= _chunks[i].startOffset && aloitusOffset < _chunks[i].endOffset) {
          chunkIdx = i;
          offsetInsideChunk = aloitusOffset - _chunks[i].startOffset;
          break;
        }
      }
    }

    _currentChunkIndex = chunkIdx;
    _currentWordStart = (aloitusOffset >= 0 && aloitusOffset < teksti.length) ? aloitusOffset : 0;
    stateNotifier.value = BookTtsState.playing;

    // Päivitetään aloitussana heti näkymään ennen kuin TTS-moottorin ensimmäinen callback saapuu
    final ensiSana = laskeSanaSiirtyma(teksti, _currentWordStart, 0);
    if (ensiSana != null) {
      _currentWordStart = ensiSana.start;
      _currentWordEnd = ensiSana.end;
      currentWordNotifier.value = ensiSana.word;
      onWordSpoken?.call(ensiSana.word, ensiSana.start, ensiSana.end);
      final ratio = (ensiSana.start / teksti.length).clamp(0.0, 1.0);
      onProgressRatio?.call(ratio, ensiSana.word);
    }

    await _puhuNykyinenChunk(aloitusOffsetInsideChunk: offsetInsideChunk);
  }

  Future<void> _puhuNykyinenChunk({int aloitusOffsetInsideChunk = 0}) async {
    if (_currentChunkIndex >= _chunks.length) {
      stateNotifier.value = BookTtsState.idle;
      currentWordNotifier.value = '';
      onPageFinished?.call();
      return;
    }

    final chunk = _chunks[_currentChunkIndex];
    String spokenText = chunk.text;
    if (aloitusOffsetInsideChunk > 0 && aloitusOffsetInsideChunk < spokenText.length) {
      _currentChunkSubOffset = aloitusOffsetInsideChunk;
      spokenText = spokenText.substring(aloitusOffsetInsideChunk);
    } else {
      _currentChunkSubOffset = 0;
    }

    if (spokenText.trim().isEmpty) {
      // Tyhjä pätkä, siirrytään seuraavaan
      if (_currentChunkIndex + 1 < _chunks.length) {
        _currentChunkIndex++;
        await _puhuNykyinenChunk();
      } else {
        stateNotifier.value = BookTtsState.idle;
      }
      return;
    }

    try {
      await _flutterTts.setSpeechRate(speechRateNotifier.value);
      await _flutterTts.speak(spokenText);
    } catch (e) {
      debugPrint('Virhe speak-kutsussa: $e');
      stateNotifier.value = BookTtsState.idle;
    }
  }

  /// Pysäyttää puheen väliaikaisesti (Pause)
  Future<void> pause() async {
    if (state != BookTtsState.playing) return;
    try {
      await _flutterTts.stop();
    } catch (_) {}
    stateNotifier.value = BookTtsState.paused;
    await tallennaTila();
  }

  /// Jatkaa puhetta tauon jälkeen suoraan pysäytyssanasta eteenpäin
  Future<void> resume() async {
    if (state != BookTtsState.paused) return;
    if (_currentFullText.trim().isEmpty) {
      stateNotifier.value = BookTtsState.idle;
      return;
    }
    final int jatkoOffset = etsiPysaytyssananAlku(_currentFullText, _currentWordStart);
    await aloitaTaiJatkaPuhetta(
      teksti: _currentFullText,
      bookPath: _currentBookPath,
      pageNumber: _currentPageNumber,
      aloitusOffset: jatkoOffset,
    );
  }

  /// Siirtyy [sanamaara] sanaa taaksepäin (esim. -3) tai eteenpäin (esim. +3).
  /// Jos puhe on käynnissä, jatkaa lukemista heti uudesta sanasta.
  /// Jos puhe on tauolla, päivittää maalattavan sanan ja keskityskohdan uuteen sanaan.
  Future<void> siirrySanoja(int sanamaara) async {
    if (!isSpeechActive || _currentFullText.trim().isEmpty) return;

    final tulos = laskeSanaSiirtyma(_currentFullText, _currentWordStart, sanamaara);
    if (tulos == null) return;

    _currentWordStart = tulos.start;
    _currentWordEnd = tulos.end;
    currentWordNotifier.value = tulos.word;

    onWordSpoken?.call(tulos.word, tulos.start, tulos.end);
    if (_currentFullText.isNotEmpty) {
      final ratio = (tulos.start / _currentFullText.length).clamp(0.0, 1.0);
      onProgressRatio?.call(ratio, tulos.word);
    }

    if (state == BookTtsState.playing) {
      await aloitaTaiJatkaPuhetta(
        teksti: _currentFullText,
        bookPath: _currentBookPath,
        pageNumber: _currentPageNumber,
        aloitusOffset: tulos.start,
      );
    } else {
      await tallennaTila();
    }
  }

  /// Rakentaa sivun alareunan pyöristetyn suorakaiteen, kun TTS-puhe on päällä tai kesken:
  /// - Vasemmalla nuoli vasemmalle (-3 sanaa taaksepäin)
  /// - Keskellä kovaäänisen/puheen kuvake
  /// - Oikealla nuoli oikealle (+3 sanaa eteenpäin)
  Widget rakennaAlapalkinOhjain() {
    return ValueListenableBuilder<BookTtsState>(
      valueListenable: stateNotifier,
      builder: (context, ttsState, _) {
        if (ttsState == BookTtsState.idle) return const SizedBox.shrink();
        return Positioned(
          bottom: 24,
          left: 20,
          right: 20,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                    tooltip: '3 sanaa taaksepäin',
                    onPressed: () => siirrySanoja(-3),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(Icons.record_voice_over, color: Colors.amberAccent, size: 22),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_forward, color: Colors.white, size: 22),
                    tooltip: '3 sanaa eteenpäin',
                    onPressed: () => siirrySanoja(3),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Lopettaa puhemoodin kokonaan (Stop)
  Future<void> stop() async {
    try {
      await _flutterTts.stop();
    } catch (_) {}
    stateNotifier.value = BookTtsState.idle;
    currentWordNotifier.value = '';
    _chunks = [];
    _currentChunkIndex = 0;
    _currentChunkSubOffset = 0;
    _currentWordStart = 0;
    _currentWordEnd = 0;
    await nollaaTallennettuTila(_currentBookPath);
  }

  /// Tallentaa puhetilan levylle poistuttaessa kirjasta
  Future<void> tallennaTila() async {
    if (_currentBookPath.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _hashPath(_currentBookPath);
      final bool aktiivinen = isSpeechActive && _currentFullText.trim().isNotEmpty;
      final bool paused = isPaused;

      await prefs.setBool('tts_active_$key', aktiivinen);
      await prefs.setBool('tts_paused_$key', paused);
      await prefs.setInt('tts_offset_$key', _currentWordStart);
      await prefs.setString('tts_word_$key', currentWord);
      await prefs.setInt('tts_page_$key', _currentPageNumber);
      await prefs.setString('tts_lang_$key', _selectedLanguageCode);
    } catch (_) {}
  }

  /// Nollaa tallennetun puhetilan
  Future<void> nollaaTallennettuTila(String bookPath) async {
    if (bookPath.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _hashPath(bookPath);
      await prefs.remove('tts_active_$key');
      await prefs.remove('tts_paused_$key');
      await prefs.remove('tts_offset_$key');
      await prefs.remove('tts_word_$key');
      await prefs.remove('tts_page_$key');
      await prefs.remove('tts_lang_$key');
    } catch (_) {}
  }

  /// Palauttaa tallennetun puhetilan kirjaa avattaessa
  static Future<Map<String, dynamic>?> haeTallennettuTila(String bookPath) async {
    if (bookPath.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _hashPath(bookPath);
      final bool? aktiivinen = prefs.getBool('tts_active_$key');
      if (aktiivinen == true) {
        return {
          'active': true,
          'paused': prefs.getBool('tts_paused_$key') ?? true,
          'offset': prefs.getInt('tts_offset_$key') ?? 0,
          'word': prefs.getString('tts_word_$key') ?? '',
          'page': prefs.getInt('tts_page_$key') ?? 1,
          'lang': prefs.getString('tts_lang_$key') ?? 'auto',
        };
      }
    } catch (_) {}
    return null;
  }

  /// Asettaa tilan palautetun tilan mukaan ilman suoraa puheen aloitusta
  void asetaPalautettuTila({
    required String bookPath,
    required int pageNumber,
    required String teksti,
    required int offset,
    required String word,
    required bool wasPaused,
    String lang = 'auto',
  }) {
    _currentBookPath = bookPath;
    _currentPageNumber = pageNumber;
    _currentFullText = teksti;
    _selectedLanguageCode = lang;
    if (teksti.trim().isEmpty) {
      stateNotifier.value = BookTtsState.idle;
      return;
    }
    _currentWordStart = (offset >= 0 && offset < teksti.length) ? offset : 0;
    currentWordNotifier.value = word;
    stateNotifier.value = BookTtsState.paused;
    _paivitaKieliPuheelle(teksti: teksti);
  }

  void dispose() {
    speechRateNotifier.removeListener(_onGlobalSpeechRateChanged);
    try {
      _flutterTts.stop();
    } catch (_) {}
    stateNotifier.dispose();
    currentWordNotifier.dispose();
  }
}
