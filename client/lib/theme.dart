import 'package:flutter/material.dart';

/// The instrument palette, taken verbatim from the C++ client's Theme.qml.
///
/// ⚠️ THE SAME TOKENS ON PURPOSE. This experiment is testing Go and Flutter, not
/// a new look - if the panel came out a different colour, every judgement about
/// "does this feel better" would be about the paint rather than the platform.
class T {
  static const ground = Color(0xFF0E1013);
  static const panel = Color(0xFF171A1F);
  static const panelDeep = Color(0xFF141619);
  static const line = Color(0xFF2A3038);
  static const text = Color(0xFFE8EAED);
  static const dim = Color(0xFF8A929C);
  static const amber = Color(0xFFFFB020);
  static const amberDim = Color(0xFF8A6320);
  static const cyan = Color(0xFF3B82F6);
  static const cyanFill = Color(0xFF1E3A6B);
  static const txRed = Color(0xFFB4232A);
  static const okGreen = Color(0xFF32C765);

  static const mono = 'monospace';

  static TextStyle silk() => const TextStyle(
      color: dim, fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w600);
}
