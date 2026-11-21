// ignore_for_file: avoid_print
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  if (args.isEmpty) {
    print('Käyttö: dart run tool/resize_icons.dart <lahdekuva>');
    exit(1);
  }

  final inputPath = args[0];
  final bytes = File(inputPath).readAsBytesSync();
  final image = img.decodeImage(bytes);
  if (image == null) {
    print('Kuvan lukeminen epäonnistui: $inputPath');
    exit(1);
  }

  final targets = {
    'android/app/src/main/res/mipmap-mdpi/ic_launcher.png': 48,
    'android/app/src/main/res/mipmap-hdpi/ic_launcher.png': 72,
    'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': 96,
    'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': 144,
    'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': 192,
  };

  for (final entry in targets.entries) {
    final resized = img.copyResize(
      image,
      width: entry.value,
      height: entry.value,
      interpolation: img.Interpolation.cubic,
    );
    final targetFile = File(entry.key);
    targetFile.parent.createSync(recursive: true);
    targetFile.writeAsBytesSync(img.encodePng(resized));
    print('Luotu: ${entry.key} (${entry.value}x${entry.value})');
  }

  print('Kaikki Android-ikonit generoitu onnistuneesti!');
}
