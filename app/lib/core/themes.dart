import 'package:flutter/material.dart';

/// One look per character. Edge-glow colours follow the assistant state.
class TommyTheme {
  final String id;
  final String label;
  final Color primary;
  final Color background;
  final List<Color> glow; // cycled while speaking
  final String characterAsset;

  const TommyTheme({
    required this.id,
    required this.label,
    required this.primary,
    required this.background,
    required this.glow,
  }) : characterAsset = 'assets/characters/$id.jpg';
}

const tommyThemes = <TommyTheme>[
  TommyTheme(id: 'crimson', label: 'Crimson', primary: Color(0xFFE5243B), background: Color(0xFF0B0507),
      glow: [Color(0xFFE5243B), Color(0xFF3D5AFE), Color(0xFFFF9100), Color(0xFF00E676)]),
  TommyTheme(id: 'violet', label: 'Violet', primary: Color(0xFFB04DFF), background: Color(0xFF0A0612),
      glow: [Color(0xFFB04DFF), Color(0xFF7C4DFF), Color(0xFFFF4081), Color(0xFF18FFFF)]),
  TommyTheme(id: 'aqua', label: 'Aqua', primary: Color(0xFF00E5FF), background: Color(0xFF02090C),
      glow: [Color(0xFF00E5FF), Color(0xFF2979FF), Color(0xFF1DE9B6), Color(0xFFEEFF41)]),
  TommyTheme(id: 'sakura', label: 'Sakura', primary: Color(0xFFFF6FAE), background: Color(0xFF10060B),
      glow: [Color(0xFFFF6FAE), Color(0xFFFFAB40), Color(0xFFEA80FC), Color(0xFF84FFFF)]),
  TommyTheme(id: 'gold', label: 'Gold', primary: Color(0xFFFFC400), background: Color(0xFF0C0902),
      glow: [Color(0xFFFFC400), Color(0xFFFF6D00), Color(0xFFFFFF00), Color(0xFFFF1744)]),
  TommyTheme(id: 'emerald', label: 'Emerald', primary: Color(0xFF00E676), background: Color(0xFF020B06),
      glow: [Color(0xFF00E676), Color(0xFF76FF03), Color(0xFF00B0FF), Color(0xFFFFEA00)]),
];

TommyTheme themeById(String id) =>
    tommyThemes.firstWhere((t) => t.id == id, orElse: () => tommyThemes.first);

ThemeData materialThemeFor(TommyTheme t) {
  final scheme = ColorScheme.fromSeed(seedColor: t.primary, brightness: Brightness.dark)
      .copyWith(primary: t.primary, surface: t.background);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: t.background,
    useMaterial3: true,
    fontFamilyFallback: const ['Noto Sans Bengali', 'Nirmala UI', 'Noto Sans Devanagari'],
  );
}
