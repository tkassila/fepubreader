import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

/// Yksittäisen dokumentin kirjanmerkki
class BookBookmark {
  final String id;
  final String bookPath;
  String title;
  final int pageNumber; // PDF: sivunumero (1-alkuinen), EPUB: luvun indeksi + 1
  final double scrollOffsetRatio; // 0.0 - 1.0 pystysuuntainen sijainti
  final String selectedText; // Maalattu tekstikohta (jos annettu valinnasta)
  final int createdAt; // Millisekunteina

  BookBookmark({
    required this.id,
    required this.bookPath,
    required this.title,
    required this.pageNumber,
    this.scrollOffsetRatio = 0.0,
    this.selectedText = '',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'bookPath': bookPath,
    'title': title,
    'pageNumber': pageNumber,
    'scrollOffsetRatio': scrollOffsetRatio,
    'selectedText': selectedText,
    'createdAt': createdAt,
  };

  factory BookBookmark.fromJson(Map<String, dynamic> json) => BookBookmark(
    id: json['id'] ?? '',
    bookPath: json['bookPath'] ?? '',
    title: json['title'] ?? '',
    pageNumber: json['pageNumber'] ?? 1,
    scrollOffsetRatio: (json['scrollOffsetRatio'] as num?)?.toDouble() ?? 0.0,
    selectedText: json['selectedText'] ?? '',
    createdAt: json['createdAt'] ?? DateTime.now().millisecondsSinceEpoch,
  );
}

/// Dokumenttikohtaisten kirjanmerkkien hallintapalvelu
class BookmarkService {
  static String _haeAvain(String bookPath) {
    final hash = md5.convert(utf8.encode(bookPath)).toString();
    return 'bookmarks_$hash';
  }

  /// Hakee kaikki tietyn kirjan kirjanmerkit
  static Future<List<BookBookmark>> haeKirjanmerkit(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_haeAvain(bookPath));
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      final merkit = list.map((item) => BookBookmark.fromJson(item)).toList();
      // Järjestetään sivun ja luontiajan mukaan
      merkit.sort((a, b) {
        final cmpPage = a.pageNumber.compareTo(b.pageNumber);
        if (cmpPage != 0) return cmpPage;
        return a.scrollOffsetRatio.compareTo(b.scrollOffsetRatio);
      });
      return merkit;
    } catch (_) {
      return [];
    }
  }

  /// Tallentaa kirjanmerkkilistan
  static Future<void> tallennaKirjanmerkit(String bookPath, List<BookBookmark> merkit) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(merkit.map((m) => m.toJson()).toList());
    await prefs.setString(_haeAvain(bookPath), jsonStr);
  }

  /// Lisää uuden kirjanmerkin ja palauttaa sen
  static Future<BookBookmark> lisaaKirjanmerkki({
    required String bookPath,
    required String title,
    required int pageNumber,
    double scrollOffsetRatio = 0.0,
    String selectedText = '',
  }) async {
    final merkit = await haeKirjanmerkit(bookPath);
    final uusi = BookBookmark(
      id: '${DateTime.now().millisecondsSinceEpoch}_${merkit.length}',
      bookPath: bookPath,
      title: title.trim().isEmpty ? 'Sivu $pageNumber' : title.trim(),
      pageNumber: pageNumber,
      scrollOffsetRatio: scrollOffsetRatio.clamp(0.0, 1.0),
      selectedText: selectedText.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    merkit.add(uusi);
    await tallennaKirjanmerkit(bookPath, merkit);
    return uusi;
  }

  /// Poistaa kirjanmerkin
  static Future<void> poistaKirjanmerkki(String bookPath, String id) async {
    final merkit = await haeKirjanmerkit(bookPath);
    merkit.removeWhere((m) => m.id == id);
    await tallennaKirjanmerkit(bookPath, merkit);
  }

  /// Päivittää kirjanmerkin nimen
  static Future<void> paivitaNimi(String bookPath, String id, String uusiNimi) async {
    final merkit = await haeKirjanmerkit(bookPath);
    for (var m in merkit) {
      if (m.id == id) {
        m.title = uusiNimi.trim().isEmpty ? 'Sivu ${m.pageNumber}' : uusiNimi.trim();
        break;
      }
    }
    await tallennaKirjanmerkit(bookPath, merkit);
  }

  /// Avaa nimeämisdialogin joko tekstikentässä tai maalatusta tekstistä
  static Future<String?> kysyKirjanmerkinNimi(
    BuildContext context, {
    String? oletusNimi,
    String? valittuTeksti,
    int? sivuNumero,
  }) async {
    String alkuNimi = '';
    if (oletusNimi != null && oletusNimi.trim().isNotEmpty) {
      alkuNimi = oletusNimi.trim();
    } else if (valittuTeksti != null && valittuTeksti.trim().isNotEmpty) {
      final siivottu = valittuTeksti.trim().replaceAll(RegExp(r'\s+'), ' ');
      alkuNimi = siivottu.length > 60 ? '${siivottu.substring(0, 57)}...' : siivottu;
    } else if (sivuNumero != null) {
      alkuNimi = 'Sivu $sivuNumero';
    }

    final controller = TextEditingController(text: alkuNimi);

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.bookmark_add, color: Colors.amber, size: 24),
            SizedBox(width: 8),
            Text('Uusi kirjanmerkki', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (valittuTeksti != null && valittuTeksti.trim().isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Maalattu tekstikohta (nimen lähde):',
                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.brown),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      valittuTeksti.trim(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ),
            ],
            const Text(
              'Anna nimi tai muokkaa nimeä:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Kirjanmerkin nimi...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                isDense: true,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => controller.clear(),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Peruuta'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Tallenna'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final nimi = controller.text.trim();
              Navigator.pop(ctx, nimi.isEmpty ? (sivuNumero != null ? 'Sivu $sivuNumero' : 'Kirjanmerkki') : nimi);
            },
          ),
        ],
      ),
    );
  }

  /// Avaa kirjanmerkkien hallintaikkunan (lista, siirtyminen, muokkaus, poisto)
  static Future<void> avaaKirjanmerkitSheet(
    BuildContext context, {
    required String bookPath,
    required int nykyinenSivu,
    double nykyinenScrollRatio = 0.0,
    required Function(BookBookmark) onSiirryKohtaan,
    required Future<void> Function() onLisaaUusi,
  }) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _KirjanmerkitModalSheet(
        bookPath: bookPath,
        nykyinenSivu: nykyinenSivu,
        nykyinenScrollRatio: nykyinenScrollRatio,
        onSiirryKohtaan: onSiirryKohtaan,
        onLisaaUusi: onLisaaUusi,
      ),
    );
  }
}

class _KirjanmerkitModalSheet extends StatefulWidget {
  final String bookPath;
  final int nykyinenSivu;
  final double nykyinenScrollRatio;
  final Function(BookBookmark) onSiirryKohtaan;
  final Future<void> Function() onLisaaUusi;

  const _KirjanmerkitModalSheet({
    required this.bookPath,
    required this.nykyinenSivu,
    required this.nykyinenScrollRatio,
    required this.onSiirryKohtaan,
    required this.onLisaaUusi,
  });

  @override
  State<_KirjanmerkitModalSheet> createState() => _KirjanmerkitModalSheetState();
}

class _KirjanmerkitModalSheetState extends State<_KirjanmerkitModalSheet> {
  List<BookBookmark> _merkit = [];
  bool _ladataan = true;

  @override
  void initState() {
    super.initState();
    _lataa();
  }

  Future<void> _lataa() async {
    final data = await BookmarkService.haeKirjanmerkit(widget.bookPath);
    if (mounted) {
      setState(() {
        _merkit = data;
        _ladataan = false;
      });
    }
  }

  String _muotoileAika(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final pvm = '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
    final klo = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$pvm klo $klo';
  }

  Future<void> _muokkaaNimea(BookBookmark merkki) async {
    final uusi = await BookmarkService.kysyKirjanmerkinNimi(
      context,
      oletusNimi: merkki.title,
      valittuTeksti: merkki.selectedText.isNotEmpty ? merkki.selectedText : null,
      sivuNumero: merkki.pageNumber,
    );
    if (uusi != null && uusi.trim().isNotEmpty) {
      await BookmarkService.paivitaNimi(widget.bookPath, merkki.id, uusi);
      _lataa();
    }
  }

  Future<void> _poista(BookBookmark merkki) async {
    final vahvista = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Poistetaanko kirjanmerkki?'),
        content: Text('Haluatko poistaa kirjanmerkin "${merkki.title}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Peruuta')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Poista'),
          ),
        ],
      ),
    );

    if (vahvista == true) {
      await BookmarkService.poistaKirjanmerkki(widget.bookPath, merkki.id);
      _lataa();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Kahva
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

          // Otsikko & Lisää-painike
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.collections_bookmark, color: Colors.amber, size: 24),
                    const SizedBox(width: 8),
                    Text(
                      'Kirjanmerkit (${_merkit.length})',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Lisää tähän'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber.shade700,
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () async {
                    Navigator.pop(context);
                    await widget.onLisaaUusi();
                  },
                ),
              ],
            ),
          ),
          const Divider(),

          // Lista kirjanmerkeistä
          Expanded(
            child: _ladataan
                ? const Center(child: CircularProgressIndicator())
                : _merkit.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.bookmark_border, size: 60, color: Colors.grey[400]),
                              const SizedBox(height: 12),
                              const Text(
                                'Ei vielä kirjanmerkkejä tässä kirjassa.',
                                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Voit lisätä kirjanmerkin painamalla yläpuolen nappia tai maalaamalla minkä tahansa tekstikohdan.',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _merkit.length,
                        separatorBuilder: (context, index) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final m = _merkit[index];
                          final isCurrentPage = m.pageNumber == widget.nykyinenSivu;

                          return ListTile(
                            leading: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(
                                color: isCurrentPage ? Colors.amber.shade100 : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isCurrentPage ? Colors.amber.shade400 : Colors.grey.shade300,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.bookmark,
                                    size: 16,
                                    color: isCurrentPage ? Colors.amber.shade800 : Colors.blueGrey,
                                  ),
                                  Text(
                                    'S. ${m.pageNumber}',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      color: isCurrentPage ? Colors.amber.shade900 : Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            title: Text(
                              m.title,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: isCurrentPage ? Colors.amber.shade900 : Colors.black87,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (m.selectedText.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    '"${m.selectedText}"',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, color: Colors.grey[700]),
                                  ),
                                ],
                                const SizedBox(height: 2),
                                Text(
                                  _muotoileAika(m.createdAt),
                                  style: TextStyle(fontSize: 10.5, color: Colors.grey[500]),
                                ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  tooltip: 'Muokkaa nimeä',
                                  onPressed: () => _muokkaaNimea(m),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                  tooltip: 'Poista kirjanmerkki',
                                  onPressed: () => _poista(m),
                                ),
                              ],
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              widget.onSiirryKohtaan(m);
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
