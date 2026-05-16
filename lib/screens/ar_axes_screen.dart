import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:qr_origin/services/map_storage_service.dart';

/// A placed node in the AR scene.
class ArNode {
  final String id;
  String name;
  bool selected;

  ArNode({required this.id, required this.name, this.selected = false});
}

/// AR screen with node management + map save/load.
class ArAxesScreen extends StatefulWidget {
  const ArAxesScreen({super.key});

  @override
  State<ArAxesScreen> createState() => _ArAxesScreenState();
}

class _ArAxesScreenState extends State<ArAxesScreen> with WidgetsBindingObserver {
  String _status = 'Initializing ARCore...';
  bool _tracked = false;
  MethodChannel? _channel;

  // Node management
  final List<ArNode> _nodes = [];
  int _nodeCounter = 0;

  // Multi-anchor: dynamically registered QR anchors
  final List<MapAnchor> _registeredAnchors = [];
  String? _primaryQrId;
  String? _lastDetectedQrId;

  // Flow 2 Phase 4: Confidence + Dead Reckoning
  double _confidence = 0.0;
  bool _frozen = false;
  double _timeSinceAnchor = 0.0;
  double _pathLength = 0.0;
  int _trackingAnchors = 0;
  bool _qrVisible = false;

  // Map saved state
  bool _mapSaved = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedMap();
  }

  Future<void> _loadSavedMap() async {
    final map = await MapStorageService.loadMap();
    if (map != null) {
      setState(() {
        _registeredAnchors.addAll(map.anchors);
        _primaryQrId = map.primaryQrId;
        for (final node in map.nodes) {
          _nodeCounter++;
          _nodes.add(ArNode(id: node.id, name: node.name));
        }
        _mapSaved = true;
        _status = 'Map loaded (${map.anchors.length} anchors). Scan any QR...';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('qr_origin/ar_view_$id');
    _channel!.setMethodCallHandler((call) async {
      if (call.method == 'onImageTracked') {
        final data = call.arguments;
        String qrId = 'unknown';
        if (data is Map) {
          qrId = (data['name'] as String?) ?? 'unknown';
        }
        setState(() {
          _tracked = true;
          _qrVisible = true;
          _confidence = 1.0;
          _lastDetectedQrId = qrId;
          _primaryQrId ??= qrId;
          _status = '✓ QR "$qrId" detected — origin locked';
        });

        // Auto-register this QR if not known
        if (!_registeredAnchors.any((a) => a.qrId == qrId)) {
          _registeredAnchors.add(MapAnchor(
            qrId: qrId,
            isPrimary: _registeredAnchors.isEmpty,
            x: 0, y: 0, z: 0,
            qx: 0, qy: 0, qz: 0, qw: 1,
            registeredAt: DateTime.now(),
          ));
        }
      } else if (call.method == 'onConfidenceUpdate') {
        final data = Map<String, dynamic>.from(call.arguments as Map);
        setState(() {
          _confidence = (data['confidence'] as num).toDouble();
          _timeSinceAnchor = (data['timeSinceAnchorSec'] as num).toDouble();
          _pathLength = (data['pathLengthM'] as num).toDouble();
          _qrVisible = data['qrVisible'] as bool;
          _frozen = data['frozen'] as bool;
          _trackingAnchors = (data['trackingAnchors'] as num).toInt();

          if (_qrVisible) {
            _status = '✓ QR visible — full accuracy';
          } else if (_frozen) {
            _status = '⚠ FROZEN — return to reference point';
          } else if (_confidence < 0.4) {
            _status = '⚠ Low confidence — look at a landmark';
          } else if (_confidence < 0.7) {
            _status = 'Tracking via VIO (${(_confidence * 100).toInt()}%)';
          } else {
            _status = '✓ Tracking stable (${(_confidence * 100).toInt()}%)';
          }
        });
      } else if (call.method == 'onDeadReckoningFreeze') {
        final frozen = call.arguments as bool;
        setState(() {
          _frozen = frozen;
          if (frozen) {
            _status = '⚠ POSITION STALE — return to QR code';
          } else {
            _status = '✓ Tracking recovered';
          }
        });
      }
    });
    setState(() => _status = 'Camera ready. Point at QR code...');
  }

  // --- Map Save ---

  Future<void> _saveMap() async {
    // Get real node positions from native
    final nodes = <MapNode>[];
    try {
      final result = await _channel?.invokeMethod('getNodePositions');
      if (result != null) {
        final positions = Map<String, dynamic>.from(result as Map);
        for (final node in _nodes) {
          final pos = positions[node.id];
          if (pos != null) {
            final p = Map<String, dynamic>.from(pos as Map);
            nodes.add(MapNode(
              id: node.id, name: node.name,
              x: (p['x'] as num).toDouble(),
              y: (p['y'] as num).toDouble(),
              z: (p['z'] as num).toDouble(),
            ));
          }
        }
      }
    } catch (e) {
      // Fallback: save with 0,0,0
      for (final node in _nodes) {
        nodes.add(MapNode(id: node.id, name: node.name, x: 0, y: 0, z: 0));
      }
    }

    final primary = _primaryQrId ?? _lastDetectedQrId ?? 'unknown';

    if (_registeredAnchors.isEmpty && _lastDetectedQrId != null) {
      _registeredAnchors.add(MapAnchor(
        qrId: _lastDetectedQrId!,
        isPrimary: true,
        x: 0, y: 0, z: 0,
        qx: 0, qy: 0, qz: 0, qw: 1,
        registeredAt: DateTime.now(),
      ));
    }

    final mapData = MapData(
      primaryQrId: primary,
      anchors: _registeredAnchors,
      nodes: nodes,
      savedAt: DateTime.now(),
    );

    await MapStorageService.saveMap(mapData);
    setState(() => _mapSaved = true);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ Map saved: ${_registeredAnchors.length} anchors, ${nodes.length} nodes'),
          backgroundColor: Colors.green.shade700,
        ),
      );
    }
  }

  Future<void> _loadMap() async {
    final map = await MapStorageService.loadMap();
    if (map == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No saved map found'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() {
      _registeredAnchors.clear();
      _registeredAnchors.addAll(map.anchors);
      _primaryQrId = map.primaryQrId;
      _nodes.clear();
      _nodeCounter = 0;
      for (final node in map.nodes) {
        _nodeCounter++;
        _nodes.add(ArNode(id: node.id, name: node.name));
      }
      _mapSaved = true;
      _status = 'Map loaded: ${map.anchors.length} anchors, ${map.nodes.length} nodes. Scan any QR to sync.';
    });

    // Reload nodes in native with saved positions
    for (final node in map.nodes) {
      _channel?.invokeMethod('addNode', {
        'id': node.id,
        'name': node.name,
        'x': node.x,
        'y': node.y,
        'z': node.z,
      });
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ Map loaded: ${map.anchors.length} anchors, ${map.nodes.length} nodes'),
          backgroundColor: Colors.blue.shade700,
        ),
      );
    }
  }

  // --- Node Actions ---

  void _addNode() {
    _nodeCounter++;
    final id = 'node_$_nodeCounter';
    final name = 'Node $_nodeCounter';

    // Send to native to place 3D sphere
    _channel?.invokeMethod('addNode', {
      'id': id,
      'name': name,
    });

    setState(() {
      // Deselect all others
      for (final n in _nodes) {
        n.selected = false;
      }
      _nodes.add(ArNode(id: id, name: name, selected: true));
      _status = 'Node "$name" placed';
    });
  }

  void _selectNode(ArNode node) {
    setState(() {
      for (final n in _nodes) {
        n.selected = false;
      }
      node.selected = true;
    });

    // Tell native to highlight this node (red) and unhighlight others
    _channel?.invokeMethod('selectNode', {'id': node.id});
  }

  void _deleteNode(ArNode node) {
    _channel?.invokeMethod('deleteNode', {'id': node.id});
    setState(() {
      _nodes.remove(node);
      _status = 'Node "${node.name}" deleted';
    });
  }

  void _renameNode(ArNode node) {
    final controller = TextEditingController(text: node.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('Rename Node', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Enter name',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white30),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.green),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                setState(() => node.name = newName);
                _channel?.invokeMethod('renameNode', {
                  'id': node.id,
                  'name': newName,
                });
              }
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedNode = _nodes.where((n) => n.selected).firstOrNull;

    return Scaffold(
      body: Stack(
        children: [
          // Native ARCore view
          SizedBox.expand(
            child: PlatformViewLink(
              viewType: 'arcore_axes_view',
              surfaceFactory: (context, controller) {
                return AndroidViewSurface(
                  controller: controller as AndroidViewController,
                  gestureRecognizers: const {},
                  hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                );
              },
              onCreatePlatformView: (params) {
                return PlatformViewsService.initExpensiveAndroidView(
                  id: params.id,
                  viewType: 'arcore_axes_view',
                  layoutDirection: TextDirection.ltr,
                  onFocus: () => params.onFocusChanged(true),
                )
                  ..addOnPlatformViewCreatedListener((id) {
                    params.onPlatformViewCreated(id);
                    _onPlatformViewCreated(id);
                  })
                  ..create();
              },
            ),
          ),

          // Status bar
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _statusColor,
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(_statusIcon, color: _statusColor, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_status,
                            style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    ],
                  ),
                  if (_tracked) ...[
                    const SizedBox(height: 6),
                    // Confidence bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: _confidence,
                        backgroundColor: Colors.white12,
                        valueColor: AlwaysStoppedAnimation(_confidenceBarColor),
                        minHeight: 4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${(_confidence * 100).toInt()}% conf',
                          style: TextStyle(color: _confidenceBarColor, fontSize: 9),
                        ),
                        Text(
                          '${_trackingAnchors} anchors',
                          style: const TextStyle(color: Colors.white38, fontSize: 9),
                        ),
                        Text(
                          '${_pathLength.toStringAsFixed(1)}m walked',
                          style: const TextStyle(color: Colors.white38, fontSize: 9),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Dead reckoning freeze overlay
          if (_frozen)
            Positioned.fill(
              child: Container(
                color: Colors.red.withAlpha(40),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.red, width: 2),
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.warning_amber, color: Colors.red, size: 48),
                        SizedBox(height: 12),
                        Text('POSITION DATA STALE',
                            style: TextStyle(color: Colors.red, fontSize: 18, fontWeight: FontWeight.bold)),
                        SizedBox(height: 8),
                        Text('Return to QR code or a known landmark\nto restore accurate tracking.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Node list (left side)
          if (_nodes.isNotEmpty)
            Positioned(
              top: MediaQuery.of(context).padding.top + 80,
              left: 12,
              child: Container(
                width: 160,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(200),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: _nodes.length,
                  itemBuilder: (ctx, i) => _buildNodeItem(_nodes[i]),
                ),
              ),
            ),

          // Bottom toolbar
          Positioned(
            bottom: 32,
            left: 16,
            right: 16,
            child: Row(
              children: [
                // Add node button
                FloatingActionButton(
                  heroTag: 'add_node',
                  onPressed: (_tracked && !_frozen) ? _addNode : null,
                  backgroundColor: (_tracked && !_frozen) ? Colors.green : Colors.grey,
                  child: const Icon(Icons.add_location_alt, color: Colors.white),
                ),

                const SizedBox(width: 8),

                // Save map button
                FloatingActionButton.small(
                  heroTag: 'save_map',
                  onPressed: _tracked ? _saveMap : null,
                  backgroundColor: _tracked ? Colors.blue : Colors.grey,
                  child: Icon(
                    _mapSaved ? Icons.cloud_done : Icons.save,
                    color: Colors.white, size: 20,
                  ),
                ),

                const SizedBox(width: 4),

                // Load map button
                FloatingActionButton.small(
                  heroTag: 'load_map',
                  onPressed: _loadMap,
                  backgroundColor: Colors.orange,
                  child: const Icon(Icons.folder_open, color: Colors.white, size: 20),
                ),

                const SizedBox(width: 12),

                // Selected node actions
                if (selectedNode != null) ...[
                  _actionButton(
                    icon: Icons.edit,
                    label: 'Rename',
                    color: Colors.blue,
                    onTap: () => _renameNode(selectedNode),
                  ),
                  const SizedBox(width: 8),
                  _actionButton(
                    icon: Icons.delete,
                    label: 'Delete',
                    color: Colors.red,
                    onTap: () => _deleteNode(selectedNode),
                  ),
                ],

                const Spacer(),

                // Node count
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${_nodes.length} nodes',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNodeItem(ArNode node) {
    return GestureDetector(
      onTap: () => _selectNode(node),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: node.selected ? Colors.red.withAlpha(60) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: node.selected ? Colors.red : Colors.white24,
            width: node.selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.circle,
              size: 12,
              color: node.selected ? Colors.red : Colors.green,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.name,
                style: TextStyle(
                  color: node.selected ? Colors.red : Colors.white,
                  fontSize: 12,
                  fontWeight: node.selected ? FontWeight.bold : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(40),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  // --- Status helpers ---

  Color get _statusColor {
    if (_frozen) return Colors.red;
    if (!_tracked) return Colors.orange;
    if (_qrVisible) return Colors.green;
    if (_confidence > 0.7) return Colors.green;
    if (_confidence > 0.4) return Colors.amber;
    return Colors.red;
  }

  IconData get _statusIcon {
    if (_frozen) return Icons.warning_amber;
    if (!_tracked) return Icons.qr_code_scanner;
    if (_qrVisible) return Icons.check_circle;
    if (_confidence > 0.7) return Icons.check_circle;
    if (_confidence > 0.4) return Icons.info_outline;
    return Icons.warning_amber;
  }

  Color get _confidenceBarColor {
    if (_confidence > 0.7) return Colors.green;
    if (_confidence > 0.4) return Colors.amber;
    return Colors.red;
  }
}
