import 'package:flutter/material.dart';

import 'theme.dart';

/// How urgent something is: a maintenance due or a pilot's competency
/// running out. Yellow when soon, red when over.
enum Urgency { ok, soon, over }

/// Text and background color for [u]; null colors for [Urgency.ok].
(Color?, Color?) urgencyColors(BuildContext context, Urgency u) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final check = CheckColors.of(context);
  return switch (u) {
    Urgency.ok => (null, null),
    Urgency.soon => (
      dark ? AppPalette.gold : const Color(0xFF7A5600),
      dark ? AppPalette.darkGoldContainer : AppPalette.goldContainer,
    ),
    Urgency.over => (check.problem, check.problemContainer),
  };
}

/// A small rounded label in the urgency's colors.
class UrgencyPill extends StatelessWidget {
  const UrgencyPill(this.text, this.urgency, {super.key});
  final String text;
  final Urgency urgency;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = urgencyColors(context, urgency);
    final check = CheckColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg ?? check.okContainer,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg ?? check.ok,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}
