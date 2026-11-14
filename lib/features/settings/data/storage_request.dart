/// An account's ask for more cloud storage (#208).
class StorageRequest {
  const StorageRequest({
    required this.id,
    required this.requestedBytes,
    required this.status,
    this.reason = '',
    this.grantedBytes,
    this.decisionReason,
    required this.createdAt,
  });

  factory StorageRequest.fromJson(Map<String, dynamic> json) => StorageRequest(
        id: json['id'] as String,
        requestedBytes: (json['requestedBytes'] as num).toInt(),
        status: json['status'] as String? ?? 'pending',
        reason: json['reason'] as String? ?? '',
        grantedBytes: (json['grantedBytes'] as num?)?.toInt(),
        decisionReason: json['decisionReason'] as String?,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  final String id;
  final int requestedBytes;

  /// pending, approved or rejected.
  final String status;
  final String reason;
  final int? grantedBytes;

  /// Why an admin turned it down, if they said.
  final String? decisionReason;
  final DateTime createdAt;

  bool get pending => status == 'pending';
  bool get approved => status == 'approved';
  bool get rejected => status == 'rejected';
}

/// A request in the admin queue, with who asked and what they use.
class PendingStorageRequest {
  const PendingStorageRequest({
    required this.request,
    required this.accountId,
    required this.email,
    required this.usedBytes,
    required this.quotaBytes,
  });

  factory PendingStorageRequest.fromJson(Map<String, dynamic> json) =>
      PendingStorageRequest(
        request: StorageRequest.fromJson(json),
        accountId: json['accountId'] as String? ?? '',
        email: json['email'] as String? ?? '',
        usedBytes: (json['usedBytes'] as num?)?.toInt() ?? 0,
        quotaBytes: (json['quotaBytes'] as num?)?.toInt() ?? 0,
      );

  final StorageRequest request;
  final String accountId;
  final String email;
  final int usedBytes;
  final int quotaBytes;
}

abstract interface class StorageRequestApi {
  /// The account's latest request; null when it never asked.
  Future<StorageRequest?> myStorageRequest(String token);

  /// Asks for [bytes] in all. Throws ApiException 409 `request_open` when
  /// one is already waiting, 403 `email_unverified` before verifying.
  Future<StorageRequest> requestStorage(String token, int bytes,
      {String reason = ''});

  Future<List<PendingStorageRequest>> pendingStorageRequests(String token);

  /// Throws ApiException 409 `not_pending` when another admin decided it,
  /// or `quota_decrease` when [bytes] is not above the account's quota.
  Future<void> decideStorageRequest(String token, String id,
      {required bool approved, int bytes = 0, String reason = ''});
}
