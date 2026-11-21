import 'package:flutter/material.dart';

class ProgressiveSelectionResult {
  final String selectedText;
  final String noticeText;
  final String levelText;
  final int sentenceCount;
  final int paragraphCount;
  final int wordCount;
  final bool canShrink;
  final bool canExpand;

  ProgressiveSelectionResult({
    required this.selectedText,
    required this.noticeText,
    required this.levelText,
    required this.sentenceCount,
    required this.paragraphCount,
    required this.wordCount,
    required this.canShrink,
    required this.canExpand,
  });
}

class TextParagraph {
  final int paragraphIndex;
  final String text;
  final List<String> sentences;

  TextParagraph({
    required this.paragraphIndex,
    required this.text,
    required this.sentences,
  });
}

class TextSelectionScope {
  final String fullText;
  final List<TextParagraph> paragraphs;

  TextSelectionScope({required this.fullText, required this.paragraphs});

  factory TextSelectionScope.fromText(String text) {
    final rawParas = text.split(RegExp(r'\n\s*\n+'));
    List<TextParagraph> paras = [];
    int pCounter = 0;
    for (int i = 0; i < rawParas.length; i++) {
      final pText = rawParas[i].trim();
      if (pText.isEmpty) continue;

      // Etsitään lauseet: päättyvät pisteeseen, huutomerkkiin tai kysymysmerkkiin
      final sentenceRegex = RegExp(r'[^.!?]+[.!?]+(?:\s+|$)|[^.!?]+$');
      final matches = sentenceRegex.allMatches(pText);
      List<String> sentences = [];
      for (final m in matches) {
        final s = m.group(0)?.trim() ?? '';
        if (s.isNotEmpty) sentences.add(s);
      }
      if (sentences.isEmpty) sentences.add(pText);

      paras.add(TextParagraph(
        paragraphIndex: pCounter++,
        text: pText,
        sentences: sentences,
      ));
    }
    return TextSelectionScope(fullText: text, paragraphs: paras);
  }
}

class ProgressiveTextSelector {
  int _currentParagraphIndex = 0;
  int _startSentenceIndex = 0;
  int _endSentenceIndex = 0;
  int _startParagraphIndex = 0;
  int _endParagraphIndex = 0;
  bool _isParagraphMode = false;
  bool _hasActiveSelection = false;
  DateTime _lastLongPressTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool get hasActiveSelection => _hasActiveSelection;

  void reset() {
    _currentParagraphIndex = 0;
    _startSentenceIndex = 0;
    _endSentenceIndex = 0;
    _startParagraphIndex = 0;
    _endParagraphIndex = 0;
    _isParagraphMode = false;
    _hasActiveSelection = false;
  }

  /// Valitsee heti tasan 1 lauseen kohdistuskohdasta (tuplatapautus tai 1. pitkä painallus)
  ProgressiveSelectionResult selectSentence({
    required TextSelectionScope scope,
    int? focusParagraphIndex,
    int? focusSentenceIndex,
  }) {
    if (scope.paragraphs.isEmpty) {
      return _emptyResult();
    }

    _currentParagraphIndex = (focusParagraphIndex ?? 0).clamp(0, scope.paragraphs.length - 1);
    final p = scope.paragraphs[_currentParagraphIndex];
    final sIdx = (focusSentenceIndex ?? 0).clamp(0, p.sentences.length - 1);

    _startSentenceIndex = sIdx;
    _endSentenceIndex = sIdx;
    _startParagraphIndex = _currentParagraphIndex;
    _endParagraphIndex = _currentParagraphIndex;
    _isParagraphMode = false;
    _hasActiveSelection = true;
    _lastLongPressTime = DateTime.now();

    return _buildResult(scope);
  }

  /// Laajentaa valintaa [+] askeleella:
  /// Lausemoodissa: +2 ympäröivää lausetta (tai koko kappale)
  /// Kappalemoodissa: +2 ympäröivää kappaletta
  ProgressiveSelectionResult expand({required TextSelectionScope scope}) {
    if (scope.paragraphs.isEmpty) return _emptyResult();
    if (!_hasActiveSelection) {
      return selectSentence(scope: scope);
    }

    final p = scope.paragraphs[_currentParagraphIndex];

    if (!_isParagraphMode) {
      final newStart = (_startSentenceIndex - 1).clamp(0, p.sentences.length - 1);
      final newEnd = (_endSentenceIndex + 1).clamp(0, p.sentences.length - 1);

      if (newStart == 0 && newEnd == p.sentences.length - 1) {
        _isParagraphMode = true;
        _startParagraphIndex = _currentParagraphIndex;
        _endParagraphIndex = _currentParagraphIndex;
      } else {
        _startSentenceIndex = newStart;
        _endSentenceIndex = newEnd;
      }
    } else {
      final newStartP = (_startParagraphIndex - 1).clamp(0, scope.paragraphs.length - 1);
      final newEndP = (_endParagraphIndex + 1).clamp(0, scope.paragraphs.length - 1);
      _startParagraphIndex = newStartP;
      _endParagraphIndex = newEndP;
    }

    return _buildResult(scope);
  }

  /// Supistaa valintaa [–] askeleella:
  /// Kappalemoodissa: supistaa kappaleita tai palaa lausemoodiin
  /// Lausemoodissa: supistaa 2 lausetta
  ProgressiveSelectionResult shrink({required TextSelectionScope scope}) {
    if (scope.paragraphs.isEmpty) return _emptyResult();
    if (!_hasActiveSelection) return _emptyResult();

    final p = scope.paragraphs[_currentParagraphIndex];

    if (_isParagraphMode) {
      if (_startParagraphIndex < _endParagraphIndex) {
        _startParagraphIndex = (_startParagraphIndex + 1).clamp(0, _endParagraphIndex);
        _endParagraphIndex = (_endParagraphIndex - 1).clamp(_startParagraphIndex, scope.paragraphs.length - 1);
      } else {
        // Palataan lausemoodiin
        _isParagraphMode = false;
        _startSentenceIndex = 0;
        _endSentenceIndex = (p.sentences.length - 1).clamp(0, p.sentences.length - 1);
      }
    } else {
      if (_startSentenceIndex < _endSentenceIndex) {
        _startSentenceIndex = (_startSentenceIndex + 1).clamp(0, _endSentenceIndex);
        _endSentenceIndex = (_endSentenceIndex - 1).clamp(_startSentenceIndex, p.sentences.length - 1);
      }
    }

    return _buildResult(scope);
  }

  /// Käsittelee peräkkäiset painallukset
  ProgressiveSelectionResult processLongPress({
    required TextSelectionScope scope,
    int? focusParagraphIndex,
    int? focusSentenceIndex,
  }) {
    if (scope.paragraphs.isEmpty) return _emptyResult();

    final now = DateTime.now();
    final isConsecutive = now.difference(_lastLongPressTime) < const Duration(milliseconds: 5000);
    _lastLongPressTime = now;

    if (!isConsecutive || !_hasActiveSelection) {
      return selectSentence(
        scope: scope,
        focusParagraphIndex: focusParagraphIndex,
        focusSentenceIndex: focusSentenceIndex,
      );
    } else {
      return expand(scope: scope);
    }
  }

  ProgressiveSelectionResult _buildResult(TextSelectionScope scope) {
    if (!_isParagraphMode) {
      final p = scope.paragraphs[_currentParagraphIndex];
      final sentences = p.sentences.sublist(_startSentenceIndex, _endSentenceIndex + 1);
      final text = sentences.join(' ');
      final sCount = sentences.length;
      final words = _countWords(text);

      final level = sCount == 1 ? '1 lause' : '$sCount lausetta';
      final canShrink = _startSentenceIndex < _endSentenceIndex;
      final canExpand = true;

      return ProgressiveSelectionResult(
        selectedText: text,
        noticeText: 'Valittu: $level ($words sanaa)',
        levelText: level,
        sentenceCount: sCount,
        paragraphCount: 1,
        wordCount: words,
        canShrink: canShrink,
        canExpand: canExpand,
      );
    } else {
      final paras = scope.paragraphs.sublist(_startParagraphIndex, _endParagraphIndex + 1);
      final text = paras.map((e) => e.text).join('\n\n');
      final pCount = paras.length;
      final words = _countWords(text);

      final level = pCount == 1 ? '1 kappale' : '$pCount kappaletta';
      final canShrink = true;
      final canExpand = _startParagraphIndex > 0 || _endParagraphIndex < scope.paragraphs.length - 1;

      return ProgressiveSelectionResult(
        selectedText: text,
        noticeText: 'Valittu: $level ($words sanaa)',
        levelText: level,
        sentenceCount: paras.fold<int>(0, (sum, p) => sum + p.sentences.length),
        paragraphCount: pCount,
        wordCount: words,
        canShrink: canShrink,
        canExpand: canExpand,
      );
    }
  }

  ProgressiveSelectionResult _emptyResult() {
    return ProgressiveSelectionResult(
      selectedText: '',
      noticeText: 'Ei valittavaa tekstiä',
      levelText: '0',
      sentenceCount: 0,
      paragraphCount: 0,
      wordCount: 0,
      canShrink: false,
      canExpand: false,
    );
  }

  /// Laskee valitun tekstin koon ja muodostaa ilmoitustekstin
  static String muodostaIlmoitusteksti(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return 'Ei valintaa';

    final sanat = _countWords(clean);
    final kappaleet = clean.split(RegExp(r'\n\s*\n+')).where((k) => k.trim().isNotEmpty).length;
    final lauseet = clean.split(RegExp(r'[.!?]+(?:\s+|\n+|$)')).where((l) => l.trim().isNotEmpty).length;

    if (kappaleet > 1) {
      return 'Valittu: $kappaleet tekstikappaletta ($sanat sanaa)';
    } else if (kappaleet == 1 && lauseet > 1) {
      return 'Valittu: $lauseet lausetta ($sanat sanaa)';
    } else if (lauseet <= 1 && sanat > 1) {
      return 'Valittu: 1 lause ($sanat sanaa)';
    } else {
      return 'Valittu: $sanat sanaa';
    }
  }

  static int _countWords(String text) {
    return text.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length;
  }
}

/// Kelluva lausesäätimen ja pikatoimintojen ohjauspaneeli näytön alareunaan
class SelectionControlPanel extends StatelessWidget {
  final ProgressiveSelectionResult? result;
  final VoidCallback? onExpand;
  final VoidCallback? onShrink;
  final VoidCallback? onCopy;
  final VoidCallback? onWebSearch;
  final VoidCallback? onAiSearch;
  final VoidCallback? onBookmark;
  final VoidCallback? onMetaotsikko;
  final VoidCallback? onDismiss;

  const SelectionControlPanel({
    super.key,
    required this.result,
    this.onExpand,
    this.onShrink,
    this.onCopy,
    this.onWebSearch,
    this.onAiSearch,
    this.onBookmark,
    this.onMetaotsikko,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (result == null || result!.selectedText.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      bottom: 20,
      left: 12,
      right: 12,
      child: Center(
        child: Material(
          elevation: 10,
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF1E222B),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 500),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.4), width: 1.2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Ylärivi: Valintatieto ja sulkupainike
                Row(
                  children: [
                    const Icon(Icons.format_quote_rounded, color: Colors.amberAccent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        result!.noticeText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (onDismiss != null)
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Sulje valinta',
                        onPressed: onDismiss,
                      ),
                  ],
                ),
                const SizedBox(height: 6),

                // Keskirivi: [–] ja [+] lausesäätimet ja markeeraustagin tila
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Vähennä lauseita [-]
                      TextButton.icon(
                        icon: const Icon(Icons.remove_circle_outline, size: 16),
                        label: const Text('Vähennä'),
                        style: TextButton.styleFrom(
                          foregroundColor: result!.canShrink ? Colors.white : Colors.white30,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: result!.canShrink ? onShrink : null,
                      ),

                      // Markeeraustagit-ilmaisin ja lausemäärä
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.arrow_left, color: Colors.blueAccent, size: 22),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blueAccent.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              result!.levelText,
                              style: const TextStyle(
                                color: Colors.amberAccent,
                                fontSize: 12.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const Icon(Icons.arrow_right, color: Colors.blueAccent, size: 22),
                        ],
                      ),

                      // Laajenna lauseita [+]
                      TextButton.icon(
                        icon: const Icon(Icons.add_circle_outline, size: 16),
                        label: const Text('Laajenna'),
                        style: TextButton.styleFrom(
                          foregroundColor: result!.canExpand ? Colors.white : Colors.white30,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: result!.canExpand ? onExpand : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Alarivi: Pikatoiminnot (Kopioi, Verkkohaku, Tekoäly, Kirjanmerkki)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _ActionButton(
                      icon: Icons.copy,
                      label: 'Kopioi',
                      color: Colors.white,
                      onTap: onCopy,
                    ),
                    _ActionButton(
                      icon: Icons.search,
                      label: 'Verkkohaku',
                      color: Colors.lightBlueAccent,
                      onTap: onWebSearch,
                    ),
                    _ActionButton(
                      icon: Icons.auto_awesome,
                      label: 'Tekoäly',
                      color: Colors.purpleAccent,
                      isAccent: true,
                      onTap: onAiSearch,
                    ),
                    if (onBookmark != null)
                      _ActionButton(
                        icon: Icons.bookmark_add,
                        label: 'Kirjanmerkki',
                        color: Colors.amberAccent,
                        onTap: onBookmark,
                      ),
                    if (onMetaotsikko != null)
                      _ActionButton(
                        icon: Icons.title,
                        label: 'Metaotsikkoon',
                        color: Colors.tealAccent,
                        onTap: onMetaotsikko,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool isAccent;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    this.isAccent = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isAccent ? Colors.purple.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: isAccent ? Border.all(color: Colors.purpleAccent.withValues(alpha: 0.5)) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Yhteensopivuusluokka vanhalle ilmoitukselle
class SelectionNoticeOverlay extends StatelessWidget {
  final String? noticeText;
  final VoidCallback? onTap;

  const SelectionNoticeOverlay({
    super.key,
    required this.noticeText,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (noticeText == null) return const SizedBox.shrink();

    return Positioned(
      bottom: 24,
      left: 20,
      right: 20,
      child: Center(
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(30),
          color: Colors.black87,
          child: InkWell(
            borderRadius: BorderRadius.circular(30),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle, color: Colors.amberAccent, size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      noticeText!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.touch_app, color: Colors.amberAccent, size: 16),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
