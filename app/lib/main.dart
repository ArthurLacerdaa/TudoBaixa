import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:share_plus/share_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';
import 'package:device_info_plus/device_info_plus.dart';

const String kDefaultApiUrl = 'http://10.0.2.2:8000';

class AppTheme {
  static const Color background = Color(0xFF0D0818);
  static const Color backgroundSecondary = Color(0xFF1A1033);
  static const Color primaryPurple = Color(0xFF8B5CF6);
  static const Color primaryPurpleLight = Color(0xFFA78BFA);
  static const Color accentGlow = Color(0xFFC4B5FD);
  static const Color glassWhite = Color(0x22FFFFFF);
  static const Color glassBorder = Color(0x33FFFFFF);
  static const Color textPrimary = Color(0xFFF5F3FF);
  static const Color textSecondary = Color(0xFFC4B5FD);
  static const Color textMuted = Color(0xFF8B83A8);
  static const Color success = Color(0xFF34D399);
  static const Color error = Color(0xFFF87171);
  static const Color warning = Color(0xFFFBBF24);

  static ThemeData darkTheme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: const ColorScheme.dark(
        primary: primaryPurple,
        secondary: primaryPurpleLight,
        surface: backgroundSecondary,
        error: error,
      ),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        foregroundColor: textPrimary,
      ),
    );
  }
}

class VideoFormat {
  final String formatId;
  final String ext;
  final String resolution;
  final int height;
  final int? filesize;
  final double? fps;

  VideoFormat({
    required this.formatId,
    required this.ext,
    required this.resolution,
    required this.height,
    this.filesize,
    this.fps,
  });

  factory VideoFormat.fromJson(Map<String, dynamic> json) => VideoFormat(
        formatId: json['format_id']?.toString() ?? '',
        ext: json['ext']?.toString() ?? 'mp4',
        resolution: json['resolution']?.toString() ?? 'Desconhecida',
        height: (json['height'] as num?)?.toInt() ?? 0,
        filesize: (json['filesize'] as num?)?.toInt(),
        fps: (json['fps'] as num?)?.toDouble(),
      );

  String get label {
    final parts = <String>[resolution];
    if (fps != null) parts.add('${fps!.toStringAsFixed(0)}fps');
    if (filesize != null) parts.add(formatBytes(filesize!));
    return parts.join(' · ');
  }
}

class VideoInfo {
  final String title;
  final String uploader;
  final int? duration;
  final String thumbnail;
  final String url;
  final String platform;
  final int? filesize;
  final List<VideoFormat> formats;

  VideoInfo({
    required this.title,
    required this.uploader,
    this.duration,
    required this.thumbnail,
    required this.url,
    required this.platform,
    this.filesize,
    required this.formats,
  });

  factory VideoInfo.fromJson(Map<String, dynamic> json) => VideoInfo(
        title: json['title']?.toString() ?? 'Vídeo sem título',
        uploader: json['uploader']?.toString() ?? '',
        duration: (json['duration'] as num?)?.toInt(),
        thumbnail: json['thumbnail']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        platform: json['platform']?.toString() ?? 'Desconhecida',
        filesize: (json['filesize'] as num?)?.toInt(),
        formats: (json['formats'] as List<dynamic>?)
                ?.map((e) => VideoFormat.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

enum DownloadStatus {
  analyzing,
  queued,
  downloading,
  transferring,
  completed,
  error,
  canceled,
}

class DownloadTask {
  String taskId;
  final String url;
  DownloadStatus status;
  double progress;
  String? filename;
  String? error;
  String? localPath;
  final DateTime createdAt;
  VideoInfo? info;
  int? totalBytes;
  int downloadedBytes;
  double? speed;
  int? eta;

  DownloadTask({
    required this.taskId,
    required this.url,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.filename,
    this.error,
    this.localPath,
    DateTime? createdAt,
    this.info,
    this.totalBytes,
    this.downloadedBytes = 0,
    this.speed,
    this.eta,
  }) : createdAt = createdAt ?? DateTime.now();
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  final i = (log(bytes) / log(1024)).floor();
  return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
}

String formatDuration(int? seconds) {
  if (seconds == null || seconds <= 0) return '--:--';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String formatSpeed(double? bytesPerSec) {
  if (bytesPerSec == null || bytesPerSec <= 0) return '-- KB/s';
  return '${formatBytes(bytesPerSec.toInt())}/s';
}

void main() {
  runApp(const TudoBaixaApp());
}

class TudoBaixaApp extends StatelessWidget {
  const TudoBaixaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TudoBaixa',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme(),
      home: const AnimatedBg(child: HomePage()),
    );
  }
}

class AnimatedBg extends StatelessWidget {
  final Widget child;
  const AnimatedBg({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0D0818),
            Color(0xFF1A0E33),
            Color(0xFF120B24),
            Color(0xFF0D0818),
          ],
          stops: [0.0, 0.3, 0.6, 1.0],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -100,
            right: -80,
            child: Container(
              width: 300,
              height: 300,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryPurple,
                    blurRadius: 120,
                    spreadRadius: -20,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: -120,
            left: -60,
            child: Container(
              width: 280,
              height: 280,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.accentGlow,
                    blurRadius: 140,
                    spreadRadius: -40,
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double blur;
  final Color? color;
  final double borderWidth;
  final List<Color>? gradientColors;

  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.padding,
    this.margin,
    this.blur = 18,
    this.color,
    this.borderWidth = 1,
    this.gradientColors,
  });

  @override
  Widget build(BuildContext context) {
    final clip = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: gradientColors ??
                  [
                    (color ?? AppTheme.glassWhite).withOpacity(0.08),
                    (color ?? AppTheme.glassWhite).withOpacity(0.04),
                  ],
            ),
            border: Border.all(
              color: AppTheme.glassBorder.withOpacity(0.4),
              width: borderWidth,
            ),
          ),
          padding: padding ?? const EdgeInsets.all(20),
          child: child,
        ),
      ),
    );
    if (margin != null) {
      return Padding(padding: margin!, child: clip);
    }
    return clip;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  final List<DownloadTask> _tasks = [];
  late StreamSubscription _intentDataStreamSubscription;
  String _apiUrl = kDefaultApiUrl;
  Timer? _pollingTimer;
  bool _isProcessingShare = false;

  VideoInfo? _previewInfo;
  bool _isLoadingPreview = false;
  String? _previewError;
  String? _lastPreviewUrl;

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
    _urlController.dispose();
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
      try {
        await Permission.notification.request();
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        if (androidInfo.version.sdkInt <= 32) {
          await Permission.storage.request();
        } else {
          await Permission.photos.request();
          await Permission.videos.request();
        }
      } catch (_) {}
    }
  }

  void _initSharingIntent() {
    _intentDataStreamSubscription =
        ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> list) {
        if (list.isNotEmpty) _handleSharedMedia(list.first);
      },
      onError: (_) {},
    );

    ReceiveSharingIntent.instance.getInitialMedia().then(
      (List<SharedMediaFile> list) {
        if (list.isNotEmpty && !_isProcessingShare) {
          _isProcessingShare = true;
          _handleSharedMedia(list.first);
        }
      },
    );
  }

  void _handleSharedMedia(SharedMediaFile media) {
    final payload = (media.message != null && media.message!.isNotEmpty)
        ? media.message!
        : media.path;
    if (payload.isNotEmpty) _handleSharedText(payload);
    ReceiveSharingIntent.instance.reset();
  }

  void _handleSharedText(String text) {
    final urls = _extractUrls(text);
    if (urls.isNotEmpty) {
      final first = urls.first;
      setState(() {
        _urlController.text = first;
      });
      _loadPreview(first);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Link recebido! Buscando informações...'),
          backgroundColor: AppTheme.primaryPurple,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nenhum link encontrado no conteúdo compartilhado'),
          backgroundColor: AppTheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
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
      if (url.startsWith('www.')) url = 'https://$url';
      url = url.replaceAll(RegExp(r'[.,;:!?)]$'), '');
      urls.add(url);
    }
    return urls.toList();
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _updateAllTaskStatuses();
    });
  }

  Future<void> _loadPreview(String url) async {
    if (url.isEmpty) return;
    final validUrl = Uri.tryParse(url);
    if (validUrl == null || !validUrl.hasScheme) {
      setState(() {
        _previewError = 'URL inválida';
        _previewInfo = null;
        _isLoadingPreview = false;
        _lastPreviewUrl = null;
      });
      return;
    }

    setState(() {
      _isLoadingPreview = true;
      _previewError = null;
      _previewInfo = null;
      _lastPreviewUrl = url;
    });

    try {
      final response = await http.post(
        Uri.parse('$_apiUrl/api/info'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': url}),
      ).timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (mounted) {
          setState(() {
            _previewInfo = VideoInfo.fromJson(data);
            _isLoadingPreview = false;
          });
        }
      } else {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (mounted) {
          setState(() {
            _previewError =
                data['detail']?.toString() ?? 'Não foi possível analisar o link';
            _isLoadingPreview = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _previewError = 'Erro de conexão: verifique se a API está rodando em $_apiUrl';
          _isLoadingPreview = false;
        });
      }
    }
  }

  Future<void> _startDownloadFromPreview() async {
    if (_previewInfo == null || _lastPreviewUrl == null) return;
    await _startDownload(_lastPreviewUrl!, info: _previewInfo);
    setState(() {
      _previewInfo = null;
      _lastPreviewUrl = null;
      _urlController.clear();
    });
  }

  Future<void> _startDownload(String url, {VideoInfo? info}) async {
    final localTask = DownloadTask(
      taskId: 'local_${DateTime.now().millisecondsSinceEpoch}',
      url: url,
      status: DownloadStatus.analyzing,
      info: info,
    );
    setState(() {
      _tasks.insert(0, localTask);
    });

    try {
      final response = await http.post(
        Uri.parse('$_apiUrl/api/download'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': url}),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            localTask.taskId = data['task_id'];
            localTask.status = DownloadStatus.queued;
          });
        }
      } else {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (mounted) {
          setState(() {
            localTask.status = DownloadStatus.error;
            localTask.error = data['detail']?.toString() ?? 'Erro ao iniciar download';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          localTask.status = DownloadStatus.error;
          localTask.error =
              'Falha de conexão: $e. Verifique a URL da API nas configurações.';
        });
      }
    }
  }

  Future<void> _updateAllTaskStatuses() async {
    if (_tasks.isEmpty) return;
    final needsUpdate = _tasks.where((t) =>
        t.status == DownloadStatus.queued ||
        t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.analyzing);
    for (final task in needsUpdate.toList()) {
      await _updateTaskStatus(task);
    }
  }

  Future<void> _updateTaskStatus(DownloadTask task) async {
    if (task.taskId.startsWith('local_')) return;
    try {
      final response = await http.get(Uri.parse('$_apiUrl/api/status/${task.taskId}'));
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final apiStatus = data['status']?.toString() ?? 'queued';
        final newProgress = (data['progress'] as num?)?.toDouble() ?? 0.0;

        final serverCompleted = apiStatus == 'completed';
        final nowCompleted = serverCompleted &&
            task.status != DownloadStatus.completed &&
            task.localPath == null &&
            task.status != DownloadStatus.transferring;

        setState(() {
          if (apiStatus == 'queued') task.status = DownloadStatus.queued;
          if (apiStatus == 'downloading') task.status = DownloadStatus.downloading;
          if (apiStatus == 'completed' && task.localPath == null) {
            task.status = DownloadStatus.transferring;
          }
          if (apiStatus == 'completed' && task.localPath != null) {
            task.status = DownloadStatus.completed;
          }
          if (apiStatus == 'error') {
            task.status = DownloadStatus.error;
            task.error = data['error']?.toString() ?? 'Erro desconhecido';
          }
          task.progress = newProgress;
          task.filename = data['filename']?.toString();
        });

        if (nowCompleted) _downloadFileToDevice(task);
      }
    } catch (_) {}
  }

  Future<void> _downloadFileToDevice(DownloadTask task) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final filename =
          task.filename ?? 'video_${task.taskId.substring(0, 8)}.mp4';
      final filePath = '${tempDir.path}/$filename';
      final file = File(filePath);

      final request =
          http.Request('GET', Uri.parse('$_apiUrl/api/download/${task.taskId}/file'));
      final response = await request.send().timeout(
        const Duration(minutes: 15),
        onTimeout: () {
          throw TimeoutException('Download demorou muito');
        },
      );

      if (response.statusCode == 200) {
        final contentLength = response.contentLength;
        int received = 0;
        final stopwatch = Stopwatch()..start();

        final sink = file.openWrite();
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (contentLength != null) {
            final percent = (received / contentLength) * 100;
            if (mounted) {
              setState(() {
                task.downloadedBytes = received;
                task.totalBytes = contentLength;
                task.progress = percent;
                if (stopwatch.elapsedMilliseconds > 500) {
                  task.speed = received / (stopwatch.elapsedMilliseconds / 1000);
                }
              });
            }
          }
        }
        await sink.close();

        final savedToGallery = await _saveToGallery(file, filename);

        if (mounted) {
          setState(() {
            task.localPath = savedToGallery ? filePath : filePath;
            task.progress = 100.0;
            task.status = DownloadStatus.completed;
            task.speed = null;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            task.status = DownloadStatus.error;
            task.error = 'Erro ao baixar arquivo (${response.statusCode})';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          task.status = DownloadStatus.error;
          task.error = 'Falha ao salvar: $e';
        });
      }
    }
  }

  Future<bool> _saveToGallery(File file, String filename) async {
    try {
      final Directory? dir = Platform.isAndroid
          ? Directory('/storage/emulated/0/Download')
          : await getApplicationDocumentsDirectory();
      if (dir != null) {
        if (!await dir.exists()) await dir.create(recursive: true);
        final target = File('${dir.path}/TudoBaixa_${DateTime.now().millisecondsSinceEpoch}_$filename');
        await file.copy(target.path);
        return true;
      }
      return false;
    } catch (_) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final target = File('${dir.path}/$filename');
        await file.copy(target.path);
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  void _openFile(DownloadTask task) {
    if (task.localPath != null) {
      OpenFilex.open(task.localPath!);
    }
  }

  Future<void> _shareFile(DownloadTask task) async {
    if (task.localPath != null) {
      await Share.shareXFiles(
        [XFile(task.localPath!)],
        text: task.info?.title ?? task.filename ?? 'Vídeo baixado com TudoBaixa',
      );
    }
  }

  Future<void> _showApiUrlDialog() async {
    final controller = TextEditingController(text: _apiUrl);
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: DraggableScrollableSheet(
          initialChildSize: 0.45,
          maxChildSize: 0.6,
          minChildSize: 0.3,
          builder: (_, scrollController) => GlassCard(
            margin: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              controller: scrollController,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryPurple.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.api_rounded,
                          color: AppTheme.primaryPurpleLight,
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Configurar API',
                              style: GoogleFonts.inter(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Backend com yt-dlp',
                              style: GoogleFonts.inter(
                                color: AppTheme.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close, color: AppTheme.textMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'URL da API',
                    style: GoogleFonts.inter(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    style: const TextStyle(color: AppTheme.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'http://seu-servidor:8000',
                      hintStyle: const TextStyle(color: AppTheme.textMuted),
                      filled: true,
                      fillColor: AppTheme.background.withOpacity(0.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide:
                            const BorderSide(color: AppTheme.glassBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide:
                            BorderSide(color: AppTheme.glassBorder.withOpacity(0.3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide:
                            const BorderSide(color: AppTheme.primaryPurpleLight),
                      ),
                      prefixIcon:
                          const Icon(Icons.link_rounded, color: AppTheme.textMuted),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '• Emulador Android: http://10.0.2.2:8000\n'
                    '• Celular físico: IP do seu computador na mesma rede (ex: http://192.168.1.10:8000)',
                    style: GoogleFonts.inter(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: () {
                        _saveApiUrl(controller.text.trim());
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('URL da API salva!'),
                            backgroundColor: AppTheme.success,
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryPurple,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        'Salvar',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloadingCount = _tasks.where((t) {
      return t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.analyzing ||
          t.status == DownloadStatus.transferring;
    }).length;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primaryPurpleLight, AppTheme.primaryPurple],
                ),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(
                Icons.arrow_downward_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'TudoBaixa',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                fontSize: 19,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
        actions: [
          if (downloadingCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Icon(Icons.download_rounded, size: 26),
                  Positioned(
                    right: 0,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryPurple,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$downloadingCount',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          IconButton(
            icon: const Icon(Icons.settings_rounded, size: 26),
            onPressed: _showApiUrlDialog,
            tooltip: 'Configurar API',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          color: AppTheme.primaryPurpleLight,
          backgroundColor: AppTheme.backgroundSecondary,
          onRefresh: () async {
            await _updateAllTaskStatuses();
            await Future.delayed(const Duration(milliseconds: 400));
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, AppBar().preferredSize.height + 30, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 28),
                _buildUrlInput(),
                const SizedBox(height: 20),
                if (_isLoadingPreview) _buildPreviewSkeleton(),
                if (_previewError != null && !_isLoadingPreview)
                  _buildPreviewError(),
                if (_previewInfo != null && !_isLoadingPreview)
                  _buildPreviewCard(),
                const SizedBox(height: 32),
                if (_tasks.isNotEmpty) _buildTasksHeader(),
                if (_tasks.isNotEmpty) const SizedBox(height: 12),
                ..._tasks.map((task) => _buildTaskCard(task)),
                if (_tasks.isEmpty &&
                    _previewInfo == null &&
                    !_isLoadingPreview &&
                    _previewError == null)
                  _buildEmptyState(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Baixe seus vídeos',
            style: GoogleFonts.inter(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
              letterSpacing: -0.5,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Instagram, TikTok, Facebook e muito mais',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: AppTheme.textSecondary.withOpacity(0.8),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUrlInput() {
    return GlassCard(
      padding: const EdgeInsets.all(4),
      child: Column(
        children: [
          TextField(
            controller: _urlController,
            style: GoogleFonts.inter(
              color: AppTheme.textPrimary,
              fontSize: 15,
            ),
            decoration: InputDecoration(
              hintText: '🔗  Cole seu link aqui...',
              hintStyle: GoogleFonts.inter(
                color: AppTheme.textMuted,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              filled: true,
              fillColor: Colors.transparent,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              prefixIcon: Padding(
                padding: const EdgeInsets.only(left: 14, right: 4),
                child: Icon(
                  Icons.link_rounded,
                  color: AppTheme.primaryPurpleLight,
                  size: 22,
                ),
              ),
              suffixIcon: _urlController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: AppTheme.textMuted, size: 20),
                      onPressed: () {
                        setState(() {
                          _urlController.clear();
                          _previewInfo = null;
                          _previewError = null;
                          _lastPreviewUrl = null;
                        });
                      },
                    )
                  : null,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 18),
            ),
            onSubmitted: (v) => _loadPreview(v.trim()),
            textInputAction: TextInputAction.search,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () => _loadPreview(_urlController.text.trim()),
                icon: const Icon(Icons.search_rounded, size: 20),
                label: Text(
                  'Analisar link',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryPurple,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shadowColor: AppTheme.primaryPurple.withOpacity(0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewSkeleton() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Shimmer.fromColors(
            baseColor: Colors.white10,
            highlightColor: Colors.white24,
            child: Container(
              width: double.infinity,
              height: 180,
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Shimmer.fromColors(
            baseColor: Colors.white10,
            highlightColor: Colors.white24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: double.infinity, height: 16, color: Colors.white10),
                const SizedBox(height: 8),
                Container(width: 180, height: 12, color: Colors.white10),
                const SizedBox(height: 16),
                Container(width: 120, height: 44, color: Colors.white10),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewError() {
    return GlassCard(
      gradientColors: [
        AppTheme.error.withOpacity(0.10),
        AppTheme.error.withOpacity(0.03),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.error.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.error_outline_rounded,
                color: AppTheme.error, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Não foi possível analisar',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.error,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _previewError!,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppTheme.textSecondary.withOpacity(0.7),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => _loadPreview(_lastPreviewUrl ?? ''),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(
                        'Tentar novamente',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.primaryPurpleLight,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _showApiUrlDialog,
                      icon: const Icon(Icons.settings_rounded, size: 18),
                      label: Text(
                        'Configurar API',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard() {
    final info = _previewInfo!;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: Stack(
              children: [
                if (info.thumbnail.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: info.thumbnail,
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                      height: 200,
                      color: AppTheme.backgroundSecondary,
                      child: const Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.primaryPurpleLight,
                        ),
                      ),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      height: 200,
                      color: AppTheme.backgroundSecondary,
                      child: const Center(
                        child: Icon(Icons.movie_rounded,
                            size: 60, color: AppTheme.textMuted),
                      ),
                    ),
                  )
                else
                  Container(
                    height: 200,
                    width: double.infinity,
                    color: AppTheme.backgroundSecondary,
                    child: const Center(
                      child: Icon(Icons.movie_rounded,
                          size: 60, color: AppTheme.textMuted),
                    ),
                  ),
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.7),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 12,
                  left: 16,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryPurple.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _platformIcon(info.platform),
                          color: Colors.white,
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          info.platform,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (info.duration != null)
                  Positioned(
                    bottom: 12,
                    right: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        formatDuration(info.duration),
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                    height: 1.3,
                  ),
                ),
                if (info.uploader.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.person_outline_rounded,
                          size: 16, color: AppTheme.textMuted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          info.uploader,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: AppTheme.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (info.filesize != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryPurple.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            formatBytes(info.filesize!),
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryPurpleLight,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton.icon(
                    onPressed: _startDownloadFromPreview,
                    icon: const Icon(Icons.download_rounded, size: 22),
                    label: Text(
                      'Baixar agora',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryPurple,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shadowColor: AppTheme.primaryPurple.withOpacity(0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
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

  IconData _platformIcon(String platform) {
    final p = platform.toLowerCase();
    if (p.contains('tiktok')) return Icons.music_note_rounded;
    if (p.contains('instagram')) return Icons.camera_alt_rounded;
    if (p.contains('facebook') || p.contains('fb')) return Icons.facebook_rounded;
    if (p.contains('youtube')) return Icons.smart_display_rounded;
    if (p.contains('twitter') || p.contains('x:')) return Icons.alternate_email_rounded;
    return Icons.language_rounded;
  }

  Widget _buildTasksHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Text(
            'Downloads',
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.primaryPurple.withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${_tasks.length}',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.primaryPurpleLight,
              ),
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () {
              setState(() {
                _tasks.clear();
              });
            },
            icon: const Icon(Icons.cleaning_services_rounded, size: 18),
            label: Text(
              'Limpar',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600),
            ),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(DownloadTask task) {
    final statusConfig = _statusConfig(task);
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 14),
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (task.info?.thumbnail != null && task.info!.thumbnail.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedNetworkImage(
                      imageUrl: task.info!.thumbnail,
                      width: 84,
                      height: 84,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        width: 84,
                        height: 84,
                        color: AppTheme.backgroundSecondary,
                      ),
                      errorWidget: (_, __, ___) => Container(
                        width: 84,
                        height: 84,
                        color: AppTheme.backgroundSecondary,
                        child: const Icon(
                          Icons.movie_rounded,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  )
                else
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundSecondary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.movie_rounded,
                      size: 36,
                      color: statusConfig.color.withOpacity(0.6),
                    ),
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              task.info?.title ?? task.filename ?? task.url,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: statusConfig.color.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(statusConfig.icon,
                                size: 12, color: statusConfig.color),
                            const SizedBox(width: 5),
                            Text(
                              statusConfig.label,
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: statusConfig.color,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (task.info?.platform != null &&
                          task.info!.platform.isNotEmpty)
                        Row(
                          children: [
                            Icon(_platformIcon(task.info!.platform),
                                size: 13, color: AppTheme.textMuted),
                            const SizedBox(width: 4),
                            Text(
                              task.info!.platform,
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (task.status == DownloadStatus.downloading ||
                task.status == DownloadStatus.transferring) ...[
              const SizedBox(height: 16),
              _buildProgressBar(task, statusConfig),
              const SizedBox(height: 10),
              _buildDownloadStats(task),
            ] else if (task.progress > 0 &&
                task.progress < 100 &&
                task.status != DownloadStatus.completed) ...[
              const SizedBox(height: 12),
              _buildProgressBar(task, statusConfig),
            ],
            if (task.status == DownloadStatus.completed &&
                task.localPath != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 42,
                      child: ElevatedButton.icon(
                        onPressed: () => _openFile(task),
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: Text(
                          'Abrir',
                          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.success.withOpacity(0.18),
                          foregroundColor: AppTheme.success,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 42,
                      child: OutlinedButton.icon(
                        onPressed: () => _shareFile(task),
                        icon: const Icon(Icons.share_rounded, size: 18),
                        label: Text(
                          'Compartilhar',
                          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryPurpleLight,
                          side: const BorderSide(color: AppTheme.glassBorder),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (task.status == DownloadStatus.error && task.error != null) ...[
              const SizedBox(height: 12),
              Text(
                task.error!,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: AppTheme.error.withOpacity(0.9),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 40,
                child: OutlinedButton.icon(
                  onPressed: () => _startDownload(task.url, info: task.info),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(
                    'Tentar novamente',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error,
                    side: BorderSide(color: AppTheme.error.withOpacity(0.4)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(DownloadTask task, _StatusConfig status) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: (task.progress.clamp(0, 100)) / 100,
            minHeight: 8,
            backgroundColor: status.color.withOpacity(0.1),
            valueColor: AlwaysStoppedAnimation<Color>(status.color),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${task.progress.toStringAsFixed(0)}%',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: status.color,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDownloadStats(DownloadTask task) {
    return Row(
      children: [
        if (task.totalBytes != null)
          Text(
            '${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes!)}',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          )
        else
          Text(
            formatBytes(task.downloadedBytes),
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        const Spacer(),
        if (task.speed != null)
          Text(
            formatSpeed(task.speed),
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppTheme.primaryPurpleLight,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }

  _StatusConfig _statusConfig(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.analyzing:
        return _StatusConfig(
          color: AppTheme.warning,
          icon: Icons.auto_awesome_rounded,
          label: 'Analisando',
        );
      case DownloadStatus.queued:
        return _StatusConfig(
          color: AppTheme.warning,
          icon: Icons.schedule_rounded,
          label: 'Na fila',
        );
      case DownloadStatus.downloading:
        return _StatusConfig(
          color: AppTheme.primaryPurpleLight,
          icon: Icons.downloading_rounded,
          label: 'Baixando',
        );
      case DownloadStatus.transferring:
        return _StatusConfig(
          color: AppTheme.primaryPurpleLight,
          icon: Icons.sync_rounded,
          label: 'Salvando',
        );
      case DownloadStatus.completed:
        return _StatusConfig(
          color: AppTheme.success,
          icon: Icons.check_circle_rounded,
          label: 'Concluído',
        );
      case DownloadStatus.error:
        return _StatusConfig(
          color: AppTheme.error,
          icon: Icons.error_outline_rounded,
          label: 'Erro',
        );
      case DownloadStatus.canceled:
        return _StatusConfig(
          color: AppTheme.textMuted,
          icon: Icons.cancel_rounded,
          label: 'Cancelado',
        );
    }
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: GlassCard(
        gradientColors: [
          AppTheme.primaryPurple.withOpacity(0.06),
          Colors.transparent,
        ],
        child: Column(
          children: [
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppTheme.primaryPurple.withOpacity(0.3),
                    AppTheme.primaryPurple.withOpacity(0.0),
                  ],
                ),
              ),
              child: Icon(
                Icons.share_rounded,
                size: 64,
                color: AppTheme.primaryPurpleLight.withOpacity(0.85),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Sem downloads ainda',
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Cole um link acima ou compartilhe um vídeo\n diretamente com o TudoBaixa',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppTheme.textSecondary.withOpacity(0.8),
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                _platformChip('Instagram', Icons.camera_alt_rounded),
                _platformChip('TikTok', Icons.music_note_rounded),
                _platformChip('Facebook', Icons.facebook_rounded),
                _platformChip('YouTube', Icons.smart_display_rounded),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _platformChip(String name, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary.withOpacity(0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.glassBorder.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppTheme.primaryPurpleLight),
          const SizedBox(width: 6),
          Text(
            name,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusConfig {
  final Color color;
  final IconData icon;
  final String label;

  _StatusConfig({
    required this.color,
    required this.icon,
    required this.label,
  });
}


