import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// A placed node in the AR scene.
class ArNode {
  final String id;
  String name;
  bool selected;

  ArNode({required this.id, required this.name, this.selected = false});
}

/// AR screen with node management.
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

  // Flow 2 Phase 4: Confidence + Dead Reckoning
  double _confidence = 0.0;
  bool _frozen = false;
  double _timeSinceAnchor = 0.0;
  double _pathLength = 0.0;
  int _trackingAnchors = 0;
  bool _qrVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
        setState(() {
          _tracked = true;
          _qrVisible = true;
          _confidence = 1.0;
          _status = '✓ QR detected — origin locked';
        });
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

                const SizedBox(width: 12),

                // Selected node actions
                if (selectedNode != null) ...[
                  // Rename
                  _actionButton(
                    icon: Icons.edit,
                    label: 'Rename',
                    color: Colors.blue,
                    onTap: () => _renameNode(selectedNode),
                  ),
                  const SizedBox(width: 8),
                  // Delete
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
