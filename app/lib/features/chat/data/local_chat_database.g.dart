// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_chat_database.dart';

// ignore_for_file: type=lint
class $LocalThreadsTable extends LocalThreads
    with TableInfo<$LocalThreadsTable, LocalThread> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalThreadsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _threadIdMeta =
      const VerificationMeta('threadId');
  @override
  late final GeneratedColumn<String> threadId = GeneratedColumn<String>(
      'thread_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _isPinnedMeta =
      const VerificationMeta('isPinned');
  @override
  late final GeneratedColumn<bool> isPinned = GeneratedColumn<bool>(
      'is_pinned', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_pinned" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _isArchivedMeta =
      const VerificationMeta('isArchived');
  @override
  late final GeneratedColumn<bool> isArchived = GeneratedColumn<bool>(
      'is_archived', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_archived" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _projectIdMeta =
      const VerificationMeta('projectId');
  @override
  late final GeneratedColumn<String> projectId = GeneratedColumn<String>(
      'project_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _timestampMeta =
      const VerificationMeta('timestamp');
  @override
  late final GeneratedColumn<DateTime> timestamp = GeneratedColumn<DateTime>(
      'timestamp', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [threadId, title, isPinned, isArchived, projectId, timestamp];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_threads';
  @override
  VerificationContext validateIntegrity(Insertable<LocalThread> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('thread_id')) {
      context.handle(_threadIdMeta,
          threadId.isAcceptableOrUnknown(data['thread_id']!, _threadIdMeta));
    } else if (isInserting) {
      context.missing(_threadIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('is_pinned')) {
      context.handle(_isPinnedMeta,
          isPinned.isAcceptableOrUnknown(data['is_pinned']!, _isPinnedMeta));
    }
    if (data.containsKey('is_archived')) {
      context.handle(
          _isArchivedMeta,
          isArchived.isAcceptableOrUnknown(
              data['is_archived']!, _isArchivedMeta));
    }
    if (data.containsKey('project_id')) {
      context.handle(_projectIdMeta,
          projectId.isAcceptableOrUnknown(data['project_id']!, _projectIdMeta));
    }
    if (data.containsKey('timestamp')) {
      context.handle(_timestampMeta,
          timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {threadId};
  @override
  LocalThread map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalThread(
      threadId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}thread_id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      isPinned: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_pinned'])!,
      isArchived: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_archived'])!,
      projectId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}project_id']),
      timestamp: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}timestamp']),
    );
  }

  @override
  $LocalThreadsTable createAlias(String alias) {
    return $LocalThreadsTable(attachedDatabase, alias);
  }
}

class LocalThread extends DataClass implements Insertable<LocalThread> {
  final String threadId;
  final String title;
  final bool isPinned;
  final bool isArchived;
  final String? projectId;
  final DateTime? timestamp;
  const LocalThread(
      {required this.threadId,
      required this.title,
      required this.isPinned,
      required this.isArchived,
      this.projectId,
      this.timestamp});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['thread_id'] = Variable<String>(threadId);
    map['title'] = Variable<String>(title);
    map['is_pinned'] = Variable<bool>(isPinned);
    map['is_archived'] = Variable<bool>(isArchived);
    if (!nullToAbsent || projectId != null) {
      map['project_id'] = Variable<String>(projectId);
    }
    if (!nullToAbsent || timestamp != null) {
      map['timestamp'] = Variable<DateTime>(timestamp);
    }
    return map;
  }

  LocalThreadsCompanion toCompanion(bool nullToAbsent) {
    return LocalThreadsCompanion(
      threadId: Value(threadId),
      title: Value(title),
      isPinned: Value(isPinned),
      isArchived: Value(isArchived),
      projectId: projectId == null && nullToAbsent
          ? const Value.absent()
          : Value(projectId),
      timestamp: timestamp == null && nullToAbsent
          ? const Value.absent()
          : Value(timestamp),
    );
  }

  factory LocalThread.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalThread(
      threadId: serializer.fromJson<String>(json['threadId']),
      title: serializer.fromJson<String>(json['title']),
      isPinned: serializer.fromJson<bool>(json['isPinned']),
      isArchived: serializer.fromJson<bool>(json['isArchived']),
      projectId: serializer.fromJson<String?>(json['projectId']),
      timestamp: serializer.fromJson<DateTime?>(json['timestamp']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'threadId': serializer.toJson<String>(threadId),
      'title': serializer.toJson<String>(title),
      'isPinned': serializer.toJson<bool>(isPinned),
      'isArchived': serializer.toJson<bool>(isArchived),
      'projectId': serializer.toJson<String?>(projectId),
      'timestamp': serializer.toJson<DateTime?>(timestamp),
    };
  }

  LocalThread copyWith(
          {String? threadId,
          String? title,
          bool? isPinned,
          bool? isArchived,
          Value<String?> projectId = const Value.absent(),
          Value<DateTime?> timestamp = const Value.absent()}) =>
      LocalThread(
        threadId: threadId ?? this.threadId,
        title: title ?? this.title,
        isPinned: isPinned ?? this.isPinned,
        isArchived: isArchived ?? this.isArchived,
        projectId: projectId.present ? projectId.value : this.projectId,
        timestamp: timestamp.present ? timestamp.value : this.timestamp,
      );
  LocalThread copyWithCompanion(LocalThreadsCompanion data) {
    return LocalThread(
      threadId: data.threadId.present ? data.threadId.value : this.threadId,
      title: data.title.present ? data.title.value : this.title,
      isPinned: data.isPinned.present ? data.isPinned.value : this.isPinned,
      isArchived:
          data.isArchived.present ? data.isArchived.value : this.isArchived,
      projectId: data.projectId.present ? data.projectId.value : this.projectId,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalThread(')
          ..write('threadId: $threadId, ')
          ..write('title: $title, ')
          ..write('isPinned: $isPinned, ')
          ..write('isArchived: $isArchived, ')
          ..write('projectId: $projectId, ')
          ..write('timestamp: $timestamp')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(threadId, title, isPinned, isArchived, projectId, timestamp);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalThread &&
          other.threadId == this.threadId &&
          other.title == this.title &&
          other.isPinned == this.isPinned &&
          other.isArchived == this.isArchived &&
          other.projectId == this.projectId &&
          other.timestamp == this.timestamp);
}

class LocalThreadsCompanion extends UpdateCompanion<LocalThread> {
  final Value<String> threadId;
  final Value<String> title;
  final Value<bool> isPinned;
  final Value<bool> isArchived;
  final Value<String?> projectId;
  final Value<DateTime?> timestamp;
  final Value<int> rowid;
  const LocalThreadsCompanion({
    this.threadId = const Value.absent(),
    this.title = const Value.absent(),
    this.isPinned = const Value.absent(),
    this.isArchived = const Value.absent(),
    this.projectId = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalThreadsCompanion.insert({
    required String threadId,
    required String title,
    this.isPinned = const Value.absent(),
    this.isArchived = const Value.absent(),
    this.projectId = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : threadId = Value(threadId),
        title = Value(title);
  static Insertable<LocalThread> custom({
    Expression<String>? threadId,
    Expression<String>? title,
    Expression<bool>? isPinned,
    Expression<bool>? isArchived,
    Expression<String>? projectId,
    Expression<DateTime>? timestamp,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (threadId != null) 'thread_id': threadId,
      if (title != null) 'title': title,
      if (isPinned != null) 'is_pinned': isPinned,
      if (isArchived != null) 'is_archived': isArchived,
      if (projectId != null) 'project_id': projectId,
      if (timestamp != null) 'timestamp': timestamp,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalThreadsCompanion copyWith(
      {Value<String>? threadId,
      Value<String>? title,
      Value<bool>? isPinned,
      Value<bool>? isArchived,
      Value<String?>? projectId,
      Value<DateTime?>? timestamp,
      Value<int>? rowid}) {
    return LocalThreadsCompanion(
      threadId: threadId ?? this.threadId,
      title: title ?? this.title,
      isPinned: isPinned ?? this.isPinned,
      isArchived: isArchived ?? this.isArchived,
      projectId: projectId ?? this.projectId,
      timestamp: timestamp ?? this.timestamp,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (threadId.present) {
      map['thread_id'] = Variable<String>(threadId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (isPinned.present) {
      map['is_pinned'] = Variable<bool>(isPinned.value);
    }
    if (isArchived.present) {
      map['is_archived'] = Variable<bool>(isArchived.value);
    }
    if (projectId.present) {
      map['project_id'] = Variable<String>(projectId.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<DateTime>(timestamp.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalThreadsCompanion(')
          ..write('threadId: $threadId, ')
          ..write('title: $title, ')
          ..write('isPinned: $isPinned, ')
          ..write('isArchived: $isArchived, ')
          ..write('projectId: $projectId, ')
          ..write('timestamp: $timestamp, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalMessagesTable extends LocalMessages
    with TableInfo<$LocalMessagesTable, LocalMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _threadIdMeta =
      const VerificationMeta('threadId');
  @override
  late final GeneratedColumn<String> threadId = GeneratedColumn<String>(
      'thread_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
      'role', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contentMeta =
      const VerificationMeta('content');
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
      'content', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _feedbackMeta =
      const VerificationMeta('feedback');
  @override
  late final GeneratedColumn<int> feedback = GeneratedColumn<int>(
      'feedback', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _modelNameMeta =
      const VerificationMeta('modelName');
  @override
  late final GeneratedColumn<String> modelName = GeneratedColumn<String>(
      'model_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _metricsMeta =
      const VerificationMeta('metrics');
  @override
  late final GeneratedColumn<String> metrics = GeneratedColumn<String>(
      'metrics', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _toolEventsMeta =
      const VerificationMeta('toolEvents');
  @override
  late final GeneratedColumn<String> toolEvents = GeneratedColumn<String>(
      'tool_events', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _activityMeta =
      const VerificationMeta('activity');
  @override
  late final GeneratedColumn<String> activity = GeneratedColumn<String>(
      'activity', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _reasoningMeta =
      const VerificationMeta('reasoning');
  @override
  late final GeneratedColumn<String> reasoning = GeneratedColumn<String>(
      'reasoning', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _reasoningDurationSecondsMeta =
      const VerificationMeta('reasoningDurationSeconds');
  @override
  late final GeneratedColumn<double> reasoningDurationSeconds =
      GeneratedColumn<double>('reasoning_duration_seconds', aliasedName, true,
          type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _timestampMeta =
      const VerificationMeta('timestamp');
  @override
  late final GeneratedColumn<DateTime> timestamp = GeneratedColumn<DateTime>(
      'timestamp', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        threadId,
        role,
        content,
        feedback,
        modelName,
        metrics,
        toolEvents,
        activity,
        reasoning,
        reasoningDurationSeconds,
        timestamp
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_messages';
  @override
  VerificationContext validateIntegrity(Insertable<LocalMessage> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('thread_id')) {
      context.handle(_threadIdMeta,
          threadId.isAcceptableOrUnknown(data['thread_id']!, _threadIdMeta));
    } else if (isInserting) {
      context.missing(_threadIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
          _roleMeta, role.isAcceptableOrUnknown(data['role']!, _roleMeta));
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(_contentMeta,
          content.isAcceptableOrUnknown(data['content']!, _contentMeta));
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('feedback')) {
      context.handle(_feedbackMeta,
          feedback.isAcceptableOrUnknown(data['feedback']!, _feedbackMeta));
    }
    if (data.containsKey('model_name')) {
      context.handle(_modelNameMeta,
          modelName.isAcceptableOrUnknown(data['model_name']!, _modelNameMeta));
    }
    if (data.containsKey('metrics')) {
      context.handle(_metricsMeta,
          metrics.isAcceptableOrUnknown(data['metrics']!, _metricsMeta));
    }
    if (data.containsKey('tool_events')) {
      context.handle(
          _toolEventsMeta,
          toolEvents.isAcceptableOrUnknown(
              data['tool_events']!, _toolEventsMeta));
    }
    if (data.containsKey('activity')) {
      context.handle(_activityMeta,
          activity.isAcceptableOrUnknown(data['activity']!, _activityMeta));
    }
    if (data.containsKey('reasoning')) {
      context.handle(_reasoningMeta,
          reasoning.isAcceptableOrUnknown(data['reasoning']!, _reasoningMeta));
    }
    if (data.containsKey('reasoning_duration_seconds')) {
      context.handle(
          _reasoningDurationSecondsMeta,
          reasoningDurationSeconds.isAcceptableOrUnknown(
              data['reasoning_duration_seconds']!,
              _reasoningDurationSecondsMeta));
    }
    if (data.containsKey('timestamp')) {
      context.handle(_timestampMeta,
          timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalMessage(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      threadId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}thread_id'])!,
      role: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}role'])!,
      content: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}content'])!,
      feedback: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}feedback'])!,
      modelName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}model_name']),
      metrics: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}metrics']),
      toolEvents: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}tool_events']),
      activity: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}activity']),
      reasoning: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reasoning']),
      reasoningDurationSeconds: attachedDatabase.typeMapping.read(
          DriftSqlType.double,
          data['${effectivePrefix}reasoning_duration_seconds']),
      timestamp: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}timestamp']),
    );
  }

  @override
  $LocalMessagesTable createAlias(String alias) {
    return $LocalMessagesTable(attachedDatabase, alias);
  }
}

class LocalMessage extends DataClass implements Insertable<LocalMessage> {
  final String id;
  final String threadId;
  final String role;
  final String content;
  final int feedback;
  final String? modelName;
  final String? metrics;
  final String? toolEvents;
  final String? activity;
  final String? reasoning;
  final double? reasoningDurationSeconds;
  final DateTime? timestamp;
  const LocalMessage(
      {required this.id,
      required this.threadId,
      required this.role,
      required this.content,
      required this.feedback,
      this.modelName,
      this.metrics,
      this.toolEvents,
      this.activity,
      this.reasoning,
      this.reasoningDurationSeconds,
      this.timestamp});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['thread_id'] = Variable<String>(threadId);
    map['role'] = Variable<String>(role);
    map['content'] = Variable<String>(content);
    map['feedback'] = Variable<int>(feedback);
    if (!nullToAbsent || modelName != null) {
      map['model_name'] = Variable<String>(modelName);
    }
    if (!nullToAbsent || metrics != null) {
      map['metrics'] = Variable<String>(metrics);
    }
    if (!nullToAbsent || toolEvents != null) {
      map['tool_events'] = Variable<String>(toolEvents);
    }
    if (!nullToAbsent || activity != null) {
      map['activity'] = Variable<String>(activity);
    }
    if (!nullToAbsent || reasoning != null) {
      map['reasoning'] = Variable<String>(reasoning);
    }
    if (!nullToAbsent || reasoningDurationSeconds != null) {
      map['reasoning_duration_seconds'] =
          Variable<double>(reasoningDurationSeconds);
    }
    if (!nullToAbsent || timestamp != null) {
      map['timestamp'] = Variable<DateTime>(timestamp);
    }
    return map;
  }

  LocalMessagesCompanion toCompanion(bool nullToAbsent) {
    return LocalMessagesCompanion(
      id: Value(id),
      threadId: Value(threadId),
      role: Value(role),
      content: Value(content),
      feedback: Value(feedback),
      modelName: modelName == null && nullToAbsent
          ? const Value.absent()
          : Value(modelName),
      metrics: metrics == null && nullToAbsent
          ? const Value.absent()
          : Value(metrics),
      toolEvents: toolEvents == null && nullToAbsent
          ? const Value.absent()
          : Value(toolEvents),
      activity: activity == null && nullToAbsent
          ? const Value.absent()
          : Value(activity),
      reasoning: reasoning == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoning),
      reasoningDurationSeconds: reasoningDurationSeconds == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoningDurationSeconds),
      timestamp: timestamp == null && nullToAbsent
          ? const Value.absent()
          : Value(timestamp),
    );
  }

  factory LocalMessage.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalMessage(
      id: serializer.fromJson<String>(json['id']),
      threadId: serializer.fromJson<String>(json['threadId']),
      role: serializer.fromJson<String>(json['role']),
      content: serializer.fromJson<String>(json['content']),
      feedback: serializer.fromJson<int>(json['feedback']),
      modelName: serializer.fromJson<String?>(json['modelName']),
      metrics: serializer.fromJson<String?>(json['metrics']),
      toolEvents: serializer.fromJson<String?>(json['toolEvents']),
      activity: serializer.fromJson<String?>(json['activity']),
      reasoning: serializer.fromJson<String?>(json['reasoning']),
      reasoningDurationSeconds:
          serializer.fromJson<double?>(json['reasoningDurationSeconds']),
      timestamp: serializer.fromJson<DateTime?>(json['timestamp']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'threadId': serializer.toJson<String>(threadId),
      'role': serializer.toJson<String>(role),
      'content': serializer.toJson<String>(content),
      'feedback': serializer.toJson<int>(feedback),
      'modelName': serializer.toJson<String?>(modelName),
      'metrics': serializer.toJson<String?>(metrics),
      'toolEvents': serializer.toJson<String?>(toolEvents),
      'activity': serializer.toJson<String?>(activity),
      'reasoning': serializer.toJson<String?>(reasoning),
      'reasoningDurationSeconds':
          serializer.toJson<double?>(reasoningDurationSeconds),
      'timestamp': serializer.toJson<DateTime?>(timestamp),
    };
  }

  LocalMessage copyWith(
          {String? id,
          String? threadId,
          String? role,
          String? content,
          int? feedback,
          Value<String?> modelName = const Value.absent(),
          Value<String?> metrics = const Value.absent(),
          Value<String?> toolEvents = const Value.absent(),
          Value<String?> activity = const Value.absent(),
          Value<String?> reasoning = const Value.absent(),
          Value<double?> reasoningDurationSeconds = const Value.absent(),
          Value<DateTime?> timestamp = const Value.absent()}) =>
      LocalMessage(
        id: id ?? this.id,
        threadId: threadId ?? this.threadId,
        role: role ?? this.role,
        content: content ?? this.content,
        feedback: feedback ?? this.feedback,
        modelName: modelName.present ? modelName.value : this.modelName,
        metrics: metrics.present ? metrics.value : this.metrics,
        toolEvents: toolEvents.present ? toolEvents.value : this.toolEvents,
        activity: activity.present ? activity.value : this.activity,
        reasoning: reasoning.present ? reasoning.value : this.reasoning,
        reasoningDurationSeconds: reasoningDurationSeconds.present
            ? reasoningDurationSeconds.value
            : this.reasoningDurationSeconds,
        timestamp: timestamp.present ? timestamp.value : this.timestamp,
      );
  LocalMessage copyWithCompanion(LocalMessagesCompanion data) {
    return LocalMessage(
      id: data.id.present ? data.id.value : this.id,
      threadId: data.threadId.present ? data.threadId.value : this.threadId,
      role: data.role.present ? data.role.value : this.role,
      content: data.content.present ? data.content.value : this.content,
      feedback: data.feedback.present ? data.feedback.value : this.feedback,
      modelName: data.modelName.present ? data.modelName.value : this.modelName,
      metrics: data.metrics.present ? data.metrics.value : this.metrics,
      toolEvents:
          data.toolEvents.present ? data.toolEvents.value : this.toolEvents,
      activity: data.activity.present ? data.activity.value : this.activity,
      reasoning: data.reasoning.present ? data.reasoning.value : this.reasoning,
      reasoningDurationSeconds: data.reasoningDurationSeconds.present
          ? data.reasoningDurationSeconds.value
          : this.reasoningDurationSeconds,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessage(')
          ..write('id: $id, ')
          ..write('threadId: $threadId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('feedback: $feedback, ')
          ..write('modelName: $modelName, ')
          ..write('metrics: $metrics, ')
          ..write('toolEvents: $toolEvents, ')
          ..write('activity: $activity, ')
          ..write('reasoning: $reasoning, ')
          ..write('reasoningDurationSeconds: $reasoningDurationSeconds, ')
          ..write('timestamp: $timestamp')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      threadId,
      role,
      content,
      feedback,
      modelName,
      metrics,
      toolEvents,
      activity,
      reasoning,
      reasoningDurationSeconds,
      timestamp);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalMessage &&
          other.id == this.id &&
          other.threadId == this.threadId &&
          other.role == this.role &&
          other.content == this.content &&
          other.feedback == this.feedback &&
          other.modelName == this.modelName &&
          other.metrics == this.metrics &&
          other.toolEvents == this.toolEvents &&
          other.activity == this.activity &&
          other.reasoning == this.reasoning &&
          other.reasoningDurationSeconds == this.reasoningDurationSeconds &&
          other.timestamp == this.timestamp);
}

class LocalMessagesCompanion extends UpdateCompanion<LocalMessage> {
  final Value<String> id;
  final Value<String> threadId;
  final Value<String> role;
  final Value<String> content;
  final Value<int> feedback;
  final Value<String?> modelName;
  final Value<String?> metrics;
  final Value<String?> toolEvents;
  final Value<String?> activity;
  final Value<String?> reasoning;
  final Value<double?> reasoningDurationSeconds;
  final Value<DateTime?> timestamp;
  final Value<int> rowid;
  const LocalMessagesCompanion({
    this.id = const Value.absent(),
    this.threadId = const Value.absent(),
    this.role = const Value.absent(),
    this.content = const Value.absent(),
    this.feedback = const Value.absent(),
    this.modelName = const Value.absent(),
    this.metrics = const Value.absent(),
    this.toolEvents = const Value.absent(),
    this.activity = const Value.absent(),
    this.reasoning = const Value.absent(),
    this.reasoningDurationSeconds = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMessagesCompanion.insert({
    required String id,
    required String threadId,
    required String role,
    required String content,
    this.feedback = const Value.absent(),
    this.modelName = const Value.absent(),
    this.metrics = const Value.absent(),
    this.toolEvents = const Value.absent(),
    this.activity = const Value.absent(),
    this.reasoning = const Value.absent(),
    this.reasoningDurationSeconds = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        threadId = Value(threadId),
        role = Value(role),
        content = Value(content);
  static Insertable<LocalMessage> custom({
    Expression<String>? id,
    Expression<String>? threadId,
    Expression<String>? role,
    Expression<String>? content,
    Expression<int>? feedback,
    Expression<String>? modelName,
    Expression<String>? metrics,
    Expression<String>? toolEvents,
    Expression<String>? activity,
    Expression<String>? reasoning,
    Expression<double>? reasoningDurationSeconds,
    Expression<DateTime>? timestamp,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (threadId != null) 'thread_id': threadId,
      if (role != null) 'role': role,
      if (content != null) 'content': content,
      if (feedback != null) 'feedback': feedback,
      if (modelName != null) 'model_name': modelName,
      if (metrics != null) 'metrics': metrics,
      if (toolEvents != null) 'tool_events': toolEvents,
      if (activity != null) 'activity': activity,
      if (reasoning != null) 'reasoning': reasoning,
      if (reasoningDurationSeconds != null)
        'reasoning_duration_seconds': reasoningDurationSeconds,
      if (timestamp != null) 'timestamp': timestamp,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMessagesCompanion copyWith(
      {Value<String>? id,
      Value<String>? threadId,
      Value<String>? role,
      Value<String>? content,
      Value<int>? feedback,
      Value<String?>? modelName,
      Value<String?>? metrics,
      Value<String?>? toolEvents,
      Value<String?>? activity,
      Value<String?>? reasoning,
      Value<double?>? reasoningDurationSeconds,
      Value<DateTime?>? timestamp,
      Value<int>? rowid}) {
    return LocalMessagesCompanion(
      id: id ?? this.id,
      threadId: threadId ?? this.threadId,
      role: role ?? this.role,
      content: content ?? this.content,
      feedback: feedback ?? this.feedback,
      modelName: modelName ?? this.modelName,
      metrics: metrics ?? this.metrics,
      toolEvents: toolEvents ?? this.toolEvents,
      activity: activity ?? this.activity,
      reasoning: reasoning ?? this.reasoning,
      reasoningDurationSeconds:
          reasoningDurationSeconds ?? this.reasoningDurationSeconds,
      timestamp: timestamp ?? this.timestamp,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (threadId.present) {
      map['thread_id'] = Variable<String>(threadId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (feedback.present) {
      map['feedback'] = Variable<int>(feedback.value);
    }
    if (modelName.present) {
      map['model_name'] = Variable<String>(modelName.value);
    }
    if (metrics.present) {
      map['metrics'] = Variable<String>(metrics.value);
    }
    if (toolEvents.present) {
      map['tool_events'] = Variable<String>(toolEvents.value);
    }
    if (activity.present) {
      map['activity'] = Variable<String>(activity.value);
    }
    if (reasoning.present) {
      map['reasoning'] = Variable<String>(reasoning.value);
    }
    if (reasoningDurationSeconds.present) {
      map['reasoning_duration_seconds'] =
          Variable<double>(reasoningDurationSeconds.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<DateTime>(timestamp.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessagesCompanion(')
          ..write('id: $id, ')
          ..write('threadId: $threadId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('feedback: $feedback, ')
          ..write('modelName: $modelName, ')
          ..write('metrics: $metrics, ')
          ..write('toolEvents: $toolEvents, ')
          ..write('activity: $activity, ')
          ..write('reasoning: $reasoning, ')
          ..write('reasoningDurationSeconds: $reasoningDurationSeconds, ')
          ..write('timestamp: $timestamp, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ArtifactWorkEntriesTable extends ArtifactWorkEntries
    with TableInfo<$ArtifactWorkEntriesTable, ArtifactWorkEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ArtifactWorkEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _workKeyMeta =
      const VerificationMeta('workKey');
  @override
  late final GeneratedColumn<String> workKey = GeneratedColumn<String>(
      'work_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _stateJsonMeta =
      const VerificationMeta('stateJson');
  @override
  late final GeneratedColumn<String> stateJson = GeneratedColumn<String>(
      'state_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMsMeta =
      const VerificationMeta('updatedAtMs');
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
      'updated_at_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [workKey, stateJson, updatedAtMs];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'artifact_work_entries';
  @override
  VerificationContext validateIntegrity(Insertable<ArtifactWorkEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('work_key')) {
      context.handle(_workKeyMeta,
          workKey.isAcceptableOrUnknown(data['work_key']!, _workKeyMeta));
    } else if (isInserting) {
      context.missing(_workKeyMeta);
    }
    if (data.containsKey('state_json')) {
      context.handle(_stateJsonMeta,
          stateJson.isAcceptableOrUnknown(data['state_json']!, _stateJsonMeta));
    } else if (isInserting) {
      context.missing(_stateJsonMeta);
    }
    if (data.containsKey('updated_at_ms')) {
      context.handle(
          _updatedAtMsMeta,
          updatedAtMs.isAcceptableOrUnknown(
              data['updated_at_ms']!, _updatedAtMsMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {workKey};
  @override
  ArtifactWorkEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ArtifactWorkEntry(
      workKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}work_key'])!,
      stateJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}state_json'])!,
      updatedAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at_ms'])!,
    );
  }

  @override
  $ArtifactWorkEntriesTable createAlias(String alias) {
    return $ArtifactWorkEntriesTable(attachedDatabase, alias);
  }
}

class ArtifactWorkEntry extends DataClass
    implements Insertable<ArtifactWorkEntry> {
  final String workKey;
  final String stateJson;
  final int updatedAtMs;
  const ArtifactWorkEntry(
      {required this.workKey,
      required this.stateJson,
      required this.updatedAtMs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['work_key'] = Variable<String>(workKey);
    map['state_json'] = Variable<String>(stateJson);
    map['updated_at_ms'] = Variable<int>(updatedAtMs);
    return map;
  }

  ArtifactWorkEntriesCompanion toCompanion(bool nullToAbsent) {
    return ArtifactWorkEntriesCompanion(
      workKey: Value(workKey),
      stateJson: Value(stateJson),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory ArtifactWorkEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ArtifactWorkEntry(
      workKey: serializer.fromJson<String>(json['workKey']),
      stateJson: serializer.fromJson<String>(json['stateJson']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'workKey': serializer.toJson<String>(workKey),
      'stateJson': serializer.toJson<String>(stateJson),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  ArtifactWorkEntry copyWith(
          {String? workKey, String? stateJson, int? updatedAtMs}) =>
      ArtifactWorkEntry(
        workKey: workKey ?? this.workKey,
        stateJson: stateJson ?? this.stateJson,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      );
  ArtifactWorkEntry copyWithCompanion(ArtifactWorkEntriesCompanion data) {
    return ArtifactWorkEntry(
      workKey: data.workKey.present ? data.workKey.value : this.workKey,
      stateJson: data.stateJson.present ? data.stateJson.value : this.stateJson,
      updatedAtMs:
          data.updatedAtMs.present ? data.updatedAtMs.value : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ArtifactWorkEntry(')
          ..write('workKey: $workKey, ')
          ..write('stateJson: $stateJson, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(workKey, stateJson, updatedAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ArtifactWorkEntry &&
          other.workKey == this.workKey &&
          other.stateJson == this.stateJson &&
          other.updatedAtMs == this.updatedAtMs);
}

class ArtifactWorkEntriesCompanion extends UpdateCompanion<ArtifactWorkEntry> {
  final Value<String> workKey;
  final Value<String> stateJson;
  final Value<int> updatedAtMs;
  final Value<int> rowid;
  const ArtifactWorkEntriesCompanion({
    this.workKey = const Value.absent(),
    this.stateJson = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ArtifactWorkEntriesCompanion.insert({
    required String workKey,
    required String stateJson,
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : workKey = Value(workKey),
        stateJson = Value(stateJson);
  static Insertable<ArtifactWorkEntry> custom({
    Expression<String>? workKey,
    Expression<String>? stateJson,
    Expression<int>? updatedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (workKey != null) 'work_key': workKey,
      if (stateJson != null) 'state_json': stateJson,
      if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ArtifactWorkEntriesCompanion copyWith(
      {Value<String>? workKey,
      Value<String>? stateJson,
      Value<int>? updatedAtMs,
      Value<int>? rowid}) {
    return ArtifactWorkEntriesCompanion(
      workKey: workKey ?? this.workKey,
      stateJson: stateJson ?? this.stateJson,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (workKey.present) {
      map['work_key'] = Variable<String>(workKey.value);
    }
    if (stateJson.present) {
      map['state_json'] = Variable<String>(stateJson.value);
    }
    if (updatedAtMs.present) {
      map['updated_at_ms'] = Variable<int>(updatedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ArtifactWorkEntriesCompanion(')
          ..write('workKey: $workKey, ')
          ..write('stateJson: $stateJson, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ArtifactRuntimeStorageEntriesTable extends ArtifactRuntimeStorageEntries
    with
        TableInfo<$ArtifactRuntimeStorageEntriesTable,
            ArtifactRuntimeStorageEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ArtifactRuntimeStorageEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _scopeIdMeta =
      const VerificationMeta('scopeId');
  @override
  late final GeneratedColumn<String> scopeId = GeneratedColumn<String>(
      'scope_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _entryKeyMeta =
      const VerificationMeta('entryKey');
  @override
  late final GeneratedColumn<String> entryKey = GeneratedColumn<String>(
      'entry_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _entryValueMeta =
      const VerificationMeta('entryValue');
  @override
  late final GeneratedColumn<String> entryValue = GeneratedColumn<String>(
      'entry_value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMsMeta =
      const VerificationMeta('updatedAtMs');
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
      'updated_at_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns =>
      [scopeId, entryKey, entryValue, updatedAtMs];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'artifact_runtime_storage_entries';
  @override
  VerificationContext validateIntegrity(
      Insertable<ArtifactRuntimeStorageEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('scope_id')) {
      context.handle(_scopeIdMeta,
          scopeId.isAcceptableOrUnknown(data['scope_id']!, _scopeIdMeta));
    } else if (isInserting) {
      context.missing(_scopeIdMeta);
    }
    if (data.containsKey('entry_key')) {
      context.handle(_entryKeyMeta,
          entryKey.isAcceptableOrUnknown(data['entry_key']!, _entryKeyMeta));
    } else if (isInserting) {
      context.missing(_entryKeyMeta);
    }
    if (data.containsKey('entry_value')) {
      context.handle(
          _entryValueMeta,
          entryValue.isAcceptableOrUnknown(
              data['entry_value']!, _entryValueMeta));
    } else if (isInserting) {
      context.missing(_entryValueMeta);
    }
    if (data.containsKey('updated_at_ms')) {
      context.handle(
          _updatedAtMsMeta,
          updatedAtMs.isAcceptableOrUnknown(
              data['updated_at_ms']!, _updatedAtMsMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {scopeId, entryKey};
  @override
  ArtifactRuntimeStorageEntry map(Map<String, dynamic> data,
      {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ArtifactRuntimeStorageEntry(
      scopeId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}scope_id'])!,
      entryKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entry_key'])!,
      entryValue: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entry_value'])!,
      updatedAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at_ms'])!,
    );
  }

  @override
  $ArtifactRuntimeStorageEntriesTable createAlias(String alias) {
    return $ArtifactRuntimeStorageEntriesTable(attachedDatabase, alias);
  }
}

class ArtifactRuntimeStorageEntry extends DataClass
    implements Insertable<ArtifactRuntimeStorageEntry> {
  final String scopeId;
  final String entryKey;
  final String entryValue;
  final int updatedAtMs;
  const ArtifactRuntimeStorageEntry(
      {required this.scopeId,
      required this.entryKey,
      required this.entryValue,
      required this.updatedAtMs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['scope_id'] = Variable<String>(scopeId);
    map['entry_key'] = Variable<String>(entryKey);
    map['entry_value'] = Variable<String>(entryValue);
    map['updated_at_ms'] = Variable<int>(updatedAtMs);
    return map;
  }

  ArtifactRuntimeStorageEntriesCompanion toCompanion(bool nullToAbsent) {
    return ArtifactRuntimeStorageEntriesCompanion(
      scopeId: Value(scopeId),
      entryKey: Value(entryKey),
      entryValue: Value(entryValue),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory ArtifactRuntimeStorageEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ArtifactRuntimeStorageEntry(
      scopeId: serializer.fromJson<String>(json['scopeId']),
      entryKey: serializer.fromJson<String>(json['entryKey']),
      entryValue: serializer.fromJson<String>(json['entryValue']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'scopeId': serializer.toJson<String>(scopeId),
      'entryKey': serializer.toJson<String>(entryKey),
      'entryValue': serializer.toJson<String>(entryValue),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  ArtifactRuntimeStorageEntry copyWith(
          {String? scopeId,
          String? entryKey,
          String? entryValue,
          int? updatedAtMs}) =>
      ArtifactRuntimeStorageEntry(
        scopeId: scopeId ?? this.scopeId,
        entryKey: entryKey ?? this.entryKey,
        entryValue: entryValue ?? this.entryValue,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      );
  ArtifactRuntimeStorageEntry copyWithCompanion(
      ArtifactRuntimeStorageEntriesCompanion data) {
    return ArtifactRuntimeStorageEntry(
      scopeId: data.scopeId.present ? data.scopeId.value : this.scopeId,
      entryKey: data.entryKey.present ? data.entryKey.value : this.entryKey,
      entryValue:
          data.entryValue.present ? data.entryValue.value : this.entryValue,
      updatedAtMs:
          data.updatedAtMs.present ? data.updatedAtMs.value : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ArtifactRuntimeStorageEntry(')
          ..write('scopeId: $scopeId, ')
          ..write('entryKey: $entryKey, ')
          ..write('entryValue: $entryValue, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(scopeId, entryKey, entryValue, updatedAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ArtifactRuntimeStorageEntry &&
          other.scopeId == this.scopeId &&
          other.entryKey == this.entryKey &&
          other.entryValue == this.entryValue &&
          other.updatedAtMs == this.updatedAtMs);
}

class ArtifactRuntimeStorageEntriesCompanion
    extends UpdateCompanion<ArtifactRuntimeStorageEntry> {
  final Value<String> scopeId;
  final Value<String> entryKey;
  final Value<String> entryValue;
  final Value<int> updatedAtMs;
  final Value<int> rowid;
  const ArtifactRuntimeStorageEntriesCompanion({
    this.scopeId = const Value.absent(),
    this.entryKey = const Value.absent(),
    this.entryValue = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ArtifactRuntimeStorageEntriesCompanion.insert({
    required String scopeId,
    required String entryKey,
    required String entryValue,
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : scopeId = Value(scopeId),
        entryKey = Value(entryKey),
        entryValue = Value(entryValue);
  static Insertable<ArtifactRuntimeStorageEntry> custom({
    Expression<String>? scopeId,
    Expression<String>? entryKey,
    Expression<String>? entryValue,
    Expression<int>? updatedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (scopeId != null) 'scope_id': scopeId,
      if (entryKey != null) 'entry_key': entryKey,
      if (entryValue != null) 'entry_value': entryValue,
      if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ArtifactRuntimeStorageEntriesCompanion copyWith(
      {Value<String>? scopeId,
      Value<String>? entryKey,
      Value<String>? entryValue,
      Value<int>? updatedAtMs,
      Value<int>? rowid}) {
    return ArtifactRuntimeStorageEntriesCompanion(
      scopeId: scopeId ?? this.scopeId,
      entryKey: entryKey ?? this.entryKey,
      entryValue: entryValue ?? this.entryValue,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (scopeId.present) {
      map['scope_id'] = Variable<String>(scopeId.value);
    }
    if (entryKey.present) {
      map['entry_key'] = Variable<String>(entryKey.value);
    }
    if (entryValue.present) {
      map['entry_value'] = Variable<String>(entryValue.value);
    }
    if (updatedAtMs.present) {
      map['updated_at_ms'] = Variable<int>(updatedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ArtifactRuntimeStorageEntriesCompanion(')
          ..write('scopeId: $scopeId, ')
          ..write('entryKey: $entryKey, ')
          ..write('entryValue: $entryValue, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$LocalChatDatabase extends GeneratedDatabase {
  _$LocalChatDatabase(QueryExecutor e) : super(e);
  $LocalChatDatabaseManager get managers => $LocalChatDatabaseManager(this);
  late final $LocalThreadsTable localThreads = $LocalThreadsTable(this);
  late final $LocalMessagesTable localMessages = $LocalMessagesTable(this);
  late final $ArtifactWorkEntriesTable artifactWorkEntries =
      $ArtifactWorkEntriesTable(this);
  late final $ArtifactRuntimeStorageEntriesTable artifactRuntimeStorageEntries =
      $ArtifactRuntimeStorageEntriesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        localThreads,
        localMessages,
        artifactWorkEntries,
        artifactRuntimeStorageEntries
      ];
}

typedef $$LocalThreadsTableCreateCompanionBuilder = LocalThreadsCompanion
    Function({
  required String threadId,
  required String title,
  Value<bool> isPinned,
  Value<bool> isArchived,
  Value<String?> projectId,
  Value<DateTime?> timestamp,
  Value<int> rowid,
});
typedef $$LocalThreadsTableUpdateCompanionBuilder = LocalThreadsCompanion
    Function({
  Value<String> threadId,
  Value<String> title,
  Value<bool> isPinned,
  Value<bool> isArchived,
  Value<String?> projectId,
  Value<DateTime?> timestamp,
  Value<int> rowid,
});

class $$LocalThreadsTableFilterComposer
    extends Composer<_$LocalChatDatabase, $LocalThreadsTable> {
  $$LocalThreadsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get threadId => $composableBuilder(
      column: $table.threadId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isPinned => $composableBuilder(
      column: $table.isPinned, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isArchived => $composableBuilder(
      column: $table.isArchived, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get projectId => $composableBuilder(
      column: $table.projectId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnFilters(column));
}

class $$LocalThreadsTableOrderingComposer
    extends Composer<_$LocalChatDatabase, $LocalThreadsTable> {
  $$LocalThreadsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get threadId => $composableBuilder(
      column: $table.threadId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isPinned => $composableBuilder(
      column: $table.isPinned, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isArchived => $composableBuilder(
      column: $table.isArchived, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get projectId => $composableBuilder(
      column: $table.projectId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnOrderings(column));
}

class $$LocalThreadsTableAnnotationComposer
    extends Composer<_$LocalChatDatabase, $LocalThreadsTable> {
  $$LocalThreadsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get threadId =>
      $composableBuilder(column: $table.threadId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<bool> get isPinned =>
      $composableBuilder(column: $table.isPinned, builder: (column) => column);

  GeneratedColumn<bool> get isArchived => $composableBuilder(
      column: $table.isArchived, builder: (column) => column);

  GeneratedColumn<String> get projectId =>
      $composableBuilder(column: $table.projectId, builder: (column) => column);

  GeneratedColumn<DateTime> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);
}

class $$LocalThreadsTableTableManager extends RootTableManager<
    _$LocalChatDatabase,
    $LocalThreadsTable,
    LocalThread,
    $$LocalThreadsTableFilterComposer,
    $$LocalThreadsTableOrderingComposer,
    $$LocalThreadsTableAnnotationComposer,
    $$LocalThreadsTableCreateCompanionBuilder,
    $$LocalThreadsTableUpdateCompanionBuilder,
    (
      LocalThread,
      BaseReferences<_$LocalChatDatabase, $LocalThreadsTable, LocalThread>
    ),
    LocalThread,
    PrefetchHooks Function()> {
  $$LocalThreadsTableTableManager(
      _$LocalChatDatabase db, $LocalThreadsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalThreadsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalThreadsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalThreadsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> threadId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<bool> isPinned = const Value.absent(),
            Value<bool> isArchived = const Value.absent(),
            Value<String?> projectId = const Value.absent(),
            Value<DateTime?> timestamp = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalThreadsCompanion(
            threadId: threadId,
            title: title,
            isPinned: isPinned,
            isArchived: isArchived,
            projectId: projectId,
            timestamp: timestamp,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String threadId,
            required String title,
            Value<bool> isPinned = const Value.absent(),
            Value<bool> isArchived = const Value.absent(),
            Value<String?> projectId = const Value.absent(),
            Value<DateTime?> timestamp = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalThreadsCompanion.insert(
            threadId: threadId,
            title: title,
            isPinned: isPinned,
            isArchived: isArchived,
            projectId: projectId,
            timestamp: timestamp,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalThreadsTableProcessedTableManager = ProcessedTableManager<
    _$LocalChatDatabase,
    $LocalThreadsTable,
    LocalThread,
    $$LocalThreadsTableFilterComposer,
    $$LocalThreadsTableOrderingComposer,
    $$LocalThreadsTableAnnotationComposer,
    $$LocalThreadsTableCreateCompanionBuilder,
    $$LocalThreadsTableUpdateCompanionBuilder,
    (
      LocalThread,
      BaseReferences<_$LocalChatDatabase, $LocalThreadsTable, LocalThread>
    ),
    LocalThread,
    PrefetchHooks Function()>;
typedef $$LocalMessagesTableCreateCompanionBuilder = LocalMessagesCompanion
    Function({
  required String id,
  required String threadId,
  required String role,
  required String content,
  Value<int> feedback,
  Value<String?> modelName,
  Value<String?> metrics,
  Value<String?> toolEvents,
  Value<String?> activity,
  Value<String?> reasoning,
  Value<double?> reasoningDurationSeconds,
  Value<DateTime?> timestamp,
  Value<int> rowid,
});
typedef $$LocalMessagesTableUpdateCompanionBuilder = LocalMessagesCompanion
    Function({
  Value<String> id,
  Value<String> threadId,
  Value<String> role,
  Value<String> content,
  Value<int> feedback,
  Value<String?> modelName,
  Value<String?> metrics,
  Value<String?> toolEvents,
  Value<String?> activity,
  Value<String?> reasoning,
  Value<double?> reasoningDurationSeconds,
  Value<DateTime?> timestamp,
  Value<int> rowid,
});

class $$LocalMessagesTableFilterComposer
    extends Composer<_$LocalChatDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get threadId => $composableBuilder(
      column: $table.threadId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get feedback => $composableBuilder(
      column: $table.feedback, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get modelName => $composableBuilder(
      column: $table.modelName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get metrics => $composableBuilder(
      column: $table.metrics, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get toolEvents => $composableBuilder(
      column: $table.toolEvents, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get activity => $composableBuilder(
      column: $table.activity, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get reasoning => $composableBuilder(
      column: $table.reasoning, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get reasoningDurationSeconds => $composableBuilder(
      column: $table.reasoningDurationSeconds,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnFilters(column));
}

class $$LocalMessagesTableOrderingComposer
    extends Composer<_$LocalChatDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get threadId => $composableBuilder(
      column: $table.threadId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get feedback => $composableBuilder(
      column: $table.feedback, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get modelName => $composableBuilder(
      column: $table.modelName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get metrics => $composableBuilder(
      column: $table.metrics, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get toolEvents => $composableBuilder(
      column: $table.toolEvents, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get activity => $composableBuilder(
      column: $table.activity, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get reasoning => $composableBuilder(
      column: $table.reasoning, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get reasoningDurationSeconds => $composableBuilder(
      column: $table.reasoningDurationSeconds,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get timestamp => $composableBuilder(
      column: $table.timestamp, builder: (column) => ColumnOrderings(column));
}

class $$LocalMessagesTableAnnotationComposer
    extends Composer<_$LocalChatDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get threadId =>
      $composableBuilder(column: $table.threadId, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<int> get feedback =>
      $composableBuilder(column: $table.feedback, builder: (column) => column);

  GeneratedColumn<String> get modelName =>
      $composableBuilder(column: $table.modelName, builder: (column) => column);

  GeneratedColumn<String> get metrics =>
      $composableBuilder(column: $table.metrics, builder: (column) => column);

  GeneratedColumn<String> get toolEvents => $composableBuilder(
      column: $table.toolEvents, builder: (column) => column);

  GeneratedColumn<String> get activity =>
      $composableBuilder(column: $table.activity, builder: (column) => column);

  GeneratedColumn<String> get reasoning =>
      $composableBuilder(column: $table.reasoning, builder: (column) => column);

  GeneratedColumn<double> get reasoningDurationSeconds => $composableBuilder(
      column: $table.reasoningDurationSeconds, builder: (column) => column);

  GeneratedColumn<DateTime> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);
}

class $$LocalMessagesTableTableManager extends RootTableManager<
    _$LocalChatDatabase,
    $LocalMessagesTable,
    LocalMessage,
    $$LocalMessagesTableFilterComposer,
    $$LocalMessagesTableOrderingComposer,
    $$LocalMessagesTableAnnotationComposer,
    $$LocalMessagesTableCreateCompanionBuilder,
    $$LocalMessagesTableUpdateCompanionBuilder,
    (
      LocalMessage,
      BaseReferences<_$LocalChatDatabase, $LocalMessagesTable, LocalMessage>
    ),
    LocalMessage,
    PrefetchHooks Function()> {
  $$LocalMessagesTableTableManager(
      _$LocalChatDatabase db, $LocalMessagesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> threadId = const Value.absent(),
            Value<String> role = const Value.absent(),
            Value<String> content = const Value.absent(),
            Value<int> feedback = const Value.absent(),
            Value<String?> modelName = const Value.absent(),
            Value<String?> metrics = const Value.absent(),
            Value<String?> toolEvents = const Value.absent(),
            Value<String?> activity = const Value.absent(),
            Value<String?> reasoning = const Value.absent(),
            Value<double?> reasoningDurationSeconds = const Value.absent(),
            Value<DateTime?> timestamp = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMessagesCompanion(
            id: id,
            threadId: threadId,
            role: role,
            content: content,
            feedback: feedback,
            modelName: modelName,
            metrics: metrics,
            toolEvents: toolEvents,
            activity: activity,
            reasoning: reasoning,
            reasoningDurationSeconds: reasoningDurationSeconds,
            timestamp: timestamp,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String threadId,
            required String role,
            required String content,
            Value<int> feedback = const Value.absent(),
            Value<String?> modelName = const Value.absent(),
            Value<String?> metrics = const Value.absent(),
            Value<String?> toolEvents = const Value.absent(),
            Value<String?> activity = const Value.absent(),
            Value<String?> reasoning = const Value.absent(),
            Value<double?> reasoningDurationSeconds = const Value.absent(),
            Value<DateTime?> timestamp = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalMessagesCompanion.insert(
            id: id,
            threadId: threadId,
            role: role,
            content: content,
            feedback: feedback,
            modelName: modelName,
            metrics: metrics,
            toolEvents: toolEvents,
            activity: activity,
            reasoning: reasoning,
            reasoningDurationSeconds: reasoningDurationSeconds,
            timestamp: timestamp,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalMessagesTableProcessedTableManager = ProcessedTableManager<
    _$LocalChatDatabase,
    $LocalMessagesTable,
    LocalMessage,
    $$LocalMessagesTableFilterComposer,
    $$LocalMessagesTableOrderingComposer,
    $$LocalMessagesTableAnnotationComposer,
    $$LocalMessagesTableCreateCompanionBuilder,
    $$LocalMessagesTableUpdateCompanionBuilder,
    (
      LocalMessage,
      BaseReferences<_$LocalChatDatabase, $LocalMessagesTable, LocalMessage>
    ),
    LocalMessage,
    PrefetchHooks Function()>;
typedef $$ArtifactWorkEntriesTableCreateCompanionBuilder
    = ArtifactWorkEntriesCompanion Function({
  required String workKey,
  required String stateJson,
  Value<int> updatedAtMs,
  Value<int> rowid,
});
typedef $$ArtifactWorkEntriesTableUpdateCompanionBuilder
    = ArtifactWorkEntriesCompanion Function({
  Value<String> workKey,
  Value<String> stateJson,
  Value<int> updatedAtMs,
  Value<int> rowid,
});

class $$ArtifactWorkEntriesTableFilterComposer
    extends Composer<_$LocalChatDatabase, $ArtifactWorkEntriesTable> {
  $$ArtifactWorkEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get workKey => $composableBuilder(
      column: $table.workKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get stateJson => $composableBuilder(
      column: $table.stateJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnFilters(column));
}

class $$ArtifactWorkEntriesTableOrderingComposer
    extends Composer<_$LocalChatDatabase, $ArtifactWorkEntriesTable> {
  $$ArtifactWorkEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get workKey => $composableBuilder(
      column: $table.workKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get stateJson => $composableBuilder(
      column: $table.stateJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnOrderings(column));
}

class $$ArtifactWorkEntriesTableAnnotationComposer
    extends Composer<_$LocalChatDatabase, $ArtifactWorkEntriesTable> {
  $$ArtifactWorkEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get workKey =>
      $composableBuilder(column: $table.workKey, builder: (column) => column);

  GeneratedColumn<String> get stateJson =>
      $composableBuilder(column: $table.stateJson, builder: (column) => column);

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => column);
}

class $$ArtifactWorkEntriesTableTableManager extends RootTableManager<
    _$LocalChatDatabase,
    $ArtifactWorkEntriesTable,
    ArtifactWorkEntry,
    $$ArtifactWorkEntriesTableFilterComposer,
    $$ArtifactWorkEntriesTableOrderingComposer,
    $$ArtifactWorkEntriesTableAnnotationComposer,
    $$ArtifactWorkEntriesTableCreateCompanionBuilder,
    $$ArtifactWorkEntriesTableUpdateCompanionBuilder,
    (
      ArtifactWorkEntry,
      BaseReferences<_$LocalChatDatabase, $ArtifactWorkEntriesTable,
          ArtifactWorkEntry>
    ),
    ArtifactWorkEntry,
    PrefetchHooks Function()> {
  $$ArtifactWorkEntriesTableTableManager(
      _$LocalChatDatabase db, $ArtifactWorkEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ArtifactWorkEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ArtifactWorkEntriesTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ArtifactWorkEntriesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> workKey = const Value.absent(),
            Value<String> stateJson = const Value.absent(),
            Value<int> updatedAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ArtifactWorkEntriesCompanion(
            workKey: workKey,
            stateJson: stateJson,
            updatedAtMs: updatedAtMs,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String workKey,
            required String stateJson,
            Value<int> updatedAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ArtifactWorkEntriesCompanion.insert(
            workKey: workKey,
            stateJson: stateJson,
            updatedAtMs: updatedAtMs,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ArtifactWorkEntriesTableProcessedTableManager = ProcessedTableManager<
    _$LocalChatDatabase,
    $ArtifactWorkEntriesTable,
    ArtifactWorkEntry,
    $$ArtifactWorkEntriesTableFilterComposer,
    $$ArtifactWorkEntriesTableOrderingComposer,
    $$ArtifactWorkEntriesTableAnnotationComposer,
    $$ArtifactWorkEntriesTableCreateCompanionBuilder,
    $$ArtifactWorkEntriesTableUpdateCompanionBuilder,
    (
      ArtifactWorkEntry,
      BaseReferences<_$LocalChatDatabase, $ArtifactWorkEntriesTable,
          ArtifactWorkEntry>
    ),
    ArtifactWorkEntry,
    PrefetchHooks Function()>;
typedef $$ArtifactRuntimeStorageEntriesTableCreateCompanionBuilder
    = ArtifactRuntimeStorageEntriesCompanion Function({
  required String scopeId,
  required String entryKey,
  required String entryValue,
  Value<int> updatedAtMs,
  Value<int> rowid,
});
typedef $$ArtifactRuntimeStorageEntriesTableUpdateCompanionBuilder
    = ArtifactRuntimeStorageEntriesCompanion Function({
  Value<String> scopeId,
  Value<String> entryKey,
  Value<String> entryValue,
  Value<int> updatedAtMs,
  Value<int> rowid,
});

class $$ArtifactRuntimeStorageEntriesTableFilterComposer
    extends Composer<_$LocalChatDatabase, $ArtifactRuntimeStorageEntriesTable> {
  $$ArtifactRuntimeStorageEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get scopeId => $composableBuilder(
      column: $table.scopeId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entryKey => $composableBuilder(
      column: $table.entryKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entryValue => $composableBuilder(
      column: $table.entryValue, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnFilters(column));
}

class $$ArtifactRuntimeStorageEntriesTableOrderingComposer
    extends Composer<_$LocalChatDatabase, $ArtifactRuntimeStorageEntriesTable> {
  $$ArtifactRuntimeStorageEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get scopeId => $composableBuilder(
      column: $table.scopeId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entryKey => $composableBuilder(
      column: $table.entryKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entryValue => $composableBuilder(
      column: $table.entryValue, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnOrderings(column));
}

class $$ArtifactRuntimeStorageEntriesTableAnnotationComposer
    extends Composer<_$LocalChatDatabase, $ArtifactRuntimeStorageEntriesTable> {
  $$ArtifactRuntimeStorageEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get scopeId =>
      $composableBuilder(column: $table.scopeId, builder: (column) => column);

  GeneratedColumn<String> get entryKey =>
      $composableBuilder(column: $table.entryKey, builder: (column) => column);

  GeneratedColumn<String> get entryValue => $composableBuilder(
      column: $table.entryValue, builder: (column) => column);

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => column);
}

class $$ArtifactRuntimeStorageEntriesTableTableManager extends RootTableManager<
    _$LocalChatDatabase,
    $ArtifactRuntimeStorageEntriesTable,
    ArtifactRuntimeStorageEntry,
    $$ArtifactRuntimeStorageEntriesTableFilterComposer,
    $$ArtifactRuntimeStorageEntriesTableOrderingComposer,
    $$ArtifactRuntimeStorageEntriesTableAnnotationComposer,
    $$ArtifactRuntimeStorageEntriesTableCreateCompanionBuilder,
    $$ArtifactRuntimeStorageEntriesTableUpdateCompanionBuilder,
    (
      ArtifactRuntimeStorageEntry,
      BaseReferences<_$LocalChatDatabase, $ArtifactRuntimeStorageEntriesTable,
          ArtifactRuntimeStorageEntry>
    ),
    ArtifactRuntimeStorageEntry,
    PrefetchHooks Function()> {
  $$ArtifactRuntimeStorageEntriesTableTableManager(
      _$LocalChatDatabase db, $ArtifactRuntimeStorageEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ArtifactRuntimeStorageEntriesTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$ArtifactRuntimeStorageEntriesTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ArtifactRuntimeStorageEntriesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> scopeId = const Value.absent(),
            Value<String> entryKey = const Value.absent(),
            Value<String> entryValue = const Value.absent(),
            Value<int> updatedAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ArtifactRuntimeStorageEntriesCompanion(
            scopeId: scopeId,
            entryKey: entryKey,
            entryValue: entryValue,
            updatedAtMs: updatedAtMs,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String scopeId,
            required String entryKey,
            required String entryValue,
            Value<int> updatedAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ArtifactRuntimeStorageEntriesCompanion.insert(
            scopeId: scopeId,
            entryKey: entryKey,
            entryValue: entryValue,
            updatedAtMs: updatedAtMs,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ArtifactRuntimeStorageEntriesTableProcessedTableManager
    = ProcessedTableManager<
        _$LocalChatDatabase,
        $ArtifactRuntimeStorageEntriesTable,
        ArtifactRuntimeStorageEntry,
        $$ArtifactRuntimeStorageEntriesTableFilterComposer,
        $$ArtifactRuntimeStorageEntriesTableOrderingComposer,
        $$ArtifactRuntimeStorageEntriesTableAnnotationComposer,
        $$ArtifactRuntimeStorageEntriesTableCreateCompanionBuilder,
        $$ArtifactRuntimeStorageEntriesTableUpdateCompanionBuilder,
        (
          ArtifactRuntimeStorageEntry,
          BaseReferences<_$LocalChatDatabase,
              $ArtifactRuntimeStorageEntriesTable, ArtifactRuntimeStorageEntry>
        ),
        ArtifactRuntimeStorageEntry,
        PrefetchHooks Function()>;

class $LocalChatDatabaseManager {
  final _$LocalChatDatabase _db;
  $LocalChatDatabaseManager(this._db);
  $$LocalThreadsTableTableManager get localThreads =>
      $$LocalThreadsTableTableManager(_db, _db.localThreads);
  $$LocalMessagesTableTableManager get localMessages =>
      $$LocalMessagesTableTableManager(_db, _db.localMessages);
  $$ArtifactWorkEntriesTableTableManager get artifactWorkEntries =>
      $$ArtifactWorkEntriesTableTableManager(_db, _db.artifactWorkEntries);
  $$ArtifactRuntimeStorageEntriesTableTableManager
      get artifactRuntimeStorageEntries =>
          $$ArtifactRuntimeStorageEntriesTableTableManager(
              _db, _db.artifactRuntimeStorageEntries);
}
