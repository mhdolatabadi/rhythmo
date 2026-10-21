import 'package:rhythmo/features/library/data/track.dart';

class AdminSongReport {
  const AdminSongReport(
      {required this.track,
      required this.reason,
      required this.count,
      this.details});
  factory AdminSongReport.fromJson(Map<String, dynamic> json) =>
      AdminSongReport(
          track: Track.fromStoreJson(json['track'] as Map<String, dynamic>),
          reason: json['reason'] as String,
          details: json['details'] as String?,
          count: (json['reports'] as num).toInt());
  final Track track;
  final String reason;
  final String? details;
  final int count;
}

abstract interface class AdminSongReportsApi {
  Future<List<AdminSongReport>> songReports(String token);
  Future<void> moderateSong(String token, String entryId,
      {required bool remove});
}
