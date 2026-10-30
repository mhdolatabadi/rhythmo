class BaleLecture {
  const BaleLecture({
    required this.id,
    required this.date,
    required this.title,
    required this.topic,
    required this.session,
    required this.needsReview,
  });
  final String id;
  final int date;
  final String title;
  final String topic;
  final int session;
  final bool needsReview;

  factory BaleLecture.fromJson(Map<String, dynamic> json) => BaleLecture(
        id: json['id'] as String,
        date: (json['date'] as num).toInt(),
        title: json['title'] as String? ?? '',
        topic: json['topic'] as String? ?? '',
        session: (json['session'] as num?)?.toInt() ?? 0,
        needsReview: json['needsReview'] as bool? ?? true,
      );

  BaleLecture reviewed(String topic, int session) => BaleLecture(
        id: id,
        date: date,
        title: title,
        topic: topic,
        session: session,
        needsReview: topic.trim().isEmpty || session < 1,
      );
}

class BaleArchivePage {
  const BaleArchivePage(this.entries, this.nextBefore, this.done);
  final List<BaleLecture> entries;
  final int nextBefore;
  final bool done;
  factory BaleArchivePage.fromJson(Map<String, dynamic> json) =>
      BaleArchivePage(
        [
          for (final item in json['entries'] as List<dynamic>)
            BaleLecture.fromJson(item as Map<String, dynamic>),
        ],
        (json['nextBefore'] as num).toInt(),
        json['done'] as bool,
      );
}

class BaleArchiveJob {
  const BaleArchiveJob(this.id, this.state, this.fileName, this.error,
      {this.messageId = '',
      this.date = 0,
      this.title = '',
      this.topic = '',
      this.session = 0});
  final String id;
  final String state;
  final String fileName;
  final String? error;
  final String messageId;
  final int date;
  final String title;
  final String topic;
  final int session;
  factory BaleArchiveJob.fromJson(Map<String, dynamic> json) => BaleArchiveJob(
        json['id'] as String,
        json['state'] as String,
        json['fileName'] as String,
        json['error'] as String?,
        messageId: json['messageId'] as String? ?? '',
        date: (json['date'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        topic: json['topic'] as String? ?? '',
        session: (json['session'] as num?)?.toInt() ?? 0,
      );

  BaleLecture get lecture => BaleLecture(
      id: messageId,
      date: date,
      title: title.isNotEmpty ? title : '$topic؛ جلسه $session',
      topic: topic,
      session: session,
      needsReview: topic.isEmpty || session <= 0);
}

abstract interface class BaleArchiveApi {
  Future<BaleArchivePage> previewBaleArchive(String token, {int? before});
  Future<BaleArchiveJob> importBaleLecture(String token, BaleLecture lecture);
  Future<List<BaleArchiveJob>> baleArchiveJobs(String token);
}
