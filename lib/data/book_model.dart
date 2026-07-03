import 'dart:typed_data';

class BookModel {
  final String title;
  final String path;
  final bool isPdf;
  Uint8List? thumbnail;

  BookModel({
    required this.title,
    required this.path,
    required this.isPdf,
    this.thumbnail,
  });
}
