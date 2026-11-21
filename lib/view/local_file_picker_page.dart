import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Paikallisen tallennustilan tiedosto- ja kansioselain.
/// Mahdollistaa laitteen sisäisen muistin ja kansioiden selailun suoraan sovelluksessa,
/// tiedostojen tai kansion valinnan sekä vahvistamisen "Valmis"-painikkeella.
class LocalFilePickerPage extends StatefulWidget {
  final bool isFolderPicker;
  final String? initialPath;

  const LocalFilePickerPage({
    super.key,
    required this.isFolderPicker,
    this.initialPath,
  });

  @override
  State<LocalFilePickerPage> createState() => _LocalFilePickerPageState();
}

class _LocalFilePickerPageState extends State<LocalFilePickerPage> {
  late String _currentPath;
  List<FileSystemEntity> _subFolders = [];
  List<File> _bookFiles = [];
  final Set<String> _selectedFiles = {};
  bool _isLoading = true;
  String? _errorMessage;

  // Pikapainikkeet yleisiin kansioihin
  final List<Map<String, String>> _shortcuts = [];

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath ?? '/storage/emulated/0';
    _alustaPikavalinnatJaAvaa();
  }

  Future<void> _alustaPikavalinnatJaAvaa() async {
    _shortcuts.clear();

    if (Platform.isAndroid) {
      final emulated0 = Directory('/storage/emulated/0');
      if (await emulated0.exists()) {
        _shortcuts.add({'name': 'Sisäinen muisti', 'path': '/storage/emulated/0', 'icon': 'phone'});
        _shortcuts.add({'name': 'Lataukset', 'path': '/storage/emulated/0/Download', 'icon': 'download'});
        _shortcuts.add({'name': 'Asiakirjat', 'path': '/storage/emulated/0/Documents', 'icon': 'doc'});
        _shortcuts.add({'name': 'Books', 'path': '/storage/emulated/0/Books', 'icon': 'books'});
      }

      // Etsitään mahdolliset ulkoiset SD-kortit
      try {
        final storageDir = Directory('/storage');
        if (await storageDir.exists()) {
          final entries = storageDir.listSync();
          for (var entry in entries) {
            final name = p.basename(entry.path);
            if (name != 'emulated' && name != 'self' && name != 'knox' && entry is Directory) {
              _shortcuts.add({'name': 'SD-kortti ($name)', 'path': entry.path, 'icon': 'sd'});
            }
          }
        }
      } catch (_) {}
    } else {
      // Linux, Windows, macOS, Desktop
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
      if (home.isNotEmpty) {
        _shortcuts.add({'name': 'Kotihakemisto', 'path': home, 'icon': 'phone'});
        _shortcuts.add({'name': 'Lataukset', 'path': p.join(home, 'Downloads'), 'icon': 'download'});
        _shortcuts.add({'name': 'Asiakirjat', 'path': p.join(home, 'Documents'), 'icon': 'doc'});
        _shortcuts.add({'name': 'Books', 'path': p.join(home, 'Books'), 'icon': 'books'});
      }
      try {
        final doc = await getApplicationDocumentsDirectory();
        _shortcuts.add({'name': 'Dokumentit', 'path': doc.path, 'icon': 'doc'});
      } catch (_) {}
    }

    // Jos oletuspolku ei ole olemassa, käytetään ensimmäistä saatavilla olevaa pikavalintaa
    final dir = Directory(_currentPath);
    if (!await dir.exists() && _shortcuts.isNotEmpty) {
      _currentPath = _shortcuts.first['path']!;
    }

    await _lueNykyinenHakemisto();
  }

  Future<void> _lueNykyinenHakemisto() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final dir = Directory(_currentPath);
      if (!await dir.exists()) {
        setState(() {
          _errorMessage = 'Hakemistoa ei löydy: $_currentPath';
          _subFolders = [];
          _bookFiles = [];
          _isLoading = false;
        });
        return;
      }

      final List<FileSystemEntity> entities = dir.listSync(recursive: false);
      final List<FileSystemEntity> folders = [];
      final List<File> books = [];

      for (var e in entities) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue; // Ohitetaan piilotiedostot

        if (e is Directory) {
          folders.add(e);
        } else if (e is File) {
          final ext = p.extension(e.path).toLowerCase();
          if (ext == '.pdf' || ext == '.epub' || ext == '.mobi' || ext == '.prc') {
            books.add(e);
          }
        }
      }

      // Järjestetään aakkosjärjestykseen
      folders.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
      books.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));

      setState(() {
        _subFolders = folders;
        _bookFiles = books;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Ei lukuoikeutta kansioon: $e';
        _subFolders = [];
        _bookFiles = [];
        _isLoading = false;
      });
    }
  }

  void _siirryKansioon(String uusiPolku) {
    _currentPath = uusiPolku;
    _lueNykyinenHakemisto();
  }

  void _siirryYlemmas() {
    final parent = Directory(_currentPath).parent;
    if (parent.path != _currentPath && parent.path.isNotEmpty) {
      _siirryKansioon(parent.path);
    }
  }

  void _toggleValitseKaikki() {
    setState(() {
      if (_selectedFiles.length == _bookFiles.length) {
        _selectedFiles.clear();
      } else {
        _selectedFiles.addAll(_bookFiles.map((f) => f.path));
      }
    });
  }

  String _formatKoko(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData _getShortcutIcon(String type) {
    switch (type) {
      case 'download':
        return Icons.download;
      case 'doc':
        return Icons.description;
      case 'books':
        return Icons.menu_book;
      case 'sd':
        return Icons.sd_card;
      default:
        return Icons.smartphone;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool onJuuri = Directory(_currentPath).parent.path == _currentPath || _currentPath == '/' || _currentPath == '/storage';
    final int valitutMaara = _selectedFiles.length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isFolderPicker ? 'Valitse kansio' : 'Valitse tiedostoja',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            Text(
              'Paikallinen tallennustila',
              style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85)),
            ),
          ],
        ),
        backgroundColor: Colors.blueAccent,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Päivitä näkymä',
            onPressed: _lueNykyinenHakemisto,
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Pikavalintapalkki (Sisäinen muisti, Lataukset, Asiakirjat, SD-kortti)
          if (_shortcuts.isNotEmpty)
            Container(
              color: Colors.blue.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _shortcuts.map((sc) {
                    final isCurrent = _currentPath == sc['path'] || _currentPath.startsWith('${sc['path']}/');
                    return Padding(
                      padding: const EdgeInsets.only(right: 6.0),
                      child: ActionChip(
                        avatar: Icon(_getShortcutIcon(sc['icon']!), size: 16, color: isCurrent ? Colors.blueAccent : Colors.grey.shade700),
                        label: Text(sc['name']!, style: TextStyle(fontSize: 12, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
                        backgroundColor: isCurrent ? Colors.white : Colors.grey.shade200,
                        onPressed: () => _siirryKansioon(sc['path']!),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

          // 2. Nykyinen polku & Ylös-painike
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'Ylös ylempään kansioon',
                  onPressed: onJuuri ? null : _siirryYlemmas,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      _currentPath,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                if (!widget.isFolderPicker && _bookFiles.isNotEmpty)
                  TextButton.icon(
                    icon: Icon(_selectedFiles.length == _bookFiles.length ? Icons.deselect : Icons.select_all, size: 16),
                    label: Text(_selectedFiles.length == _bookFiles.length ? 'Tyhjennä' : 'Kaikki (${_bookFiles.length})', style: const TextStyle(fontSize: 12)),
                    onPressed: _toggleValitseKaikki,
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                  ),
              ],
            ),
          ),

          // 3. Tiedostojen ja kansioiden listaus
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline, size: 48, color: Colors.orange),
                              const SizedBox(height: 12),
                              Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: () {
                                  if (_shortcuts.isNotEmpty) {
                                    _siirryKansioon(_shortcuts.first['path']!);
                                  }
                                },
                                child: const Text('Palaa pääkansioon'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : (_subFolders.isEmpty && _bookFiles.isEmpty)
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.folder_open, size: 56, color: Colors.grey.shade400),
                                const SizedBox(height: 8),
                                const Text('Kansio on tyhjä tai ei sisällä .pdf / .epub -kirjoja', style: TextStyle(color: Colors.grey)),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: _subFolders.length + (widget.isFolderPicker ? 0 : _bookFiles.length),
                            separatorBuilder: (context, index) => Divider(height: 1, color: Colors.grey.shade200),
                            itemBuilder: (context, index) {
                              // Kansiot ensin
                              if (index < _subFolders.length) {
                                final folder = _subFolders[index];
                                final folderName = p.basename(folder.path);

                                return ListTile(
                                  leading: const Icon(Icons.folder, color: Colors.amber, size: 30),
                                  title: Text(folderName, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                                  onTap: () => _siirryKansioon(folder.path),
                                );
                              }

                              // Tiedostot (vain tiedostonvalintatilassa)
                              final fileIndex = index - _subFolders.length;
                              final file = _bookFiles[fileIndex];
                              final fileName = p.basename(file.path);
                              final ext = p.extension(file.path).toLowerCase();
                              final isSelected = _selectedFiles.contains(file.path);

                              int fileSize = 0;
                              try {
                                fileSize = file.lengthSync();
                              } catch (_) {}

                              return CheckboxListTile(
                                value: isSelected,
                                onChanged: (bool? checked) {
                                  setState(() {
                                    if (checked == true) {
                                      _selectedFiles.add(file.path);
                                    } else {
                                      _selectedFiles.remove(file.path);
                                    }
                                  });
                                },
                                secondary: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: ext == '.pdf'
                                        ? Colors.red.shade100
                                        : (ext == '.mobi' || ext == '.prc')
                                            ? Colors.teal.shade100
                                            : Colors.green.shade100,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: ext == '.pdf'
                                          ? Colors.red.shade400
                                          : (ext == '.mobi' || ext == '.prc')
                                              ? Colors.teal.shade400
                                              : Colors.green.shade400,
                                    ),
                                  ),
                                  child: Text(
                                    ext == '.pdf'
                                        ? 'PDF'
                                        : (ext == '.mobi' || ext == '.prc')
                                            ? 'MOBI'
                                            : 'EPUB',
                                    style: TextStyle(
                                      color: ext == '.pdf'
                                          ? Colors.red.shade900
                                          : (ext == '.mobi' || ext == '.prc')
                                              ? Colors.teal.shade900
                                              : Colors.green.shade900,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                title: Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                subtitle: Text(_formatKoko(fileSize), style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                              );
                            },
                          ),
          ),

          // 4. ALAPALKKI JA "VALMIS"-PAINONAPPI
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              child: widget.isFolderPicker
                  ? Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Valittu kansio:',
                                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                              ),
                              Text(
                                p.basename(_currentPath),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                              Text(
                                '${_bookFiles.length} kirjaa (.pdf, .epub) tässä kansiossa',
                                style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.check_circle, size: 20),
                          label: const Text(
                            'Valmis',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () {
                            Navigator.pop(context, _currentPath);
                          },
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: Text(
                            valitutMaara > 0 ? '$valitutMaara kirjaa valittu' : 'Ei valittuja kirjoja',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: valitutMaara > 0 ? FontWeight.bold : FontWeight.normal,
                              color: valitutMaara > 0 ? Colors.black87 : Colors.grey,
                            ),
                          ),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: valitutMaara > 0 ? Colors.green.shade700 : Colors.grey.shade400,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.check_circle, size: 20),
                          label: Text(
                            valitutMaara > 0 ? 'Valmis ($valitutMaara)' : 'Valmis',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          onPressed: valitutMaara > 0
                              ? () {
                                  Navigator.pop(context, _selectedFiles.toList());
                                }
                              : null,
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
