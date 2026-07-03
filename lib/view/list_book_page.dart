import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

// Tuodaan aiemmin luodut palveluluokat ja lukunäkymät
import '../data/indexed_book_scanner.dart';
import 'pdf_page.dart';
import 'epub_page.dart';

class SkippedBook {
  final String title;
  final String reason;
  SkippedBook(this.title, this.reason);
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

  @override
  void initState() {
    super.initState();
    _kaynnistaAutomaattinenLataus();
  }

  // Kaksivaiheinen automaattinen lataus
  Future<void> _kaynnistaAutomaattinenLataus() async {
    // VAIHE 1: Haetaan vanha indeksi heti näkyviin (Lataa sekunnin murto-osassa)
    final vanhaIndeksi = await IndexedBookScanner.haeKirjat(widget.directoryPath);

    setState(() {
      _kirjat = vanhaIndeksi;
      _ladataanAluksi = false;
      // Jos indeksi oli täysin tyhjä, se teki jo skannauksen, joten taustaskannausta ei tarvita erikseen
      _skannaaTaustalla = vanhaIndeksi.isNotEmpty;
    });

    // VAIHE 2: Jos indeksi ei ollut tyhjä, tarkistetaan taustalla onko tullut uusia kirjoja
    if (_skannaaTaustalla) {
      print("Aloitetaan automaattinen taustamuutosten tarkistus...");

      bool onkoMuutoksia = await IndexedBookScanner.tarkistaMuutoksetTaustalla(
          widget.directoryPath,
          _kirjat
      );

      if (onkoMuutoksia) {
        print("Muutoksia havaittu kansiossa! Päivitetään indeksi automaattisesti...");
        // Suoritetaan taustaskannaus ja korvataan lista uunituoreilla tiedoilla
        final paivitettyLista = await IndexedBookScanner.odotaUudelleenSkannaus(widget.directoryPath);

        if (mounted) {
          setState(() {
            _kirjat = paivitettyLista;
            _skannaaTaustalla = false;
          });

          // Näytetään pieni ilmoitus käyttäjälle, että uusia kirjoja löytyi
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Kirjahylly päivitetty automaattisesti taustalla!'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        print("Ei muutoksia kansiossa. Indeksi on ajan tasalla.");
        if (mounted) {
          setState(() {
            _skannaaTaustalla = false;
          });
        }
      }
    }
  }

  // Metodi uusien kirjojen valitsemiseen ja kopioimiseen sovelluksen kansioon
  Future<void> _lisaaUusiaKirjoja() async {
    const XTypeGroup typeGroup = XTypeGroup(
      label: 'Kirjat',
      extensions: <String>['pdf', 'epub'],
    );

    final List<XFile> files = await openFiles(acceptedTypeGroups: <XTypeGroup>[typeGroup]);

    if (files.isNotEmpty) {
      int lisatytMaara = 0;
      bool naytaSkipped = false;

      for (var file in files) {
        final String kohdePolku = p.join(widget.directoryPath, file.name);
        final String uusiNimiIlmanPaatetta = p.basenameWithoutExtension(file.name);

        // Tarkistetaan, löytyykö kirja jo nykyisestä listasta (polun tai nimen perusteella)
        final bool onJoListalla = _kirjat.any((kirja) =>
            kirja.path == kohdePolku ||
            kirja.title.toLowerCase() == uusiNimiIlmanPaatetta.toLowerCase());

        if (onJoListalla) {
          setState(() {
            _skippedBooks.add(SkippedBook(uusiNimiIlmanPaatetta, "ei importtia"));
          });
          naytaSkipped = true;
          continue;
        }

        // Kopioidaan tiedosto sovelluksen omaan kansioon
        final File uusiTiedosto = File(kohdePolku);
        if (await uusiTiedosto.exists()) {
          setState(() {
            _skippedBooks.add(SkippedBook(uusiNimiIlmanPaatetta, "ei importtia"));
          });
          naytaSkipped = true;
          continue;
        }

        await File(file.path).copy(kohdePolku);
        lisatytMaara++;
      }

      // Päivitetään näkymä jos jotain lisättiin
      if (lisatytMaara > 0) {
        _kaynnistaAutomaattinenLataus();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$lisatytMaara kirjaa lisätty hyllyyn!')),
          );
        }
      }

      if (naytaSkipped && mounted) {
        _naytaSkippedBooksSivu();
      }
    }
  }

  // Avaa kirjan lukunäkymään
  Future<void> _avaaKirja(IndexedBook kirja) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => kirja.isPdf
            ? PdfLukuruutu(tiedostoPolku: kirja.path, aloitusSivu: kirja.lastReadPage)
            : EpubLukuruutu(tiedostoPolku: kirja.path, aloitusSivu: kirja.lastReadPage),
      ),
    );
    // Kun palataan lukunäkymästä, päivitetään lista (sivunumerot jne)
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

  @override
  Widget build(BuildContext context) {
    final viimeisin = _kirjat.isNotEmpty && _kirjat.first.lastReadTimestamp > 0
        ? _kirjat.first
        : null;
    final muutKirjat = viimeisin != null ? _kirjat.skip(1).toList() : _kirjat;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kirjahylly'),
        backgroundColor: Colors.blueAccent,
        bottom: _skannaaTaustalla
            ? const PreferredSize(
          preferredSize: Size.fromHeight(4),
          child: LinearProgressIndicator(minHeight: 4, valueColor: AlwaysStoppedAnimation<Color>(Colors.orange)),
        )
            : null, // Näyttää ohuen latauspalkin AppBarin alla VAIN taustaskannauksen aikana
        actions: [
          Tooltip(
            message: 'Kirjojen polku: ${widget.directoryPath}',
            child: IconButton(
              icon: const Icon(Icons.folder_open, color: Colors.black),
              onPressed: () {}, // Tooltip näyttää viestin pitkään painettaessa
              style: IconButton.styleFrom(
                backgroundColor: Colors.white10,
                shape: const CircleBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (_skippedBooks.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.history, color: Colors.black),
              onPressed: _naytaSkippedBooksSivu,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white10,
                shape: const CircleBorder(),
              ),
            ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.add, color: Colors.black),
            onPressed: _lisaaUusiaKirjoja,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white10,
              shape: const CircleBorder(),
            ),
          ),
          const SizedBox(width: 8),
          // Refresh-painike jätetään varmuuden vuoksi, jos käyttäjä haluaa pakottaa skannauksen käsin
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black),
            onPressed: () => _kaynnistaAutomaattinenLataus(),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white10,
              shape: const CircleBorder(),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _ladataanAluksi
          ? const Center(child: CircularProgressIndicator())
          : _kirjat.isEmpty
          ? const Center(child: Text('Hakemisto on tyhjä. Lisää PDF- tai EPUB-tiedostoja.'))
          : CustomScrollView(
        slivers: [
          if (viimeisin != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20.0),
                child: Column(
                  children: [
                    const Text(
                      "Jatka lukemista",
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: SizedBox(
                        width: 180,
                        height: 250,
                        child: InkWell(
                          onTap: () => _avaaKirja(viimeisin),
                          child: _buildBookCard(viimeisin),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Divider(indent: 40, endIndent: 40),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.7,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              delegate: SliverChildBuilderDelegate(
                    (context, index) {
                  final kirja = muutKirjat[index];
                  return InkWell(
                    onTap: () => _avaaKirja(kirja),
                    child: _buildBookCard(kirja),
                  );
                },
                childCount: muutKirjat.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookCard(IndexedBook kirja) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: kirja.thumbnailPath.isNotEmpty && File(kirja.thumbnailPath).existsSync()
                ? ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              child: Image.file(File(kirja.thumbnailPath), fit: BoxFit.cover),
            )
                : Container(
              color: Colors.grey[300],
              child: Icon(
                kirja.isPdf ? Icons.picture_as_pdf : Icons.book,
                size: 50,
                color: kirja.isPdf ? Colors.red : Colors.green,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              kirja.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          )
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Kopioitu leikepöydälle')),
    );
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
            tooltip: 'Kopioi kaikki',
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
