import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

import './util/permission_helper.dart';
// Tuodaan kaikki aiemmin luodut komponentit projektistasi
import './view/list_book_page.dart';
import './view/pdf_page.dart';
import './view/epub_page.dart';

/// Hakee ja luo sisäisen muistin /Books-hakemiston kirjoille (.pdf ja .epub).
/// Androidissa aina sisäisen muistin standardi /storage/emulated/0/Books.
Future<String> _haeTaiLuoBooksKansio() async {
  if (Platform.isAndroid) {
    const String androidBooksPolku = '/storage/emulated/0/Books';
    final standardiBooks = Directory(androidBooksPolku);
    try {
      if (!await standardiBooks.exists()) {
        await standardiBooks.create(recursive: true);
      }
    } catch (_) {}
    return androidBooksPolku;
  }

  // Muut alustat (Linux, Windows, Desktop)
  final docDir = await getApplicationDocumentsDirectory();
  final fallbackBooks = Directory(p.join(docDir.path, 'Books'));
  if (!await fallbackBooks.exists()) {
    try {
      await fallbackBooks.create(recursive: true);
    } catch (_) {}
  }
  return fallbackBooks.path;
}

/// Siirtää tai kopioi aiemmin vanhoissa 'Kirjat'-kansioissa olleet kirjat uuteen /Books-kansioon
Future<void> _migroiVanhatKirjatJosTarpeen(String uusiBooksPolku) async {
  try {
    final extDir = await getExternalStorageDirectory();
    final docDir = await getApplicationDocumentsDirectory();
    final List<Directory> vanhatKansiot = [
      if (extDir != null) Directory('${extDir.path}/Kirjat'),
      Directory('${docDir.path}/Kirjat'),
    ];

    final uusiDir = Directory(uusiBooksPolku);
    for (final vanha in vanhatKansiot) {
      if (await vanha.exists()) {
        final files = vanha.listSync().whereType<File>();
        for (final file in files) {
          final ext = p.extension(file.path).toLowerCase();
          if (ext == '.pdf' || ext == '.epub') {
            final kohdePolku = p.join(uusiDir.path, p.basename(file.path));
            if (!File(kohdePolku).existsSync()) {
              await file.copy(kohdePolku);
            }
          }
        }
      }
    }
  } catch (_) {}
}

void main() async {
  // Varmistetaan, että Flutter-ympäristö on valmis ennen asynkronisia kutsuja
  WidgetsFlutterBinding.ensureInitialized();

  // Pyydetään laitteen tallennustilaoikeus (Kaikkien tiedostojen hallinta) /Books-kansiota varten
  await PermissionHelper.pyydaTallennustilaOikeus();

  // 1. Haetaan ja luodaan sisäisen muistin /Books-kansio
  final String kirjakansioPolku = await _haeTaiLuoBooksKansio();

  // 2. Migroidaan mahdolliset aiemmat kirjat vanhoista kansioista /Books-kansioon
  await _migroiVanhatKirjatJosTarpeen(kirjakansioPolku);

  // 3. Tarkistetaan muistista, onko jokin kirja jäänyt viimeksi kesken
  final prefs = await SharedPreferences.getInstance();
  String? viimeisinKirjaPolku = prefs.getString('viimeksi_luettu_polku');
  int viimeisinSivu = prefs.getInt('viimeksi_luettu_sivu') ?? 1;
  double viimeisinOffset = prefs.getDouble('viimeksi_luettu_offset') ?? 0.0;
  bool? oliPdf = prefs.getBool('viimeksi_luettu_olipdf');

  // Varmistetaan vielä, että kyseinen tiedosto on edelleen olemassa levyllä
  bool kirjaLoytyy = viimeisinKirjaPolku != null && File(viimeisinKirjaPolku).existsSync();

  runApp(Lukusovellus(
    kirjakansioPolku: kirjakansioPolku,
    automaattiAvausPolku: kirjaLoytyy ? viimeisinKirjaPolku : null,
    automaattiAvausSivu: viimeisinSivu,
    automaattiAvausScrollRatio: viimeisinOffset,
    automaattiAvausOliPdf: oliPdf ?? true,
  ));
}

class Lukusovellus extends StatelessWidget {
  final String kirjakansioPolku;
  final String? automaattiAvausPolku;
  final int automaattiAvausSivu;
  final double automaattiAvausScrollRatio;
  final bool automaattiAvausOliPdf;

  const Lukusovellus({
    super.key,
    required this.kirjakansioPolku,
    this.automaattiAvausPolku,
    required this.automaattiAvausSivu,
    this.automaattiAvausScrollRatio = 0.0,
    required this.automaattiAvausOliPdf,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Älykäs Lukusovellus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true, // Käytetään nykyaikaista Material 3 -käyttöliittymää
      ),
      // Määritetään kotisivu (Home)
      home: AloituksenOhjaaja(
        kirjakansioPolku: kirjakansioPolku,
        automaattiAvausPolku: automaattiAvausPolku,
        automaattiAvausSivu: automaattiAvausSivu,
        automaattiAvausScrollRatio: automaattiAvausScrollRatio,
        automaattiAvausOliPdf: automaattiAvausOliPdf,
      ),
    );
  }
}

// Tämä widget ohjaa käyttäjän joko suoraan kirjaan tai hyllyyn käynnistyksessä
class AloituksenOhjaaja extends StatefulWidget {
  final String kirjakansioPolku;
  final String? automaattiAvausPolku;
  final int automaattiAvausSivu;
  final double automaattiAvausScrollRatio;
  final bool automaattiAvausOliPdf;

  const AloituksenOhjaaja({
    super.key,
    required this.kirjakansioPolku,
    this.automaattiAvausPolku,
    required this.automaattiAvausSivu,
    this.automaattiAvausScrollRatio = 0.0,
    required this.automaattiAvausOliPdf,
  });

  @override
  State<AloituksenOhjaaja> createState() => _AloituksenOhjaajaState();
}

class _AloituksenOhjaajaState extends State<AloituksenOhjaaja> {

  final bool _bDebug = false;

  @override
  void initState() {
    super.initState();
    // Suoritetaan tarkistus heti kun ensimmäinen frame on piirretty ruudulle
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tarkistaAutomaattiAvaus();
    });
  }

  void _tarkistaAutomaattiAvaus() async {
    if (widget.automaattiAvausPolku != null) {
      // 1. Avataan viimeksi kesken jäänyt dokumentti automaattisesti
      if (_bDebug) {
        debugPrint("Automaattiavaus aktivoitu tiedostolle: ${widget.automaattiAvausPolku}");
      }

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => widget.automaattiAvausOliPdf
              ? PdfLukuruutu(
                  tiedostoPolku: widget.automaattiAvausPolku!,
                  aloitusSivu: widget.automaattiAvausSivu,
                )
              : EpubLukuruutu(
                  tiedostoPolku: widget.automaattiAvausPolku!,
                  aloitusSivu: widget.automaattiAvausSivu,
                  aloitusScrollRatio: widget.automaattiAvausScrollRatio,
                ),
        ),
      );
    }

    // 2. Kun kirja suljetaan (tai jos mitään ei ollut kesken), siirrytään suoraan indeksoituun kirjahyllyyn
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ListBookPage(directoryPath: widget.kirjakansioPolku),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Näytetään lyhyt latausruutu siirtymän aikana
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.book, size: 80, color: Colors.blueAccent),
            SizedBox(height: 16),
            CircularProgressIndicator(),
            SizedBox(height: 8),
            Text('Valmistellaan kirjahyllyä...', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/*
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    final mediaQueryData = MediaQuery.of(context);
    double deviceWidth = MediaQuery.of(context).size.width;
    final paddingRight = MediaQuery.of(context).padding.right;
    final paddingLeft = MediaQuery.of(context).padding.left;
    final double availableWidth = deviceWidth - paddingRight - paddingLeft;
    //Inside Build function since we need context.
    // This is device height
    final deviceHeight = MediaQuery.of(context).size.height -100;
    final availableHeight = deviceHeight - AppBar().preferredSize.height -
    MediaQuery.of(context).padding.top
    - MediaQuery.of(context).padding.bottom;


    return ScreenUtilInit(
        designSize: Size(availableHeight * .4, availableWidth * .5),
        minTextAdapt: true,
        enableScaleWH: () => true,
        enableScaleText: () => true,
        splitScreenMode: true,
        builder: (_, __) {
          return MaterialApp(
            title: 'fEpubReader',
            theme: ThemeData(
              // This is the theme of your application.
              //
              // TRY THIS: Try running your application with "flutter run". You'll see
              // the application has a purple toolbar. Then, without quitting the app,
              // try changing the seedColor in the colorScheme below to Colors.green
              // and then invoke "hot reload" (save your changes or press the "hot
              // reload" button in a Flutter-supported IDE, or press "r" if you used
              // the command line to start the app).
              //
              // Notice that the counter didn't reset back to zero; the application
              // state is not lost during the reload. To reset the state, use hot
              // restart instead.
              //
              // This works for code too, not just values: Most code changes can be
              // tested with just a hot reload.
              colorScheme: .fromSeed(seedColor: Colors.deepPurple),
            ),
            home: const MyHomePage(title: 'fEpubReader'),
          );
        }
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  bool _isChecked2Columns = false;
  bool _isDocOpen = false;
  bool _bTurnIntoRigth = true;
  ButtonStyle buttonStyle = ElevatedButton.styleFrom(textStyle:
  TextStyle(fontSize: ScreenUtil().setSp(15),
      fontWeight: FontWeight.bold),
      backgroundColor: Colors.amberAccent);

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
        actions: [
        ElevatedButton(style: buttonStyle,
            onPressed: (){}, child:
          const Text("Open")),
        Checkbox(
          semanticLabel: 'show 2 doc views',
        checkColor: Colors.white,
        value: _isChecked2Columns,
        onChanged: !_isDocOpen ? null : (bool? value) {
          setState(() {
            _isChecked2Columns = value!;
          });
        },
        ),
        Text('Show 2 views'),
        SizedBox(width: 10,),
        InkWell(child: Icon(Icons.rotate_90_degrees_cw),
          onTap: (){
            setState(() {
              if (_bTurnIntoRigth) {
                // Lukitsee näytön vaakatilaan
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.landscapeRight,
                  DeviceOrientation.landscapeLeft,
                ]);
                _bTurnIntoRigth = false;
              } else {
                // Palauttaa normaalin pystysuunnan (portrait) käyttäjälle
                SystemChrome.setPreferredOrientations([
                DeviceOrientation.portraitUp,
                ]);
                _bTurnIntoRigth = true;
                }
            });
          },
        ),
          SizedBox(width: 10,),
      ],
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: .center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
*/