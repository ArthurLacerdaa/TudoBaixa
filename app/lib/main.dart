import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kDefaultApiUrl = 'http://10.0.2.2:8000';

class DownloadTask {
  final String taskId;
  final String url;
  String status;
  double progress;
  String? filename;
  String? error;
  String? localPath;
  final DateTime createdAt;

  DownloadTask({
    required this.taskId,
    required this.url,
    this.status = 'queued',
    this.progress = 0.0,
    this.filename,
    this.error,
    this.localPath,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

void main() {
  runApp(const VideoDownloaderApp());
}

class VideoDownloaderApp extends StatelessWidget {
  const VideoDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TudoBaixa',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _multiLinkController = TextEditingController();
  final List<DownloadTask> _tasks = [];
  late StreamSubscription _intentDataStreamSubscription;
  String _apiUrl = kDefaultApiUrl;
  Timer? _pollingTimer;
  bool _isProcessingShare = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _initSharingIntent();
    _requestPermissions();
    _startPolling();
  }

  @override
  void dispose() {
    _intentDataStreamSubscription.cancel();
    _multiLinkController.dispose();
    _pollingTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiUrl = prefs.getString('api_url') ?? kDefaultApiUrl;
    });
  }

  Future<void> _saveApiUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_url', url);
    setState(() {
      _apiUrl = url;
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await Permission.notification.request();
      await Permission.storage.request();
    }
  }

  void _initSharingIntent() {
    ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> list) {
      if (list.isNotEmpty) {
        _handleSharedMedia(list.first);
      }
    }, onError: (err) {});

    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> list) {
      if (list.isNotEmpty && !_isProcessingShare) {
        _isProcessingShare = true;
        _handleSharedMedia(list.first);
      }
    });
  }

  void _handleSharedMedia(SharedMediaFile media) {
    final payload = (media.message != null && media.message!.isNotEmpty)
        ? media.message!
        : media.path;
    if (payload.isNotEmpty) {
      _handleSharedText(payload);
    }
    ReceiveSharingIntent.instance.reset();
  }

  void _handleSharedText(String text) {
    final urls = _extractUrls(text);
    if (urls.isNotEmpty) {
      for (final url in urls) {
        _startDownload(url);
      }
      _showSnackBar('${urls.length} URL(s) recebida(s) do compartilhamento');
    } else {
      _showSnackBar('Nenhuma URL encontrada no conteúdo compartilhado');
    }
  }

  List<String> _extractUrls(String text) {
    final regex = RegExp(
      r'''https?://[^\s<>"']+|www\.[^\s<>"']+''',
      caseSensitive: false,
    );
    final matches = regex.allMatches(text);
    final urls = <String>{};
    for (final match in matches) {
      var url = match.group(0)!;
      if (url.startsWith('www.')) {
        url = 'https://$url';
      }
      url = url.replaceAll(RegExp(r'[.,;:!?)]$'), '');
      urls.add(url);
    }
    return urls.toList();
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _updateAllTaskStatuses();
    });
  }

  Future<void> _startDownload(String url) async {
    try {
      final response = await http.post(
        Uri.parse('$_apiUrl/api/download'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': url}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final task = DownloadTask(
          taskId: data['task_id'],
          url: url,
          status: data['status'] ?? 'queued',
        );
        setState(() {
          _tasks.insert(0, task);
        });
      } else {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final task = DownloadTask(
          taskId: 'local_${DateTime.now().millisecondsSinceEpoch}',
          url: url,
          status: 'error',
          error: data['detail'] ?? 'Erro ao iniciar download',
        );
        setState(() {
          _tasks.insert(0, task);
        });
      }
    } catch (e) {
      final task = DownloadTask(
        taskId: 'local_${DateTime.now().millisecondsSinceEpoch}',
        url: url,
        status: 'error',
        error: 'Falha de conexão: $e',
      );
      setState(() {
        _tasks.insert(0, task);
      });
    }
  }

  Future<void> _startMultiDownload() async {
    final text = _multiLinkController.text.trim();
    if (text.isEmpty) {
      _showSnackBar('Cole o texto com os links');
      return;
    }

    final urls = _extractUrls(text);
    if (urls.isEmpty) {
      _showSnackBar('Nenhuma URL válida encontrada');
      return;
    }

    _multiLinkController.clear();
    _showSnackBar('Iniciando ${urls.length} download(s)...');

    try {
      final response = await http.post(
        Uri.parse('$_apiUrl/api/download/multi'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          for (final t in data['tasks']) {
            _tasks.insert(0, DownloadTask(
              taskId: t['task_id'],
              url: t['url'],
              status: t['status'] ?? 'queued',
            ));
          }
        });
      } else {
        for (final url in urls) {
          _startDownload(url);
        }
      }
    } catch (e) {
      for (final url in urls) {
        _startDownload(url);
      }
    }
  }

  Future<void> _updateAllTaskStatuses() async {
    if (_tasks.isEmpty) return;
    final needsUpdate = _tasks.where((t) =>
    t.status == 'queued' || t.status == 'downloading').toList();
    for (final task in needsUpdate) {
      await _updateTaskStatus(task);
    }
  }

  Future<void> _updateTaskStatus(DownloadTask task) async {
    if (task.taskId.startsWith('local_')) return;
    try {
      final response = await http.get(Uri.parse('$_apiUrl/api/status/${task.taskId}'));
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final needsDownload = data['status'] == 'completed' &&
            task.status != 'completed' &&
            task.localPath == null;
        setState(() {
          task.status = data['status'];
          task.progress = (data['progress'] as num?)?.toDouble() ?? 0.0;
          task.filename = data['filename'];
          task.error = data['error'];
        });
        if (needsDownload) {
          _downloadFileToDevice(task);
        }
      }
    } catch (e) {
    }
  }

  Future<void> _downloadFileToDevice(DownloadTask task) async {
    try {
      final directory = Platform.isAndroid
          ? Directory('/storage/emulated/0/Download')
          : await getApplicationDocumentsDirectory();

      if (Platform.isAndroid && !(await directory.exists())) {
        await directory.create(recursive: true);
      }

      final filename = task.filename ?? 'video_${task.taskId.substring(0, 8)}.mp4';
      final filePath = '${directory.path}/$filename';
      final file = File(filePath);

      final request = http.Request(
        'GET',
        Uri.parse('$_apiUrl/api/download/${task.taskId}/file'),
      );
      final response = await request.send();

      if (response.statusCode == 200) {
        final contentLength = response.contentLength;
        int received = 0;

        final sink = file.openWrite();
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (contentLength != null) {
            final percent = (received / contentLength) * 100;
            if (mounted) {
              setState(() {
                task.progress = percent;
              });
            }
          }
        }
        await sink.close();

        if (mounted) {
          setState(() {
            task.localPath = filePath;
            task.progress = 100.0;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            task.status = 'error';
            task.error = 'Erro ao baixar arquivo (${response.statusCode})';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          task.status = 'error';
          task.error = 'Falha ao salvar arquivo: $e';
        });
      }
    }
  }

  void _openFile(DownloadTask task) {
    if (task.localPath != null) {
      OpenFilex.open(task.localPath!);
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _showApiUrlDialog() async {
    final controller = TextEditingController(text: _apiUrl);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('URL da API'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'https://api.exemplo.com'),
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              _saveApiUrl(controller.text.trim());
              Navigator.pop(context);
              _showSnackBar('URL da API atualizada');
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloadingCount = _tasks.where((t) =>
    t.status == 'downloading' || t.status == 'queued').length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('TudoBaixa'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showApiUrlDialog,
            tooltip: 'Configurar API',
          ),
          if (downloadingCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Badge(
                  label: Text('$downloadingCount'),
                  child: const Icon(Icons.download),
                ),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _updateAllTaskStatuses();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.link, color: Colors.deepPurple),
                          const SizedBox(width: 8),
                          Text(
                            'Múltiplos Links',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _multiLinkController,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          hintText: 'Cole aqui mensagens ou texto com links.\nExemplo:\nInstagram: https://instagram.com/...\nTikTok: https://vm.tiktok.com/...',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _startMultiDownload,
                          icon: const Icon(Icons.download),
                          label: Text('Baixar Tudo (${_extractUrls(_multiLinkController.text).length} links)'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (_tasks.isNotEmpty)
                Row(
                  children: [
                    Icon(Icons.list, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Fila de Downloads (${_tasks.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _tasks.clear();
                        });
                      },
                      icon: const Icon(Icons.cleaning_services),
                      label: const Text('Limpar'),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              ..._tasks.map((task) => _buildTaskCard(task)),
              if (_tasks.isEmpty)
                Center(
                  child: Column(
                    children: [
                      const SizedBox(height: 60),
                      Icon(
                        Icons.share,
                        size: 80,
                        color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Sem downloads em andamento',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Use o botão Compartilhar no Instagram,\nTikTok, Facebook ou YouTube e escolha o\nTudoBaixa.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTaskCard(DownloadTask task) {
    final Color statusColor;
    final IconData statusIcon;
    final String statusText;

    switch (task.status) {
      case 'queued':
        statusColor = Colors.orange;
        statusIcon = Icons.schedule;
        statusText = 'Na fila';
        break;
      case 'downloading':
        statusColor = Colors.blue;
        statusIcon = Icons.downloading;
        statusText = 'Baixando';
        break;
      case 'completed':
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
        statusText = task.localPath != null ? 'Concluído' : 'Transferindo';
        break;
      case 'error':
        statusColor = Colors.red;
        statusIcon = Icons.error;
        statusText = 'Erro';
        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.help;
        statusText = task.status;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(statusIcon, color: statusColor, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.filename ?? task.url,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        task.url,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (task.status == 'completed' && task.localPath != null)
                  IconButton(
                    icon: const Icon(Icons.play_circle, color: Colors.green, size: 32),
                    onPressed: () => _openFile(task),
                    tooltip: 'Abrir vídeo',
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (task.status == 'downloading' || task.progress > 0)
                  Text(
                    '${task.progress.toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            if (task.status == 'downloading' ||
                (task.status == 'completed' && task.localPath == null) ||
                task.progress > 0 && task.progress < 100)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: task.progress / 100,
                    minHeight: 6,
                    backgroundColor: statusColor.withOpacity(0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                  ),
                ),
              ),
            if (task.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  task.error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.red,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
