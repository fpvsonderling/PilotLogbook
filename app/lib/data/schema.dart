/// Single description of every table. The same tables exist in three places:
/// the local SQLite database, the Google Sheets tabs and the Apps Script
/// SCHEMA constant (apps_script/Code.gs). A test keeps the last two in sync.
library;

enum ColType { text, integer, real }

class Col {
  const Col(this.name, [this.type = ColType.text]);
  final String name;
  final ColType type;
}

class TableDef {
  const TableDef(this.name, this.columns);

  /// Table name locally and the tab name in Google Sheets.
  final String name;

  /// Domain columns, without the system columns below.
  final List<Col> columns;

  /// Columns every synced row carries, in this order, before the domain ones.
  static const systemColumns = [
    Col('id'),
    Col('updated_at'),
    Col('server_seq', ColType.integer),
    Col('deleted', ColType.integer),
    // People id of whoever added the row, set by the script from their own
    // link; they may change and delete it. Empty for the shared links.
    Col('created_by'),
  ];

  List<Col> get allColumns => [...systemColumns, ...columns];

  List<String> get columnNames => [for (final c in allColumns) c.name];
}

class Tables {
  static const people = TableDef('people', [
    Col('name'),
    // Comma separated: pilot, spotter, technician, signatory, admin.
    Col('roles'),
    Col('email'),
    Col('active', ColType.integer),
  ]);

  static const projects = TableDef('projects', [
    Col('name'),
    Col('active', ColType.integer),
  ]);

  static const aircraft = TableDef('aircraft', [
    Col('name'),
    Col('model'),
    Col('serial'),
    Col('active', ColType.integer),
  ]);

  static const batteries = TableDef('batteries', [
    Col('name'),
    Col('set_name'),
    Col('serial'),
    Col('active', ColType.integer),
  ]);

  static const missionTypes = TableDef('mission_types', [
    Col('name'),
    Col('active', ColType.integer),
  ]);

  static const flights = TableDef('flights', [
    Col('date'), // yyyy-MM-dd
    Col('kind'), // cargo | inspection
    Col('project_id'),
    Col('aircraft_id'),
    Col('battery_id'),
    Col('takeoff_at'), // HH:mm:ss
    Col('landing_at'), // HH:mm:ss
    Col('duration_s', ColType.integer),
    // Not filled by the app: AppSheet's "Batt" turned out to be the battery
    // number, now battery_id. Kept so existing sheets keep their column.
    Col('battery_pct', ColType.integer),
    Col('used', ColType.real),
    Col('temp_c', ColType.integer),
    Col('mission'),
    Col('rp_id'),
    Col('pa_id'),
    Col('spotter_id'),
    Col('notes'),
  ]);

  static const checklistTemplates = TableDef('checklist_templates', [
    Col('name'),
    Col('kind'), // ua | gcs | maintenance
    Col('active', ColType.integer),
  ]);

  static const checklistItems = TableDef('checklist_items', [
    Col('template_id'),
    Col('position', ColType.integer),
    Col('label'),
  ]);

  static const checks = TableDef('checks', [
    Col('template_id'),
    Col('aircraft_id'),
    Col('performed_at'),
    Col('performed_by_id'),
    Col('notes'),
  ]);

  static const checkAnswers = TableDef('check_answers', [
    Col('check_id'),
    Col('item_id'),
    Col('result'), // ok | no | na
    Col('comment'),
  ]);

  // Daily checks: one row per check, one column per checklist section with
  // "Ok", "Not used" or the pilot's note (see checklists.dart).
  static const dailyChecksFb3 = TableDef('daily_checks_fb3', [
    Col('checked_at'), // yyyy-MM-dd HH:mm:ss, local time
    Col('aircraft_id'),
    Col('pilot_id'),
    Col('motors_propellers'),
    Col('centre_plate'),
    Col('load_structure'),
    Col('landing_gear'),
    Col('cargo_compartment'),
    Col('external_rf'),
    Col('power_on_gcs'),
    Col('ua_power_on'),
    Col('rfd_rclh'),
    Col('fts_rc_video'),
    Col('switch_off'),
    Col('storage'),
    Col('notes'),
  ]);

  static const dailyChecksM30t = TableDef('daily_checks_m30t', [
    Col('checked_at'),
    Col('aircraft_id'),
    Col('pilot_id'),
    Col('body_arms'),
    Col('propellers_motors'),
    Col('gimbal_camera'),
    Col('batteries'),
    Col('rc_plus'),
    Col('before_takeoff'),
    Col('notes'),
  ]);

  static const faults = TableDef('faults', [
    Col('reported_at'),
    Col('aircraft_id'),
    Col('battery_id'),
    Col('equipment'),
    Col('severity', ColType.integer), // 1 monitor, 2 repair, 3 grounded
    Col('description'),
    Col('discovered_by_id'),
    Col('status'), // not_fixed | repaired | fixed_tested
    Col('repair_started_at'),
    Col('technicians'),
    Col('work_performed'),
    Col('materials_used'),
    Col('final_note'),
    Col('signatory_id'),
    Col('signed_at'),
  ]);

  static const faultPhotos = TableDef('fault_photos', [
    Col('fault_id'),
    Col('drive_file_id'),
    Col('url'),
  ]);

  static const torqueSpecs = TableDef('torque_specs', [
    Col('model'),
    Col('component'),
    Col('value_nm', ColType.real),
    Col('notes'),
  ]);

  static const documents = TableDef('documents', [
    Col('title'),
    Col('url'),
    Col('notes'),
  ]);

  static const all = [
    people,
    projects,
    aircraft,
    batteries,
    missionTypes,
    flights,
    checklistTemplates,
    checklistItems,
    checks,
    checkAnswers,
    dailyChecksFb3,
    dailyChecksM30t,
    faults,
    faultPhotos,
    torqueSpecs,
    documents,
  ];

  static TableDef byName(String name) => all.firstWhere((t) => t.name == name);
}
