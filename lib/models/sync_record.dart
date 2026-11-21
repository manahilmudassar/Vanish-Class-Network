/// Representation of a synchronization record compatible with the teacher's
/// field-sync API (`/sync/push`, `/sync/pull?since=...`, `/records/{record_id}`).
class SyncRecord {
  final String recordId;
  final String type;
  final int timestamp;
  final Map<String, dynamic> data;

  const SyncRecord({
    required this.recordId,
    required this.type,
    required this.timestamp,
    required this.data,
  });

  Map<String, dynamic> toJson() => {
        'record_id': recordId,
        'type': type,
        'timestamp': timestamp,
        'data': data,
      };

  factory SyncRecord.fromJson(Map<String, dynamic> json) {
    return SyncRecord(
      recordId: json['record_id']?.toString() ?? '',
      type: json['type']?.toString() ?? 'unknown',
      timestamp: json['timestamp'] is int
          ? json['timestamp'] as int
          : (int.tryParse(json['timestamp']?.toString() ?? '') ?? 0),
      data: json['data'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['data'] as Map)
          : <String, dynamic>{},
    );
  }

  @override
  String toString() =>
      'SyncRecord(recordId: $recordId, type: $type, timestamp: $timestamp)';
}
