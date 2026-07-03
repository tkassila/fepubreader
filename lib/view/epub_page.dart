import 'dart:io';
import 'package:flutter/material.dart';
import 'package:epubx/epubx.dart';
import '../data/indexed_book_scanner.dart';

class EpubLukuruutu extends StatefulWidget {
  final String tiedostoPolku;
  final int aloitusSivu; // Hyllystä haettu viimeisin kappale/sivuindeksi

  const EpubLukuruutu({
    super.key,
    required this.tiedostoPolku,
    required this.aloitusSivu,
  });

  @override
  State<EpubLukuruutu> createState() => _EpubLukuruutuState();
}

class _EpubLukuruutuState extends State<EpubLukuruutu> {
  late PageController _sivuOhjain;
  PageController? _sivuOhjain2;
  EpubBook? _kirja;
  List<EpubChapter> _kappaleet = [];
  bool _ladataan = true;
  int _nykyinenSivu = 1;
  bool _kaksiNayttoa = false;

  @override
  void initState() {
    super.initState();
    _nykyinenSivu = widget.aloitusSivu;

    // Alustetaan sivuohjain oikealle kohdalle (muunnetaan 1-pohjainen sivu 0-pohjaiseksi indeksiksi)
    _sivuOhjain = PageController(initialPage: widget.aloitusSivu - 1);
    _lataaEpubSisalto();
  }

  Future<void> _lataaEpubSisalto() async {
    try {
      final tiedosto = File(widget.tiedostoPolku);
      final tavut = await tiedosto.readAsBytes();
      final epubKirja = await EpubReader.readBook(tavut);

      setState(() {
        _kirja = epubKirja;
        _kappaleet = epubKirja.Chapters ?? [];
        _ladataan = false;
      });

      // Lisätään kuuntelija ohjaimeen vasta kun data on ladattu
      _sivuOhjain.addListener(_onSivuVaihtui);
    } catch (e) {
      print("Virhe EPUB-latauksessa: $e");
    }
  }

  // REAALIAIKAINEN TALLENNUS EPUB-PUOLELLA
  void _onSivuVaihtui() {
    if (_sivuOhjain.page != null) {
      // Pyöristetään sivunumero kokonaisluvuksi (PageView palauttaa double-arvon liukumissa)
      int uusiSivu = _sivuOhjain.page!.round() + 1;

      if (uusiSivu != _nykyinenSivu) {
        setState(() {
          _nykyinenSivu = uusiSivu;
        });
        // Tallennetaan muuttunut kappale/sivu lennosta JSON-indeksiin
        IndexedBookScanner.paivitaLukutilanne(widget.tiedostoPolku, uusiSivu);
      }
    }
  }

  @override
  void dispose() {
    _sivuOhjain.removeListener(_onSivuVaihtui);
    _sivuOhjain.dispose();
    _sivuOhjain2?.dispose();
    super.dispose();
  }

  void _vaihdaKaksiNayttoa(bool? arvo) {
    setState(() {
      _kaksiNayttoa = arvo ?? false;
      if (_kaksiNayttoa && _sivuOhjain2 == null) {
        _sivuOhjain2 = PageController(initialPage: _nykyinenSivu - 1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_ladataan) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${_kirja?.Title ?? "EPUB"} - Sivu $_nykyinenSivu'),
        backgroundColor: Colors.greenAccent,
        actions: [
          Row(
            children: [
              const Text("2 näkymää", style: TextStyle(fontSize: 14)),
              Checkbox(
                value: _kaksiNayttoa,
                onChanged: _vaihdaKaksiNayttoa,
              ),
            ],
          ),
        ],
      ),
      // PageView mahdollistaa kirjan sivujen selaamisen pyyhkäisemällä sivusuunnassa
      body: _kaksiNayttoa
          ? Row(
              children: [
                Expanded(child: _buildEpubView(_sivuOhjain)),
                const VerticalDivider(width: 1, color: Colors.black26),
                Expanded(
                  child: _sivuOhjain2 != null
                      ? _buildEpubView(_sivuOhjain2!)
                      : const Center(child: CircularProgressIndicator()),
                ),
              ],
            )
          : _buildEpubView(_sivuOhjain),
    );
  }

  Widget _buildEpubView(PageController controller) {
    return PageView.builder(
      controller: controller,
      itemCount: _kappaleet.length,
      itemBuilder: (context, index) {
        final kappale = _kappaleet[index];
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            kappale.HtmlContent ?? '', // Oikeassa sovelluksessa tämä kannattaa ajaa esim. flutter_html -widgetin läpi
            style: const TextStyle(fontSize: 16, height: 1.5),
          ),
        );
      },
    );
  }
}
