abstract interface class FeedbackApi {
  Future<void> submitFeedback(
      String token, String kind, String subject, String body);
  Future<List<Map<String, dynamic>>> feedbackInbox(String token);
  Future<void> resolveFeedback(String token, String id);
}
