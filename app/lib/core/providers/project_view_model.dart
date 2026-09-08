import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/project/data/project_repository.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class ProjectState {
  final List<Map<String, dynamic>> projects;
  final String? activeProjectId;
  final String? activeProjectName;
  final bool showProjectDashboard;
  final bool showAllProjectsDashboard;
  final String? error;

  ProjectState({
    this.projects = const [],
    this.activeProjectId,
    this.activeProjectName,
    this.showProjectDashboard = false,
    this.showAllProjectsDashboard = false,
    this.error,
  });

  ProjectState copyWith({
    List<Map<String, dynamic>>? projects,
    String? activeProjectId,
    bool clearActiveProject = false,
    String? activeProjectName,
    bool? showProjectDashboard,
    bool? showAllProjectsDashboard,
    String? error,
    bool clearError = false,
  }) {
    return ProjectState(
      projects: projects ?? this.projects,
      activeProjectId:
          clearActiveProject ? null : (activeProjectId ?? this.activeProjectId),
      activeProjectName: clearActiveProject
          ? null
          : (activeProjectName ?? this.activeProjectName),
      showProjectDashboard: showProjectDashboard ?? this.showProjectDashboard,
      showAllProjectsDashboard:
          showAllProjectsDashboard ?? this.showAllProjectsDashboard,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final projectViewModelProvider =
    NotifierProvider<ProjectViewModel, ProjectState>(
  () => ProjectViewModel(),
);

class ProjectViewModel extends Notifier<ProjectState> {
  @override
  ProjectState build() {
    Future.microtask(() => loadProjects());
    return ProjectState();
  }

  Future<void> loadProjects() async {
    try {
      final repo = ref.read(projectRepositoryProvider);
      final projects = await repo.getProjects();
      state = state.copyWith(projects: projects, clearError: true);
    } catch (e, stack) {
      Sentry.captureException(e, stackTrace: stack);
      state = state.copyWith(error: 'Failed to load projects: $e');
    }
  }

  void selectProject(String id, String name) {
    state = state.copyWith(
      activeProjectId: id,
      activeProjectName: name,
      showProjectDashboard: true,
      showAllProjectsDashboard: false,
    );
  }

  void openAllProjectsDashboard() {
    state = state.copyWith(
      showAllProjectsDashboard: true,
      showProjectDashboard: false,
      clearActiveProject: true,
    );
  }

  void exitProject() {
    state = state.copyWith(
      clearActiveProject: true,
      showProjectDashboard: false,
      showAllProjectsDashboard: false,
    );
  }

  Future<Map<String, dynamic>?> createProject(String name) async {
    try {
      final repo = ref.read(projectRepositoryProvider);
      final project = await repo.createProject(name);
      await loadProjects();
      return project;
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to create project: $e');
      return null;
    }
  }

  Future<void> renameProject(String projectId, String newName) async {
    try {
      final repo = ref.read(projectRepositoryProvider);
      await repo.renameProject(projectId, newName);
      await loadProjects();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to rename project: $e');
    }
  }

  Future<void> deleteProject(String projectId) async {
    try {
      final repo = ref.read(projectRepositoryProvider);
      await repo.deleteProject(projectId);
      if (state.activeProjectId == projectId) {
        state = state.copyWith(
          clearActiveProject: true,
          showProjectDashboard: false,
        );
      }
      await loadProjects();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to delete project: $e');
    }
  }
}
