import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/store.dart';
import '../theme.dart';

/// Round avatar: photo if [fileId] is set, otherwise colored initials.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    required this.seed,
    this.fileId,
    this.size = 54,
  });

  final String name;
  final int seed;
  final String? fileId;
  final double size;

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    final letters = parts.take(2).map((p) => p.characters.first.toUpperCase());
    return parts.length == 1 ? letters.first : letters.join();
  }

  @override
  Widget build(BuildContext context) {
    final color = Fg.avatarColors[seed.abs() % Fg.avatarColors.length];
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        initials(name),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.36,
        ),
      ),
    );
    final api = context.read<AppStore>().api;
    if (fileId == null || api == null) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: api.fileUrl(fileId!),
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}
