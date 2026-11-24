import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/chat/view_models/connect_repo_view_model.dart';

/// Opens the centered Connect Repository modal from Code Chat or the
/// sidebar without navigating away from the user's active thread.
Future<void> showConnectRepoDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.65),
    builder: (_) => const ConnectRepoDialog(),
  );
}

/// Centered modal dialog for connecting a codebase into Veraxi's
/// Neo4j + Qdrant GraphRAG index.
///
/// Mirrors the visual contract in `docs/design/connect_repo_modal.svg`:
/// Local Path and Git URL / PAT tabs are live; GitHub App is cleanly
/// staged behind a Coming Soon state; submitting triggers non-blocking
/// background indexing so the user stays in Code Chat.
class ConnectRepoDialog extends ConsumerStatefulWidget {
  const ConnectRepoDialog({super.key});

  @override
  ConsumerState<ConnectRepoDialog> createState() => _ConnectRepoDialogState();
}

class _ConnectRepoDialogState extends ConsumerState<ConnectRepoDialog> {
  static const _surfaceBg = Color(0xFF141418);
  static const _recessedBg = Color(0xFF0B0B0E);
  static const _borderColor = Color(0xFF27272A);
  static const _subtleBorder = Color(0xFF222227);
  static const _emerald = Color(0xFF34D399);
  static const _emeraldSolid = Color(0xFF10B981);

  final TextEditingController _localPathController = TextEditingController();
  final TextEditingController _gitUrlController = TextEditingController();
  final TextEditingController _branchController =
      TextEditingController(text: 'main');
  final TextEditingController _patController = TextEditingController();

  ConnectRepoSourceTab _activeTab = ConnectRepoSourceTab.localPath;
  String? _inlineValidation;

  @override
  void dispose() {
    _localPathController.dispose();
    _gitUrlController.dispose();
    _branchController.dispose();
    _patController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_activeTab == ConnectRepoSourceTab.githubApp) {
      setState(() {
        _inlineValidation =
            'GitHub App OAuth is coming soon — switch to Local Path or Git URL / PAT.';
      });
      return;
    }

    final target = _activeTab == ConnectRepoSourceTab.localPath
        ? _localPathController.text.trim()
        : _gitUrlController.text.trim();

    if (target.isEmpty) {
      setState(() {
        _inlineValidation = _activeTab == ConnectRepoSourceTab.localPath
            ? 'Enter a local repository directory path.'
            : 'Enter a Git repository URL.';
      });
      return;
    }

    ref.read(connectRepoViewModelProvider.notifier).startIndexing(target);
    Navigator.of(context).pop();
  }

  void _selectIndexedRepo(IndexedRepoItem repo) {
    ref.read(connectRepoViewModelProvider.notifier).selectExistingRepo(repo);
    Navigator.of(context).pop();
  }

  void _openFullRepoXray() {
    Navigator.of(context).pop();
    ref.read(codeSubViewProvider.notifier).state = CodeSubView.repoXray;
  }

  @override
  Widget build(BuildContext context) {
    final repos = ref.watch(indexedReposProvider);
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          decoration: BoxDecoration(
            color: _surfaceBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _borderColor, width: 1.2),
          ),
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 18),
                _buildSourceTabs(),
                const SizedBox(height: 18),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _buildTabBody(repos, selectedRepo),
                ),
                if (_inlineValidation != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _inlineValidation!,
                    style: const TextStyle(
                      color: Color(0xFFF87171),
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                _buildTrustBar(),
                const SizedBox(height: 18),
                _buildFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connect a repository',
                style: TextStyle(
                  color: Color(0xFFF4F4F5),
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Index a codebase into Veraxi\'s Neo4j + Qdrant GraphRAG for line-anchored answers.',
                style: TextStyle(
                  color: Color(0xFFA1A1AA),
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFF18181B),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: _borderColor),
            ),
            child: const Icon(
              Icons.close,
              size: 16,
              color: Color(0xFFA1A1AA),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSourceTabs() {
    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _recessedBg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _subtleBorder),
      ),
      child: Row(
        children: [
          _SourceTabButton(
            label: 'Local Path',
            selected: _activeTab == ConnectRepoSourceTab.localPath,
            onTap: () => _switchTab(ConnectRepoSourceTab.localPath),
          ),
          _SourceTabButton(
            label: 'Git URL / PAT',
            selected: _activeTab == ConnectRepoSourceTab.gitUrl,
            onTap: () => _switchTab(ConnectRepoSourceTab.gitUrl),
          ),
          _SourceTabButton(
            label: 'GitHub App',
            badge: 'SOON',
            selected: _activeTab == ConnectRepoSourceTab.githubApp,
            onTap: () => _switchTab(ConnectRepoSourceTab.githubApp),
          ),
        ],
      ),
    );
  }

  void _switchTab(ConnectRepoSourceTab tab) {
    setState(() {
      _activeTab = tab;
      _inlineValidation = null;
    });
  }

  Widget _buildTabBody(List<IndexedRepoItem> repos, String? selectedRepo) {
    switch (_activeTab) {
      case ConnectRepoSourceTab.localPath:
        return _LocalPathTab(
          key: const ValueKey('local_path_tab'),
          controller: _localPathController,
          repos: repos,
          selectedRepo: selectedRepo,
          onSelectRepo: _selectIndexedRepo,
          onSubmitted: _submit,
        );
      case ConnectRepoSourceTab.gitUrl:
        return _GitUrlTab(
          key: const ValueKey('git_url_tab'),
          urlController: _gitUrlController,
          branchController: _branchController,
          patController: _patController,
          onSwitchToLocal: () => _switchTab(ConnectRepoSourceTab.localPath),
        );
      case ConnectRepoSourceTab.githubApp:
        return _GitHubAppStagedTab(
          key: const ValueKey('github_app_tab'),
          onSwitchToLocal: () => _switchTab(ConnectRepoSourceTab.localPath),
          onSwitchToGitUrl: () => _switchTab(ConnectRepoSourceTab.gitUrl),
        );
    }
  }

  Widget _buildTrustBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111916),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFF1E352C)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF182B24),
              shape: BoxShape.circle,
              border: Border.all(color: _emerald),
            ),
            child: const Icon(Icons.check, size: 11, color: _emerald),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Read-only & local-first by default',
                  style: TextStyle(
                    color: Color(0xFFE4E4E7),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Veraxi indexes locally into Neo4j & Qdrant. Never pushes, modifies files, or trains on code.',
                  style: TextStyle(
                    color: Color(0xFFA1A1AA),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final canSubmit = _activeTab != ConnectRepoSourceTab.githubApp;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _openFullRepoXray,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Text.rich(
                TextSpan(
                  text: 'Or open full ',
                  style: TextStyle(color: Color(0xFF71717A), fontSize: 11.5),
                  children: [
                    TextSpan(
                      text: 'Repo X-Ray',
                      style: TextStyle(
                        color: Color(0xFFA1A1AA),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFA1A1AA),
            backgroundColor: const Color(0xFF18181B),
            side: const BorderSide(color: _borderColor),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text('Cancel', style: TextStyle(fontSize: 12.5)),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: canSubmit ? _submit : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: _emeraldSolid,
            disabledBackgroundColor: const Color(0xFF27272A),
            foregroundColor: const Color(0xFF052E16),
            disabledForegroundColor: const Color(0xFF71717A),
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text(
            'Connect & Index',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _SourceTabButton extends StatelessWidget {
  final String label;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  const _SourceTabButton({
    required this.label,
    this.badge,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF222228) : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: selected
                ? Border.all(color: const Color(0xFF32323A))
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? const Color(0xFFF4F4F5)
                        : badge != null
                            ? const Color(0xFF71717A)
                            : const Color(0xFFA1A1AA),
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181D),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFF27272A)),
                  ),
                  child: Text(
                    badge!,
                    style: const TextStyle(
                      color: Color(0xFF71717A),
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalPathTab extends StatelessWidget {
  final TextEditingController controller;
  final List<IndexedRepoItem> repos;
  final String? selectedRepo;
  final ValueChanged<IndexedRepoItem> onSelectRepo;
  final VoidCallback onSubmitted;

  const _LocalPathTab({
    super.key,
    required this.controller,
    required this.repos,
    required this.selectedRepo,
    required this.onSelectRepo,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Repository Directory',
          style: TextStyle(
            color: Color(0xFFE4E4E7),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          onSubmitted: (_) => onSubmitted(),
          style: const TextStyle(
            color: Color(0xFFF4F4F5),
            fontFamily: 'monospace',
            fontSize: 12.5,
          ),
          decoration: _inputDecoration('/home/ubuntu/src/ai/veraxi'),
        ),
        const SizedBox(height: 12),
        if (repos.isNotEmpty) ...[
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0E0E12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF222227)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 10, 14, 8),
                  child: Text(
                    'INDEXED IN WORKSPACE',
                    style: TextStyle(
                      color: Color(0xFF71717A),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                const Divider(height: 1, color: Color(0xFF1E1E24)),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 156),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(8),
                    itemCount: repos.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, index) {
                      final repo = repos[index];
                      final isSelected = repo.repoKey == selectedRepo;
                      return _IndexedRepoRow(
                        repo: repo,
                        isSelected: isSelected,
                        onTap: () => onSelectRepo(repo),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF16161B),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0xFF222228)),
          ),
          child: const Text(
            'Scope: Auto-skips node_modules, .venv, build/, .git',
            style: TextStyle(color: Color(0xFF71717A), fontSize: 11.5),
          ),
        ),
      ],
    );
  }
}

class _IndexedRepoRow extends StatelessWidget {
  final IndexedRepoItem repo;
  final bool isSelected;
  final VoidCallback onTap;

  const _IndexedRepoRow({
    required this.repo,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final initial = repo.displayName.isNotEmpty
        ? repo.displayName[0].toUpperCase()
        : 'R';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF16161C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF27272D)),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF22222A),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              initial,
              style: const TextStyle(
                color: Color(0xFFE4E4E7),
                fontFamily: 'monospace',
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  repo.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFF4F4F5),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  repo.subtitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF71717A),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF14231D),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: const Color(0xFF224438)),
              ),
              child: Text(
                isSelected ? '✓ Active' : 'Use in chat',
                style: const TextStyle(
                  color: Color(0xFF34D399),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GitUrlTab extends StatelessWidget {
  final TextEditingController urlController;
  final TextEditingController branchController;
  final TextEditingController patController;
  final VoidCallback onSwitchToLocal;

  const _GitUrlTab({
    super.key,
    required this.urlController,
    required this.branchController,
    required this.patController,
    required this.onSwitchToLocal,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Repository URL',
          style: TextStyle(
            color: Color(0xFFE4E4E7),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: urlController,
          style: const TextStyle(
            color: Color(0xFFF4F4F5),
            fontFamily: 'monospace',
            fontSize: 12.5,
          ),
          decoration:
              _inputDecoration('https://github.com/org/private-service.git'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            SizedBox(
              width: 132,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Branch',
                    style: TextStyle(
                      color: Color(0xFFE4E4E7),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: branchController,
                    style: const TextStyle(
                      color: Color(0xFFE4E4E7),
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                    ),
                    decoration: _inputDecoration('main'),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Read-only Token (optional)',
                    style: TextStyle(
                      color: Color(0xFFE4E4E7),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: patController,
                    obscureText: true,
                    style: const TextStyle(
                      color: Color(0xFFE4E4E7),
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                    ),
                    decoration:
                        _inputDecoration('github_pat_... (Contents: Read-only)'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        InkWell(
          onTap: onSwitchToLocal,
          child: const Text.rich(
            TextSpan(
              text: 'Prefer zero credentials? ',
              style: TextStyle(color: Color(0xFF71717A), fontSize: 11.5),
              children: [
                TextSpan(
                  text: 'Index a Local Path directly →',
                  style: TextStyle(
                    color: Color(0xFF34D399),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _GitHubAppStagedTab extends StatelessWidget {
  final VoidCallback onSwitchToLocal;
  final VoidCallback onSwitchToGitUrl;

  const _GitHubAppStagedTab({
    super.key,
    required this.onSwitchToLocal,
    required this.onSwitchToGitUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121217),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF27272D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_outline, size: 16, color: Color(0xFF34D399)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'GitHub App (Selected-Repos OAuth) — Coming Soon',
                  style: TextStyle(
                    color: Color(0xFFE4E4E7),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'One-click repository picker scoped strictly to repositories you select with read-only permissions — never blanket account-wide access.',
            style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              InkWell(
                onTap: onSwitchToLocal,
                child: const Text(
                  'Use Local Path now →',
                  style: TextStyle(
                    color: Color(0xFF34D399),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              InkWell(
                onTap: onSwitchToGitUrl,
                child: const Text(
                  'Use Git URL / PAT →',
                  style: TextStyle(
                    color: Color(0xFFA1A1AA),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

InputDecoration _inputDecoration(String hint) {
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(0xFF52525B), fontSize: 12),
    filled: true,
    fillColor: const Color(0xFF0B0B0E),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFF27272A)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFF34D399)),
    ),
  );
}
