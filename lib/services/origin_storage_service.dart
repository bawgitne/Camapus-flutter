import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:qr_origin/models/world_origin.dart';

/// Persistent storage for world origins.
///
/// Design principles:
/// - Origins stored as 4×4 matrix (never euler angles)
/// - All object poses stored relative to origin (never absolute)
/// - Supports multiple QR codes (each has its own origin)
/// - Keeps history for comparison/debugging
/// - File-based storage (no external DB dependency)
///
/// Storage format: JSON file per QR ID, plus a manifest.
class OriginStorageService {
  final String _storagePath;

  OriginStorageService({required String storagePath})
      : _storagePath = storagePath;

  // --- Public API ---

  /// Save a new origin. Overwrites any existing origin for the same QR ID.
  /// Also appends to history for debugging.
  Future<void> saveOrigin(WorldOrigin origin) async {
    // Save current origin
    final file = _getOriginFile(origin.qrId);
    await file.writeAsString(origin.toJsonString());

    // Append to history
    await _appendToHistory(origin);

    // Update manifest
    await _updateManifest(origin);

    debugPrint('[Storage] Saved origin for QR: ${origin.qrId}');
  }

  /// Load the most recent origin for a given QR ID.
  /// Returns null if no origin has been saved for this QR.
  Future<WorldOrigin?> loadOrigin(String qrId) async {
    final file = _getOriginFile(qrId);
    if (!await file.exists()) return null;

    try {
      final jsonStr = await file.readAsString();
      return WorldOrigin.fromJsonString(jsonStr);
    } catch (e) {
      debugPrint('[Storage] Error loading origin for $qrId: $e');
      return null;
    }
  }

  /// Load all saved origins (one per QR ID).
  Future<List<WorldOrigin>> loadAllOrigins() async {
    final manifest = await _loadManifest();
    final origins = <WorldOrigin>[];

    for (final qrId in manifest.keys) {
      final origin = await loadOrigin(qrId);
      if (origin != null) origins.add(origin);
    }

    return origins;
  }

  /// Get the history of origins for a QR ID (for debugging/comparison).
  Future<List<WorldOrigin>> loadHistory(String qrId) async {
    final file = _getHistoryFile(qrId);
    if (!await file.exists()) return [];

    try {
      final content = await file.readAsString();
      final lines = content.split('\n').where((l) => l.isNotEmpty);
      return lines.map((l) => WorldOrigin.fromJsonString(l)).toList();
    } catch (e) {
      debugPrint('[Storage] Error loading history for $qrId: $e');
      return [];
    }
  }

  /// Compare current origin with the last saved one for the same QR.
  /// Returns null if no previous origin exists.
  Future<OriginComparison?> compareWithPrevious(WorldOrigin current) async {
    final previous = await loadOrigin(current.qrId);
    if (previous == null) return null;

    return OriginComparison(
      current: current,
      previous: previous,
      positionDiffMm: current.positionDifference(previous) * 1000,
      rotationDiffDeg: current.rotationDifference(previous),
      timeDelta: current.timestamp.difference(previous.timestamp),
    );
  }

  /// Delete all stored data for a QR ID.
  Future<void> deleteOrigin(String qrId) async {
    final originFile = _getOriginFile(qrId);
    final historyFile = _getHistoryFile(qrId);

    if (await originFile.exists()) await originFile.delete();
    if (await historyFile.exists()) await historyFile.delete();

    // Update manifest
    final manifest = await _loadManifest();
    manifest.remove(qrId);
    await _saveManifest(manifest);
  }

  /// Delete all stored origins.
  Future<void> clearAll() async {
    final dir = Directory(_storagePath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
  }

  /// Export all data as a single JSON string (for sharing/debugging).
  Future<String> exportAll() async {
    final origins = await loadAllOrigins();
    final data = {
      'exportDate': DateTime.now().toIso8601String(),
      'originCount': origins.length,
      'origins': origins.map((o) => o.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  // --- Private Helpers ---

  File _getOriginFile(String qrId) {
    final sanitized = _sanitizeFilename(qrId);
    return File('$_storagePath/origins/$sanitized.json');
  }

  File _getHistoryFile(String qrId) {
    final sanitized = _sanitizeFilename(qrId);
    return File('$_storagePath/history/$sanitized.jsonl');
  }

  File get _manifestFile => File('$_storagePath/manifest.json');

  Future<void> _appendToHistory(WorldOrigin origin) async {
    final file = _getHistoryFile(origin.qrId);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${origin.toJsonString()}\n',
      mode: FileMode.append,
    );
  }

  Future<void> _updateManifest(WorldOrigin origin) async {
    final manifest = await _loadManifest();
    manifest[origin.qrId] = {
      'lastUpdated': origin.timestamp.toIso8601String(),
      'confidence': origin.confidence,
      'frameCount': origin.frameCount,
    };
    await _saveManifest(manifest);
  }

  Future<Map<String, dynamic>> _loadManifest() async {
    if (!await _manifestFile.exists()) return {};
    try {
      final content = await _manifestFile.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      return {};
    }
  }

  Future<void> _saveManifest(Map<String, dynamic> manifest) async {
    await _manifestFile.parent.create(recursive: true);
    await _manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  String _sanitizeFilename(String input) {
    return input.replaceAll(RegExp(r'[^\w\-.]'), '_');
  }
}

/// Result of comparing two origins for the same QR code.
class OriginComparison {
  final WorldOrigin current;
  final WorldOrigin previous;

  /// Positional difference in millimeters.
  final double positionDiffMm;

  /// Rotational difference in degrees.
  final double rotationDiffDeg;

  /// Time between the two scans.
  final Duration timeDelta;

  const OriginComparison({
    required this.current,
    required this.previous,
    required this.positionDiffMm,
    required this.rotationDiffDeg,
    required this.timeDelta,
  });

  /// Whether the two origins are consistent (within 5mm target).
  bool get isConsistent => positionDiffMm < 5.0 && rotationDiffDeg < 1.0;

  @override
  String toString() => 'OriginComparison('
      'Δpos=${positionDiffMm.toStringAsFixed(2)}mm, '
      'Δrot=${rotationDiffDeg.toStringAsFixed(2)}°, '
      'Δt=${timeDelta.inMinutes}min, '
      'consistent=$isConsistent)';
}
