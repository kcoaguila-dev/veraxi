import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/chat/view_models/connect_repo_view_model.dart';

/// GitHub App tab inside the Connect Repository modal.
///
/// Mirrors the visual contract in `docs/design/connect_repo_github_app.svg`.
class ConnectRepoGitHubAppTab extends StatelessWidget {
  final ConnectRepoState state;
  final TextEditingController searchController;
  final InputDecoration Function(String hint) inputDecorationBuilder;
  final VoidCallback onConnect;
  final VoidCallback onRefresh;
  final VoidCallback onManageOnGitHub;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<GitHubAppRepoItem> onSelectRepo;
  final ValueChanged<GitHubAppRepoItem>? onDisconnectRepo;
  final ValueChanged<bool> onToggleAutoSync;
  final VoidCallback onSwitchToLocal;
  final VoidCallback onSwitchToGitUrl;

  const ConnectRepoGitHubAppTab({
    super.key,
    required this.state,
    required this.searchController,
    required this.inputDecorationBuilder,
    required this.onConnect,
    required this.onRefresh,
    required this.onManageOnGitHub,
    required this.onSearchChanged,
    required this.onSelectRepo,
    this.onDisconnectRepo,
    required this.onToggleAutoSync,
    required this.onSwitchToLocal,
    required this.onSwitchToGitUrl,
  });

  @override
  Widget build(BuildContext context) {
    if (state.githubAppLoading && state.githubAppStatus == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFF34D399),
            ),
          ),
        ),
      );
    }

    final status = state.githubAppStatus;
    if (status != null && !status.configured) {
      return _UnconfiguredCard(
        onSwitchToLocal: onSwitchToLocal,
        onSwitchToGitUrl: onSwitchToGitUrl,
      );
    }

    if (status == null || !status.isConnected) {
      return _ConnectCard(
        authorizing: state.githubAppAuthorizing,
        statusMessage: state.statusMessage,
        errorMessage: state.errorMessage,
        onConnect: onConnect,
      );
    }

    return _RepoPicker(
      state: state,
      status: status,
      searchController: searchController,
      inputDecorationBuilder: inputDecorationBuilder,
      onRefresh: onRefresh,
      onManageOnGitHub: onManageOnGitHub,
      onSearchChanged: onSearchChanged,
      onSelectRepo: onSelectRepo,
      onDisconnectRepo: onDisconnectRepo,
      onToggleAutoSync: onToggleAutoSync,
    );
  }
}

class _UnconfiguredCard extends StatelessWidget {
  final VoidCallback onSwitchToLocal;
  final VoidCallback onSwitchToGitUrl;

  const _UnconfiguredCard({
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
              Icon(Icons.settings_outlined, size: 16, color: Color(0xFFFBBF24)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'GitHub App not configured on this server',
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
            'Set GITHUB_APP_ID, GITHUB_APP_SLUG, GITHUB_APP_CLIENT_ID, GITHUB_APP_CLIENT_SECRET, and GITHUB_APP_PRIVATE_KEY in backend/.env to enable Selected-Repos OAuth.',
            style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 11.5),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              InkWell(
                onTap: onSwitchToLocal,
                child: const Text(
                  'Use Local Path →',
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

class _ConnectCard extends StatelessWidget {
  final bool authorizing;
  final String? statusMessage;
  final String? errorMessage;
  final VoidCallback onConnect;

  const _ConnectCard({
    required this.authorizing,
    this.statusMessage,
    required this.errorMessage,
    required this.onConnect,
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
              Icon(
                Icons.verified_user_outlined,
                size: 16,
                color: Color(0xFF34D399),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Selected-Repos Read-Only GitHub App',
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
            'Grant access only to repositories you pick. Never requests blanket account-wide write scopes.',
            style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12),
          ),
          const SizedBox(height: 12),
          const Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _PermissionPill(label: 'Contents: Read-only', accent: true),
              _PermissionPill(label: 'Metadata: Read-only', accent: true),
              _PermissionPill(label: 'Zero Write Access', accent: false),
            ],
          ),
          if (statusMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              statusMessage!,
              style: const TextStyle(color: Color(0xFF34D399), fontSize: 11.5),
            ),
          ],
          if (errorMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              errorMessage!,
              style: const TextStyle(color: Color(0xFFF87171), fontSize: 11.5),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: authorizing ? null : onConnect,
              icon: authorizing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF052E16),
                      ),
                    )
                  : const Icon(Icons.open_in_new, size: 15),
              label: Text(
                authorizing
                    ? 'Waiting for GitHub authorization...'
                    : 'Install GitHub App & Select Repos',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: const Color(0xFF052E16),
                disabledBackgroundColor: const Color(0xFF1E352C),
                disabledForegroundColor: const Color(0xFFA1A1AA),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionPill extends StatelessWidget {
  final String label;
  final bool accent;

  const _PermissionPill({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accent ? const Color(0xFF111916) : const Color(0xFF18181B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: accent ? const Color(0xFF1E352C) : const Color(0xFF27272A),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent ? const Color(0xFF34D399) : const Color(0xFFA1A1AA),
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _RepoPicker extends StatelessWidget {
  final ConnectRepoState state;
  final GitHubAppStatus status;
  final TextEditingController searchController;
  final InputDecoration Function(String hint) inputDecorationBuilder;
  final VoidCallback onRefresh;
  final VoidCallback onManageOnGitHub;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<GitHubAppRepoItem> onSelectRepo;
  final ValueChanged<GitHubAppRepoItem>? onDisconnectRepo;
  final ValueChanged<bool> onToggleAutoSync;

  const _RepoPicker({
    required this.state,
    required this.status,
    required this.searchController,
    required this.inputDecorationBuilder,
    required this.onRefresh,
    required this.onManageOnGitHub,
    required this.onSearchChanged,
    required this.onSelectRepo,
    this.onDisconnectRepo,
    required this.onToggleAutoSync,
  });

  @override
  Widget build(BuildContext context) {
    final activeInstallations =
        status.installations.where((i) => i.status == 'active').toList();
    final activeInst = activeInstallations.isNotEmpty
        ? activeInstallations.first
        : status.installations.first;
    final headerLabel = activeInstallations.length > 1
        ? '${activeInstallations.length} accounts · ${state.githubAppRepos.length} repos granted'
        : '${activeInst.accountLogin} · ${state.githubAppRepos.length} repos granted';
    final query = state.githubAppSearchQuery.trim().toLowerCase();
    final filtered = state.githubAppRepos.where((r) {
      if (query.isEmpty) return true;
      return r.fullName.toLowerCase().contains(query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF121217),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF27272D)),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle,
                  size: 14, color: Color(0xFF34D399)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headerLabel,
                  style: const TextStyle(
                    color: Color(0xFFE4E4E7),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              InkWell(
                onTap: onRefresh,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child:
                      Icon(Icons.refresh, size: 15, color: Color(0xFFA1A1AA)),
                ),
              ),
              InkWell(
                onTap: onManageOnGitHub,
                child: const Text(
                  'Manage on GitHub ↗',
                  style: TextStyle(
                    color: Color(0xFF34D399),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: searchController,
          onChanged: onSearchChanged,
          style: const TextStyle(color: Color(0xFFE4E4E7), fontSize: 12.5),
          decoration: inputDecorationBuilder('Filter granted repositories...'),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 140),
          child: state.githubAppLoading
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF34D399),
                      ),
                    ),
                  ),
                )
              : filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'No granted repositories match your filter.',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: Color(0xFF71717A), fontSize: 12),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final repo = filtered[index];
                        final selected =
                            state.selectedGitHubAppRepo?.fullName ==
                                repo.fullName;
                        return _RepoTile(
                          repo: repo,
                          selected: selected,
                          onTap: () => onSelectRepo(repo),
                          onDisconnect:
                              repo.isIndexed && onDisconnectRepo != null
                                  ? () => onDisconnectRepo!(repo)
                                  : null,
                        );
                      },
                    ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF121217),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF222227)),
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Auto-sync code graph on git push',
                  style: TextStyle(color: Color(0xFFD4D4D8), fontSize: 12),
                ),
              ),
              Switch(
                value: state.autoSyncOnPush,
                onChanged: onToggleAutoSync,
                activeThumbColor: const Color(0xFF34D399),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RepoTile extends StatelessWidget {
  final GitHubAppRepoItem repo;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDisconnect;

  const _RepoTile({
    required this.repo,
    required this.selected,
    required this.onTap,
    this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF141C18) : const Color(0xFF121217),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF10B981) : const Color(0xFF27272D),
          ),
        ),
        child: Row(
          children: [
            Icon(
              repo.isPrivate ? Icons.lock_outline : Icons.public,
              size: 14,
              color:
                  selected ? const Color(0xFF34D399) : const Color(0xFF71717A),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    repo.fullName,
                    style: const TextStyle(
                      color: Color(0xFFF4F4F5),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${repo.isPrivate ? 'Private' : 'Public'} · ${repo.defaultBranch}',
                    style:
                        const TextStyle(color: Color(0xFF71717A), fontSize: 11),
                  ),
                ],
              ),
            ),
            if (repo.isIndexed) ...[
              const _PermissionPill(label: 'Indexed', accent: true),
              if (onDisconnect != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Disconnect & purge index',
                  child: InkWell(
                    key: ValueKey('disconnect_${repo.fullName}'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: onDisconnect,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.link_off,
                        size: 15,
                        color: Color(0xFF71717A),
                      ),
                    ),
                  ),
                ),
              ],
            ] else if (repo.isIndexing)
              const _PermissionPill(label: 'Indexing', accent: false),
          ],
        ),
      ),
    );
  }
}
