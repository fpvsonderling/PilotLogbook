/// The daily checklists. Each section is one column of the check's table in
/// Google Sheets, holding "Ok", "Not used" or the pilot's note, like the old
/// AppSheet "DailyCheks UA" sheet.
library;

import 'schema.dart';

const okValue = 'Ok';
const notUsedValue = 'Not used';

enum SectionResult { ok, problem, notUsed }

/// Reads a stored section value; null when the section is not done yet.
SectionResult? sectionResult(Object? value) {
  final v = value?.toString().trim() ?? '';
  if (v.isEmpty) return null;
  if (v.toLowerCase() == okValue.toLowerCase()) return SectionResult.ok;
  if (v.toLowerCase() == notUsedValue.toLowerCase()) {
    return SectionResult.notUsed;
  }
  return SectionResult.problem;
}

class ChecklistSection {
  const ChecklistSection(
    this.column,
    this.title,
    this.items, {
    this.group,
    this.canSkip = false,
  });

  /// Column in the check's table.
  final String column;
  final String title;
  final List<String> items;

  /// Heading the section is listed under (UA, GCS), if any.
  final String? group;

  /// Shows "N/A" (stored as "Not used").
  final bool canSkip;
}

class Checklist {
  const Checklist(this.name, this.table, this.sections);

  /// Shown to the pilot: "FB3", "M30T".
  final String name;
  final TableDef table;
  final List<ChecklistSection> sections;
}

/// FB3 Flight Manual v2.5.0, "Daily checks": UA and GCS in one check.
const fb3Checklist = Checklist('FB3', Tables.dailyChecksFb3, [
  ChecklistSection('motors_propellers', 'Motors and Propellers', [
    'Motors spin freely, no noise',
    'Motor mount torque seal continuous',
    'Motor–ESC connector tight, seal + lockwire',
    'Propellers: no cracks / deformation',
    'Prop screws torque seal OK',
    'No motor play (move prop tip up/down)',
  ], group: 'UA'),
  ChecklistSection('centre_plate', 'Centre Plate and Primary Avionics', [
    'Screws and nuts present, seal continuous',
    'No deformation on Center Plate',
    'M12 cables Primary → Expanders tight, sealed',
    'Battery power cables + connectors OK',
    'M12 Secondary ↔ Primary tight, sealed',
    'Front camera connector secured',
  ], group: 'UA'),
  ChecklistSection('load_structure', 'Load Structure Assembly and RCLH', [
    'Screws and nuts present, seal continuous',
    'Load Structure → Hook screws sealed',
    'M8 cable Hub 1 → RCLH tight, sealed',
    'No deformation on Load Structure',
    'No damage on RCLH (plastics, motor mount)',
  ], group: 'UA'),
  ChecklistSection('landing_gear', 'Landing gear', [
    'No deformation on Landing Gear',
    'Screws and nuts present, seal continuous',
    'RFD antennas fixed, heatshrink, connector tight',
    'Herelink + 5G antennas fixed, connector tight',
  ], group: 'UA'),
  ChecklistSection(
    'cargo_compartment',
    'Cargo Compartment',
    [
      'Screws and nuts present, seal continuous',
      'No cracks / bends (corners, leg joint, centre)',
      'Floating devices secured and closed',
    ],
    group: 'UA',
    canSkip: true,
  ),
  ChecklistSection(
    'external_rf',
    'External RF',
    ['External Herelink module connected', 'RFD Backbone Repeater on'],
    group: 'GCS',
    canSkip: true,
  ),
  ChecklistSection('power_on_gcs', 'Power-on GCS', [
    'Airband receiver battery checked',
    'GCS power on',
    'Bottom tablet on',
    'Top tablet on',
    'Ground GPS connected, LED blinks',
    'RC on, connector tight, ≥ 7.0 V',
    'External power charges battery',
  ], group: 'GCS'),
  ChecklistSection('ua_power_on', '12V UA Power-on', [
    'Previous defects and maintenance reviewed',
    '12V on Hub 1, 2 and 4',
    'QGC connected on both tablets',
    'System status shows "5v error"',
    '12V on Hub 3 → System status "Ok"',
    'Mavlink console: logger status',
    'Old datalogs / missions cleared',
    'UA parameters checked vs reference',
  ], group: 'GCS'),
  ChecklistSection('rfd_rclh', 'RFD and RCLH checks', [
    'RFD LED blinks green/red',
    'Bottom tablet: RFD/4G connections ok',
    'RCLH open/close with RC, status on QGC',
    '12V on Hub 1 disconnected',
    'RFD link loss + hook timeout callout',
  ], group: 'GCS'),
  ChecklistSection('fts_rc_video', 'FTS, RC, RCLH and video', [
    'FTS Link "Ok" in QGC',
    'Bottom tablet: Herelink/4G connections ok',
    'FTS engaged → "Engaged" / "Inconsistent"',
    'Front and downward video displayed',
    'RC off → "Manual Control Lost" popup',
  ], group: 'GCS'),
  ChecklistSection(
    'switch_off',
    'Switch off UA & GCS',
    [
      '12V off, disconnected from hubs',
      'GCS battery off',
      'Both tablets off',
      'RC off',
    ],
    group: 'GCS',
    canSkip: true,
  ),
  ChecklistSection(
    'storage',
    'Storage',
    ['All equipment stored', 'UA in trailer, secured, cover closed'],
    group: 'GCS',
    canSkip: true,
  ),
]);

/// Draft for the DJI Matrice 30T until the company's own list replaces it.
const m30tChecklist = Checklist('M30T', Tables.dailyChecksM30t, [
  ChecklistSection('body_arms', 'Aircraft body and arms', [
    'Arms unfolded and locked',
    'No cracks / damage on body and arms',
    'Landing gear OK',
    'Vision sensors and ToF clean',
  ]),
  ChecklistSection('propellers_motors', 'Propellers and motors', [
    'Propellers: no cracks / chips',
    'Propellers locked',
    'Motors spin freely, no noise',
  ]),
  ChecklistSection('gimbal_camera', 'Gimbal and camera', [
    'Gimbal protector removed',
    'Lenses clean',
    'Gimbal moves freely',
  ]),
  ChecklistSection('batteries', 'Batteries TB30', [
    'Both batteries charged',
    'Batteries seated and locked',
    'No swelling / damage',
  ]),
  ChecklistSection('rc_plus', 'RC Plus', [
    'RC charged',
    'Antennas unfolded',
    'Link to aircraft OK',
    'Firmware up to date',
  ]),
  ChecklistSection('before_takeoff', 'Before take-off', [
    'Compass / IMU OK',
    'RTH altitude set',
    'Home point recorded',
    'No warnings in DJI Pilot 2',
  ]),
]);

const checklists = [fb3Checklist, m30tChecklist];

/// The checklist for a drone, from its model or name ("M30T", "Matrice 30T").
/// Everything else is an FB3.
Checklist checklistForDrone({String? name, String? model}) {
  final s = '${model ?? ''} ${name ?? ''}'.toLowerCase().replaceAll(' ', '');
  return s.contains('m30') || s.contains('matrice30')
      ? m30tChecklist
      : fb3Checklist;
}
