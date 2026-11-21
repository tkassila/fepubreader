import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:epub_plus/epub_plus.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:path/path.dart' as p;
import '../data/indexed_book_scanner.dart';
import '../util/bookmark_service.dart';
import '../util/book_tts_service.dart';
import '../util/progressive_text_selector.dart';
import '../util/reading_position_service.dart';
import '../util/text_action_helper.dart';
import '../util/text_encoding_helper.dart';
import '../util/voice_service.dart';

class EpubLukuruutu extends StatefulWidget {
  final String tiedostoPolku;
  final int aloitusSivu; 
  final double aloitusScrollRatio;

  const EpubLukuruutu({
    super.key,
    required this.tiedostoPolku,
    required this.aloitusSivu,
    this.aloitusScrollRatio = 0.0,
  });

  @override
  State<EpubLukuruutu> createState() => _EpubLukuruutuState();
}

class _EpubLukuruutuState extends State<EpubLukuruutu> with WidgetsBindingObserver {
  late PageController _sivuOhjain;
  late PageController _sivuOhjain2;
  EpubBook? _kirja;
  List<EpubChapter> _kappaleet = [];
  bool _ladataan = true;
  int _nykyinenSivu = 1;
  int _nykyinenSivu2 = 1;
  bool _kaksiNayttoa = false;
  double _fontSize = 18.0;
  String _valittuEpubTeksti = '';
  String? _paivitettyOtsikko;
  double _viimeisinScrollRatio = 0.0;
  bool _aloitusSijaintiPalautettu = false;

  // Hakuun liittyvät muuttujat
  bool _naytaHaku = false;
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _hakutulokset = []; 
  int _nykyinenHakuIndeksi = -1;
  String _hakuSana = "";
  
  // Vierityksen hallinta erikseen näkymille 1 ja 2 (estää ScrollController-törmäykset jaetussa ruudussa)
  final Map<int, ScrollController> _scrollControllersView1 = {};
  final Map<int, ScrollController> _scrollControllersView2 = {};

  // Välimuisti käsitellylle HTML:lle ja kuville (estää UI-säikeen jumiutumisen ja toistuvan base64-enkoodauksen)
  final Map<int, String> _chapterHtmlCache = {};
  final Map<String, String> _imageBase64Cache = {};

  // Progressiivinen tekstivalinta & 5s valintailmoitus & lausesäätimet
  ProgressiveSelectionResult? _progressiveResult;
  String? _valintaIlmoitus;
  Timer? _valintaAjastin;
  final ProgressiveTextSelector _progressiveSelector = ProgressiveTextSelector();
  final Map<int, TextSelectionScope> _chapterScopes = {};
  String _viimeisinValittuTeksti = '';

  // Puhepalvelu (TTS)
  late final BookTtsService _ttsService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nykyinenSivu = widget.aloitusSivu;
    _nykyinenSivu2 = widget.aloitusSivu;
    _viimeisinScrollRatio = widget.aloitusScrollRatio;

    // Alustetaan puhepalvelu ja selauskohdan automaattisiirto sivun keskikohdalle
    _ttsService = BookTtsService(
      onProgressRatio: (ratio, word) {
        if (_nykyinenSivu - 1 < _kappaleet.length) {
          final sc = _scrollControllersView1[_nykyinenSivu - 1];
          if (sc != null && sc.hasClients && sc.position.maxScrollExtent > 0) {
            final double kokoKorkeus = sc.position.maxScrollExtent + sc.position.viewportDimension;
            final double sananSijainti = kokoKorkeus * ratio;
            final double target = (sananSijainti - (sc.position.viewportDimension / 2.0))
                .clamp(0.0, sc.position.maxScrollExtent);
            if ((target - sc.offset).abs() > 20) {
              sc.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
            }
          }
        }
      },
      onPageFinished: () {
        if (_nykyinenSivu < _kappaleet.length) {
          _sivuOhjain.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
          Future.delayed(const Duration(milliseconds: 400), () {
            _aloitaPuheNykyiseltaSivulta();
          });
        }
      },
    );

    ReadingPositionService.paivitaLukukohtaMuistissa(
      bookPath: widget.tiedostoPolku,
      pageNumber: _nykyinenSivu,
      scrollOffsetRatio: _viimeisinScrollRatio,
      isPdf: false,
    );

    _sivuOhjain = PageController(initialPage: widget.aloitusSivu - 1);
    _sivuOhjain2 = PageController(initialPage: widget.aloitusSivu - 1);
    _lataaEpubSisalto();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _ttsService.tallennaTila();
      ReadingPositionService.tallennaLevylle(
        bookPath: widget.tiedostoPolku,
        pageNumber: _nykyinenSivu,
        scrollOffsetRatio: _viimeisinScrollRatio,
        isPdf: false,
      );
    }
  }

  Future<void> _lataaEpubSisalto() async {
    try {
      final tiedosto = File(widget.tiedostoPolku);
      final tavut = await tiedosto.readAsBytes();
      final epubKirja = await EpubReader.readBook(tavut);
      final ladatutKappaleet = _lataaKaikkiKappaleet(epubKirja.chapters);

      // Haetaan tallennettu lukukohta
      final pos = await ReadingPositionService.haeLukukohta(
        widget.tiedostoPolku,
        oletusSivu: widget.aloitusSivu,
        oletusScrollRatio: widget.aloitusScrollRatio,
      );

      int tavoiteSivu = pos.pageNumber;
      if (tavoiteSivu > ladatutKappaleet.length) tavoiteSivu = ladatutKappaleet.length;
      if (tavoiteSivu < 1) tavoiteSivu = 1;

      setState(() {
        _kirja = epubKirja;
        _kappaleet = ladatutKappaleet;
        _ladataan = false;
        _nykyinenSivu = tavoiteSivu;
        _nykyinenSivu2 = tavoiteSivu;
        _viimeisinScrollRatio = pos.scrollOffsetRatio;
      });

      if (_sivuOhjain.hasClients && _sivuOhjain.page?.round() != (tavoiteSivu - 1)) {
        _sivuOhjain.jumpToPage(tavoiteSivu - 1);
      }

      // Palautetaan vierityssijainti luvun sisällä
      if (!_aloitusSijaintiPalautettu && pos.scrollOffsetRatio > 0.0) {
        _aloitusSijaintiPalautettu = true;
        _palautaScrollSijainti(tavoiteSivu, pos.scrollOffsetRatio);
      }

      // Varmistetaan että lukutilanne on päivitetty RAM-muistiin
      ReadingPositionService.paivitaLukukohtaMuistissa(
        bookPath: widget.tiedostoPolku,
        pageNumber: tavoiteSivu,
        scrollOffsetRatio: pos.scrollOffsetRatio,
        isPdf: false,
      );

      // d) Tarkistetaan aiemmin tallennettu puhetila
      final ttsState = await BookTtsService.haeTallennettuTila(widget.tiedostoPolku);
      if (ttsState != null && mounted) {
        final int savedPage = ttsState['page'] as int? ?? tavoiteSivu;
        final int savedOffset = ttsState['offset'] as int? ?? 0;
        final String savedWord = ttsState['word'] as String? ?? '';
        final bool wasPaused = ttsState['paused'] as bool? ?? true;
        final String savedLang = ttsState['lang'] as String? ?? 'auto';

        if (savedPage <= ladatutKappaleet.length) {
          final html = ladatutKappaleet[savedPage - 1].htmlContent ?? '';
          final text = BookTtsService.valmisteleTekstiPuheeksi(html);
          _ttsService.asetaPalautettuTila(
            bookPath: widget.tiedostoPolku,
            pageNumber: savedPage,
            teksti: text,
            offset: savedOffset,
            word: savedWord,
            wasPaused: wasPaused,
            lang: savedLang,
          );
        }
      }
    } catch (e) {
      debugPrint("Virhe EPUB-latauksessa: $e");
    }
  }

  void _palautaScrollSijainti(int sivu, double ratio, [int yritykset = 0]) {
    if (!mounted || ratio <= 0.0) return;
    final chapterIdx = sivu - 1;
    final ctrl = _scrollControllersView1[chapterIdx];
    if (ctrl != null && ctrl.hasClients && ctrl.position.maxScrollExtent > 0) {
      final target = (ctrl.position.maxScrollExtent * ratio).clamp(0.0, ctrl.position.maxScrollExtent);
      ctrl.jumpTo(target);
    } else if (yritykset < 6) {
      Future.delayed(const Duration(milliseconds: 200), () {
        _palautaScrollSijainti(sivu, ratio, yritykset + 1);
      });
    }
  }

  List<EpubChapter> _lataaKaikkiKappaleet(List<EpubChapter> chapters) {
    List<EpubChapter> all = [];
    for (var chapter in chapters) {
      all.add(chapter);
      if (chapter.subChapters.isNotEmpty) {
        all.addAll(_lataaKaikkiKappaleet(chapter.subChapters));
      }
    }
    return all;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Tallennetaan puhetila ja lukukohta levylle vasta poistuttaessa kirjasta ulos
    _ttsService.tallennaTila();
    _ttsService.dispose();
    ReadingPositionService.tallennaLevylle(
      bookPath: widget.tiedostoPolku,
      pageNumber: _nykyinenSivu,
      scrollOffsetRatio: _viimeisinScrollRatio,
      isPdf: false,
    );
    _valintaAjastin?.cancel();
    _searchController.dispose();
    _sivuOhjain.dispose();
    _sivuOhjain2.dispose();
    for (var c in _scrollControllersView1.values) {
      c.dispose();
    }
    for (var c in _scrollControllersView2.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _kaynnistaValintaAjastin() {
    _valintaAjastin?.cancel();
    _valintaAjastin = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() {
          _valintaIlmoitus = null;
          _progressiveResult = null;
        });
      }
    });
  }

  void _nollaaValinta() {
    _valintaAjastin?.cancel();
    _progressiveSelector.reset();
    setState(() {
      _progressiveResult = null;
      _valintaIlmoitus = null;
      _viimeisinValittuTeksti = '';
    });
  }

  void _naytaValintaIlmoitus(String teksti) {
    final clean = teksti.trim();
    if (clean.isEmpty) return;
    _viimeisinValittuTeksti = clean;
    final ilmoitus = ProgressiveTextSelector.muodostaIlmoitusteksti(clean);
    setState(() {
      _valintaIlmoitus = ilmoitus;
      _progressiveResult = ProgressiveSelectionResult(
        selectedText: clean,
        noticeText: ilmoitus,
        levelText: 'Valittu',
        sentenceCount: 1,
        paragraphCount: 1,
        wordCount: clean.split(RegExp(r'\s+')).length,
        canShrink: false,
        canExpand: true,
      );
    });
    _kaynnistaValintaAjastin();
  }

  void _kasitteleKaksoisnapautus(int chapterIndex, Offset localOffset) {
    if (chapterIndex < 0 || chapterIndex >= _kappaleet.length) return;
    final rawHtml = _kappaleet[chapterIndex].htmlContent ?? '';
    final plainText = rawHtml
        .replaceAll(RegExp(r'<[^>]*>|&[^;]+;'), ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();

    final scope = _chapterScopes.putIfAbsent(
      chapterIndex,
      () => TextSelectionScope.fromText(plainText),
    );

    if (scope.paragraphs.isEmpty) return;

    int targetParagraphIndex = 0;
    final scrollCtrl = _scrollControllersView1[chapterIndex];
    if (scrollCtrl != null && scrollCtrl.hasClients && scrollCtrl.position.maxScrollExtent > 0) {
      final totalHeight = scrollCtrl.position.maxScrollExtent + scrollCtrl.position.viewportDimension;
      final touchY = (scrollCtrl.offset + localOffset.dy).clamp(0.0, totalHeight);
      final ratio = (touchY / totalHeight).clamp(0.0, 1.0);
      targetParagraphIndex = (ratio * scope.paragraphs.length).floor().clamp(0, scope.paragraphs.length - 1);
    }

    final result = _progressiveSelector.selectSentence(
      scope: scope,
      focusParagraphIndex: targetParagraphIndex,
      focusSentenceIndex: 0,
    );

    if (result.selectedText.trim().isEmpty) return;
    setState(() {
      _progressiveResult = result;
      _valittuEpubTeksti = result.selectedText;
      _viimeisinValittuTeksti = result.selectedText;
      _valintaIlmoitus = result.noticeText;
    });
    _kaynnistaValintaAjastin();
  }

  void _laajennaValintaa() {
    final chapterIndex = _nykyinenSivu - 1;
    final scope = _chapterScopes[chapterIndex];
    if (scope == null) return;

    final result = _progressiveSelector.expand(scope: scope);
    setState(() {
      _progressiveResult = result;
      _valittuEpubTeksti = result.selectedText;
      _viimeisinValittuTeksti = result.selectedText;
      _valintaIlmoitus = result.noticeText;
    });
    _kaynnistaValintaAjastin();
  }

  void _vahennaValintaa() {
    final chapterIndex = _nykyinenSivu - 1;
    final scope = _chapterScopes[chapterIndex];
    if (scope == null) return;

    final result = _progressiveSelector.shrink(scope: scope);
    setState(() {
      _progressiveResult = result;
      _valittuEpubTeksti = result.selectedText;
      _viimeisinValittuTeksti = result.selectedText;
      _valintaIlmoitus = result.noticeText;
    });
    _kaynnistaValintaAjastin();
  }

  /// Korvaa hakutermin turvallisesti vain HTML-tekstiosuuksissa (ei tagien sisällä).
  /// Estää suorituskykyä syövän ja käyttöliittymän jumiuttavan säännöllisen lausekkeen backtrackingin.
  String _korvaaVainTekstiosuuksissa(
    String html,
    String query, {
    required String Function(Match match, int matchIndex) replacer,
    bool vainEnsimmainen = false,
  }) {
    if (query.trim().isEmpty || html.isEmpty) return html;

    final queryPattern = RegExp(RegExp.escape(query.trim()), caseSensitive: false);
    final tagRegex = RegExp(r'<[^>]+>');
    final buffer = StringBuffer();
    int lastEnd = 0;
    int counter = 0;
    bool korvattu = false;

    for (final match in tagRegex.allMatches(html)) {
      if (match.start > lastEnd) {
        final textChunk = html.substring(lastEnd, match.start);
        if (!korvattu && queryPattern.hasMatch(textChunk)) {
          final replaced = textChunk.replaceAllMapped(queryPattern, (m) {
            if (vainEnsimmainen && korvattu) return m.group(0)!;
            final res = replacer(m, counter);
            counter++;
            if (vainEnsimmainen) korvattu = true;
            return res;
          });
          buffer.write(replaced);
        } else {
          buffer.write(textChunk);
        }
      }
      buffer.write(match.group(0));
      lastEnd = match.end;
    }

    if (lastEnd < html.length) {
      final textChunk = html.substring(lastEnd);
      if (!korvattu && queryPattern.hasMatch(textChunk)) {
        final replaced = textChunk.replaceAllMapped(queryPattern, (m) {
          if (vainEnsimmainen && korvattu) return m.group(0)!;
          final res = replacer(m, counter);
          counter++;
          if (vainEnsimmainen) korvattu = true;
          return res;
        });
        buffer.write(replaced);
      } else {
        buffer.write(textChunk);
      }
    }

    return buffer.toString();
  }

  String _korostaValittuAlue(String html, String selectedText) {
    final trimmed = selectedText.trim();
    if (trimmed.length < 3) return html;
    final searchPart = trimmed.length > 80 ? trimmed.substring(0, 80) : trimmed;

    return _korvaaVainTekstiosuuksissa(
      html,
      searchPart,
      vainEnsimmainen: true,
      replacer: (match, _) =>
          '<mark style="background-color: #bfdbfe; color: #1e3a8a; border-radius: 4px; padding: 2px 4px; border-left: 3px solid #2563eb; border-right: 3px solid #2563eb; font-weight: 500;"><span style="color: #2563eb; font-weight: bold;">◀ </span>${match.group(0)}<span style="color: #2563eb; font-weight: bold;"> ▶</span></mark>',
    );
  }

  Future<void> _lisaaKirjanmerkki({String? valittuTeksti}) async {
    final sivu = _nykyinenSivu;
    final scrollCtrl = _scrollControllersView1[sivu - 1];
    double scrollRatio = 0.0;
    if (scrollCtrl != null && scrollCtrl.hasClients && scrollCtrl.position.maxScrollExtent > 0) {
      scrollRatio = (scrollCtrl.offset / scrollCtrl.position.maxScrollExtent).clamp(0.0, 1.0);
    }

    final nimi = await BookmarkService.kysyKirjanmerkinNimi(
      context,
      valittuTeksti: valittuTeksti,
      sivuNumero: sivu,
    );
    if (!mounted || nimi == null) return;

    await BookmarkService.lisaaKirjanmerkki(
      bookPath: widget.tiedostoPolku,
      title: nimi,
      pageNumber: sivu,
      scrollOffsetRatio: scrollRatio,
      selectedText: valittuTeksti ?? '',
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Kirjanmerkki "$nimi" lisätty sivulle $sivu!'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Asettaa valitun tekstin kirjan otsikoksi (metaotsikko) ja suorittaa uuden lajittelun kirjahyllyyn
  Future<void> _asetaMetaotsikoksi(String valittuTeksti) async {
    final clean = valittuTeksti.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) return;

    final onnistui = await IndexedBookScanner.paivitaKirjanOtsikko(widget.tiedostoPolku, clean);
    if (!mounted) return;

    if (onnistui) {
      setState(() {
        _paivitettyOtsikko = clean;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Asetettu metaotsikoksi: "$clean"',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _avaaKirjanmerkit() async {
    final sivu = _nykyinenSivu;
    final scrollCtrl = _scrollControllersView1[sivu - 1];
    double scrollRatio = 0.0;
    if (scrollCtrl != null && scrollCtrl.hasClients && scrollCtrl.position.maxScrollExtent > 0) {
      scrollRatio = (scrollCtrl.offset / scrollCtrl.position.maxScrollExtent).clamp(0.0, 1.0);
    }

    await BookmarkService.avaaKirjanmerkitSheet(
      context,
      bookPath: widget.tiedostoPolku,
      nykyinenSivu: sivu,
      nykyinenScrollRatio: scrollRatio,
      onSiirryKohtaan: (BookBookmark bookmark) {
        final chapterIndex = bookmark.pageNumber - 1;
        if (chapterIndex >= 0 && chapterIndex < _kappaleet.length) {
          _sivuOhjain.jumpToPage(chapterIndex);
          if (_kaksiNayttoa) {
            _sivuOhjain2.jumpToPage(chapterIndex);
          }

          Future.delayed(const Duration(milliseconds: 300), () {
            final targetCtrl = _scrollControllersView1[chapterIndex];
            if (targetCtrl != null && targetCtrl.hasClients && targetCtrl.position.maxScrollExtent > 0) {
              final targetOffset = targetCtrl.position.maxScrollExtent * bookmark.scrollOffsetRatio;
              targetCtrl.animateTo(
                targetOffset.clamp(0.0, targetCtrl.position.maxScrollExtent),
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut,
              );
            }
          });

          if (bookmark.selectedText.isNotEmpty) {
            _naytaValintaIlmoitus(bookmark.selectedText);
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Siirrytty kirjanmerkkiin: ${bookmark.title} (Sivu ${bookmark.pageNumber})'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
      onLisaaUusi: () async {
        await _lisaaKirjanmerkki();
      },
    );
  }

  Future<void> _avaaAanihaku() async {
    final teksti = await VoiceService.kuuntelePuhetta(context);
    if (!mounted || teksti == null || teksti.trim().isEmpty) return;
    final clean = teksti.trim();
    setState(() {
      _searchController.text = clean;
    });
    _suoritaHaku(clean);
  }

  void _suoritaHaku(String query) {
    if (query.isEmpty || query.length < 3) return;
    
    List<Map<String, dynamic>> tulokset = [];
    for (int i = 0; i < _kappaleet.length; i++) {
      String content = _kappaleet[i].htmlContent ?? "";
      String plainText = content.replaceAll(RegExp(r'<[^>]*>|&[^;]+;'), ' ');
      String lowerQuery = query.toLowerCase();
      String lowerText = plainText.toLowerCase();

      int pos = lowerText.indexOf(lowerQuery);
      while (pos != -1) {
        tulokset.add({
          'chapter': i,
          'offset': pos,
          'textLength': lowerText.length,
        });
        pos = lowerText.indexOf(lowerQuery, pos + 1);
      }
    }

    setState(() {
      _hakutulokset = tulokset;
      _hakuSana = query;
      if (tulokset.isNotEmpty) {
        _nykyinenHakuIndeksi = 0;
        _siirryHakuOsumaan(0);
      } else {
        _nykyinenHakuIndeksi = -1;
      }
    });
  }

  void _siirryHakuOsumaan(int suunta) {
    if (_hakutulokset.isEmpty) return;
    
    int uusiIndeksi = _nykyinenHakuIndeksi + suunta;
    if (uusiIndeksi < 0) uusiIndeksi = _hakutulokset.length - 1;
    if (uusiIndeksi >= _hakutulokset.length) uusiIndeksi = 0;

    setState(() {
      _nykyinenHakuIndeksi = uusiIndeksi;
    });

    final osuma = _hakutulokset[uusiIndeksi];
    int tavoiteKappale = osuma['chapter'];
    
    if (_sivuOhjain.page?.round() != tavoiteKappale) {
      _sivuOhjain.jumpToPage(tavoiteKappale);
    }

    Future.delayed(const Duration(milliseconds: 250), () {
      final controller = _scrollControllersView1[tavoiteKappale];
      if (controller != null && controller.hasClients) {
        double suhde = osuma['offset'] / osuma['textLength'];
        double kokoKorkeus = controller.position.maxScrollExtent + controller.position.viewportDimension;
        double osumanSijainti = kokoKorkeus * suhde;
        
        double tavoite = osumanSijainti - (controller.position.viewportDimension / 2);
        tavoite = tavoite.clamp(0.0, controller.position.maxScrollExtent);

        controller.animateTo(
          tavoite,
          duration: const Duration(milliseconds: 400),
          curve: Curves.fastOutSlowIn,
        );
      }
    });
  }

  void _vaihdaKaksiNayttoa(bool? arvo) {
    setState(() {
      _kaksiNayttoa = arvo ?? false;
      if (_kaksiNayttoa) {
        _sivuOhjain2 = PageController(initialPage: _nykyinenSivu - 1);
      }
    });
  }

  void _muutaZoom(double kerroin) {
    setState(() {
      _fontSize = (_fontSize * kerroin).clamp(10.0, 50.0);
    });
  }

  // 2a) Puhe alkaa selattavan sivun yläosasta (taulukot ja kuvat ilmoitetaan erikseen tauoilla)
  void _aloitaPuheNykyiseltaSivulta({int startOffset = 0}) {
    if (_kappaleet.isEmpty || _nykyinenSivu < 1 || _nykyinenSivu > _kappaleet.length) return;
    final html = _kappaleet[_nykyinenSivu - 1].htmlContent ?? '';
    final text = BookTtsService.valmisteleTekstiPuheeksi(html);
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tällä sivulla ei ole luettavaa tekstiä.')),
        );
      }
      return;
    }

    if (startOffset == 0) {
      final sc = _scrollControllersView1[_nykyinenSivu - 1];
      if (sc != null && sc.hasClients) {
        sc.jumpTo(0);
      }
    }

    _ttsService.aloitaTaiJatkaPuhetta(
      teksti: text,
      bookPath: widget.tiedostoPolku,
      pageNumber: _nykyinenSivu,
      aloitusOffset: startOffset,
    );
  }

  // 2d) Jatkaa puhetta tauon jälkeen suoraan pysäytyssanasta ja siirtää selauskohdan sivun keskikohdalle
  void _jatkaPuhetta() {
    if (_kappaleet.isEmpty || _nykyinenSivu < 1 || _nykyinenSivu > _kappaleet.length) return;
    if (_ttsService.currentFullText.trim().isEmpty || _ttsService.currentPageNumber != _nykyinenSivu) {
      _aloitaPuheNykyiseltaSivulta();
      return;
    }
    final sc = _scrollControllersView1[_nykyinenSivu - 1];
    if (sc != null && sc.hasClients && sc.position.maxScrollExtent > 0 && _ttsService.currentWordStart > 0) {
      final html = _kappaleet[_nykyinenSivu - 1].htmlContent ?? '';
      final text = BookTtsService.valmisteleTekstiPuheeksi(html);
      if (text.isNotEmpty) {
        final jatkoOffset = BookTtsService.etsiPysaytyssananAlku(text, _ttsService.currentWordStart);
        final ratio = (jatkoOffset / text.length).clamp(0.0, 1.0);
        final double kokoKorkeus = sc.position.maxScrollExtent + sc.position.viewportDimension;
        final double sananSijainti = kokoKorkeus * ratio;
        final double target = (sananSijainti - (sc.position.viewportDimension / 2.0))
            .clamp(0.0, sc.position.maxScrollExtent);
        sc.animateTo(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    }
    _ttsService.resume();
  }

  @override
  Widget build(BuildContext context) {
    if (_ladataan) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _ttsService.tallennaTila();
          ReadingPositionService.tallennaLevylle(
            bookPath: widget.tiedostoPolku,
            pageNumber: _nykyinenSivu,
            scrollOffsetRatio: _viimeisinScrollRatio,
            isPdf: false,
          );
        }
      },
      child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: true,
        leading: const BackButton(color: Colors.black87),
        titleSpacing: 0,
        title: Text(
          '${_paivitettyOtsikko ?? _kirja?.title ?? "EPUB"} - Sivu $_nykyinenSivu',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        backgroundColor: Colors.greenAccent,
        elevation: 0,
        actions: [
          // 2b & 2c) Puhe- / Pause- / Jatka- ja Pysäytä-ikonit kirjanmerkin viereen
          ValueListenableBuilder<BookTtsState>(
            valueListenable: _ttsService.stateNotifier,
            builder: (context, ttsState, _) {
              final bool isPlaying = ttsState == BookTtsState.playing;
              final bool isPaused = ttsState == BookTtsState.paused;
              final bool isActive = _ttsService.isSpeechActive;

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onLongPress: () async {
                      final valittu = await _ttsService.avaaKielivalikko(context);
                      if (valittu != null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Puhekieleksi asetettu: $valittu'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_circle_filled
                            : (isPaused ? Icons.play_circle_filled : Icons.record_voice_over),
                        color: isPlaying
                            ? Colors.amber.shade900
                            : (isPaused ? Colors.blue.shade900 : Colors.black87),
                        size: 22,
                      ),
                      tooltip: isPlaying
                          ? 'Pysäytä puhe väliaikaisesti (Pause)\nPidä pohjassa valitaksesi kielen'
                          : (isPaused
                              ? 'Jatka puhetta\nPidä pohjassa valitaksesi kielen'
                              : 'Lue teksti ääneen (Puhesynteesi)\nPidä pohjassa valitaksesi kielen'),
                      onPressed: () {
                        if (isPlaying) {
                          _ttsService.pause();
                        } else if (isPaused) {
                          _jatkaPuhetta();
                        } else {
                          _aloitaPuheNykyiseltaSivulta();
                        }
                      },
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 36),
                    icon: Icon(
                      Icons.stop_circle,
                      color: isActive ? Colors.red.shade700 : Colors.black26,
                      size: 22,
                    ),
                    tooltip: isActive ? 'Pysäytä puhemoodi' : 'Puhe ei ole päällä',
                    onPressed: isActive
                        ? () {
                            _ttsService.stop();
                          }
                        : null,
                  ),
                ],
              );
            },
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 36),
            icon: const Icon(Icons.bookmark_border, color: Colors.black87, size: 21),
            tooltip: 'Kirjanmerkit',
            onPressed: _avaaKirjanmerkit,
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 36),
            icon: Icon(_naytaHaku ? Icons.search_off : Icons.search, color: Colors.black87, size: 21),
            tooltip: 'Etsi tekstistä',
            onPressed: () {
              setState(() {
                _naytaHaku = !_naytaHaku;
                if (!_naytaHaku) {
                  _hakuSana = "";
                  _hakutulokset = [];
                  _nykyinenHakuIndeksi = -1;
                  _searchController.clear();
                }
              });
            },
          ),
          // Tiiviit Zoom-ohjaimet
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 36),
                icon: const Icon(Icons.zoom_out, size: 19),
                onPressed: () => _muutaZoom(0.9),
                tooltip: 'Pienennä tekstiä',
              ),
              Text(
                "${((_fontSize / 18.0) * 100).toInt()}%",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10.5),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 36),
                icon: const Icon(Icons.zoom_in, size: 19),
                onPressed: () => _muutaZoom(1.1),
                tooltip: 'Suurenna tekstiä',
              ),
            ],
          ),
          const SizedBox(width: 2),
          // Tiivis 2 näkymää -valinta
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("2 s", style: TextStyle(fontSize: 11, color: Colors.black87)),
              Transform.scale(
                scale: 0.75,
                child: Checkbox(
                  value: _kaksiNayttoa,
                  onChanged: _vaihdaKaksiNayttoa,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_naytaHaku)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Hae tekstiä...',
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.mic, color: Colors.deepOrange),
                              tooltip: 'Äänihaku',
                              onPressed: _avaaAanihaku,
                            ),
                          ),
                          onSubmitted: _suoritaHaku,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: _hakutulokset.isNotEmpty ? () => _siirryHakuOsumaan(-1) : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: _hakutulokset.isNotEmpty ? () => _siirryHakuOsumaan(1) : null,
                      ),
                      Text(
                        _hakutulokset.isNotEmpty
                            ? '${_nykyinenHakuIndeksi + 1} / ${_hakutulokset.length}'
                            : '0/0',
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _kaksiNayttoa
                    ? Column(
                        children: [
                          Expanded(child: _buildEpubView(_sivuOhjain, 1)),
                          const Divider(height: 1, color: Colors.black26),
                          Expanded(child: _buildEpubView(_sivuOhjain2, 2)),
                        ],
                      )
                    : _buildEpubView(_sivuOhjain, 1),
              ),
            ],
          ),
          // Kelluva lausesäädin ja pikatoiminnot (– ja + säädöt, Kopioi, Verkkohaku, Tekoäly)
          if (_progressiveResult != null)
            SelectionControlPanel(
              result: _progressiveResult,
              onExpand: _laajennaValintaa,
              onShrink: _vahennaValintaa,
              onCopy: () {
                if (_viimeisinValittuTeksti.isNotEmpty) {
                  TextActionHelper.kopioiLeikepoydalle(context, _viimeisinValittuTeksti);
                }
              },
              onWebSearch: () {
                if (_viimeisinValittuTeksti.isNotEmpty) {
                  TextActionHelper.avaaVerkkohaku(context, _viimeisinValittuTeksti);
                }
              },
              onAiSearch: () {
                if (_viimeisinValittuTeksti.isNotEmpty) {
                  TextActionHelper.avaaTekoalyhaku(context, _viimeisinValittuTeksti);
                }
              },
              onBookmark: () {
                if (_viimeisinValittuTeksti.isNotEmpty) {
                  _lisaaKirjanmerkki(valittuTeksti: _viimeisinValittuTeksti);
                }
              },
              onMetaotsikko: () {
                if (_viimeisinValittuTeksti.isNotEmpty) {
                  _asetaMetaotsikoksi(_viimeisinValittuTeksti);
                }
              },
              onDismiss: _nollaaValinta,
            )
          else if (_valintaIlmoitus != null)
            SelectionNoticeOverlay(
              noticeText: _valintaIlmoitus,
              onTap: () {
                if (_viimeisinValittuTeksti.isNotEmpty) {
                  TextActionHelper.naytaValintaPikavalikko(
                    context,
                    _viimeisinValittuTeksti,
                    onLisaaKirjanmerkki: () => _lisaaKirjanmerkki(valittuTeksti: _viimeisinValittuTeksti),
                    onAsetaMetaotsikoksi: () => _asetaMetaotsikoksi(_viimeisinValittuTeksti),
                  );
                }
              },
            ),

          // 2e) Alareunan pyöristetty TTS-ohjainpalkki (<- 3 sanaa taaksepäin | puhekuvake | 3 sanaa eteenpäin ->)
          _ttsService.rakennaAlapalkinOhjain(),
        ],
      ),
    ),
  );
}

  Widget _buildEpubView(PageController controller, int viewIndex) {
    int nykyinen = viewIndex == 1 ? _nykyinenSivu : _nykyinenSivu2;
    int yhteensa = _kappaleet.length;

    return Column(
      children: [
        if (yhteensa > 1)
          Slider(
            value: nykyinen.toDouble().clamp(1.0, yhteensa.toDouble()),
            min: 1,
            max: yhteensa.toDouble(),
            divisions: yhteensa - 1,
            label: nykyinen.toString(),
            onChanged: (double value) {
              int sivu = value.round();
              controller.jumpToPage(sivu - 1);
            },
          ),
        Expanded(
          child: PageView.builder(
            controller: controller,
            itemCount: yhteensa,
            onPageChanged: (index) async {
              int uusiSivu = index + 1;
              setState(() {
                if (viewIndex == 1) {
                  _nykyinenSivu = uusiSivu;
                  _viimeisinScrollRatio = 0.0;
                } else {
                  _nykyinenSivu2 = uusiSivu;
                }
              });
              if (viewIndex == 1) {
                // Päivitetään lukukohta vain RAM-muistiin (ei levykirjoitusta lukiessa)
                ReadingPositionService.paivitaLukukohtaMuistissa(
                  bookPath: widget.tiedostoPolku,
                  pageNumber: uusiSivu,
                  scrollOffsetRatio: 0.0,
                  isPdf: false,
                );
              }
            },
            itemBuilder: (context, index) {
              final kappale = _kappaleet[index];
              String html = _valmisteleHtml(index, kappale.htmlContent ?? '');

              // Korostetaan valittu alue ja asetetaan näkyvät markeeraustagit ◀ ▶
              if (index == (_nykyinenSivu - 1) &&
                  _progressiveResult != null &&
                  _progressiveResult!.selectedText.isNotEmpty) {
                html = _korostaValittuAlue(html, _progressiveResult!.selectedText);
              }

              if (viewIndex == 1 && _hakuSana.length >= 3) {
                // Lasketaan, mikäli tässä luvussa on aktiivinen osuma
                int aktiivinenOsumaLuvussa = -1;
                if (_nykyinenHakuIndeksi != -1) {
                  final osuma = _hakutulokset[_nykyinenHakuIndeksi];
                  if (osuma['chapter'] == index) {
                    // Selvitetään osuman järjestysnumero TÄMÄN luvun sisällä
                    aktiivinenOsumaLuvussa = 0;
                    for (int i = 0; i < _nykyinenHakuIndeksi; i++) {
                      if (_hakutulokset[i]['chapter'] == index) {
                        aktiivinenOsumaLuvussa++;
                      }
                    }
                  }
                }
                html = _etsiJaKorosta(html, _hakuSana, aktiivinenOsumaLuvussa);
              }
              
              final controllersMap = viewIndex == 1 ? _scrollControllersView1 : _scrollControllersView2;
              controllersMap[index] ??= ScrollController();

              return Padding(
                padding: const EdgeInsets.all(16.0),
                child: NotificationListener<ScrollNotification>(
                  onNotification: (ScrollNotification notification) {
                    if (viewIndex == 1 && notification.metrics.maxScrollExtent > 0) {
                      final ratio = (notification.metrics.pixels / notification.metrics.maxScrollExtent).clamp(0.0, 1.0);
                      _viimeisinScrollRatio = ratio;
                      // Vierittäessä päivitetään vain RAM-muistiin ilman levyn kuormitusta
                      ReadingPositionService.paivitaLukukohtaMuistissa(
                        bookPath: widget.tiedostoPolku,
                        pageNumber: _nykyinenSivu,
                        scrollOffsetRatio: ratio,
                        isPdf: false,
                      );
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: controllersMap[index],
                    child: SelectionArea(
                    onSelectionChanged: (content) {
                      final text = content?.plainText ?? '';
                      _valittuEpubTeksti = text;
                      if (text.trim().isNotEmpty) {
                        _naytaValintaIlmoitus(text);
                      }
                    },
                    contextMenuBuilder: (context, selectableRegionState) {
                      final buttonItems = selectableRegionState.contextMenuButtonItems;

                      final copyIdx = buttonItems.indexWhere((it) => it.type == ContextMenuButtonType.copy);
                      if (copyIdx != -1) {
                        final orig = buttonItems[copyIdx];
                        buttonItems[copyIdx] = ContextMenuButtonItem(
                          type: ContextMenuButtonType.copy,
                          label: 'Kopioi',
                          onPressed: () {
                            orig.onPressed?.call();
                            _naytaValintaIlmoitus(_valittuEpubTeksti);
                            TextActionHelper.kopioiLeikepoydalle(context, _valittuEpubTeksti);
                          },
                        );
                      }

                      buttonItems.add(
                        ContextMenuButtonItem(
                          label: 'Verkkohaku',
                          onPressed: () {
                            selectableRegionState.hideToolbar();
                            _naytaValintaIlmoitus(_valittuEpubTeksti);
                            TextActionHelper.avaaVerkkohaku(context, _valittuEpubTeksti);
                          },
                        ),
                      );

                      buttonItems.add(
                        ContextMenuButtonItem(
                          label: 'Tekoälyhaku',
                          onPressed: () {
                            selectableRegionState.hideToolbar();
                            _naytaValintaIlmoitus(_valittuEpubTeksti);
                            TextActionHelper.avaaTekoalyhaku(context, _valittuEpubTeksti);
                          },
                        ),
                      );

                      buttonItems.add(
                        ContextMenuButtonItem(
                          label: 'Kirjanmerkki',
                          onPressed: () {
                            selectableRegionState.hideToolbar();
                            _naytaValintaIlmoitus(_valittuEpubTeksti);
                            _lisaaKirjanmerkki(valittuTeksti: _valittuEpubTeksti);
                          },
                        ),
                      );

                      buttonItems.add(
                        ContextMenuButtonItem(
                          label: 'Metaotsikkoon',
                          onPressed: () {
                            selectableRegionState.hideToolbar();
                            _naytaValintaIlmoitus(_valittuEpubTeksti);
                            _asetaMetaotsikoksi(_valittuEpubTeksti);
                          },
                        ),
                      );

                      return AdaptiveTextSelectionToolbar.buttonItems(
                        anchors: selectableRegionState.contextMenuAnchors,
                        buttonItems: buttonItems,
                      );
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTapDown: (details) {
                        _kasitteleKaksoisnapautus(index, details.localPosition);
                      },
                      onLongPressStart: (details) {
                        _kasitteleKaksoisnapautus(index, details.localPosition);
                      },
                      child: ValueListenableBuilder<String>(
                        valueListenable: _ttsService.currentWordNotifier,
                        builder: (context, ttsWord, _) {
                          String renderedHtml = html;
                          if (index == (_nykyinenSivu - 1) &&
                              _ttsService.isSpeechActive &&
                              ttsWord.trim().isNotEmpty) {
                            final fullLen = _ttsService.currentFullText.length;
                            final ratio = fullLen > 0
                                ? (_ttsService.currentWordStart / fullLen).clamp(0.0, 1.0)
                                : 0.0;
                            renderedHtml = _korostaTtsSana(renderedHtml, ttsWord, ratio);
                          }
                          return HtmlWidget(
                            renderedHtml,
                            textStyle: TextStyle(fontSize: _fontSize),
                            onTapUrl: (url) {
                              _kasitteleLinkki(url, controller);
                              return true;
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
            },
          ),
        ),
      ],
    );
  }

  void _kasitteleLinkki(String url, PageController controller) {
    String cleanUrl = url.split('#').first;
    while (cleanUrl.startsWith('../')) {
      cleanUrl = cleanUrl.substring(3);
    }

    int foundIndex = -1;
    for (int i = 0; i < _kappaleet.length; i++) {
      if (_kappaleet[i].contentFileName != null &&
          (_kappaleet[i].contentFileName!.endsWith(cleanUrl) ||
              cleanUrl.endsWith(_kappaleet[i].contentFileName!))) {
        foundIndex = i;
        break;
      }
    }

    if (foundIndex != -1) {
      controller.animateToPage(
        foundIndex,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  String _valmisteleHtml(int index, String rawHtml) {
    if (_chapterHtmlCache.containsKey(index)) {
      return _chapterHtmlCache[index]!;
    }

    String processedHtml = TextEncodingHelper.korjaaMerkistovirheet(rawHtml);
    if (_kirja != null && _kirja!.content?.images != null) {
      final images = _kirja!.content!.images;

      images.forEach((fileName, imageFile) {
        if (imageFile.content != null) {
          String shortName = p.basename(fileName);
          if (processedHtml.contains(shortName)) {
            final dataUrl = _imageBase64Cache.putIfAbsent(fileName, () {
              String base64Image = base64Encode(imageFile.content!);
              String mimeType = _getMimeType(fileName);
              return 'data:$mimeType;base64,$base64Image';
            });

            final regex = RegExp('src\\s*=\\s*["\']([^"]*${RegExp.escape(shortName)})["\']', caseSensitive: false);
            processedHtml = processedHtml.replaceAll(regex, 'src="$dataUrl"');
          }
        }
      });
    }

    _chapterHtmlCache[index] = processedHtml;
    return processedHtml;
  }

  String _getMimeType(String fileName) {
    String ext = p.extension(fileName).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.svg':
        return 'image/svg+xml';
      default:
        return 'image/jpeg';
    }
  }

  String _etsiJaKorosta(String html, String query, int activeMatchIndex) {
    if (query.trim().isEmpty) return html;

    return _korvaaVainTekstiosuuksissa(
      html,
      query,
      vainEnsimmainen: false,
      replacer: (match, counter) {
        String color = (counter == activeMatchIndex) ? "orange" : "yellow";
        return '<mark style="background-color: $color; color: black;">${match.group(0)}</mark>';
      },
    );
  }

  /// Maalaa ja korostaa parhaillaan TTS-puheessa luettavan sanan HTML-tekstistä.
  /// Valitsee sen osuman, jonka suhteellinen sijainti tekstissä vastaa parhaiten puheen lukukohtaa (progressRatio).
  String _korostaTtsSana(String html, String rawWord, double progressRatio) {
    final cleanWord = rawWord
        .trim()
        .replaceAll(RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true), '');
    if (cleanWord.isEmpty || html.isEmpty) return html;

    final wordPattern = RegExp(RegExp.escape(cleanWord), caseSensitive: false);
    final tagRegex = RegExp(r'<[^>]+>');

    // 1. Kierros: lasketaan tekstiosuuksien kokonaispituus ja kaikkien osumien sijainnit
    int totalPlainLen = 0;
    final List<int> matchPlainOffsets = [];
    int lastEnd = 0;

    for (final tagMatch in tagRegex.allMatches(html)) {
      if (tagMatch.start > lastEnd) {
        final chunk = html.substring(lastEnd, tagMatch.start);
        for (final m in wordPattern.allMatches(chunk)) {
          matchPlainOffsets.add(totalPlainLen + m.start);
        }
        totalPlainLen += chunk.length;
      }
      lastEnd = tagMatch.end;
    }
    if (lastEnd < html.length) {
      final chunk = html.substring(lastEnd);
      for (final m in wordPattern.allMatches(chunk)) {
        matchPlainOffsets.add(totalPlainLen + m.start);
      }
      totalPlainLen += chunk.length;
    }

    if (matchPlainOffsets.isEmpty || totalPlainLen <= 0) return html;

    // Etsitään osuma, jonka suhteellinen paikka on lähimpänä progressRatiota
    int bestMatchIdx = 0;
    double bestDiff = 999.0;
    for (int i = 0; i < matchPlainOffsets.length; i++) {
      final ratio = matchPlainOffsets[i] / totalPlainLen;
      final diff = (ratio - progressRatio).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestMatchIdx = i;
      }
    }

    // 2. Kierros: maalataan vain valittu bestMatchIdx
    return _korvaaVainTekstiosuuksissa(
      html,
      cleanWord,
      vainEnsimmainen: false,
      replacer: (match, counter) {
        if (counter == bestMatchIdx) {
          return '<mark style="background-color: #fde047; color: #000000; font-weight: bold; border-radius: 3px; padding: 1px 3px; border-bottom: 2px solid #ea580c;">${match.group(0)}</mark>';
        }
        return match.group(0)!;
      },
    );
  }
}
