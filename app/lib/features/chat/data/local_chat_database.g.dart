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
          ..write('timestamp: $timestamp')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, threadId, role, content, feedback,
      modelName, metrics, toolEvents, timestamp);
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
          ..write('timestamp: $timestamp, ')
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
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [localThreads, localMessages];
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

class $LocalChatDatabaseManager {
  final _$LocalChatDatabase _db;
  $LocalChatDatabaseManager(this._db);
  $$LocalThreadsTableTableManager get localThreads =>
      $$LocalThreadsTableTableManager(_db, _db.localThreads);
  $$LocalMessagesTableTableManager get localMessages =>
      $$LocalMessagesTableTableManager(_db, _db.localMessages);
}
