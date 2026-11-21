import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class VoiceService {
  static final stt.SpeechToText _speech = stt.SpeechToText();
  static bool _isInitialized = false;

  /// Alustaa puheentunnistuspalvelun
  static Future<bool> init() async {
    if (_isInitialized) return true;
    try {
      _isInitialized = await _speech.initialize(
        onError: (_) {},
        onStatus: (_) {},
      );
    } catch (_) {
      _isInitialized = false;
    }
    return _isInitialized;
  }

  static stt.SpeechToText get speech => _speech;

  /// Muuntaa kielikoodin (esim. 'fi', 'en') sopivaksi SpeechToText-localeId:ksi
  static String haeLocaleId(String langCode) {
    switch (langCode.toLowerCase()) {
      case 'fi':
        return 'fi_FI';
      case 'en':
        return 'en_US';
      case 'sv':
        return 'sv_SE';
      case 'de':
        return 'de_DE';
      case 'fr':
        return 'fr_FR';
      case 'es':
        return 'es_ES';
      case 'it':
        return 'it_IT';
      case 'no':
        return 'nb_NO';
      case 'da':
        return 'da_DK';
      case 'et':
        return 'et_EE';
      case 'ja':
        return 'ja_JP';
      case 'zh':
        return 'zh_CN';
      case 'ru':
        return 'ru_RU';
      default:
        return 'fi_FI';
    }
  }

  /// Avaa ääniohjausdialogin, kuuntelee puhetta ja palauttaa tunnistetun tekstin
  static Future<String?> kuuntelePuhetta(
    BuildContext context, {
    String langCode = 'fi',
    String otsikko = 'Ääniohjaus',
    String vihje = 'Puhu nyt...',
  }) async {
    final ready = await init();
    if (!ready && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mikrofonia tai puheentunnistusta ei saatu käyttöön.')),
      );
      return null;
    }

    if (!context.mounted) return null;

    return await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => VoiceListeningSheet(
        langCode: langCode,
        otsikko: otsikko,
        vihje: vihje,
      ),
    );
  }
}

class VoiceListeningSheet extends StatefulWidget {
  final String langCode;
  final String otsikko;
  final String vihje;

  const VoiceListeningSheet({
    super.key,
    required this.langCode,
    required this.otsikko,
    required this.vihje,
  });

  @override
  State<VoiceListeningSheet> createState() => _VoiceListeningSheetState();
}

class _VoiceListeningSheetState extends State<VoiceListeningSheet>
    with SingleTickerProviderStateMixin {
  String _tunnistettuTeksti = '';
  bool _kuuntelee = false;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _aloitaKuuntelu();
  }

  @override
  void dispose() {
    _animController.dispose();
    VoiceService.speech.stop();
    super.dispose();
  }

  Future<void> _aloitaKuuntelu() async {
    setState(() {
      _kuuntelee = true;
      _tunnistettuTeksti = '';
    });

    final targetLocale = VoiceService.haeLocaleId(widget.langCode);

    try {
      await VoiceService.speech.listen(
        onResult: (result) {
          if (mounted) {
            setState(() {
              _tunnistettuTeksti = result.recognizedWords;
            });
          }
        },
        listenOptions: stt.SpeechListenOptions(
          localeId: targetLocale,
          listenMode: stt.ListenMode.confirmation,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _kuuntelee = false;
        });
      }
    }
  }

  void _lopetaKuunteluJaPalauta() {
    VoiceService.speech.stop();
    Navigator.pop(context, _tunnistettuTeksti.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 5,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.mic, color: Colors.redAccent, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    widget.otsikko,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  VoiceService.speech.stop();
                  Navigator.pop(context, null);
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          ScaleTransition(
            scale: Tween<double>(begin: 1.0, end: 1.25).animate(_animController),
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.redAccent.withValues(alpha: 0.15),
              ),
              child: Center(
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.redAccent,
                  ),
                  child: const Icon(Icons.mic, color: Colors.white, size: 30),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _kuuntelee ? 'Kuunnellaan puhetta...' : 'Kuuntelu päättynyt',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _kuuntelee ? Colors.redAccent : Colors.grey,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Text(
              _tunnistettuTeksti.isNotEmpty ? _tunnistettuTeksti : widget.vihje,
              style: TextStyle(
                fontSize: 15,
                color: _tunnistettuTeksti.isNotEmpty ? Colors.black87 : Colors.grey,
                fontStyle: _tunnistettuTeksti.isNotEmpty ? FontStyle.normal : FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    VoiceService.speech.stop();
                    Navigator.pop(context, null);
                  },
                  child: const Text('Peruuta'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Käytä puhetta'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _tunnistettuTeksti.isNotEmpty ? _lopetaKuunteluJaPalauta : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}
