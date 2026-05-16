import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Stores the AR map: nodes + QR anchor relationships.
///
/// When user scans QR_001 (primary) then walks to QR_002 and scans it,
/// the system records: "QR_002 is at position (x,y,z) relative to QR_001".
/// Next session, scanning QR_002 alone is enough to restore the full map.
class MapStorageService {
  static const String _fileName = 'ar_map_data.json';

  /// Save the full map state.
  static Future<void> saveMap(MapData data) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_fileName');
    final json = const JsonEncoder.withIndent('  ').convert(data.toJson());
    await file.writeAsString(json);
    debugPrint('[MapStorage] Saved: ${data.anchors.length} anchors, ${data.nodes.length} nodes');
  }

  /// Load saved map. Returns null if no map exists.
  static Future<MapData?> loadMap() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_fileName');
    if (!await file.exists()) return null;

    try {
      final json = await file.readAsString();
      final data = MapData.fromJson(jsonDecode(json) as Map<String, dynamic>);
      debugPrint('[MapStorage] Loaded: ${data.anchors.length} anchors, ${data.nodes.length} nodes');
      return data;
    } catch (e) {
      debugPrint('[MapStorage] Error loading: $e');
      return null;
    }
  }

  /// Check if a saved map exists.
  static Future<bool> hasMap() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_fileName');
    return file.exists();
  }

  /// Delete saved map.
  static Future<void> deleteMap() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_fileName');
    if (await file.exists()) await file.delete();
  }
}

/// Full map data — anchors + nodes.
class MapData {
  final String primaryQrId;
  final List<MapAnchor> anchors;
  final List<MapNode> nodes;
  final DateTime savedAt;

  MapData({
    required this.primaryQrId,
    required this.anchors,
    required this.nodes,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
    'version': 1,
    'primaryQrId': primaryQrId,
    'savedAt': savedAt.toIso8601String(),
    'anchors': anchors.map((a) => a.toJson()).toList(),
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };

  factory MapData.fromJson(Map<String, dynamic> json) {
    return MapData(
      primaryQrId: json['primaryQrId'] as String,
      savedAt: DateTime.parse(json['savedAt'] as String),
      anchors: (json['anchors'] as List)
          .map((a) => MapAnchor.fromJson(a as Map<String, dynamic>))
          .toList(),
      nodes: (json['nodes'] as List)
          .map((n) => MapNode.fromJson(n as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// A QR anchor with its position relative to primary origin.
class MapAnchor {
  final String qrId;       // QR content (e.g. "QR_ORIGIN_002")
  final bool isPrimary;
  final double x, y, z;   // position relative to primary origin (meters)
  final double qx, qy, qz, qw; // rotation quaternion relative to primary
  final DateTime registeredAt;

  MapAnchor({
    required this.qrId,
    required this.isPrimary,
    required this.x, required this.y, required this.z,
    required this.qx, required this.qy, required this.qz, required this.qw,
    required this.registeredAt,
  });

  Map<String, dynamic> toJson() => {
    'qrId': qrId,
    'isPrimary': isPrimary,
    'position': [x, y, z],
    'rotation': [qx, qy, qz, qw],
    'registeredAt': registeredAt.toIso8601String(),
  };

  factory MapAnchor.fromJson(Map<String, dynamic> json) {
    final pos = json['position'] as List;
    final rot = json['rotation'] as List;
    return MapAnchor(
      qrId: json['qrId'] as String,
      isPrimary: json['isPrimary'] as bool,
      x: (pos[0] as num).toDouble(),
      y: (pos[1] as num).toDouble(),
      z: (pos[2] as num).toDouble(),
      qx: (rot[0] as num).toDouble(),
      qy: (rot[1] as num).toDouble(),
      qz: (rot[2] as num).toDouble(),
      qw: (rot[3] as num).toDouble(),
      registeredAt: DateTime.parse(json['registeredAt'] as String),
    );
  }
}

/// A user-placed node with position relative to primary origin.
class MapNode {
  final String id;
  final String name;
  final double x, y, z;

  MapNode({
    required this.id,
    required this.name,
    required this.x, required this.y, required this.z,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'position': [x, y, z],
  };

  factory MapNode.fromJson(Map<String, dynamic> json) {
    final pos = json['position'] as List;
    return MapNode(
      id: json['id'] as String,
      name: json['name'] as String,
      x: (pos[0] as num).toDouble(),
      y: (pos[1] as num).toDouble(),
      z: (pos[2] as num).toDouble(),
    );
  }
}
