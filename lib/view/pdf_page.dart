import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import '../data/indexed_book_scanner.dart'; // Tuodaan skanneri, jossa paivitaLukutilanne sijaitsee

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

class _PdfLukuruutuState extends State<PdfLukuruutu> {
  int _nykyinenSivu = 1;
  int _nykyinenSivu2 = 1;
  int _yhteensaSivuja = 1;
  bool _kaksiNayttoa = false;
  PDFViewController? _pdfController1;
  PDFViewController? _pdfController2;

  @override
  void initState() {
    super.initState();
    _nykyinenSivu = widget.aloitusSivu;
    _nykyinenSivu2 = widget.aloitusSivu;
  }

  void _vaihdaKaksiNayttoa(bool? arvo) {
    setState(() {
      _kaksiNayttoa = arvo ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Sivu $_nykyinenSivu'),
        backgroundColor: Colors.redAccent,
        elevation: 0, // Poistetaan varjo yläreunasta
        actions: [
          Row(
            children: [
              const Text("2 näkymää", style: TextStyle(fontSize: 12)),
              Checkbox(
                value: _kaksiNayttoa,
                onChanged: _vaihdaKaksiNayttoa,
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _kaksiNayttoa
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
    );
  }

  Widget _buildPdfView(int viewIndex) {
    int nykyinen = viewIndex == 1 ? _nykyinenSivu : _nykyinenSivu2;
    PDFViewController? controller = viewIndex == 1 ? _pdfController1 : _pdfController2;

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
              int sivu = value.round();
              controller?.setPage(sivu - 1);
            },
          ),
        Expanded(
          child: PDFView(
            filePath: widget.tiedostoPolku,
            enableSwipe: true,
            swipeHorizontal: true,
            autoSpacing: false,
            pageFling: true,
            pageSnap: true,
            fitEachPage: true,
            fitPolicy: FitPolicy.WIDTH,
            defaultPage: widget.aloitusSivu - 1, // 0-based
            useBestQuality: true,
            onRender: (pages) {
              if (pages != null) {
                setState(() {
                  _yhteensaSivuja = pages;
                });
              }
            },
            onError: (error) {
              print(error.toString());
            },
            onPageError: (page, error) {
              print('$page: ${error.toString()}');
            },
            onViewCreated: (PDFViewController pdfViewController) {
              if (viewIndex == 1) {
                _pdfController1 = pdfViewController;
              } else {
                _pdfController2 = pdfViewController;
              }
            },
            onPageChanged: (int? page, int? total) async {
              if (page != null) {
                int uusiSivu = page + 1;
                setState(() {
                  if (viewIndex == 1) {
                    _nykyinenSivu = uusiSivu;
                  } else {
                    _nykyinenSivu2 = uusiSivu;
                  }
                });
                if (viewIndex == 1) {
                  await IndexedBookScanner.paivitaLukutilanne(widget.tiedostoPolku, uusiSivu);
                }
              }
            },
          ),
        ),
      ],
    );
  }
}
