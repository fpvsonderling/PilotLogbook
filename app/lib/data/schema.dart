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
    // What the drone flies: "cargo", "inspection" or "cargo,inspection".
    // Empty (drones from before) counts as both. See DroneUsage.
    Col('usage'),
  ]);

  static const batteries = TableDef('batteries', [
    Col('name'),
    Col('set_name'),
    Col('serial'),
    Col('active', ColType.integer),
    // Drones the battery goes in, comma separated ids; empty = any drone.
    Col('aircraft_ids'),
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
    // 1 when the mission was aborted / there was a near miss, else empty.
    Col('aborted', ColType.integer),
    Col('near_miss', ColType.integer),
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

  // Fault Repair Report: each step is its own row, made by whoever did it,
  // so a technician and a signatory never change someone else's report.
  // The status follows from the rows (see FaultCase in logbook.dart).
  static const faults = TableDef('faults', [
    Col('reported_at'), // yyyy-MM-dd HH:mm:ss, local time
    Col('aircraft_id'),
    Col('battery_id'),
    // Anything else: GCS, charger, radio, a battery set not in the list.
    Col('equipment'),
    Col('severity', ColType.integer), // 1 monitor, 2 repair, 3 grounded
    Col('description'),
    // People id; imported rows may hold a name that is not in People.
    Col('discovered_by_id'),
  ]);

  static const faultRepairs = TableDef('fault_repairs', [
    Col('fault_id'),
    Col('started_at'),
    Col('finished_at'),
    Col('technicians'), // names, comma separated
    Col('work_performed'),
    Col('materials_used'),
    Col('notes'),
  ]);

  /// Test after a repair and sign-off. "pass" closes the fault, "fail"
  /// sends it back for another repair.
  static const faultSignoffs = TableDef('fault_signoffs', [
    Col('fault_id'),
    Col('tested_at'),
    Col('result'), // pass | fail
    Col('notes'),
    Col('signatory_id'),
  ]);

  static const faultPhotos = TableDef('fault_photos', [
    Col('fault_id'),
    Col('repair_id'), // empty for photos of the report
    Col('drive_file_id'),
    Col('url'),
  ]);

  // Maintenance: one row per maintenance of a drone, one column per
  // assembly with "Checked" or what was done (see maintenance.dart), like
  // the old AppSheet "Maintenance" sheet.
  static const maintenance = TableDef('maintenance', [
    Col('performed_at'), // yyyy-MM-dd HH:mm:ss, local time
    Col('aircraft_id'),
    Col('technician_id'),
    Col('arm_assembly'),
    Col('center_plate'),
    Col('propulsion_system'),
    Col('load_assembly'),
    Col('leg_assembly'),
    Col('power_system'),
    Col('fts'),
    Col('notes'),
  ]);

  // How often each maintenance assembly is due, whichever comes first.
  // Rows override the maintenance book's intervals (maintenance.dart):
  // model empty = every drone, else drones whose model is this one. A row
  // with all three empty turns the reminder off. Only the admin changes it.
  static const maintenanceIntervals = TableDef('maintenance_intervals', [
    Col('model'),
    Col('section'), // maintenance column, e.g. arm_assembly
    Col('hours', ColType.real),
    Col('flights', ColType.integer),
    Col('days', ColType.integer),
  ]);

  static const torqueSpecs = TableDef('torque_specs', [
    Col('model'),
    Col('component'),
    Col('value_nm', ColType.real),
    Col('notes'),
  ]);

  // A person's licences, trainings, medicals and insurance. Only that
  // person (own key) and the admin get, add and change them; only the admin
  // marks one verified, and the person's own change clears it again. No
  // scans in the app: url is a link to the document in Google Drive.
  static const competencies = TableDef('competencies', [
    Col('person_id'),
    Col('type'), // e.g. GWO, Medical, see competencyTypes
    Col('number'),
    Col('issued_on'), // yyyy-MM-dd
    Col('expires_on'), // yyyy-MM-dd, empty = does not expire
    Col('url'),
    Col('notes'),
    Col('verified', ColType.integer), // 1 = the admin checked the document
    Col('verified_by'), // people id, empty for the master admin key
  ]);

  // Documents every pilot needs. Only the admin link adds, changes and
  // deletes them. The file is in Google Drive; each app keeps a copy for
  // offline use (see documents.dart).
  static const documents = TableDef('documents', [
    Col('title'),
    Col('url'), // the file in Drive, or any web page
    Col('notes'),
    Col('drive_file_id'),
    Col('file_name'),
    Col('mime_type'),
    Col('size_bytes', ColType.integer),
    // Drive's last change of the file; a new one makes apps download again.
    Col('file_version'),
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
    faultRepairs,
    faultSignoffs,
    faultPhotos,
    maintenance,
    maintenanceIntervals,
    torqueSpecs,
    competencies,
    documents,
  ];

  /// Tables of one person's own rows (person_id): the script gives each
  /// person only theirs, the admin everyone's. See PERSONAL_TABLES in Code.gs.
  static const personal = [competencies];

  static TableDef byName(String name) => all.firstWhere((t) => t.name == name);
}
