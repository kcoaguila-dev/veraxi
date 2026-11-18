import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/repo_xray_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_intel_panel.dart';

/// Code Intel workbench section (Knowledge Hub): Repo X-Ray and
/// Vuln Intel panels sharing one repository-path field state.
///
/// Design contracts: docs/design/repo_xray_panel.svg and
/// docs/design/vuln_intel_panel.svg.
class CodeIntelSection extends StatefulWidget {
  const CodeIntelSection({super.key});

  @override
  State<CodeIntelSection> createState() => _CodeIntelSectionState();
}

class _CodeIntelSectionState extends State<CodeIntelSection> {
  final TextEditingController _repoPathController = TextEditingController();

  @override
  void dispose() {
    _repoPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Code Intel',
            style: theme.textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 20)),
        const SizedBox(height: 8),
        Text(
          'Index a repository into the code graph and scan its dependencies against NVD / CISA KEV.',
          style: TextStyle(color: ext.iconColor, fontSize: 14),
        ),
        const SizedBox(height: 16),
        RepoXrayPanel(repoPathController: _repoPathController),
        const SizedBox(height: 24),
        VulnIntelPanel(repoPathController: _repoPathController),
      ],
    );
  }
}
