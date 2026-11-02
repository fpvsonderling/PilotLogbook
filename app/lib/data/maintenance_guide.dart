/// What to do on each maintenance assembly and how, shown from the info
/// button next to the assembly on the maintenance form. Taken from the
/// FB3 UAS Maintenance Manual 2.4.8 (Visual Inspection chapter); pictures
/// are its figures, in assets/maintenance/.
library;

/// One inspection task of an assembly, e.g. "A10-002-01 Arm Assembly GVI".
class GuideTask {
  const GuideTask({
    required this.code,
    required this.title,
    this.when = '',
    this.text = '',
    this.checks = const [],
    this.after = '',
    this.images = const [],
  });

  /// Manual task number, e.g. "A10-002-01".
  final String code;
  final String title;

  /// How often, from the Maintenance Planning Document.
  final String when;

  /// What the part is and what to look for.
  final String text;

  /// What to check, one line each.
  final List<String> checks;

  /// What to do after the checks.
  final String after;

  /// Asset paths of the figures.
  final List<String> images;
}

/// Instruction for one assembly.
class MaintenanceGuide {
  const MaintenanceGuide({
    this.intro = '',
    this.warning = noPower,
    required this.tasks,
  });

  final String intro;

  /// Safety note shown on top.
  final String warning;
  final List<GuideTask> tasks;
}

const noPower =
    'Perform the inspection without batteries or any power source '
    'connected to the UAS.';

const _damaged =
    'Damage must be checked or repaired. Parts that cannot be repaired must '
    'be clearly marked as scrap, disposed of and replaced '
    '(10-20-001 Standard Repair Material).';

const _img = 'assets/maintenance';

/// Instructions by maintenance column (see maintenanceSections).
const maintenanceGuides = <String, MaintenanceGuide>{
  'arm_assembly': MaintenanceGuide(
    intro:
        'Structural parts are inspected at every daily check (GVI) or every '
        '5 flight hours (DVI) to make sure no parts are missing or broken. '
        'Aluminium and plastic parts must be free of bends, scratches, sharp '
        'edges and dents. Remove dirt, sand and water when found.',
    tasks: [
      GuideTask(
        code: 'A10-002-01',
        title: 'Arm Assembly GVI',
        when: 'Torque check every 20 flight hours or 6 months.',
        text:
            'The arm assembly is made of aluminium tubes, the T-plate '
            'assembly and the motor assembly. The T-plate assembly is '
            'aluminium plates with plastic spacers, held by zinc-plated '
            'screws with lock-nuts. The motor assembly is two motors held '
            'on the arm by two machined aluminium clamps. $_damaged',
        checks: [
          'Fasteners are tight and the torque seal is intact. Motor mounts: '
              'two screws and two nuts on each side of the motor mount '
              '(orange markings).',
          'No plastics are damaged or missing.',
          'Aluminium structure: no surface damage or dirt.',
          'ESC to motor wires: no damage to the insulation.',
          'ESC to motor connectors are plugged in completely and the '
              'lockwire is tight.',
        ],
        images: ['$_img/arm_1.jpg', '$_img/arm_2.jpg'],
      ),
    ],
  ),
  'center_plate': MaintenanceGuide(
    intro:
        'Structural parts are inspected every 5 flight hours to make sure no '
        'parts are missing or broken. Aluminium and plastic parts must be '
        'free of bends, scratches, sharp edges and dents. Remove dirt, sand '
        'and water when found.',
    tasks: [
      GuideTask(
        code: 'C10-002-01',
        title: 'Center Plate Assembly GVI',
        when:
            'Torque check of nuts and screws every 20 flight hours or '
            '6 months.',
        text:
            'Two aluminium plates with plastic spacers, held by zinc-plated '
            'screws with lock-nuts. $_damaged',
        checks: [
          'No screws loose or missing.',
          'No nuts loose or missing.',
          'No plastics missing, deformed or delaminated.',
          'Aluminium structure: no surface damage or dirt.',
          'Components: no damage or dirt.',
          'Main power wiring is OK.',
          'Battery connectors are OK.',
          'Connectors are plugged in completely and not damaged.',
        ],
        images: ['$_img/center_plate_1.jpg'],
      ),
    ],
  ),
  'propulsion_system': MaintenanceGuide(
    tasks: [
      GuideTask(
        code: 'P20-002-01',
        title: 'Propeller GVI',
        when: 'Every 10 flight hours or 3 months.',
        text:
            'Do it without high-voltage power connected. The propellers are '
            'a carbon fibre shell with a foam core.',
        checks: [
          'Leading edge: small erosion dents are allowed only if less than '
              '1 mm deep.',
          'Any damage at the centre of the propeller: replace it.',
          'Any sign of cracks: replace it.',
          'Clean the surface with a damp cloth.',
        ],
      ),
      GuideTask(
        code: 'P10-002-01',
        title: 'Motor GVI',
        when: 'Replace the motor bearings every 500 flight hours.',
        text:
            'Check the motors for external damage or dirt. The motor must '
            'turn without excessive force and without rattling or scratching '
            'noise. If there is noise, take the motor apart and check the '
            'bearings (P11-001 Remove and Install Motor Bearing).',
        images: ['$_img/motor_1.jpg', '$_img/motor_bearing.jpg'],
      ),
      GuideTask(
        code: 'P11-002-01',
        title: 'Motor Mounts DVI',
        when: 'Every 20 flight hours or 6 months.',
        text:
            'Motor mounts carry a particularly high load. Remove the LED '
            'module first (LI10-001 Remove and install LED Module). The '
            'picture shows the bottom side; check the top side the same way.',
        checks: [
          'Fasteners inside the arms are tight and the torque seal is intact '
              '(orange markings, two on the bottom and two on top).',
          'Motor clamps: no signs of fatigue (cracks) on the inner edge and '
              'no fretting between motor and clamp (blue arrow).',
          'Arm tube: no signs of cracks (green arrows).',
          'LED wiring and connector are OK.',
        ],
        after: 'Install the LED module again (LI10-001).',
        images: ['$_img/motor_mounts.jpg'],
      ),
    ],
  ),
  'load_assembly': MaintenanceGuide(
    tasks: [
      GuideTask(
        code: 'LD10-002-01',
        title: 'Load Attachment Assembly GVI',
        when:
            'Torque check of nuts and screws every 20 flight hours or '
            '6 months.',
        text:
            'Aluminium plates with PETG plastic spacers, held by zinc-plated '
            'screws with lock-nuts. Check the area near the connection points '
            'for signs of stress: it may deform under abnormal load, e.g. an '
            'abrupt loading caused by pilot error. $_damaged',
        checks: [
          'No screws loose or missing.',
          'No nuts loose or missing.',
          'No plastics missing, deformed or delaminated.',
          'Aluminium structure: no surface damage or dirt.',
          'Components: no damage or dirt.',
          'Exposed wiring is OK.',
          'Connectors are plugged in completely and not damaged.',
        ],
        images: ['$_img/load_attachment.jpg'],
      ),
      GuideTask(
        code: 'LD50-002-01',
        title: 'Remote Controlled Load Hook GVI',
        when:
            'Every 10 flight hours or 3 months. Check and record the latch '
            'free play.',
        text:
            'The RCLH is six layers of 2 mm 7075 aluminium, a stainless steel '
            'latch, one motor, PETG covers and one buckle.',
        checks: [
          'No signs of abnormal stress, dents, bends or corrosion; clean and '
              'check where found.',
          'Pay attention to the contact points with the load attachment '
              'shackle and the mouth of the hook (red circle).',
          'Latch: slight force must not show excessive movement.',
          'Parts with dents, bends or corrosion must be replaced.',
        ],
        images: ['$_img/load_hook.jpg'],
      ),
    ],
  ),
  'leg_assembly': MaintenanceGuide(
    intro:
        'The landing gear is the leg assemblies, skids and leg connector '
        'assembly: aluminium plates and tubes with PETG spacers, held by '
        'zinc-plated screws with lock-nuts. The skids are bent aluminium '
        'tubes. The datalink antennas are mounted on the landing gear, so '
        'they are part of this inspection.',
    tasks: [
      GuideTask(
        code: 'L10-002-01',
        title: 'Landing Gear Structure GVI',
        when:
            'Torque check of nuts and screws every 20 flight hours or '
            '6 months.',
        text: 'Inspect the whole structure by naked eye. $_damaged',
        checks: [
          'No screws loose or missing.',
          'No nuts loose or missing.',
          'No plastics missing, deformed or delaminated.',
          'Aluminium structure: no surface damage or dirt.',
          'Components: no damage or dirt.',
          'Exposed wiring is OK.',
          'Connectors are plugged in completely and not damaged.',
          'Skid tubes: no deformation or damage.',
          'Antennas are in place and not damaged.',
        ],
        images: ['$_img/leg_assembly.jpg'],
      ),
    ],
  ),
  'power_system': MaintenanceGuide(
    warning: 'Perform the inspection with the battery powered off.',
    tasks: [
      GuideTask(
        code: 'PW10-002-01',
        title: 'Batteries GVI',
        when: 'Every 10 flight hours or 3 months.',
        text: 'Makes sure the battery pack is intact.',
        checks: [
          'Battery box: no hits, dents, scratches, sharp edges, dust, water, '
              'abnormal colour or smell.',
          'All fasteners are in place and tight.',
          'Connectors: no wear, corrosion, dirt or water.',
          'Integrated batteries: before pressing the button the status LED '
              'is off.',
          "Press the button: the blink sequence must be 'G-G' or 'G-G-G'. "
              'Any other status: see PW-20-001-002 Battery Pack 2.0 Status '
              'LED.',
        ],
        images: ['$_img/battery.jpg'],
      ),
    ],
  ),
  'fts': MaintenanceGuide(
    warning:
        'Make sure the GCS is powered off and the charger cable is not '
        'plugged in.',
    intro:
        'Done to comply with MoC 2511, at least every 1000 activations of '
        'the Flight Termination System (or every 6 months).',
    tasks: [
      GuideTask(
        code: 'CNT20-002-01',
        title: 'FTS DVI: M12 connector',
        text:
            'Inspect the solder joints of the connectors and the cable for '
            'any damage.',
        checks: [
          'Torque seals are intact.',
          'The connector is tightened.',
          'No corrosion.',
          'The counter nut is tightened.',
        ],
        after: 'Re-apply torque seal.',
      ),
      GuideTask(
        code: 'CNT20-002-01',
        title: 'FTS DVI: antenna connectors',
        checks: [
          'Torque seals are intact.',
          'Antenna connectors on the secondary avionics are tight.',
        ],
        after: 'Re-apply torque seal.',
      ),
      GuideTask(
        code: 'CNT20-002-01',
        title: 'FTS DVI: FTS ground controller',
        text:
            'Remove the top and bottom GCS covers (GS70-001) and the '
            'FTS / Power On switches (GS80-001).',
        checks: [
          'Secondary cellular ground unit and its wiring are OK.',
          'Herelink ground unit and its wiring are OK.',
          'Wiring between the FTS input controller and the hub is OK.',
          'Switches: no deformation of the metal part.',
          'Switches: properly fixed to the plastic support (metal and '
              'plastic intact).',
          'Switches: wiring is OK.',
          'Switches: move freely.',
        ],
        after: 'Install the switches and the GCS covers again.',
        images: ['$_img/fts_1.jpg', '$_img/fts_2.jpg'],
      ),
    ],
  ),
};
