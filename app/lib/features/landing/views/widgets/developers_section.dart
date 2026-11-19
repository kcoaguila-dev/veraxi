import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';

/// Points developers at the MCP tools and the `vx` command-line tool.
class DevelopersSection extends StatelessWidget {
  const DevelopersSection({super.key});

  @override
  Widget build(BuildContext context) {
    return LandingColumn(
      top: LandingLayout.sectionGap(context),
      bottom: LandingLayout.sectionGap(context),
      child: const LandingColumns(
        gap: 48,
        children: [
          _Intro(),
          _ToolList(),
        ],
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LandingHeading('Call it from your own agent'),
        SizedBox(height: 16),
        LandingBody(
          'Veraxi offers its search as tools over the Model Context '
          'Protocol, so any MCP client can use them. The vx command does the '
          'same from a terminal: vx chat, vx trace and vx stats.',
          size: 18,
          maxWidth: 520,
        ),
      ],
    );
  }
}

class _ToolList extends StatelessWidget {
  const _ToolList();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Tool(
          name: 'mcp_merge_rank',
          description:
              'Search by meaning and by connection at once, merged into one '
              'ranked list.',
        ),
        SizedBox(height: 24),
        _Tool(
          name: 'mcp_query_graph',
          description:
              'Follow relationships from a known entity across several steps.',
        ),
        SizedBox(height: 24),
        _Tool(
          name: 'mcp_agentic_debate',
          description:
              'Research a hard question with specialist agents and a skeptic '
              'that sends unsupported claims back for revision. Takes 15 to '
              '30 seconds.',
        ),
      ],
    );
  }
}

class _Tool extends StatelessWidget {
  final String name;
  final String description;

  const _Tool({required this.name, required this.description});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style:
              LandingType.mono(size: 16).copyWith(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
        LandingBody(description, maxWidth: 520),
      ],
    );
  }
}
