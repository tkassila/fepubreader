import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import '../data/indexed_book_scanner.dart';
import '../util/bookmark_service.dart';
import '../util/book_tts_service.dart';
import '../util/progressive_text_selector.dart';
import '../util/reading_position_service.dart';
import '../util/text_action_helper.dart';
import '../util/voice_service.dart';

class PdfLukuruutu extends StatefulWidget {
  final String tiedostoPolku;
  final int aloitusSivu;

  const PdfLukuruutu({
    super.key,
    required this.tiedostoPolku,
    required this.aloitusSivu,
  });

  @override
  State<PdfLukuruutu> createState() => _PdfLukuruutuState();
}

class _PdfLukuruutuState extends State<PdfLukuruutu> with WidgetsBindingObserver {
  late PdfViewerController _pdfController1;
  late PdfViewerController _pdfController2;
  late PdfTextSearcher _textSearcher1;
  late PdfTextSearcher _textSearcher2;
  int _nykyinenSivu = 1;
  int _nykyinenSivu2 = 1;
  int _yhteensaSivuja = 0;
  String? _paivitettyOtsikko;
  bool _kaksiNayttoa = false;
  bool _naytaHaku = false;
  final TextEditingController _searchController = TextEditingController();

  // Valintailmoituksen ja lausesäätimen hallinta (5 sekunnin näyttö)
  ProgressiveSelectionResult? _progressiveResult;
  String? _valintaIlmoitus;
  Timer? _ilmoitusAjastin;
  String _viimeisinValittuTeksti = '';

  // Puhepalvelu (TTS) ja puhutun sanan maalaus / keskitys PDF-sivulla
  late final BookTtsService _ttsService;
  PdfPageRawText? _nykyinenPdfRawText;
  PdfRect? _ttsHighlightRect;
  int _ttsHighlightPage = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nykyinenSivu = widget.aloitusSivu;
    _nykyinenSivu2 = widget.aloitusSivu;

    _ttsService = BookTtsService(
      onWordSpoken: (word, startOffset, endOffset) {
        _paivitaPdfTtsKorostusJaKeskitus(word, startOffset, endOffset);
      },
      onPageFinished: () {
        if (_nykyinenSivu < _yhteensaSivuja) {
          _pdfController1.goToPage(pageNumber: _nykyinenSivu + 1);
          Future.delayed(const Duration(milliseconds: 500), () {
            _aloitaPuheNykyiseltaSivulta();
          });
        }
      },
    );
    _ttsService.stateNotifier.addListener(_onTtsStateChanged);

    _pdfController1 = PdfViewerController();
    _pdfController2 = PdfViewerController();

    _textSearcher1 = PdfTextSearcher(_pdfController1);
    _textSearcher2 = PdfTextSearcher(_pdfController2);

    _textSearcher1.addListener(_onSearchChanged);
    _textSearcher2.addListener(_onSearchChanged);

    // Alustetaan aloitussivu RAM-muistiin (ei levykirjoitusta lukiessa)
    ReadingPositionService.paivitaLukukohtaMuistissa(
      bookPath: widget.tiedostoPolku,
      pageNumber: _nykyinenSivu,
      isPdf: true,
    );

    // Palautetaan mahdollinen aiempi puhetila kun dokumentti on valmis
    _palautaPuhetilaJosOlemassa();
  }

  void _onTtsStateChanged() {
    if (_ttsService.state == BookTtsState.idle && _ttsHighlightRect != null) {
      _ttsHighlightRect = null;
      if (_pdfController1.isReady) {
        _pdfController1.invalidate();
      }
    }
  }

  /// Etsii puhutun sanan sijainnin PDF-sivun merkki-neliöistä (charRects),
  /// maalaa sanan ja vierittää PDF-näkymän sivun keskikohdalle.
  void _paivitaPdfTtsKorostusJaKeskitus(String rawWord, int startOffset, int endOffset) {
    final raw = _nykyinenPdfRawText;
    if (raw == null || raw.fullText.isEmpty || raw.charRects.isEmpty) return;

    final cleanWord = rawWord
        .trim()
        .replaceAll(RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true), '');
    if (cleanWord.isEmpty) return;

    final fullTtsLen = _ttsService.currentFullText.length;
    final double progressRatio = fullTtsLen > 0
        ? (startOffset / fullTtsLen).clamp(0.0, 1.0)
        : 0.0;

    final pattern = RegExp(RegExp.escape(cleanWord), caseSensitive: false);
    final matches = pattern.allMatches(raw.fullText).toList();
    if (matches.isEmpty) return;

    Match bestMatch = matches.first;
    double bestDiff = 999.0;
    for (final m in matches) {
      final ratio = m.start / raw.fullText.length;
      final diff = (ratio - progressRatio).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestMatch = m;
      }
    }

    final int cStart = bestMatch.start.clamp(0, raw.charRects.length - 1);
    final int cEnd = bestMatch.end.clamp(cStart + 1, raw.charRects.length);
    final PdfRect wordRect = raw.charRects.boundingRect(start: cStart, end: cEnd);

    _ttsHighlightRect = wordRect;
    _ttsHighlightPage = _nykyinenSivu;

    if (_pdfController1.isReady) {
      _pdfController1.invalidate();

      // Vieritetään näyttöä niin, että puhuttu sana on sivun/näytön keskikohdalla
      final docRect = _pdfController1.calcRectForRectInsidePage(
        pageNumber: _nykyinenSivu,
        rect: wordRect,
      );
      final currentCenter = _pdfController1.centerPosition;
      if ((docRect.center.dy - currentCenter.dy).abs() > 25) {
        final targetMatrix = _pdfController1.calcMatrixFor(
          Offset(currentCenter.dx, docRect.center.dy),
        );
        _pdfController1.goTo(
          targetMatrix,
          duration: const Duration(milliseconds: 220),
        );
      }
    }
  }

  /// Piirtää TTS-puheen korostusmaalauksen PDF-sivun kankaalle (canvas)
  void _ttsWordPaintCallback(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    if (_ttsHighlightRect != null &&
        _ttsHighlightPage == page.pageNumber &&
        _ttsService.isSpeechActive) {
      final rect = _ttsHighlightRect!
          .toRect(page: page, scaledPageSize: pageRect.size)
          .translate(pageRect.left, pageRect.top);
      final rrect = RRect.fromRectAndRadius(rect.inflate(2.0), const Radius.circular(3.0));
      canvas.drawRRect(
        rrect,
        Paint()..color = const Color(0xFFFDE047).withValues(alpha: 0.65),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0xFFEA580C)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  /// Hakee PDF-sivun tekstisisällön sekä merkkien koordinaatit suoraan dokumentista
  Future<String> _haePdfSivunTeksti(int sivuNumero) async {
    try {
      if (_pdfController1.isReady) {
        final raw = await _pdfController1.useDocument<PdfPageRawText?>((document) async {
          if (sivuNumero < 1 || sivuNumero > document.pages.length) return null;
          final page = document.pages[sivuNumero - 1];
          final loaded = page.isLoaded ? page : await page.waitForLoaded();
          if (loaded == null) return null;
          return await loaded.loadText();
        });
        if (raw != null && raw.fullText.trim().isNotEmpty) {
          _nykyinenPdfRawText = raw;
          return raw.fullText;
        }
      }
      final pageText = await _textSearcher1.loadText(pageNumber: sivuNumero);
      if (pageText != null && pageText.fullText.isNotEmpty) {
        _nykyinenPdfRawText = PdfPageRawText(pageText.fullText, pageText.charRects);
        return pageText.fullText;
      }
      return '';
    } catch (e) {
      debugPrint('PDF-sivun tekstin luku epäonnistui: $e');
      return '';
    }
  }

  Future<void> _palautaPuhetilaJosOlemassa() async {
    final ttsState = await BookTtsService.haeTallennettuTila(widget.tiedostoPolku);
    if (ttsState != null && mounted) {
      final int savedPage = ttsState['page'] as int? ?? _nykyinenSivu;
      final int savedOffset = ttsState['offset'] as int? ?? 0;
      final String savedWord = ttsState['word'] as String? ?? '';
      final bool wasPaused = ttsState['paused'] as bool? ?? true;
      final String savedLang = ttsState['lang'] as String? ?? 'auto';

      final rawText = await _haePdfSivunTeksti(savedPage);
      final text = BookTtsService.valmisteleTekstiPuheeksi(rawText);

      if (text.isNotEmpty) {
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
  }

  Future<void> _aloitaPuheNykyiseltaSivulta({int startOffset = 0}) async {
    final rawText = await _haePdfSivunTeksti(_nykyinenSivu);
    final text = BookTtsService.valmisteleTekstiPuheeksi(rawText);
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sivulta ei löytynyt luettavaa tekstiä.')),
        );
      }
      return;
    }

    _ttsService.aloitaTaiJatkaPuhetta(
      teksti: text,
      bookPath: widget.tiedostoPolku,
      pageNumber: _nykyinenSivu,
      aloitusOffset: startOffset,
    );
  }

  void _jatkaPuhetta() {
    if (_ttsService.currentFullText.trim().isEmpty || _ttsService.currentPageNumber != _nykyinenSivu) {
      _aloitaPuheNykyiseltaSivulta();
      return;
    }
    _ttsService.resume();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _ttsService.tallennaTila();
      ReadingPositionService.tallennaLevylle(
        bookPath: widget.tiedostoPolku,
        pageNumber: _nykyinenSivu,
        isPdf: true,
      );
    }
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ttsService.stateNotifier.removeListener(_onTtsStateChanged);
    // Tallennetaan puhetila ja lukukohta levylle vasta kun kirjasta poistutaan ulos
    _ttsService.tallennaTila();
    _ttsService.dispose();
    ReadingPositionService.tallennaLevylle(
      bookPath: widget.tiedostoPolku,
      pageNumber: _nykyinenSivu,
      isPdf: true,
    );
    _ilmoitusAjastin?.cancel();
    _textSearcher1.removeListener(_onSearchChanged);
    _textSearcher2.removeListener(_onSearchChanged);
    _textSearcher1.dispose();
    _textSearcher2.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _kaynnistaValintaAjastin() {
    _ilmoitusAjastin?.cancel();
    _ilmoitusAjastin = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() {
          _valintaIlmoitus = null;
          _progressiveResult = null;
        });
      }
    });
  }

  void _nollaaValinta() {
    _ilmoitusAjastin?.cancel();
    setState(() {
      _valintaIlmoitus = null;
      _progressiveResult = null;
      _viimeisinValittuTeksti = '';
    });
  }

  void _naytaValintaIlmoitus(String teksti) {
    final clean = teksti.trim();
    if (clean.isEmpty) return;
    _viimeisinValittuTeksti = clean;
    final ilmoitus = ProgressiveTextSelector.muodostaIlmoitusteksti(clean);
    final sanat = clean.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length;
    final lauseet = clean.split(RegExp(r'[.!?]+(?:\s+|\n+|$)')).where((l) => l.trim().isNotEmpty).length;
    final level = lauseet <= 1 ? '1 lause' : '$lauseet lausetta';

    setState(() {
      _valintaIlmoitus = ilmoitus;
      _progressiveResult = ProgressiveSelectionResult(
        selectedText: clean,
        noticeText: ilmoitus,
        levelText: level,
        sentenceCount: lauseet,
        paragraphCount: 1,
        wordCount: sanat,
        canShrink: lauseet > 1,
        canExpand: true,
      );
    });
    _kaynnistaValintaAjastin();
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

  Future<void> _lisaaKirjanmerkki({String? valittuTeksti}) async {
    final sivu = _nykyinenSivu;
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
    await BookmarkService.avaaKirjanmerkitSheet(
      context,
      bookPath: widget.tiedostoPolku,
      nykyinenSivu: _nykyinenSivu,
      onSiirryKohtaan: (BookBookmark bookmark) {
        _pdfController1.goToPage(pageNumber: bookmark.pageNumber, duration: Duration.zero);
        if (_kaksiNayttoa) {
          _pdfController2.goToPage(pageNumber: bookmark.pageNumber, duration: Duration.zero);
        }
        if (bookmark.selectedText.isNotEmpty) {
          _naytaValintaIlmoitus(bookmark.selectedText);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Siirrytty kirjanmerkkiin: ${bookmark.title} (Sivu ${bookmark.pageNumber})'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      onLisaaUusi: () async {
        await _lisaaKirjanmerkki();
      },
    );
  }

  void _vaihdaKaksiNayttoa(bool? arvo) {
    setState(() {
      _kaksiNayttoa = arvo ?? false;
    });
  }

  void _suoritaHaku(String text) {
    if (text.isEmpty) {
      _textSearcher1.resetTextSearch();
      _textSearcher2.resetTextSearch();
    } else {
      _textSearcher1.startTextSearch(text, searchImmediately: true);
      if (_kaksiNayttoa) {
        _textSearcher2.startTextSearch(text, searchImmediately: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _ttsService.tallennaTila();
          ReadingPositionService.tallennaLevylle(
            bookPath: widget.tiedostoPolku,
            pageNumber: _nykyinenSivu,
            isPdf: true,
          );
        }
      },
      child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: true,
        leading: const BackButton(color: Colors.black87),
        titleSpacing: 0,
        title: Text(
          _paivitettyOtsikko != null
              ? '$_paivitettyOtsikko - Sivu $_nykyinenSivu / $_yhteensaSivuja'
              : 'Sivu $_nykyinenSivu / $_yhteensaSivuja',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Colors.red.shade100,
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
                      color: isActive ? Colors.yellow.shade900 : Colors.black26,
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
                  _textSearcher1.resetTextSearch();
                  _textSearcher2.resetTextSearch();
                  _searchController.clear();
                }
              });
            },
          ),
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
                          onSubmitted: (value) => _suoritaHaku(value),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: _textSearcher1.hasMatches
                            ? () => _textSearcher1.goToPrevMatch()
                            : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: _textSearcher1.hasMatches
                            ? () => _textSearcher1.goToNextMatch()
                            : null,
                      ),
                      Text(
                        _textSearcher1.hasMatches
                            ? '${(_textSearcher1.currentIndex ?? 0) + 1} / ${_textSearcher1.matches.length}'
                            : (_textSearcher1.isSearching ? 'Haetaan...' : '0/0'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _kaksiNayttoa
                    ? Column(
                        children: [
                          Expanded(
                            child: _buildPdfView(1),
                          ),
                          const Divider(height: 1, color: Colors.black26),
                          Expanded(
                            child: _buildPdfView(2),
                          ),
                        ],
                      )
                    : _buildPdfView(1),
              ),
            ],
          ),
          if (_progressiveResult != null)
            SelectionControlPanel(
              result: _progressiveResult,
              onExpand: () {
                _kaynnistaValintaAjastin();
              },
              onShrink: () {
                _kaynnistaValintaAjastin();
              },
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

  Widget _buildPdfView(int viewIndex) {
    final controller = viewIndex == 1 ? _pdfController1 : _pdfController2;
    final textSearcher = viewIndex == 1 ? _textSearcher1 : _textSearcher2;
    final nykyinen = viewIndex == 1 ? _nykyinenSivu : _nykyinenSivu2;

    return Column(
      children: [
        if (_yhteensaSivuja > 1)
          Slider(
            value: nykyinen.toDouble().clamp(1.0, _yhteensaSivuja.toDouble()),
            min: 1,
            max: _yhteensaSivuja.toDouble(),
            divisions: _yhteensaSivuja - 1,
            label: nykyinen.toString(),
            onChanged: (double value) {
              controller.goToPage(pageNumber: value.round(), duration: Duration.zero);
            },
          ),
        Expanded(
          child: PdfViewer.file(
            widget.tiedostoPolku,
            controller: controller,
            initialPageNumber: widget.aloitusSivu,
            params: PdfViewerParams(
              pagePaintCallbacks: [
                textSearcher.pageTextMatchPaintCallback,
                _ttsWordPaintCallback,
              ],
              textSelectionParams: PdfTextSelectionParams(
                enabled: true,
                enableSelectionHandles: true,
                showContextMenuAutomatically: true,
                onTextSelectionChange: (PdfTextSelection selection) {
                  final text = selection.selectedTextIfLoaded;
                  if (text != null && text.trim().isNotEmpty) {
                    _naytaValintaIlmoitus(text);
                  }
                },
              ),
              customizeContextMenuItems: (params, items) {
                // Päivitetään Kopioi-valinta näyttämään vahvistusilmoitus
                final copyIdx = items.indexWhere((it) => it.type == ContextMenuButtonType.copy);
                if (copyIdx != -1) {
                  final orig = items[copyIdx];
                  items[copyIdx] = ContextMenuButtonItem(
                    type: ContextMenuButtonType.copy,
                    label: 'Kopioi',
                    onPressed: () async {
                      orig.onPressed?.call();
                      final text = await params.textSelectionDelegate.getSelectedText();
                      if (!mounted) return;
                      _naytaValintaIlmoitus(text);
                      TextActionHelper.kopioiLeikepoydalle(context, text);
                    },
                  );
                } else {
                  items.insert(
                    0,
                    ContextMenuButtonItem(
                      label: 'Kopioi',
                      onPressed: () async {
                        params.dismissContextMenu();
                        final text = await params.textSelectionDelegate.getSelectedText();
                        if (!mounted) return;
                        _naytaValintaIlmoitus(text);
                        TextActionHelper.kopioiLeikepoydalle(context, text);
                      },
                    ),
                  );
                }

                // Lisätään Verkkohaku
                items.add(
                  ContextMenuButtonItem(
                    label: 'Verkkohaku',
                    onPressed: () async {
                      params.dismissContextMenu();
                      final text = await params.textSelectionDelegate.getSelectedText();
                      if (!mounted) return;
                      _naytaValintaIlmoitus(text);
                      TextActionHelper.avaaVerkkohaku(context, text);
                    },
                  ),
                );

                // Lisätään Tekoälyhaku
                items.add(
                  ContextMenuButtonItem(
                    label: 'Tekoälyhaku',
                    onPressed: () async {
                      params.dismissContextMenu();
                      final text = await params.textSelectionDelegate.getSelectedText();
                      if (!mounted) return;
                      _naytaValintaIlmoitus(text);
                      TextActionHelper.avaaTekoalyhaku(context, text);
                    },
                  ),
                );

                // Lisätään Kirjanmerkki
                items.add(
                  ContextMenuButtonItem(
                    label: 'Kirjanmerkki',
                    onPressed: () async {
                      params.dismissContextMenu();
                      final text = await params.textSelectionDelegate.getSelectedText();
                      if (!mounted) return;
                      _naytaValintaIlmoitus(text);
                      _lisaaKirjanmerkki(valittuTeksti: text);
                    },
                  ),
                );

                // Lisätään Metaotsikkoon
                items.add(
                  ContextMenuButtonItem(
                    label: 'Metaotsikkoon',
                    onPressed: () async {
                      params.dismissContextMenu();
                      final text = await params.textSelectionDelegate.getSelectedText();
                      if (!mounted) return;
                      _naytaValintaIlmoitus(text);
                      _asetaMetaotsikoksi(text);
                    },
                  ),
                );
              },
              onViewerReady: (document, controller) {
                if (mounted) {
                  setState(() {
                    _yhteensaSivuja = document.pages.length;
                  });
                  if (viewIndex == 1 && !_ttsService.isSpeechActive) {
                    _palautaPuhetilaJosOlemassa();
                  }
                }
              },
              onPageChanged: (int? pageNumber) async {
                if (pageNumber == null) return;
                setState(() {
                  if (viewIndex == 1) {
                    _nykyinenSivu = pageNumber;
                  } else {
                    _nykyinenSivu2 = pageNumber;
                  }
                });
                if (viewIndex == 1) {
                  // Päivitetään lukukohta RAM-muistissa ilman levykirjoitusta
                  ReadingPositionService.paivitaLukukohtaMuistissa(
                    bookPath: widget.tiedostoPolku,
                    pageNumber: pageNumber,
                    isPdf: true,
                  );
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}
