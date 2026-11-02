/// What to do on each maintenance assembly and how, shown from the info
/// button next to the assembly on the maintenance form.
library;

/// One step of an assembly's instruction, with an optional picture from
/// assets/maintenance/.
class GuideStep {
  const GuideStep(this.text, {this.image});

  final String text;

  /// Asset path, e.g. 'assets/maintenance/arm_assembly_1.jpg'.
  final String? image;
}

/// Instruction for one assembly.
class MaintenanceGuide {
  const MaintenanceGuide({this.intro = '', required this.steps});

  final String intro;
  final List<GuideStep> steps;
}

/// Instructions by maintenance column (see maintenanceSections).
const maintenanceGuides = <String, MaintenanceGuide>{};
