import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';

/// Displays a single agent tool invocation inline in the chat stream.
///
/// Shows a spinner while running, a success/error icon on completion,
/// and expands to reveal the full output when tapped.
class ToolEventCard extends StatefulWidget {
  const ToolEventCard({super.key, required this.event});

  final ToolEvent event;

  @override
  State<ToolEventCard> createState() => _ToolEventCardState();
}

class _ToolEventCardState extends State<ToolEventCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _rotateController;

  @override
  void initState() {
    super.initState();
    _rotateController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void dispose() {
    _rotateController.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _rotateController.forward();
    } else {
      _rotateController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final isComplete = event.isComplete;
    final result = event.result;

    // Friendly name and retrieval metadata shown in the pill
    final label = _friendlyLabel(event.name);
    final meta = _summarizeResultMeta(result);
    final subtitle = _buildMetadataSubtitle(event, meta);

    // Determine icon / colour from result content
    final isError = result is String && result.startsWith('Error:');
    final Color accentColor = isError
        ? Colors.redAccent
        : isComplete
            ? Colors.greenAccent.shade400
            : Colors.blueAccent;

    final Widget statusIcon = isComplete
        ? Icon(
            isError
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 14,
            color: accentColor,
          )
        : SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation(accentColor),
            ),
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row (always visible) ───────────────────────────────
              InkWell(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                onTap: isComplete && result != null ? _toggle : null,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(
                    children: [
                      statusIcon,
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.85),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (subtitle != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  subtitle,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withValues(alpha: 0.55),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (isComplete) ...[
                        for (final leg in meta.legs)
                          if (leg == 'Vector' || leg == 'Graph')
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: _ChannelBadge(leg: leg),
                            ),
                      ],
                      if (isComplete && event.durationMs != null)
                        Tooltip(
                          message:
                              'Worked for ${event.durationMs! < 1000 ? "${event.durationMs}ms" : "${(event.durationMs! / 1000.0).toStringAsFixed(1)}s"}',
                          child: Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.12),
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.timer_outlined,
                                  size: 10,
                                  color: Colors.white.withValues(alpha: 0.5),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  event.durationMs! < 1000
                                      ? '${event.durationMs}ms'
                                      : '${(event.durationMs! / 1000.0).toStringAsFixed(1)}s',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white.withValues(alpha: 0.65),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (isComplete && result != null)
                        RotationTransition(
                          turns: Tween(begin: 0.0, end: 0.5)
                              .animate(_rotateController),
                          child: Icon(
                            Icons.expand_more_rounded,
                            size: 16,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // ── Expanded result ───────────────────────────────────────────
              if (_expanded && result != null)
                _ResultPanel(result: result.toString()),
            ],
          ),
        ),
      ),
    );
  }

  static String _friendlyLabel(String toolName) {
    final normalized =
        toolName.startsWith('mcp_') ? toolName.substring(4) : toolName;
    switch (normalized) {
      case 'read_file':
        return 'Reading file';
      case 'write_file':
        return 'Writing file';
      case 'list_files':
        return 'Listing files';
      case 'run_shell':
        return 'Running shell command';
      case 'open_app':
        return 'Opening app';
      case 'web_search':
      case 'ephemeral_web_rag':
        return 'Web Search';
      case 'build_lazy_dossier':
        return 'Causal Graph Dossier';
      case 'purge_noisy_relationships':
        return 'Purging noisy graph edges';
      case 'search_vectors':
        return 'Hybrid Vector Search';
      case 'query_graph':
        return 'Knowledge Graph Traversal';
      case 'merge_rank':
        return 'Hybrid RRF Fusion & Rerank';
      case 'code_symbol':
      case 'code_impact':
      case 'code_overview':
        return 'Code Graph X-Ray';
      case 'agentic_debate':
        return 'Multi-Agent Debate';
      default:
        return toolName;
    }
  }

  static String? _extractQueryArg(Map<String, dynamic> args) {
    const keys = [
      'query_text',
      'query',
      'entity_name',
      'name',
      'symbol',
      'task',
    ];
    for (final key in keys) {
      final val = args[key];
      if (val is String && val.trim().isNotEmpty) {
        return val.trim();
      }
    }
    return null;
  }

  static List<dynamic>? _decodeResultItems(dynamic result) {
    dynamic decoded = result;
    if (result is String) {
      final trimmed = result.trimLeft();
      if (!trimmed.startsWith('[') && !trimmed.startsWith('{')) return null;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        return null;
      }
    }
    if (decoded is List) return decoded;
    if (decoded is Map && decoded['chunks'] is List) {
      return decoded['chunks'] as List;
    }
    return null;
  }

  static void _collectLeg(String raw, List<String> legs) {
    final normalized = raw.toLowerCase();
    String? label;
    if (normalized == 'vector') label = 'Vector';
    if (normalized == 'sparse') label = 'Sparse';
    if (normalized == 'graph') label = 'Graph';
    if (label != null && !legs.contains(label)) legs.add(label);
  }

  static ({int? count, List<String> legs}) _summarizeResultMeta(
      dynamic result) {
    if (result == null) return (count: null, legs: const []);
    final items = _decodeResultItems(result);
    if (items == null) return (count: null, legs: const []);
    final legs = <String>[];
    for (final item in items) {
      if (item is! Map) continue;
      final prov = item['provenance'];
      final rawLegs = prov is Map ? prov['legs'] : item['sources'];
      if (rawLegs is List) {
        for (final leg in rawLegs) {
          if (leg is String) _collectLeg(leg, legs);
        }
      }
    }
    return (count: items.length, legs: legs);
  }

  static String? _buildMetadataSubtitle(
    ToolEvent event,
    ({int? count, List<String> legs}) meta,
  ) {
    final queryArg = _extractQueryArg(event.args);
    final parts = <String>[
      if (queryArg != null) '"$queryArg"',
      if (event.isComplete && meta.count != null)
        '${meta.count} ${meta.count == 1 ? 'result' : 'results'}',
      if (event.isComplete && meta.legs.isNotEmpty) meta.legs.join(' + '),
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    if (event.isComplete &&
        event.summary != null &&
        event.summary!.isNotEmpty) {
      return event.summary;
    }
    return null;
  }
}

class _ChannelBadge extends StatelessWidget {
  const _ChannelBadge({required this.leg});

  final String leg;

  @override
  Widget build(BuildContext context) {
    final color = leg == 'Graph'
        ? const Color(0xFFD98A2B)
        : const Color(0xFF4F8EF7);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 0.7),
      ),
      child: Text(
        leg,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _ResultPanel extends StatefulWidget {
  const _ResultPanel({required this.result});
  final String result;

  @override
  State<_ResultPanel> createState() => _ResultPanelState();
}

class _ResultPanelState extends State<_ResultPanel> {
  bool _showRaw = false;

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? dossier;
    try {
      final decoded = jsonDecode(widget.result);
      if (decoded is Map<String, dynamic> && decoded.containsKey('chunks')) {
        dossier = decoded;
      }
    } catch (_) {}

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Copy & Toggle Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (dossier != null)
                GestureDetector(
                  onTap: () => setState(() => _showRaw = !_showRaw),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _showRaw
                            ? Icons.visibility_off_outlined
                            : Icons.code_rounded,
                        size: 13,
                        color: Colors.blueAccent.shade100,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _showRaw ? 'Show Briefing Cards' : 'View Raw JSON',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.blueAccent.shade100,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              else
                const SizedBox.shrink(),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: widget.result));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied to clipboard'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy_rounded,
                        size: 12, color: Colors.white.withValues(alpha: 0.5)),
                    const SizedBox(width: 4),
                    Text(
                      'Copy',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.5)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (dossier != null && !_showRaw)
            _DossierView(dossier: dossier)
          else
            SelectableText(
              widget.result,
              style: const TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: Colors.white70,
                height: 1.5,
              ),
            ),
        ],
      ),
    );
  }
}

class _DossierView extends StatelessWidget {
  const _DossierView({required this.dossier});
  final Map<String, dynamic> dossier;

  @override
  Widget build(BuildContext context) {
    final chunks = (dossier['chunks'] as List?) ?? [];
    final total = dossier['total_chunks_retrieved'] ?? chunks.length;

    // Collect all linked entities
    final allEntities = <Map<String, dynamic>>[];
    for (var chunk in chunks) {
      if (chunk is Map && chunk['linked_entities'] is List) {
        for (var ent in chunk['linked_entities']) {
          if (ent is Map && ent.containsKey('name')) {
            final name = ent['name'].toString();
            if (!allEntities.any((e) => e['name'] == name)) {
              allEntities.add({
                'name': name,
                'type': ent['type']?.toString() ?? 'Entity',
              });
            }
          }
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blueAccent.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '$total evidence chunks',
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (allEntities.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${allEntities.length} graph anchors',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.greenAccent.shade200,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
        if (allEntities.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: allEntities.take(12).map((e) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${e['name']} (${e['type']})',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white70,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
        const SizedBox(height: 8),
        ...chunks.take(3).map((ch) {
          if (ch is! Map) return const SizedBox.shrink();
          final title = ch['title']?.toString() ?? 'Passage';
          final text = ch['text']?.toString() ?? '';
          final preview =
              text.length > 140 ? '${text.substring(0, 140)}...' : text;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: Colors.white60,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}
