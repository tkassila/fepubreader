import 'package:flutter/material.dart';
// import 'package:native_pdf_view/native_pdf_view.dart';
import 'package:pdfx/pdfx.dart';
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
  late PdfController _pdfOhjain;
  PdfController? _pdfOhjain2;
  int _nykyinenSivu = 1;
  bool _kaksiNayttoa = false;

  @override
  void initState() {
    super.initState();
    _nykyinenSivu = widget.aloitusSivu;

    // Alustetaan ohjain hyllystä saadulla viimeisimmällä sivulla
    _pdfOhjain = PdfController(
      document: PdfDocument.openFile(widget.tiedostoPolku),
      initialPage: widget.aloitusSivu,
    );
  }

  @override
  void dispose() {
    _pdfOhjain.dispose();
    _pdfOhjain2?.dispose();
    super.dispose();
  }

  void _vaihdaKaksiNayttoa(bool? arvo) {
    setState(() {
      _kaksiNayttoa = arvo ?? false;
      if (_kaksiNayttoa && _pdfOhjain2 == null) {
        _pdfOhjain2 = PdfController(
          document: PdfDocument.openFile(widget.tiedostoPolku),
          initialPage: _nykyinenSivu,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Sivu $_nykyinenSivu'),
        backgroundColor: Colors.redAccent,
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
      body: _kaksiNayttoa
          ? Row(
              children: [
                Expanded(
                  child: _buildPdfView(_pdfOhjain, true),
                ),
                const VerticalDivider(width: 1, color: Colors.black26),
                Expanded(
                  child: _pdfOhjain2 != null
                      ? _buildPdfView(_pdfOhjain2!, false)
                      : const Center(child: CircularProgressIndicator()),
                ),
              ],
            )
          : _buildPdfView(_pdfOhjain, true),
    );
  }

  Widget _buildPdfView(PdfController controller, bool paivitaIndeksi) {
    return PdfView(
      controller: controller,
      onPageChanged: (sivu) async {
        if (paivitaIndeksi) {
          setState(() {
            _nykyinenSivu = sivu;
          });
          await IndexedBookScanner.paivitaLukutilanne(widget.tiedostoPolku, sivu);
        }
      },
    );
  }
}
