import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../format.dart';

/// Opens [url] outside the app (browser / system viewer / download).
Future<void> openExternally(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
      .catchError((_) => false);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Не удалось открыть файл')));
  }
}

/// Full-screen zoomable photo.
class ImageViewer extends StatelessWidget {
  const ImageViewer({
    super.key,
    required this.heroTag,
    this.url,
    this.bytes,
    this.title = '',
  });

  final String heroTag;
  final String? url;
  final Uint8List? bytes;
  final String title;

  @override
  Widget build(BuildContext context) {
    final Widget image = bytes != null
        ? Image.memory(bytes!, fit: BoxFit.contain)
        : CachedNetworkImage(
            imageUrl: url!,
            fit: BoxFit.contain,
            placeholder: (_, _) => const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
            errorWidget: (_, _, _) => const Icon(Icons.broken_image_outlined,
                color: Colors.white54, size: 64),
          );
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
        actions: [
          if (url != null)
            IconButton(
              tooltip: 'Открыть или сохранить',
              icon: const Icon(Icons.download_outlined),
              onPressed: () => openExternally(context, url!),
            ),
        ],
      ),
      body: GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0).abs() > 600) Navigator.of(context).pop();
        },
        child: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: Hero(tag: heroTag, child: image),
          ),
        ),
      ),
    );
  }
}

/// Full-screen video player.
class VideoViewer extends StatefulWidget {
  const VideoViewer({super.key, required this.url, this.title = ''});

  final String url;
  final String title;

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  late final VideoPlayerController _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      _c.play();
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
    _c.addListener(_tick);
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_tick);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    Widget body;
    if (_failed) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Не удалось воспроизвести видео',
              style: TextStyle(color: Colors.white)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => openExternally(context, widget.url),
            child: const Text('Открыть во внешнем плеере'),
          ),
        ],
      );
    } else if (!v.isInitialized) {
      body = const CircularProgressIndicator(color: Colors.white);
    } else {
      body = GestureDetector(
        onTap: () => v.isPlaying ? _c.pause() : _c.play(),
        child: AspectRatio(
          aspectRatio: v.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_c),
              if (!v.isPlaying)
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                      color: Colors.black45, shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 40),
                ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Открыть или сохранить',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => openExternally(context, widget.url),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: Center(child: body)),
          if (v.isInitialized)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Text(duration(v.position.inMilliseconds),
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: VideoProgressIndicator(_c,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                              playedColor: Colors.white,
                              bufferedColor: Colors.white24,
                              backgroundColor: Colors.white12)),
                    ),
                    const SizedBox(width: 12),
                    Text(duration(v.duration.inMilliseconds),
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
