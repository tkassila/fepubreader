import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

// Tuodaan aiemmin luodut palveluluokat ja lukunäkymät
import '../data/indexed_book_scanner.dart';
import '../util/book_import_service.dart';
import '../util/book_tts_service.dart';
import '../util/permission_helper.dart';
import '../util/reading_position_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'pdf_page.dart';
import 'epub_page.dart';
import 'local_file_picker_page.dart';

enum BookSortCriteria {
  lastRead('Lukuajankohta'),
  title('Nimi'),
  author('Kirjailija'),
  importDate('Tuontiaika'),
  publishDate('Julkaisuaika/-vuosi'),
  publisher('Kustantaja'),
  tags('Tagi / Aihe'),
  series('Sarja');

  final String label;
  const BookSortCriteria(this.label);
}

enum BookSearchScope {
  all('Kaikki tiedot'),
  title('Kirjan nimi'),
  author('Kirjailija'),
  publisher('Kustantaja'),
  series('Sarja'),
  tags('Tagit'),
  year('Julkaisuvuosi');

  final String label;
  const BookSearchScope(this.label);
}

class ListBookPage extends StatefulWidget {
  final String directoryPath;

  const ListBookPage({super.key, required this.directoryPath});

  @override
  State<ListBookPage> createState() => _ListBookPageState();
}

class _ListBookPageState extends State<ListBookPage> {
  List<IndexedBook> _kirjat = [];
  List<SkippedBook> _skippedBooks = [];
  bool _ladataanAluksi = true;
  bool _skannaaTaustalla = false;
  StreamSubscription<BookScanEvent>? _scanSubscription;
  BookScanEvent? _activeScanEvent;

  // Haku ja lajittelu
  bool _hakuAuki = false;
  String _hakusana = '';
  final TextEditingController _searchController = TextEditingController();
  BookSortCriteria _selectedSort = BookSortCriteria.lastRead;
  bool _sortAscending = false;

  // Hakukohteen valinta ja incase (kirjainkoosta riippumaton) tekstihaku
  BookSearchScope _searchScope = BookSearchScope.all;
  bool _caseSensitive = false; // oletuksena false = incase (kirjainkoosta riippumaton)

  @override
  void initState() {
    super.initState();
    BookImportService.instance.progressNotifier.addListener(_onImportProgressChanged);
    _scanSubscription = IndexedBookScanner.scanEvents.listen(_onBookScanEvent);
    _kaynnistaAutomaattinenLataus();
  }

  void _onBookScanEvent(BookScanEvent event) {
    if (!mounted) return;
    setState(() {
      if (event.latestScannedBook != null || !event.isScanning || _kirjat.isEmpty) {
        _kirjat = List.from(event.books);
      }
      _ladataanAluksi = false;
      _skannaaTaustalla = event.isScanning;
      _activeScanEvent = event.isScanning ? event : null;
    });
  }

  void _onImportProgressChanged() {
    final progress = BookImportService.instance.progressNotifier.value;
    if (progress != null && !progress.isRunning && mounted) {
      _kaynnistaAutomaattinenLataus();
    }
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    BookImportService.instance.progressNotifier.removeListener(_onImportProgressChanged);
    _searchController.dispose();
    super.dispose();
  }

  // Kaksivaiheinen automaattinen lataus:
  // 1. Näytetään tallennettu kirja_indeksi.json välittömästi ilman koko ruudun jumitusta.
  // 2. Synkronoidaan /Books-hakemisto taustalla ja päivitetään kirjat eventeinä heti hyllyyn.
  Future<void> _kaynnistaAutomaattinenLataus() async {
    final vanhaIndeksi = await IndexedBookScanner.lueIndeksi();

    if (mounted) {
      setState(() {
        _kirjat = vanhaIndeksi;
        _ladataanAluksi = false;
        _skannaaTaustalla = true;
      });
    }

    if (Platform.isAndroid && !await PermissionHelper.onkoTallennustilaOikeus()) {
      await PermissionHelper.pyydaTallennustilaOikeus();
    }

    try {
      final paivitettyLista =
          await IndexedBookScanner.synkronoiKirjahakemisto(widget.directoryPath);

      if (mounted) {
        setState(() {
          _kirjat = paivitettyLista;
          _skannaaTaustalla = false;
          _activeScanEvent = null;
        });
      }
    } catch (e) {
      debugPrint('Virhe kirjahyllyn automaattilatauksessa: $e');
      if (mounted) {
        setState(() {
          _skannaaTaustalla = false;
          _activeScanEvent = null;
        });
      }
    }
  }

  // Valikko uusien kirjojen tuomiseen: valinta paikallisen tallennustilan ja Google Driven välillä
  Future<void> _lisaaUusiaKirjoja() async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.add_circle, color: Colors.blueAccent),
                  const SizedBox(width: 8),
                  const Text(
                    'Tuo kirjoja /Books-kansioon',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Text(
                'Valitse tallennustila ja tuontitapa:',
                style: TextStyle(fontSize: 13, color: Colors.blueGrey),
              ),
              const SizedBox(height: 12),

              // OSA 1: PAIKALLINEN TALLENNUSTILA
              Container(
                decoration: BoxDecoration(
                  color: Colors.blue.shade50.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Row(
                        children: [
                          Icon(Icons.phone_android, size: 18, color: Colors.blue.shade800),
                          const SizedBox(width: 6),
                          Text(
                            'Paikallinen tallennustila (Sisäinen muisti)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blue.shade900),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.blue.shade100,
                        child: Icon(Icons.file_open, color: Colors.blue.shade800, size: 20),
                      ),
                      title: const Text('Valitse tiedostoja (.pdf, .epub, .mobi)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: const Text('Selaa laitteen kansioita ja valitse kirjat Valmis-painikkeella', style: TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(ctx);
                        _tuoPaikallisestaTallennustilasta(isFolder: false);
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.amber.shade100,
                        child: Icon(Icons.folder_copy, color: Colors.amber.shade900, size: 20),
                      ),
                      title: const Text('Valitse kokonainen kansio', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: const Text('Selaa laitteelta kansio ja tuo kaikki sen kirjat Valmis-painikkeella', style: TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(ctx);
                        _tuoPaikallisestaTallennustilasta(isFolder: true);
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // OSA 2: GOOGLE DRIVE JA JÄRJESTELMÄN TALLENNUSTILA
              Container(
                decoration: BoxDecoration(
                  color: Colors.green.shade50.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Row(
                        children: [
                          Icon(Icons.cloud, size: 18, color: Colors.green.shade800),
                          const SizedBox(width: 6),
                          Text(
                            'Google Drive & Järjestelmän selain',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.green.shade900),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.green.shade100,
                        child: Icon(Icons.cloud_upload, color: Colors.green.shade800, size: 20),
                      ),
                      title: const Text('Google Drive / Pilvitiedostot', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: const Text('Valitse tiedostoja Google Drivesta tai järjestelmän selaimesta', style: TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(ctx);
                        _tuoGoogleDrivesta(isFolder: false);
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.teal.shade100,
                        child: Icon(Icons.cloud_sync, color: Colors.teal.shade800, size: 20),
                      ),
                      title: const Text('Google Drive / Pilvikansio', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: const Text('Valitse kansio Google Drivesta tai järjestelmän selaimesta', style: TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(ctx);
                        _tuoGoogleDrivesta(isFolder: true);
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  // 1A. Tuonti paikallisesta tallennustilasta (sisäisen muistin selain + Valmis-painonappi)
  Future<void> _tuoPaikallisestaTallennustilasta({required bool isFolder}) async {
    if (!isFolder) {
      final List<String>? selectedPaths = await Navigator.push<List<String>>(
        context,
        MaterialPageRoute(
          builder: (_) => const LocalFilePickerPage(isFolderPicker: false),
        ),
      );

      if (selectedPaths != null && selectedPaths.isNotEmpty) {
        await _suoritaTiedostojenTuonti(selectedPaths);
      }
    } else {
      final String? selectedFolder = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => const LocalFilePickerPage(isFolderPicker: true),
        ),
      );

      if (selectedFolder != null && selectedFolder.isNotEmpty) {
        await _suoritaKansionTuonti(selectedFolder);
      }
    }
  }

  // 1B. Tuonti Google Drivesta / Järjestelmän selaimesta + Valmis-painonappi
  Future<void> _tuoGoogleDrivesta({required bool isFolder}) async {
    if (!isFolder) {
      final List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'epub', 'mobi', 'prc'],
      );

      if (files.isEmpty || !mounted) return;
      final paths = files.map((f) => f.path).whereType<String>().toList();
      if (paths.isEmpty) return;

      // Näytetään valitut tiedostot ja Valmis-vahvistuspainike
      final bool? vahvistettu = await showDialog<bool>(
        context: context,
        builder: (dlgCtx) => AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.cloud_done, color: Colors.green),
              SizedBox(width: 8),
              Text('Google Drive / Valinta', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Valittu ${paths.length} kirjaa tuotavaksi /Books-kansioon:'),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: paths.map((p) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Text('• ${p.split('/').last}', style: const TextStyle(fontSize: 12)),
                    )).toList(),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dlgCtx, false),
              child: const Text('Peruuta'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
              icon: const Icon(Icons.check_circle, size: 18),
              label: Text('Valmis (${paths.length})'),
              onPressed: () => Navigator.pop(dlgCtx, true),
            ),
          ],
        ),
      );

      if (vahvistettu == true) {
        await _suoritaTiedostojenTuonti(paths);
      }
    } else {
      final String? selectedDir = await FilePicker.getDirectoryPath();
      if (selectedDir == null || selectedDir.isEmpty || !mounted) return;

      // Näytetään valittu kansio ja Valmis-vahvistuspainike
      final bool? vahvistettu = await showDialog<bool>(
        context: context,
        builder: (dlgCtx) => AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.cloud_done, color: Colors.green),
              SizedBox(width: 8),
              Text('Google Drive / Valittu kansio', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Tuodaanko kaikki kirjat valitusta kansiosta /Books-hakemistoon?'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(6)),
                child: Text(selectedDir, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dlgCtx, false),
              child: const Text('Peruuta'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
              icon: const Icon(Icons.check_circle, size: 18),
              label: const Text('Valmis – Tuo kansio'),
              onPressed: () => Navigator.pop(dlgCtx, true),
            ),
          ],
        ),
      );

      if (vahvistettu == true) {
        await _suoritaKansionTuonti(selectedDir);
      }
    }
  }

  Future<void> _suoritaTiedostojenTuonti(List<String> paths) async {
    final importResult = await BookImportService.instance.tuoTiedostot(
      tiedostoPolut: paths,
      kohdeHakemisto: widget.directoryPath,
      nykyisetKirjat: _kirjat,
    );

    if (mounted) {
      setState(() {
        _kirjat = importResult.updatedBooks;
        _skippedBooks = List.from(importResult.skipped);
      });

      if (importResult.importedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${importResult.importedCount} kirjaa lisätty /Books-kansioon!')),
        );
      }

      if (importResult.skipped.isNotEmpty) {
        _naytaSkippedBooksSivu();
      }
    }
  }

  Future<void> _suoritaKansionTuonti(String folderPath) async {
    final importResult = await BookImportService.instance.tuoKansiosta(
      lahdeKansio: folderPath,
      kohdeHakemisto: widget.directoryPath,
      nykyisetKirjat: _kirjat,
    );

    if (mounted) {
      setState(() {
        _kirjat = importResult.updatedBooks;
        _skippedBooks = List.from(importResult.skipped);
      });

      if (importResult.importedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${importResult.importedCount} kirjaa lisätty /Books-kansioon!')),
        );
      }

      if (importResult.skipped.isNotEmpty) {
        _naytaSkippedBooksSivu();
      }
    }
  }

  Future<void> _avaaKirja(IndexedBook kirja) async {
    final pos = await ReadingPositionService.haeLukukohta(
      kirja.path,
      oletusSivu: kirja.lastReadPage,
      oletusScrollRatio: kirja.lastReadScrollRatio,
    );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => kirja.isPdf
            ? PdfLukuruutu(
                tiedostoPolku: kirja.path,
                aloitusSivu: pos.pageNumber,
              )
            : EpubLukuruutu(
                tiedostoPolku: kirja.path,
                aloitusSivu: pos.pageNumber,
                aloitusScrollRatio: pos.scrollOffsetRatio,
              ),
      ),
    );
    _kaynnistaAutomaattinenLataus();
  }

  void _naytaSkippedBooksSivu() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SkippedBooksPage(skippedBooks: _skippedBooks),
      ),
    );
  }

  // Asetukset ja ylläpito -dialogi
  void _avaaAsetukset() {
    BookTtsService.haePuhenopeus();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.settings, color: Colors.blueAccent),
                  const SizedBox(width: 8),
                  const Text(
                    'Asetukset ja ylläpito',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(),
              // Hakemistotiedot
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.folder, size: 18, color: Colors.blueGrey),
                        const SizedBox(width: 6),
                        const Text('Kirjakansio (/Books):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const Spacer(),
                        Text('${_kirjat.length} kirjaa', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent, fontSize: 13)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.directoryPath,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '• Kirjatiedostot (.pdf, .epub): Sisäisen muistin /Books\n• Indeksi & kansikuvat: Ohjelman oma files-hakemisto',
                      style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 2) Puhenopeuden säätöliukujana (vaikuttaa heti seuraavaan TTS-puheeseen)
              BookTtsService.rakennaPuhenopeusSaadin(),
              const SizedBox(height: 12),
              // Toiminto 1: Metatietojen ja kansikuvien haku /Books-kirjoista
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.sync, color: Colors.blue.shade800, size: 20),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Kirjojen metatiedot ja kansikuvat',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Lukee kirjat /Books-hakemistosta, muodostaa kansikuvat ja tallentaa metatiedot ohjelman files-kansioon (lukukohdat säilyvät).',
                      style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade800),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue.shade700,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            ),
                            icon: const Icon(Icons.find_in_page, size: 16),
                            label: const Text(
                              'Hae vain puuttuvat metatiedot',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _ajaMetatiedotUudelleen(pakotaKaikki: false);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.blue.shade900,
                              side: BorderSide(color: Colors.blue.shade400),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            ),
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text(
                              'Lue kaikki uudelleen',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _ajaMetatiedotUudelleen(pakotaKaikki: true);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(),
              // Toiminto 2: Kirjat-hakemiston tyhjennys
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.red.shade800, size: 22),
                        const SizedBox(width: 8),
                        Text(
                          'Tyhjennä /Books-hakemisto',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red.shade900, fontSize: 14),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Poistaa pysyvästi kaikki kirjat (.pdf ja .epub) /Books-kansiosta ja tyhjentää kirjahyllyn. Ennen toimenpidettä kysytään vahvistus.',
                      style: TextStyle(fontSize: 12, color: Colors.red.shade900),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.delete_forever, size: 18),
                        label: const Text('Tyhjennä /Books...'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _vahvistaJaTyhjennaKirjat();
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  // Suorittaa metatietojen ja kansikuvien haun joko vain puuttuville tai kaikille /Books-kirjoille
  Future<void> _ajaMetatiedotUudelleen({required bool pakotaKaikki}) async {
    if (pakotaKaikki) {
      if (!mounted) return;
      final bool? vahvistettu = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dlgCtx) => AlertDialog(
          icon: const Icon(Icons.refresh, color: Colors.blueAccent, size: 42),
          title: const Text(
            'Lue kaikki metatiedot uudelleen?',
            style: TextStyle(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          content: const Text(
            'Tämä lukee kaikkien /Books-kansion kirjojen metatiedot ja kansikuvat '
            'uudelleen tiedostoista.\n\n'
            'Mahdolliset käsin muokatut metatiedot (kuten kirjan nimi, kirjailija tai tagit) '
            'korvautuvat tiedostojen omilla tiedoilla, mutta lukukohdat säilyvät.',
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dlgCtx, false),
              child: const Text('Ei (Peruuta)'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Kyllä, lue kaikki'),
              onPressed: () => Navigator.pop(dlgCtx, true),
            ),
          ],
        ),
      );

      if (vahvistettu != true) return;
    }

    // 1. Varmistetaan tallennustilaoikeus (Kaikkien tiedostojen hallinta Androidissa)
    final bool onOikeus = await PermissionHelper.pyydaTallennustilaOikeus();
    if (!onOikeus && mounted) {
      final bool? avaa = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.folder_special, color: Colors.amber, size: 40),
          title: const Text('Käyttöoikeus tarvitaan', style: TextStyle(fontWeight: FontWeight.bold)),
          content: Text(
            'Laitteen sisäisen muistin hakemiston (${widget.directoryPath}) lukeminen vaatii '
            'kaikkien tiedostojen hallintaoikeuden.\n\n'
            'Salli oikeus avautuvasta asetussivusta, jotta kirjat voidaan ladata hyllyyn.',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Peruuta'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.settings, size: 18),
              label: const Text('Avaa asetukset'),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );

      if (avaa == true) {
        await openAppSettings();
      }
      return;
    }

    if (!mounted) return;

    setState(() {
      _skannaaTaustalla = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          pakotaKaikki
              ? 'Luetaan kaikkien kirjojen metatiedot ja kansikuvat uudelleen hakemistosta ${widget.directoryPath}...'
              : 'Haetaan puuttuvat metatiedot ja kansikuvat hakemistosta ${widget.directoryPath}...',
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final tulos = await IndexedBookScanner.odotaUudelleenSkannaus(
        widget.directoryPath,
        pakotaUudelleenSkannaus: pakotaKaikki,
      );

      if (mounted) {
        setState(() {
          _kirjat = tulos;
          _skannaaTaustalla = false;
        });

        if (tulos.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Metatiedot luettu onnistuneesti (${tulos.length} kirjaa löydetty /Books-kansiosta)!'),
              backgroundColor: Colors.green.shade700,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Ei löytynyt .pdf, .epub tai .mobi -kirjoja hakemistosta: ${widget.directoryPath}'),
              backgroundColor: Colors.orange.shade800,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _skannaaTaustalla = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Virhe metatietojen luvussa: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Varoitus ja Kyllä / Ei -varmistus /Books-hakemiston tyhjennykselle
  Future<void> _vahvistaJaTyhjennaKirjat() async {
    final bool? vahvistus = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 48),
        title: const Text(
          'VAROITUS: Tyhjennetäänkö /Books-hakemisto?',
          style: TextStyle(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Olet tyhjentämässä sisäisen muistin /Books-kansion. Tämä toiminto poistaa:',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text('• Kaikki ${_kirjat.length} kirjaa (.pdf ja .epub)'),
            const Text('• Kaikki ohjelman files-hakemiston hyllytiedot ja kansikuvat'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Text(
                'Hakemisto: ${widget.directoryPath}\n\nTÄTÄ TOIMINTOA EI VOI PERUUTTAA!',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.red.shade900,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Haluatko varmasti jatkaa ja poistaa kaikki kirjat?',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: const BorderSide(color: Colors.grey),
            ),
            child: const Text('Ei, peruuta'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Kyllä, poista kaikki kirjat'),
          ),
        ],
      ),
    );

    if (vahvistus != true || !mounted) return;

    setState(() {
      _skannaaTaustalla = true;
    });

    final poistetut = await IndexedBookScanner.tyhjennaKirjakansio(widget.directoryPath);

    if (mounted) {
      setState(() {
        _kirjat = [];
        _skannaaTaustalla = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('/Books-kansio tyhjennetty ($poistetut tiedostoa poistettu).'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  // Vahvistusdialogi yksittäisen kirjan poistolle (Kyllä / Ei)
  Future<void> _vahvistaJaPoistaKirja(IndexedBook kirja) async {
    final bool? vahvistettu = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        icon: const Icon(Icons.delete_forever, color: Colors.red, size: 40),
        title: const Text('Poistetaanko kirja?', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Haluatko varmasti poistaa kirjan laitteelta?'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    kirja.title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (kirja.author != 'Tuntematon' && kirja.author.isNotEmpty)
                    Text(kirja.author, style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(
                    'Tiedosto: ${kirja.path}',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.grey.shade600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Toiminto poistaa sekä kirjatiedoston että sen kansikuvat ja metatiedot.',
              style: TextStyle(fontSize: 11, color: Colors.red.shade700),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('Ei (Peruuta)'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.delete, size: 16),
            label: const Text('Kyllä, poista'),
            onPressed: () => Navigator.pop(dlgCtx, true),
          ),
        ],
      ),
    );

    if (vahvistettu == true) {
      await IndexedBookScanner.poistaYksittainenKirja(kirja);
      await ReadingPositionService.poistaLukukohta(kirja.path);

      if (mounted) {
        setState(() {
          _kirjat.removeWhere((k) => k.path == kirja.path);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Kirja "${kirja.title}" poistettu laitteelta.'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _liitaLeikepoydaltaKenttaan(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final liitettava = data?.text;
    if (liitettava == null || liitettava.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Leikepöydällä ei ole liitettävää tekstiä.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final sel = controller.selection;
    if (sel.isValid && sel.start >= 0 && sel.end >= 0) {
      final alku = controller.text.substring(0, sel.start);
      final loppu = controller.text.substring(sel.end);
      final uusiTeksti = '$alku$liitettava$loppu';
      controller.value = TextEditingValue(
        text: uusiTeksti,
        selection: TextSelection.collapsed(offset: alku.length + liitettava.length),
      );
    } else {
      controller.value = TextEditingValue(
        text: liitettava,
        selection: TextSelection.collapsed(offset: liitettava.length),
      );
    }
  }

  Widget _rakennaMuokkausKentta({
    required TextEditingController controller,
    required String labelText,
    IconData? prefixIcon,
    TextInputType keyboardType = TextInputType.text,
    bool naytaTyhjenna = true,
  }) {
    return TextField(
      controller: controller,
      enableInteractiveSelection: true,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: labelText,
        prefixIcon: prefixIcon != null ? Icon(prefixIcon) : null,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.content_paste, size: 18),
              tooltip: 'Liitä leikepöydältä',
              visualDensity: VisualDensity.compact,
              onPressed: () => _liitaLeikepoydaltaKenttaan(controller),
            ),
            if (naytaTyhjenna)
              IconButton(
                icon: const Icon(Icons.clear, size: 18),
                tooltip: 'Tyhjennä kenttä',
                visualDensity: VisualDensity.compact,
                onPressed: () => controller.clear(),
              ),
          ],
        ),
      ),
    );
  }

  // Kirjan tietojen muokkausdialogi (esim. kun PDF:stä puuttuu kirjailija, sarja tai tagit)
  Future<void> _naytaMuokkausDialogi(IndexedBook kirja) async {
    final titleCtrl = TextEditingController(text: kirja.title);
    final authorCtrl = TextEditingController(text: kirja.author == 'Tuntematon' ? '' : kirja.author);
    final publisherCtrl = TextEditingController(text: kirja.publisher == 'Tuntematon' ? '' : kirja.publisher);
    final yearCtrl = TextEditingController(text: kirja.publishYear > 0 ? kirja.publishYear.toString() : (kirja.publishDateText == 'Tuntematon' ? '' : kirja.publishDateText));
    final seriesCtrl = TextEditingController(text: kirja.series);
    final seriesNumCtrl = TextEditingController(text: kirja.seriesNumber);
    final tagsCtrl = TextEditingController(text: kirja.tags.join(', '));

    final bool? tallenna = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Muokkaa kirjan tietoja'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (kirja.fileAddedTimestamp > 0 || kirja.fileModifiedTimestamp > 0) ...[
                Builder(builder: (context) {
                  final t = kirja.fileAddedTimestamp > 0 ? kirja.fileAddedTimestamp : kirja.fileModifiedTimestamp;
                  final dt = DateTime.fromMillisecondsSinceEpoch(t);
                  final pvm = '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Text(
                      'Tuotu kirjahyllyyn: $pvm',
                      style: TextStyle(fontSize: 11.5, color: Colors.blueGrey.shade700, fontStyle: FontStyle.italic),
                    ),
                  );
                }),
                const Divider(),
              ],
              _rakennaMuokkausKentta(
                controller: titleCtrl,
                labelText: 'Kirjan nimi',
                prefixIcon: Icons.book,
              ),
              const SizedBox(height: 8),
              _rakennaMuokkausKentta(
                controller: authorCtrl,
                labelText: 'Kirjailija',
                prefixIcon: Icons.person,
              ),
              const SizedBox(height: 8),
              _rakennaMuokkausKentta(
                controller: publisherCtrl,
                labelText: 'Kustantaja',
                prefixIcon: Icons.business,
              ),
              const SizedBox(height: 8),
              _rakennaMuokkausKentta(
                controller: yearCtrl,
                labelText: 'Julkaisuvuosi / -aika',
                prefixIcon: Icons.calendar_today,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _rakennaMuokkausKentta(
                      controller: seriesCtrl,
                      labelText: 'Sarja',
                      prefixIcon: Icons.collections_bookmark,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: _rakennaMuokkausKentta(
                      controller: seriesNumCtrl,
                      labelText: 'Osa #',
                      naytaTyhjenna: false,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _rakennaMuokkausKentta(
                controller: tagsCtrl,
                labelText: 'Tagit (erottele pilkulla)',
                prefixIcon: Icons.label,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Peruuta'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Tallenna'),
          ),
        ],
      ),
    );

    if (tallenna == true) {
      kirja.title = titleCtrl.text.trim().isNotEmpty ? titleCtrl.text.trim() : kirja.title;
      kirja.author = authorCtrl.text.trim().isNotEmpty ? authorCtrl.text.trim() : 'Tuntematon';
      kirja.publisher = publisherCtrl.text.trim().isNotEmpty ? publisherCtrl.text.trim() : 'Tuntematon';
      final yearStr = yearCtrl.text.trim();
      final parsedYear = int.tryParse(yearStr);
      if (parsedYear != null && parsedYear > 0) {
        kirja.publishYear = parsedYear;
        kirja.publishDateText = yearStr;
      } else if (yearStr.isNotEmpty) {
        kirja.publishYear = 0;
        kirja.publishDateText = yearStr;
      } else {
        kirja.publishYear = 0;
        kirja.publishDateText = 'Tuntematon';
      }
      kirja.series = seriesCtrl.text.trim();
      kirja.seriesNumber = seriesNumCtrl.text.trim();
      kirja.tags = tagsCtrl.text
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();

      await IndexedBookScanner.paivitaKirjanTiedot(kirja);
      if (mounted) {
        setState(() {
          final idx = _kirjat.indexWhere((k) => k.path == kirja.path);
          if (idx != -1) {
            _kirjat[idx] = kirja;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kirjan tiedot päivitetty!')),
        );
      }
    }

    Future.delayed(const Duration(milliseconds: 300), () {
      titleCtrl.dispose();
      authorCtrl.dispose();
      publisherCtrl.dispose();
      yearCtrl.dispose();
      seriesCtrl.dispose();
      seriesNumCtrl.dispose();
      tagsCtrl.dispose();
    });
  }

  // Osa-arvon haku keskeltä arvoa ja incase (case-insensitive) tekstihaku
  static bool _tasmaaOsaArvo(String kohdeTeksti, String hakusana, bool caseSensitive) {
    if (hakusana.isEmpty) return true;
    if (kohdeTeksti.isEmpty) return false;

    if (caseSensitive) {
      // Tarkka osamerkkijonotäsmäys keskeltä
      return kohdeTeksti.contains(hakusana);
    } else {
      // Incase (kirjainkoosta riippumaton) täsmäys keskeltä
      final kohdeLower = kohdeTeksti.toLowerCase();
      final hakuLower = hakusana.toLowerCase();

      // 1. Suora case-insensitive osamerkkijono
      if (kohdeLower.contains(hakuLower)) return true;

      // 2. Ääkkös- ja aksenttineutraali vertailu (esim. "linna" tai "vaino" löytää "Väinö Linna")
      String normalisoi(String s) => s
          .replaceAll('ä', 'a')
          .replaceAll('å', 'a')
          .replaceAll('ö', 'o')
          .replaceAll('é', 'e')
          .replaceAll('è', 'e')
          .replaceAll('ü', 'u');

      return normalisoi(kohdeLower).contains(normalisoi(hakuLower));
    }
  }

  // Tarkistaa täsmääkö kirja hakusanoihin ja valittuun kenttään
  bool _kirjaTasmaa(IndexedBook k, List<String> hakusanat) {
    if (hakusanat.isEmpty) return true;

    // Haetaan kentät valitun BookSearchScope-kohteen mukaan
    List<String> kentat;
    switch (_searchScope) {
      case BookSearchScope.title:
        kentat = [k.title];
        break;
      case BookSearchScope.author:
        kentat = [k.author];
        break;
      case BookSearchScope.publisher:
        kentat = [k.publisher];
        break;
      case BookSearchScope.series:
        kentat = [k.series, k.seriesNumber];
        break;
      case BookSearchScope.tags:
        kentat = k.tags;
        break;
      case BookSearchScope.year:
        kentat = [
          if (k.publishYear > 0) k.publishYear.toString(),
          if (k.publishDateText.isNotEmpty && k.publishDateText != 'Tuntematon') k.publishDateText,
        ];
        break;
      case BookSearchScope.all:
        kentat = [
          k.title,
          k.author,
          k.publisher,
          k.series,
          k.seriesNumber,
          if (k.publishYear > 0) k.publishYear.toString(),
          if (k.publishDateText.isNotEmpty && k.publishDateText != 'Tuntematon') k.publishDateText,
          ...k.tags,
        ];
        break;
    }

    // Jokaisen syötetyn hakutermin täytyy löytyä osa-arvona (keskeltä) jostain tarkasteltavasta kentästä
    return hakusanat.every((termi) {
      return kentat.any((kentta) => _tasmaaOsaArvo(kentta, termi, _caseSensitive));
    });
  }

  // Haun ja lajittelun logiikka
  List<IndexedBook> _haeSuodatetutJaLajitellutKirjat() {
    final hakusanat = _hakusana
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    // 1. Suodatus: haku valitun kohteen tai kaikkien arvojen osa-arvon mukaan
    List<IndexedBook> lista = _kirjat.where((k) => _kirjaTasmaa(k, hakusanat)).toList();

    // 2. Lajittelu kriteerin mukaan
    lista.sort((a, b) {
      int cmp = 0;
      switch (_selectedSort) {
        case BookSortCriteria.lastRead:
          cmp = a.lastReadTimestamp.compareTo(b.lastReadTimestamp);
          break;
        case BookSortCriteria.title:
          cmp = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          break;
        case BookSortCriteria.author:
          final aAuth = (a.author.isEmpty || a.author == 'Tuntematon') ? 'zzz' : a.author.toLowerCase();
          final bAuth = (b.author.isEmpty || b.author == 'Tuntematon') ? 'zzz' : b.author.toLowerCase();
          cmp = aAuth.compareTo(bAuth);
          break;
        case BookSortCriteria.importDate:
          final aAika = a.fileAddedTimestamp > 0 ? a.fileAddedTimestamp : a.fileModifiedTimestamp;
          final bAika = b.fileAddedTimestamp > 0 ? b.fileAddedTimestamp : b.fileModifiedTimestamp;
          cmp = aAika.compareTo(bAika);
          break;
        case BookSortCriteria.publishDate:
          if (a.publishYear > 0 && b.publishYear > 0) {
            cmp = a.publishYear.compareTo(b.publishYear);
          } else if (a.publishYear > 0) {
            cmp = 1;
          } else if (b.publishYear > 0) {
            cmp = -1;
          } else {
            cmp = a.publishDateText.compareTo(b.publishDateText);
          }
          break;
        case BookSortCriteria.publisher:
          final aPub = a.publisher == 'Tuntematon' ? 'zzz' : a.publisher.toLowerCase();
          final bPub = b.publisher == 'Tuntematon' ? 'zzz' : b.publisher.toLowerCase();
          cmp = aPub.compareTo(bPub);
          break;
        case BookSortCriteria.tags:
          final aTag = a.tags.isNotEmpty ? a.tags.first.toLowerCase() : 'zzz';
          final bTag = b.tags.isNotEmpty ? b.tags.first.toLowerCase() : 'zzz';
          cmp = aTag.compareTo(bTag);
          break;
        case BookSortCriteria.series:
          final aSer = a.series.isEmpty ? 'zzz' : a.series.toLowerCase();
          final bSer = b.series.isEmpty ? 'zzz' : b.series.toLowerCase();
          cmp = aSer.compareTo(bSer);
          if (cmp == 0) {
            cmp = a.seriesNumber.compareTo(b.seriesNumber);
          }
          break;
      }

      // Toissijainen lajittelu aina nimen mukaan
      if (cmp == 0) {
        cmp = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      }

      return _sortAscending ? cmp : -cmp;
    });

    return lista;
  }

  String _haeSuuntaTeksti() {
    switch (_selectedSort) {
      case BookSortCriteria.lastRead:
      case BookSortCriteria.importDate:
      case BookSortCriteria.publishDate:
        return _sortAscending ? 'Vanhin ensin' : 'Uusin ensin';
      case BookSortCriteria.title:
      case BookSortCriteria.author:
      case BookSortCriteria.publisher:
      case BookSortCriteria.tags:
      case BookSortCriteria.series:
        return _sortAscending ? 'A → Z' : 'Z → A';
    }
  }

  Widget _rakennaEdistymisBanneriKortti({
    required Color taustaVari,
    required Color reunaVari,
    required IconData ikoni,
    required Color ikoniVari,
    required String otsikko,
    required Color otsikkoVari,
    required String alaotsikko,
    required bool naytaPalkki,
    required double? edistymisArvo,
    required Color palkkiTaustaVari,
    required Color palkkiVari,
    Widget? oikeaToiminto,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: taustaVari,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: reunaVari),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(ikoni, size: 20, color: ikoniVari),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  otsikko,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                    color: otsikkoVari,
                  ),
                ),
              ),
              ?oikeaToiminto,
            ],
          ),
          if (alaotsikko.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              alaotsikko,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Colors.grey[700], fontStyle: FontStyle.italic),
            ),
          ],
          if (naytaPalkki) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: edistymisArvo,
                minHeight: 5,
                backgroundColor: palkkiTaustaVari,
                valueColor: AlwaysStoppedAnimation<Color>(palkkiVari),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImportProgressBanner() {
    return ValueListenableBuilder<BookImportProgress?>(
      valueListenable: BookImportService.instance.progressNotifier,
      builder: (context, progress, _) {
        if (progress != null) {
          final isRunning = progress.isRunning;
          return _rakennaEdistymisBanneriKortti(
            taustaVari: isRunning
                ? Colors.blue.shade50
                : (progress.importedCount > 0 ? Colors.green.shade50 : Colors.grey.shade100),
            reunaVari: isRunning
                ? Colors.blue.shade300
                : (progress.importedCount > 0 ? Colors.green.shade300 : Colors.grey.shade300),
            ikoni: isRunning
                ? Icons.sync
                : (progress.importedCount > 0 ? Icons.check_circle : Icons.info_outline),
            ikoniVari: isRunning
                ? Colors.blue.shade700
                : (progress.importedCount > 0 ? Colors.green.shade700 : Colors.grey.shade700),
            otsikko: progress.statusText,
            otsikkoVari: isRunning
                ? Colors.blue.shade900
                : (progress.importedCount > 0 ? Colors.green.shade900 : Colors.grey.shade800),
            alaotsikko: progress.currentItemName,
            naytaPalkki: isRunning,
            edistymisArvo: progress.total > 0 ? progress.progressRatio : null,
            palkkiTaustaVari: Colors.blue.shade100,
            palkkiVari: Colors.blue.shade600,
            oikeaToiminto: isRunning
                ? TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => BookImportService.instance.peruuta(),
                    child: const Text('Peruuta', style: TextStyle(color: Colors.red, fontSize: 12)),
                  )
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => BookImportService.instance.nollaaTila(),
                  ),
          );
        }

        final scan = _activeScanEvent;
        if (scan == null || !scan.isScanning) {
          return const SizedBox.shrink();
        }

        return _rakennaEdistymisBanneriKortti(
          taustaVari: Colors.amber.shade50,
          reunaVari: Colors.amber.shade300,
          ikoni: Icons.sync,
          ikoniVari: Colors.orange.shade800,
          otsikko: scan.statusText,
          otsikkoVari: Colors.orange.shade900,
          alaotsikko: scan.currentBookName,
          naytaPalkki: true,
          edistymisArvo: scan.total > 0 ? scan.progressRatio : null,
          palkkiTaustaVari: Colors.amber.shade100,
          palkkiVari: Colors.orange.shade700,
          oikeaToiminto: scan.total > 0
              ? Text(
                  '${scan.progressPercent}%',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: Colors.orange.shade900,
                  ),
                )
              : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final suodatetutKirjat = _haeSuodatetutJaLajitellutKirjat();

    final onkoOletusLajittelu = _selectedSort == BookSortCriteria.lastRead && !_sortAscending;
    final viimeisin = (onkoOletusLajittelu && _hakusana.isEmpty && suodatetutKirjat.isNotEmpty && suodatetutKirjat.first.lastReadTimestamp > 0)
        ? suodatetutKirjat.first
        : null;
    final muutKirjat = viimeisin != null ? suodatetutKirjat.skip(1).toList() : suodatetutKirjat;

    return Scaffold(
      appBar: AppBar(
        title: _hakuAuki
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Hae ${_searchScope.label.toLowerCase()} (osa-arvo)...',
                  hintStyle: const TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                ),
                onChanged: (val) {
                  setState(() {
                    _hakusana = val;
                  });
                },
              )
            : const Text('Kirjahylly'),
        leading: _hakuAuki
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () {
                  setState(() {
                    _hakuAuki = false;
                    _searchController.clear();
                    _hakusana = '';
                  });
                },
              )
            : null,
        backgroundColor: Colors.blueAccent,
        bottom: _skannaaTaustalla
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                ),
              )
            : null,
        actions: [
          if (_hakuAuki) ...[
            // Incase / Case-sensitive -tekstihakukytkin
            IconButton(
              icon: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: _caseSensitive ? Colors.amberAccent : Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Aa',
                  style: TextStyle(
                    color: _caseSensitive ? Colors.black87 : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              tooltip: _caseSensitive
                  ? 'Kirjainkoolla on väliä (Case-sensitive)'
                  : 'Incase: Kirjainkoosta riippumaton tekstihaku',
              onPressed: () {
                setState(() {
                  _caseSensitive = !_caseSensitive;
                });
              },
            ),
            if (_hakusana.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.clear, color: Colors.white),
                tooltip: 'Tyhjennä hakukenttä',
                onPressed: () {
                  setState(() {
                    _searchController.clear();
                    _hakusana = '';
                  });
                },
              ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.search, color: Colors.black),
              tooltip: 'Hae kirjoja',
              onPressed: () {
                setState(() {
                  _hakuAuki = true;
                });
              },
              style: IconButton.styleFrom(
                backgroundColor: Colors.white10,
                shape: const CircleBorder(),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Kirjojen polku: ${widget.directoryPath}',
              child: IconButton(
                icon: const Icon(Icons.folder_open, color: Colors.black),
                onPressed: () {},
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white10,
                  shape: const CircleBorder(),
                ),
              ),
            ),
            const SizedBox(width: 4),
            if (_skippedBooks.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.history, color: Colors.black),
                tooltip: 'Ohitetut tiedostot',
                onPressed: _naytaSkippedBooksSivu,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white10,
                  shape: const CircleBorder(),
                ),
              ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.add, color: Colors.black),
              tooltip: 'Tuo kirjoja (.pdf / .epub)',
              onPressed: _lisaaUusiaKirjoja,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white10,
                shape: const CircleBorder(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.black),
              tooltip: 'Päivitä kirjahylly',
              onPressed: () => _kaynnistaAutomaattinenLataus(),
              style: IconButton.styleFrom(
                backgroundColor: Colors.white10,
                shape: const CircleBorder(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.black),
              tooltip: 'Asetukset ja ylläpito',
              onPressed: _avaaAsetukset,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white10,
                shape: const CircleBorder(),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
      body: _ladataanAluksi
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildImportProgressBanner(),
                // Hakukohteen valintapalkki (kun haku on auki)
                if (_hakuAuki)
                  Container(
                    color: Colors.blue.shade50,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          const Text(
                            'Kohde: ',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey),
                          ),
                          ...BookSearchScope.values.map((scope) {
                            final isSelected = _searchScope == scope;
                            return Padding(
                              padding: const EdgeInsets.only(right: 6.0),
                              child: ChoiceChip(
                                label: Text(scope.label, style: const TextStyle(fontSize: 11)),
                                selected: isSelected,
                                selectedColor: Colors.blueAccent,
                                labelStyle: TextStyle(
                                  color: isSelected ? Colors.white : Colors.black87,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                ),
                                onSelected: (selected) {
                                  if (selected) {
                                    setState(() {
                                      _searchScope = scope;
                                    });
                                  }
                                },
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),

                // Lajittelupalkki (Scrollattavat valintasirut ja suuntapainike)
                Container(
                  color: Colors.grey.shade100,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        // Suuntapainike (Nouseva / Laskeva)
                        ActionChip(
                          avatar: Icon(
                            _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                            size: 16,
                            color: Colors.blueAccent,
                          ),
                          label: Text(
                            _haeSuuntaTeksti(),
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          backgroundColor: Colors.white,
                          onPressed: () {
                            setState(() {
                              _sortAscending = !_sortAscending;
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        // Lajittelukriteerit
                        ...BookSortCriteria.values.map((criteria) {
                          final isSelected = _selectedSort == criteria;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6.0),
                            child: FilterChip(
                              selected: isSelected,
                              label: Text(criteria.label, style: const TextStyle(fontSize: 12)),
                              selectedColor: Colors.blue.shade100,
                              checkmarkColor: Colors.blueAccent,
                              onSelected: (selected) {
                                if (selected) {
                                  setState(() {
                                    _selectedSort = criteria;
                                    switch (criteria) {
                                      case BookSortCriteria.title:
                                      case BookSortCriteria.author:
                                      case BookSortCriteria.publisher:
                                      case BookSortCriteria.tags:
                                      case BookSortCriteria.series:
                                        _sortAscending = true; // A-Z
                                        break;
                                      case BookSortCriteria.lastRead:
                                      case BookSortCriteria.importDate:
                                      case BookSortCriteria.publishDate:
                                        _sortAscending = false; // Uusin ensin
                                        break;
                                    }
                                  });
                                }
                              },
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),

                // Hakusanasta ilmoittava infopalkki
                if (_hakusana.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Colors.blue.shade50,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Hakutulos: ${suodatetutKirjat.length} kpl (haku: "$_hakusana" • ${_searchScope.label} • ${_caseSensitive ? "tarkka kirjainkoko" : "incase"})',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _searchController.clear();
                              _hakusana = '';
                            });
                          },
                          child: const Text(
                            'Tyhjennä',
                            style: TextStyle(fontSize: 13, color: Colors.blue, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Kirjalistaus
                Expanded(
                  child: suodatetutKirjat.isEmpty
                      ? Center(
                          child: Text(
                            _hakusana.isEmpty
                                ? 'Hakemisto on tyhjä.'
                                : 'Hakusanalla "$_hakusana" ei löytynyt kirjoja (${_searchScope.label}).',
                            style: const TextStyle(fontSize: 15, color: Colors.grey),
                          ),
                        )
                      : CustomScrollView(
                          slivers: [
                            if (viimeisin != null)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.auto_stories, size: 18, color: Colors.blue.shade700),
                                          const SizedBox(width: 6),
                                          const Text(
                                            "Jatka lukemista",
                                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 600),
                                        child: SizedBox(
                                          height: 116,
                                          child: InkWell(
                                            onTap: () => _avaaKirja(viimeisin),
                                            onLongPress: () => _naytaMuokkausDialogi(viimeisin),
                                            child: _buildBookCard(viimeisin, isHighlight: true),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Divider(height: 1),
                                    ],
                                  ),
                                ),
                              ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              sliver: SliverGrid(
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 400,
                                  mainAxisExtent: 116,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final kirja = muutKirjat[index];
                                    return InkWell(
                                      onTap: () => _avaaKirja(kirja),
                                      onLongPress: () => _naytaMuokkausDialogi(kirja),
                                      child: _buildBookCard(kirja),
                                    );
                                  },
                                  childCount: muutKirjat.length,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }

  Widget _rakennaOletusKansiKuvake(IndexedBook kirja) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(
        kirja.isPdf ? Icons.picture_as_pdf : Icons.book,
        size: 26,
        color: kirja.isPdf ? Colors.redAccent : Colors.teal,
      ),
    );
  }

  Widget _buildBookCard(IndexedBook kirja, {bool isHighlight = false}) {
    final int tuontiAika = kirja.fileAddedTimestamp > 0 ? kirja.fileAddedTimestamp : kirja.fileModifiedTimestamp;
    String tuontiPvmStr = '';
    if (tuontiAika > 0) {
      final dt = DateTime.fromMillisecondsSinceEpoch(tuontiAika);
      tuontiPvmStr = '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
    }

    final String? thumbPolku = kirja.getCachedThumbnailPath();

    return Card(
      elevation: isHighlight ? 2.5 : 1.0,
      margin: EdgeInsets.zero,
      color: isHighlight ? Colors.blue.shade50.withValues(alpha: 0.4) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isHighlight ? Colors.blue.shade300 : Colors.grey.shade200,
          width: isHighlight ? 1.5 : 1.0,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Kannen esikatselu (kevyt cacheWidth-dekoodaus ilman FutureBuilder- tai levykutsuja)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: SizedBox(
              width: 66,
              height: 94,
              child: (thumbPolku != null && thumbPolku.isNotEmpty)
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(
                        File(thumbPolku),
                        fit: BoxFit.cover,
                        cacheWidth: 180,
                        filterQuality: FilterQuality.medium,
                        key: ValueKey('${thumbPolku}_${kirja.fileModifiedTimestamp}'),
                        errorBuilder: (context, error, stackTrace) =>
                            _rakennaOletusKansiKuvake(kirja),
                      ),
                    )
                  : _rakennaOletusKansiKuvake(kirja),
            ),
          ),

          // Kirjan metatiedot ja poistoikoni
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Nimi, muokkausikoni ja poistoikoni
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          kirja.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, height: 1.2),
                        ),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: Icon(Icons.edit_outlined, size: 19, color: Colors.blue.shade700),
                        tooltip: 'Muokkaa kirjan metatietoja',
                        onPressed: () => _naytaMuokkausDialogi(kirja),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: Icon(Icons.delete_outline, size: 20, color: Colors.red.shade400),
                        tooltip: 'Poista kirja laitteelta',
                        onPressed: () => _vahvistaJaPoistaKirja(kirja),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),

                  // Kirjailija
                  if (kirja.author != 'Tuntematon' && kirja.author.isNotEmpty)
                    Text(
                      kirja.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Colors.blueGrey[800], fontWeight: FontWeight.w500),
                    ),

                  // Kustantaja / Vuosi
                  if (kirja.publisher != 'Tuntematon' || kirja.publishYear > 0)
                    Text(
                      [
                        if (kirja.publisher != 'Tuntematon') kirja.publisher,
                        if (kirja.publishYear > 0) '${kirja.publishYear}'
                        else if (kirja.publishDateText != 'Tuntematon' && kirja.publishDateText.isNotEmpty) kirja.publishDateText,
                      ].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 9, color: Colors.grey[600]),
                    ),

                  // Sarja
                  if (kirja.series.isNotEmpty)
                    Text(
                      'Sarja: ${kirja.series}${kirja.seriesNumber.isNotEmpty ? ' #${kirja.seriesNumber}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9, color: Colors.indigo, fontWeight: FontWeight.w600),
                    ),

                  // Tagit
                  if (kirja.tags.isNotEmpty)
                    Text(
                      kirja.tags.take(3).join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 8.5, color: Colors.teal.shade800, fontStyle: FontStyle.italic),
                    ),

                  // Alarivi: Lukukohta sekä oikealla PDF/EPUB-merkki Tuotu ... -tekstin päällä
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (kirja.lastReadTimestamp > 0)
                        Text(
                          kirja.isPdf
                              ? 'Kohta: sivu ${kirja.lastReadPage}'
                              : 'Kohta: luku ${kirja.lastReadPage}',
                          style: TextStyle(
                            fontSize: 9.0,
                            color: Colors.teal.shade700,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      else if (kirja.tags.isNotEmpty)
                        Expanded(
                          child: Text(
                            kirja.tags.take(2).join(', '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 8.5, color: Colors.teal.shade800, fontStyle: FontStyle.italic),
                          ),
                        )
                      else
                        const SizedBox.shrink(),

                      // 1) Kirjakohtainen PDF tai EPUB -teksti/merkki Tuotu ... -tekstin päällä
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: kirja.isPdf ? Colors.red.shade700 : Colors.teal.shade700,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  kirja.isPdf ? Icons.picture_as_pdf : Icons.menu_book,
                                  size: 10,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  kirja.isPdf ? 'PDF' : 'EPUB',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (tuontiPvmStr.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Tuotu: $tuontiPvmStr',
                              style: TextStyle(fontSize: 8.5, color: Colors.blueGrey.shade400),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SkippedBooksPage extends StatelessWidget {
  final List<SkippedBook> skippedBooks;
  const SkippedBooksPage({super.key, required this.skippedBooks});

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kopioitu leikepöydälle')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ei importatut kirjat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            onPressed: () {
              final allText = skippedBooks.map((b) => "${b.title} (${b.reason})").join("\n");
              _copyToClipboard(context, allText);
            },
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: skippedBooks.length,
        itemBuilder: (context, index) {
          final book = skippedBooks[index];
          return ListTile(
            title: Text(book.title),
            subtitle: Text(book.reason),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () => _copyToClipboard(context, book.title),
            ),
          );
        },
      ),
    );
  }
}
