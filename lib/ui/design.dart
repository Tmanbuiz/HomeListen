import 'package:flutter/material.dart';

const mint = Color(0xFF4FD1C5);
const coral = Color(0xFFED525D);

class HomeListenTheme {
  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: mint,
      brightness: brightness,
      primary: dark ? mint : const Color(0xFF087E73),
      surface: dark ? const Color(0xFF101A1D) : Colors.white,
      error: dark ? const Color(0xFFFF7A82) : const Color(0xFFBA2536),
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF070C0E)
          : const Color(0xFFF6F9F8),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
      ),
    );
  }
}

class HomeListenMark extends StatelessWidget {
  const HomeListenMark({super.key, this.size = 36, this.tile = false});
  final double size;
  final bool tile;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Home Listen',
    image: true,
    child: Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(tile ? size * 0.19 : 0),
      decoration: tile
          ? BoxDecoration(
              color: const Color(0xFF070C0E),
              borderRadius: BorderRadius.circular(size * 0.24),
            )
          : null,
      child: CustomPaint(
        painter: _MarkPainter(
          tile ? mint : Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.105
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(size.width * .12, size.height * .40)
        ..lineTo(size.width * .5, size.height * .1)
        ..lineTo(size.width * .88, size.height * .40),
      paint,
    );
    for (final x in [.32, .5, .68]) {
      final central = x == .5;
      canvas.drawLine(
        Offset(size.width * x, size.height * (central ? .45 : .57)),
        Offset(size.width * x, size.height * (central ? .89 : .79)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.borderColor,
    this.padding = 20,
  });
  final Widget child;
  final Color? borderColor;
  final double padding;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: BorderSide(
        color:
            borderColor ??
            Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .5),
      ),
    ),
    child: Padding(padding: EdgeInsets.all(padding), child: child),
  );
}

class SoundWave extends StatelessWidget {
  const SoundWave({super.key, required this.levels, required this.active});
  final List<double> levels;
  final bool active;
  @override
  Widget build(BuildContext context) => Semantics(
    label: active ? 'Live sound activity' : 'No live audio',
    child: SizedBox(
      height: 84,
      width: double.infinity,
      child: CustomPaint(
        painter: _WavePainter(
          levels,
          active,
          Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.levels, this.active, this.color);
  final List<double> levels;
  final bool active;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final step = size.width / levels.length;
    final paint = Paint()
      ..color = color.withValues(alpha: active ? 1 : .22)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (step * .44).clamp(2, 6);
    for (var i = 0; i < levels.length; i++) {
      final height = active ? 5 + levels[i] * (size.height - 10) : 5.0;
      canvas.drawLine(
        Offset(step * (i + .5), (size.height - height) / 2),
        Offset(step * (i + .5), (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}
