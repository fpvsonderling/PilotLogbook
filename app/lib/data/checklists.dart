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

/// FB3 Flight Manual v2.5.4, "Daily checks" (page 46-48): UA and GCS in
/// one check. Section titles and items are the manual's own wording.
const fb3Checklist = Checklist('FB3', Tables.dailyChecksFb3, [
  ChecklistSection('motors_propellers', 'Motors and Propellers', [
    'Check that all motors are spinning freely and there is no noise or disturbance while spinning them.',
    'Check the motor mountings by inspecting that the torque seal on the screws is continuous.',
    'Check Motor-ESCs connector: tight connection, torque seal is continuous and safety lockwire is installed.',
    'Inspect the propellers (including leading and trailing edge). They should not possess crack or structural deformation.',
    'Torque seal on propeller screws is present and is not cracked.',
    'Check the mechanical integrity of the motor mountings and that there is no motor play by holding the propeller tip and moving it up and down gently in two directions. (If there is play in any motor, go through maintenance tasks an find out if it’s known issue or new issue. Motor play may exist because of bearing problems).',
  ], group: 'UA'),
  ChecklistSection('centre_plate', 'Centre Plate and Primary Avionics', [
    'Check that all screws and nuts are present and not loose. The torque seal on them is continuous.',
    'There is no structural deformation or damage on the Center Plate.',
    'The M12 cables from the Primary Avionics Assembly to the Expanders are tight and the torque seal on them is continuous in both ends.',
    'The Battery Power Cables are undamaged and tightened to the Center Plate and Connectors have no signs of damage.',
    'The M12 cables between Secondary and Primary Avionics are tight and the torque seal is continuous.',
    'Front camera connector on secondary avionics and wiring on center place is connected well and secured.',
  ], group: 'UA'),
  ChecklistSection(
    'load_structure',
    'Load Structure Assembly and RCLH (sling option)',
    [
      'Check that all screws and nuts are present and not loose. The torque seal on them is continuous.',
      'Check the torque seal on Load Structure to Load Hook attachment screws/nuts. The torque seal on them is continuous.',
      'M8 Cable from Hub 1 to RCLH is fixed tight and torque seal on both ends is continuous.',
      'There is no structural deformation or damage on the Load Structure.',
      'There is no structural deformation or damage on the RCLH (plastics and motor mount)',
    ],
    group: 'UA',
  ),
  ChecklistSection('landing_gear', 'Landing gear', [
    'There is no structural deformation or damage on the Landing Gear.',
    'Check that all screws and nuts are present and not loose. The torque seal on them is continuous.',
    'The RFD antennas are fixed to the Landing Gear structure, the heatshrink is present and connector on secondary avionics is tight.',
    'The Herelink and 5G antennas are fixed to the Landing Gear structure and connector is tight.',
  ], group: 'UA'),
  ChecklistSection(
    'cargo_compartment',
    'Cargo Compartment (fixed-cargo option)',
    [
      'Check that all screws and nuts are present and not loose. The torque seal on them is continuous.',
      'Check for cracks or bends with key focus on: Corners of main structure, joint to leg assembly, center of main structure',
      'If applicable: Check Floating devices are secured and closed',
    ],
    group: 'UA',
    canSkip: true,
  ),
  ChecklistSection(
    'external_rf',
    'External RF (If applicable)',
    [
      'Check External Herelink Module is connected',
      'Power on RFD Backbone Repeater',
    ],
    group: 'GCS',
    canSkip: true,
  ),
  ChecklistSection('power_on_gcs', 'Power-on GCS', [
    'Check battery status of Airband receiver',
    'Enable GCS Power',
    'Power up Bottom Tablet',
    'Power up Top Tablet',
    'connect ground GPS and check if the LED blinks',
    'Power on RC and plug in, check connector is tight and check that voltage is ok. (min. 7.0V) (If appliccable: check battery is charging)',
    'Check that external power charges Battery',
  ], group: 'GCS'),
  ChecklistSection('ua_power_on', '12V UA Power-on', [
    'Before powering on the UAS, review previous defects and maintenance tasks open.',
    'Provide 12V to the Battery connector on Hub 1, 2 and 4',
    'Open QGroundControl and connect to the aircraft on both tablets',
    'The "System status" variable in QGroundControl software shows "5v error".',
    'Provide 12V to the Battery connector on Hub 3, the "System status" variable is "Ok"',
    'Open Mavlink console and write \'logger status\'',
    'Clear datalogs and old mission plans from memory (if necessary)',
    'Export and check UA parameters (against reference parameter file)',
  ], group: 'GCS'),
  ChecklistSection('rfd_rclh', 'RFD and RCLH checks', [
    'On successful connection RFD LED will blink green/red -> If connection is unsuccessful (only blinking green or sporadic red blinking) check for interference (e.g. other units) or wrong configuration',
    'Check on bottom tablet that connections are ok (RFD/4G depending on operation)',
    'Check the RCLH open/close with RC commands and the status updates on QGC',
    'Disconnect 12V on Hub 1',
    'Check that callout for RFD link loss and Hook timeout (if applicable) is present',
  ], group: 'GCS'),
  ChecklistSection('fts_rc_video', 'FTS, RC, RCLH and video checks', [
    'Check "FTS Link" is "Ok" in QGroundControl',
    'Check on bottom tablet that connections are ok (Herelink/4G depending on operation)',
    'Engage FTS and check that "FTS state" changes to "Engaged" and "FTS Link" changes to "Inconsistent"',
    'Check that front and downward video is displayed',
    'Disconnect RC and check "Manual Control Lost" Popup appears',
  ], group: 'GCS'),
  ChecklistSection(
    'switch_off',
    'Switch off UA & GCS',
    [
      'Turn off 12V supply and disconnect from Hubs',
      'Turn off GCS Battery',
      'Turn off both Tablets',
      'Turn off RC',
    ],
    group: 'GCS',
    canSkip: true,
  ),
  ChecklistSection(
    'storage',
    'Storage',
    [
      'Store all equipment in the appropriate place',
      'Put the UA into a trailer, secure it properly and close the cover.',
    ],
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
