/// A reported public profile (#228), as an admin reviews it.
class ProfileReport {
  const ProfileReport({
    required this.userId,
    required this.handle,
    required this.displayName,
    required this.bio,
    required this.reason,
    required this.reports,
    this.details,
  });

  factory ProfileReport.fromJson(Map<String, dynamic> json) => ProfileReport(
        userId: json['userId'] as String,
        handle: json['handle'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        bio: json['bio'] as String? ?? '',
        reason: json['reason'] as String? ?? 'other',
        details: json['details'] as String?,
        reports: (json['reports'] as num?)?.toInt() ?? 1,
      );

  final String userId;
  final String handle;
  final String displayName;
  final String bio;

  /// The latest report's reason code.
  final String reason;
  final String? details;
  final int reports;
}

abstract interface class AdminProfileReportsApi {
  Future<List<ProfileReport>> listProfileReports(String token);

  /// Closes the profile's reports; [hide] also takes the profile down.
  Future<void> resolveProfileReports(String token, String userId,
      {required bool hide});
}
