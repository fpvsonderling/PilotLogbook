/// Pilots' competencies: licences, trainings, medicals, insurance, each
/// with its expiry date and a link to the document in Google Drive.
library;

import 'local_db.dart';
import 'schema.dart';

/// Types offered as chips; any other can be typed.
const competencyTypes = [
  'UAS pilot licence',
  'GWO',
  'Medical',
  'Insurance',
  'First aid',
  'Radio licence',
];

/// From this many days before the expiry date it shows as expiring.
const expiringDays = 30;

enum CompetencyStatus { valid, expiring, expired }

class Competency {
  const Competency(this.row);
  final DbRow row;

  String get id => row['id'] as String;
  String? get personId => row['person_id'] as String?;
  String get type => (row['type'] as String? ?? '').trim();
  String get number => (row['number'] as String? ?? '').trim();
  String get issuedOn => (row['issued_on'] as String? ?? '').trim();
  String get expiresOn => (row['expires_on'] as String? ?? '').trim();
  String get url => (row['url'] as String? ?? '').trim();
  String get notes => (row['notes'] as String? ?? '').trim();
  bool get verified => row['verified'] == 1;

  /// Days from [today] to the expiry date; null when it does not expire.
  int? daysLeft(DateTime today) {
    final d = DateTime.tryParse(expiresOn);
    if (d == null) return null;
    return DateTime(
      d.year,
      d.month,
      d.day,
    ).difference(DateTime(today.year, today.month, today.day)).inDays;
  }

  CompetencyStatus status(DateTime today) {
    final left = daysLeft(today);
    if (left == null) return CompetencyStatus.valid;
    // Valid on its expiry day, expired the day after.
    if (left < 0) return CompetencyStatus.expired;
    if (left <= expiringDays) return CompetencyStatus.expiring;
    return CompetencyStatus.valid;
  }

  /// "Valid", "Expires in 12 days", "Expired 3 days ago".
  String describe(DateTime today) {
    final left = daysLeft(today);
    if (left == null) return 'No expiry';
    if (left < 0) {
      return left == -1 ? 'Expired yesterday' : 'Expired ${-left} days ago';
    }
    if (left == 0) return 'Expires today';
    if (left <= expiringDays) {
      return left == 1 ? 'Expires tomorrow' : 'Expires in $left days';
    }
    return 'Valid';
  }
}

/// Competency queries on top of [LocalDb]. A person's own key only has
/// that person's rows on the device; the admin has everyone's.
class CompetencyLog {
  CompetencyLog(this.db, {DateTime Function()? today})
    : today = today ?? DateTime.now;
  final LocalDb db;
  final DateTime Function() today;

  /// Soonest expiry first, those without one last.
  List<Competency> all({String? personId}) => [
    for (final r in db.rows(
      Tables.competencies,
      where: personId == null ? null : 'person_id = ?',
      args: personId == null ? const [] : [personId],
      orderBy:
          "CASE WHEN COALESCE(expires_on, '') = '' THEN 1 ELSE 0 END, "
          'expires_on, type COLLATE NOCASE',
    ))
      Competency(r),
  ];

  /// Expired and expiring ones, which the top bar counts.
  List<Competency> alerts() => [
    for (final c in all())
      if (c.status(today()) != CompetencyStatus.valid) c,
  ];

  /// Expired ones of a person, for the warning on a flight on [day]
  /// (yyyy-MM-dd; today when null).
  List<Competency> expired(String personId, {String? day}) {
    final on = (day == null ? null : DateTime.tryParse(day)) ?? today();
    return [
      for (final c in all(personId: personId))
        if (c.status(on) == CompetencyStatus.expired) c,
    ];
  }
}
