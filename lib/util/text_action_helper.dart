import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'voice_service.dart';

class AiLanguage {
  final String code;
  final String flag;
  final String name;
  final String country;

  const AiLanguage({
    required this.code,
    required this.flag,
    required this.name,
    required this.country,
  });
}

const List<AiLanguage> kTuetutKielet = [
  AiLanguage(code: 'fi', flag: '🇫🇮', name: 'Suomi', country: 'Suomi'),
  AiLanguage(code: 'en', flag: '🇬🇧', name: 'Englanti', country: 'Iso-Britannia / USA'),
  AiLanguage(code: 'sv', flag: '🇸🇪', name: 'Ruotsi', country: 'Ruotsi'),
  AiLanguage(code: 'de', flag: '🇩🇪', name: 'Saksa', country: 'Saksa / Itävalta'),
  AiLanguage(code: 'fr', flag: '🇫🇷', name: 'Ranska', country: 'Ranska'),
  AiLanguage(code: 'es', flag: '🇪🇸', name: 'Espanja', country: 'Espanja / Latinalainen Amerikka'),
  AiLanguage(code: 'it', flag: '🇮🇹', name: 'Italia', country: 'Italia'),
  AiLanguage(code: 'no', flag: '🇳🇴', name: 'Norja', country: 'Norja'),
  AiLanguage(code: 'da', flag: '🇩🇰', name: 'Tanska', country: 'Tanska'),
  AiLanguage(code: 'et', flag: '🇪🇪', name: 'Viro', country: 'Viro'),
  AiLanguage(code: 'is', flag: '🇮🇸', name: 'Islanti', country: 'Islanti'),
  AiLanguage(code: 'nl', flag: '🇳🇱', name: 'Hollanti', country: 'Alankomaat'),
  AiLanguage(code: 'pl', flag: '🇵🇱', name: 'Puola', country: 'Puola'),
  AiLanguage(code: 'uk', flag: '🇺🇦', name: 'Ukraina', country: 'Ukraina'),
  AiLanguage(code: 'el', flag: '🇬🇷', name: 'Kreikka', country: 'Kreikka'),
  AiLanguage(code: 'pt', flag: '🇵🇹', name: 'Portugali', country: 'Portugali / Brasilia'),
  AiLanguage(code: 'ja', flag: '🇯🇵', name: 'Japani', country: 'Japani'),
  AiLanguage(code: 'zh', flag: '🇨🇳', name: 'Kiina', country: 'Kiina'),
  AiLanguage(code: 'ko', flag: '🇰🇷', name: 'Korea', country: 'Etelä-Korea'),
  AiLanguage(code: 'ru', flag: '🇷🇺', name: 'Venäjä', country: 'Venäjä'),
  AiLanguage(code: 'ar', flag: '🇸🇦', name: 'Arabia', country: 'Saudi-Arabia / Lähi-itä'),
  AiLanguage(code: 'la', flag: '🏛️', name: 'Latina', country: 'Antiikin Rooma / Vatikaani'),
];

class TextActionHelper {
  /// Kopioi valitun tekstin leikepöydälle ja näyttää ilmoituksen
  static Future<void> kopioiLeikepoydalle(BuildContext context, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: clean));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Valittu teksti kopioitu leikepöydälle'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// Avaa verkkohaun valitulla tekstillä selaimessa (Google)
  static Future<void> avaaVerkkohaku(BuildContext context, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;

    final uri = Uri.parse('https://www.google.com/search?q=${Uri.encodeComponent(clean)}');
    try {
      final success = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!success && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Verkkohakua ei voitu avata selaimessa')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Virhe haussa: $e')),
        );
      }
    }
  }

  /// Avaa tekoälyhaku-näkymän (in-app Gemini + Perplexity / Google AI -linkit)
  static void avaaTekoalyhaku(BuildContext context, String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => TekoalyHakuSheet(valittuTeksti: clean),
    );
  }

  /// Näyttää pikavalikon valitulle tekstille (Kopioi, Verkkohaku, Tekoälyhaku, Kirjanmerkki)
  static void naytaValintaPikavalikko(
    BuildContext context,
    String text, {
    VoidCallback? onLisaaKirjanmerkki,
    VoidCallback? onAsetaMetaotsikoksi,
  }) {
    final clean = text.trim();
    if (clean.isEmpty) return;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Text(
                  clean,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Kopioi'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        kopioiLeikepoydalle(context, clean);
                      },
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.search, size: 16),
                      label: const Text('Verkkohaku'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        avaaVerkkohaku(context, clean);
                      },
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple.shade600,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('Tekoäly'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        avaaTekoalyhaku(context, clean);
                      },
                    ),
                    if (onLisaaKirjanmerkki != null)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber.shade700,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.bookmark_add, size: 16),
                        label: const Text('Kirjanmerkki'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          onLisaaKirjanmerkki();
                        },
                      ),
                    if (onAsetaMetaotsikoksi != null)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal.shade700,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.title, size: 16),
                        label: const Text('Metaotsikkoon'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          onAsetaMetaotsikoksi();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class TekoalyHakuSheet extends StatefulWidget {
  final String valittuTeksti;

  const TekoalyHakuSheet({super.key, required this.valittuTeksti});

  @override
  State<TekoalyHakuSheet> createState() => _TekoalyHakuSheetState();
}

class _TekoalyHakuSheetState extends State<TekoalyHakuSheet> {
  final TextEditingController _kysymysCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  String _vastaus = '';
  bool _ladataan = false;
  String? _virhe;
  String? _tallennettuApiKey;
  bool _naytaApiKeyKentta = false;
  int? _totalTokens;
  int? _promptTokens;
  int? _candidatesTokens;

  // Valittu kieli (lippu + sana/kieli + maa)
  AiLanguage _valittuKieli = kTuetutKielet.first; // Suomi oletuksena

  @override
  void initState() {
    super.initState();
    _lataaAsetukset();
  }

  @override
  void dispose() {
    _kysymysCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _lataaAsetukset() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('gemini_api_key');
    final langCode = prefs.getString('ai_language_code');

    if (mounted) {
      setState(() {
        _tallennettuApiKey = key;
        if (key != null && key.isNotEmpty) {
          _apiKeyCtrl.text = key;
        } else {
          _naytaApiKeyKentta = true;
        }

        if (langCode != null) {
          _valittuKieli = kTuetutKielet.firstWhere(
            (l) => l.code == langCode,
            orElse: () => kTuetutKielet.first,
          );
        }
      });
    }
  }

  Future<void> _vaihdaKieli(AiLanguage kieli) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_language_code', kieli.code);
    if (mounted) {
      setState(() {
        _valittuKieli = kieli;
      });
    }
  }

  Future<void> _tallennaApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', key.trim());
    if (mounted) {
      setState(() {
        _tallennettuApiKey = key.trim();
        _naytaApiKeyKentta = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gemini API -avain tallennettu!')),
      );
    }
  }

  /// Avaa kielenvalintadialogin, jossa näkyvät lippu, sana (kieli) ja maa arvoparina
  Future<void> _avaaKielenValintaDialogi() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        String suodatin = '';
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final naytettavatKielet = kTuetutKielet.where((k) {
              if (suodatin.isEmpty) return true;
              final q = suodatin.toLowerCase();
              return k.name.toLowerCase().contains(q) ||
                  k.country.toLowerCase().contains(q) ||
                  k.code.toLowerCase().contains(q);
            }).toList();

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.75,
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    width: 40,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.language, color: Colors.blueAccent),
                            SizedBox(width: 8),
                            Text(
                              'Valitse tekoälyn kieli',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: 'Hae kielen tai maan nimellä...',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onChanged: (val) {
                        setSheetState(() {
                          suodatin = val.trim();
                        });
                      },
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      itemCount: naytettavatKielet.length,
                      itemBuilder: (context, index) {
                        final kieli = naytettavatKielet[index];
                        final isSelected = kieli.code == _valittuKieli.code;
                        return ListTile(
                          leading: Text(
                            kieli.flag,
                            style: const TextStyle(fontSize: 28),
                          ),
                          title: Row(
                            children: [
                              Text(
                                kieli.name,
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                  fontSize: 15,
                                  color: isSelected ? Colors.blueAccent : Colors.black87,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade200,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  kieli.code.toUpperCase(),
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            'Maa: ${kieli.country}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                          trailing: isSelected
                              ? const Icon(Icons.check_circle, color: Colors.blueAccent)
                              : null,
                          onTap: () {
                            _vaihdaKieli(kieli);
                            Navigator.pop(sheetContext);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Suorittaa tekoälykyselyn Google Gemini API:lle valitulla kielellä
  Future<void> _suoritaGeminiKysely(String kehote) async {
    if (_tallennettuApiKey == null || _tallennettuApiKey!.isEmpty) {
      setState(() {
        _naytaApiKeyKentta = true;
        _virhe =
            'Aseta ilmainen Gemini API -avain käyttääksesi sisäänrakennettua tekoälyä, tai avaa suoraan verkkotekoäly alta.';
      });
      return;
    }

    setState(() {
      _ladataan = true;
      _virhe = null;
      _vastaus = '';
    });

    try {
      final prompt =
          '$kehote (Kohdekieli: ${_valittuKieli.name}, ${_valittuKieli.country})\n\nTeksti kirjalähteestä:\n"""\n${widget.valittuTeksti}\n"""';
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$_tallennettuApiKey',
      );

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt}
              ]
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final usage = data['usageMetadata'] as Map<String, dynamic>?;
        if (usage != null) {
          _totalTokens = usage['totalTokenCount'] as int?;
          _promptTokens = usage['promptTokenCount'] as int?;
          _candidatesTokens = usage['candidatesTokenCount'] as int?;
        } else {
          _totalTokens = null;
          _promptTokens = null;
          _candidatesTokens = null;
        }

        final candidates = data['candidates'] as List<dynamic>?;
        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates[0]['content'];
          final parts = content?['parts'] as List<dynamic>?;
          if (parts != null && parts.isNotEmpty) {
            final text = parts[0]['text'] as String?;
            setState(() {
              _vastaus = text ?? 'Ei vastausta tekoälyltä.';
              _ladataan = false;
            });
            return;
          }
        }
        setState(() {
          _virhe = 'Tekoäly ei palauttanut vastausta.';
          _ladataan = false;
        });
      } else {
        final virheData = jsonDecode(response.body);
        final msg = virheData['error']?['message'] ?? 'Status: ${response.statusCode}';
        setState(() {
          _virhe = 'API-virhe: $msg';
          _ladataan = false;
        });
      }
    } catch (e) {
      setState(() {
        _virhe = 'Yhteysvirhe: $e';
        _ladataan = false;
      });
    }
  }

  /// Palauttaa tekoälyhakukoneen nimen valitun kielen mukaan (Suomi, Ruotsi, Saksa, Englanti jne.)
  String _haeTekoalyHakukoneTeksti(String langCode) {
    switch (langCode.toLowerCase()) {
      case 'fi':
        return 'Tekoälyhakukone';
      case 'sv':
        return 'AI-sökmotor';
      case 'de':
        return 'KI-Suchmaschine';
      case 'en':
        return 'AI Search Engine';
      case 'fr':
        return 'Moteur de recherche IA';
      case 'es':
        return 'Motor de búsqueda IA';
      case 'it':
        return 'Motore di ricerca IA';
      case 'no':
        return 'AI-søkemotor';
      case 'da':
        return 'AI-søgemaskine';
      case 'et':
        return 'TI-otsingumootor';
      case 'nl':
        return 'AI-zoekmachine';
      case 'pl':
        return 'Wyszukiwarka AI';
      case 'ru':
        return 'ИИ-поисковик';
      default:
        return 'Tekoälyhakukone';
    }
  }

  /// Palauttaa verkkohaun otsikon valitun kielen mukaan
  String _haeVerkkohakuOtsikkoTeksti(String langCode) {
    switch (langCode.toLowerCase()) {
      case 'fi':
        return 'Verkkohaku tekoälyllä:';
      case 'sv':
        return 'Webbsökning med AI:';
      case 'de':
        return 'Websuche mit KI:';
      case 'en':
        return 'AI Web Search:';
      case 'fr':
        return 'Recherche web avec IA :';
      case 'es':
        return 'Búsqueda web con IA:';
      case 'it':
        return 'Ricerca web con IA:';
      case 'no':
        return 'Nettsøk med AI:';
      case 'da':
        return 'Websøgning med AI:';
      case 'et':
        return 'Veebiotsing tehisintellektiga:';
      default:
        return 'Verkkohaku tekoälyllä:';
    }
  }

  /// Avaa haku ulkoisessa verkkotekoälyssä selaimella huomioiden valitun kielen
  Future<void> _avaaUlkoinenTekoaly(String palvelu) async {
    Uri uri;
    final q = Uri.encodeComponent('${widget.valittuTeksti} in ${_valittuKieli.name}');
    switch (palvelu) {
      case 'perplexity':
        uri = Uri.parse('https://www.perplexity.ai/search?q=$q');
        break;
      case 'gemini':
        uri = Uri.parse('https://gemini.google.com/app');
        break;
      default:
        uri = Uri.parse(
          'https://www.google.com/search?q=${Uri.encodeComponent("Tekoäly selitys (${_valittuKieli.name}): ${widget.valittuTeksti}")}',
        );
        break;
    }

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// Ääniohjaus: kuuntelee käyttäjän puhetta ja muuntaa tekstiksi tai suoraan tekoälyhauksi
  Future<void> _avaaAanihaku({bool suoritaHakuValittomasti = false}) async {
    final teksti = await VoiceService.kuuntelePuhetta(
      context,
      langCode: _valittuKieli.code,
    );
    if (!mounted || teksti == null || teksti.trim().isEmpty) return;
    final clean = teksti.trim();
    setState(() {
      _kysymysCtrl.text = clean;
    });

    if (suoritaHakuValittomasti) {
      _suoritaGeminiKysely(
        'Vastaa selkeästi kielellä ${_valittuKieli.name} (${_valittuKieli.country}) seuraavaan kysymykseen:\n$clean',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      margin: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Yläkahva
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),

          // Otsikkorivi
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.auto_awesome, color: Colors.purple, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'Tekoälyhaku & Selitys',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                IconButton(
                  icon: Icon(
                    _naytaApiKeyKentta ? Icons.key_off : Icons.key,
                    color: _tallennettuApiKey != null ? Colors.green : Colors.grey,
                  ),
                  tooltip: 'Gemini API -avain',
                  onPressed: () {
                    setState(() {
                      _naytaApiKeyKentta = !_naytaApiKeyKentta;
                    });
                  },
                ),
              ],
            ),
          ),
          const Divider(),

          // Sisältöalue
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Valittu teksti lainauksena
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Valittu tekstialue:',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.valittuTeksti,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Pikatoimintojen otsikko ja kielenvalintapainike (Lippu + Kieli)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Pikatoiminnot tekoälylle:',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      InkWell(
                        onTap: _avaaKielenValintaDialogi,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            border: Border.all(color: Colors.blue.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_valittuKieli.flag, style: const TextStyle(fontSize: 16)),
                              const SizedBox(width: 5),
                              Text(
                                _valittuKieli.name,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueAccent,
                                ),
                              ),
                              const Icon(Icons.arrow_drop_down, size: 18, color: Colors.blueAccent),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // Pikatoiminnot: Kielen valinta -lippunappi ja toiminnot
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        // Lippunappi kielen vaihtoon ennen toimintoja
                        ActionChip(
                          avatar: Text(_valittuKieli.flag, style: const TextStyle(fontSize: 16)),
                          label: Text(
                            '${_valittuKieli.name} ▾',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                          backgroundColor: Colors.blue.shade50,
                          onPressed: _avaaKielenValintaDialogi,
                        ),
                        const SizedBox(width: 6),

                        // Ääniohjaus tekoälylle (puhe -> tekoälykysely)
                        ActionChip(
                          avatar: const Icon(Icons.mic, size: 16, color: Colors.deepOrange),
                          label: Text('Ääniohjaus (${_valittuKieli.name})'),
                          backgroundColor: Colors.deepOrange.shade50,
                          onPressed: () => _avaaAanihaku(suoritaHakuValittomasti: true),
                        ),
                        const SizedBox(width: 6),

                        // Käännä valitulle kielelle
                        ActionChip(
                          avatar: const Icon(Icons.translate, size: 16, color: Colors.green),
                          label: Text('Käännä (${_valittuKieli.flag} ${_valittuKieli.name})'),
                          onPressed: () => _suoritaGeminiKysely(
                            'Käännä seuraava teksti sujuvasti ja luontevasti kielelle ${_valittuKieli.name} (${_valittuKieli.country}):',
                          ),
                        ),
                        const SizedBox(width: 6),

                        // Selitä käsite
                        ActionChip(
                          avatar: const Icon(Icons.help_outline, size: 16, color: Colors.blue),
                          label: Text('Selitä (${_valittuKieli.name})'),
                          onPressed: () => _suoritaGeminiKysely(
                            'Selitä selkeästi ja tiiviisti kielellä ${_valittuKieli.name} (${_valittuKieli.country}) seuraava teksti tai käsite:',
                          ),
                        ),
                        const SizedBox(width: 6),

                        // Tiivistä
                        ActionChip(
                          avatar: const Icon(Icons.short_text, size: 16, color: Colors.orange),
                          label: Text('Tiivistä (${_valittuKieli.name})'),
                          onPressed: () => _suoritaGeminiKysely(
                            'Tee lyhyt ja ytimekäs tiivistelmä kielellä ${_valittuKieli.name} seuraavasta tekstistä:',
                          ),
                        ),
                        const SizedBox(width: 6),

                        // Taustat & Faktat
                        ActionChip(
                          avatar: const Icon(Icons.lightbulb_outline, size: 16, color: Colors.purple),
                          label: Text('Taustat & Faktat (${_valittuKieli.name})'),
                          onPressed: () => _suoritaGeminiKysely(
                            'Kerro kiinnostavia taustatietoja ja faktoja kielellä ${_valittuKieli.name} tästä aiheesta:',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Verkkotekoälyn pikahaku (ilman API-avainta toimiva)
                  Row(
                    children: [
                      Text(
                        _haeVerkkohakuOtsikkoTeksti(_valittuKieli.code),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'Perplexity AI (${_valittuKieli.name})',
                        child: InkWell(
                          onTap: () => _avaaUlkoinenTekoaly('perplexity'),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.teal.shade50,
                              border: Border.all(color: Colors.teal.shade300),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.manage_search, size: 14, color: Colors.teal),
                                const SizedBox(width: 4),
                                Text(
                                  _haeTekoalyHakukoneTeksti(_valittuKieli.code),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.teal,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'Google Gemini Web (${_valittuKieli.name})',
                        child: InkWell(
                          onTap: () => _avaaUlkoinenTekoaly('gemini'),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              border: Border.all(color: Colors.blue.shade300),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.auto_awesome, size: 14, color: Colors.blue),
                                SizedBox(width: 4),
                                Text(
                                  'Gemini Web',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // API-avainkenttä
                  if (_naytaApiKeyKentta) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        border: Border.all(color: Colors.amber.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Aseta Gemini API -avain (Google AI Studio, ilmainen):',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _apiKeyCtrl,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    hintText: 'Liitä AI Studio API -avain...',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: () => _tallennaApiKey(_apiKeyCtrl.text),
                                child: const Text('Tallenna'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Oma vapaa kysymys tekstistä tai äänellä
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _kysymysCtrl,
                          decoration: InputDecoration(
                            hintText: 'Kysy tai puhu (${_valittuKieli.name})...',
                            isDense: true,
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.mic, color: Colors.deepOrange),
                              tooltip: 'Äänisyöte (muunna tekstiksi)',
                              onPressed: () => _avaaAanihaku(suoritaHakuValittomasti: false),
                            ),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onSubmitted: (val) {
                            if (val.trim().isNotEmpty) {
                              _suoritaGeminiKysely(
                                'Vastaa selkeästi kielellä ${_valittuKieli.name} (${_valittuKieli.country}) seuraavaan kysymykseen:\n${val.trim()}',
                              );
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        icon: const Icon(Icons.send, size: 18),
                        onPressed: () {
                          if (_kysymysCtrl.text.trim().isNotEmpty) {
                            _suoritaGeminiKysely(
                              'Vastaa selkeästi kielellä ${_valittuKieli.name} (${_valittuKieli.country}) seuraavaan kysymykseen:\n${_kysymysCtrl.text.trim()}',
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Tekoälyn vastausalue
                  if (_ladataan) ...[
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24.0),
                        child: Column(
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 12),
                            Text(
                              'Tekoäly analysoi tekstiä (${_valittuKieli.flag} ${_valittuKieli.name})...',
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ] else if (_virhe != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        border: Border.all(color: Colors.red.shade200),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_virhe!, style: TextStyle(color: Colors.red.shade800, fontSize: 13)),
                    ),
                  ] else if (_vastaus.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.purple.shade50.withValues(alpha: 0.5),
                        border: Border.all(color: Colors.purple.shade200),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.auto_awesome, color: Colors.purple, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Vastaus (${_valittuKieli.flag} ${_valittuKieli.name}):',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: Colors.purple,
                                    ),
                                  ),
                                ],
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 18),
                                tooltip: 'Kopioi vastaus',
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: _vastaus));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Vastaus kopioitu leikepöydälle')),
                                  );
                                },
                              ),
                            ],
                          ),
                          const Divider(),
                          SelectableText(
                            _vastaus,
                            style: const TextStyle(fontSize: 14, height: 1.4),
                          ),
                          if (_totalTokens != null) ...[
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Icon(Icons.token_outlined, size: 13, color: Colors.purple.shade400),
                                const SizedBox(width: 4),
                                Text(
                                  'Kulutus: $_totalTokens tokenia (syöte: $_promptTokens, vastaus: $_candidatesTokens)',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade600,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
