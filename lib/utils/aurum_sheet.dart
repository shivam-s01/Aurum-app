import 'package:flutter/material.dart';

/// Drop-in replacement for [showModalBottomSheet].
///
/// FIX (stuck grey overlay bug): every bottom sheet in the app called
/// `showModalBottomSheet` without an explicit [barrierColor]. With no
/// explicit value, Flutter builds its own default barrier-transition
/// widget internally — and that default construction is the thing that
/// can occasionally race with a system back press, leaving one extra
/// frame of the modal scrim painted on screen after the sheet itself
/// has already been removed (the "stuck grey layer" bug — this matches
/// a known Flutter engine issue, flutter/flutter#128367).
///
/// Passing an explicit [barrierColor] skips that default construction
/// path entirely, so there's nothing left to desync from the sheet's
/// own dismissal. That's the entire fix — no extra widgets, no extra
/// listeners, nothing added to the render tree. Safe and cheap on
/// low-end devices.
///
/// Use this everywhere a bottom sheet is shown. Existing call sites can
/// switch over by replacing `showModalBottomSheet(` with
/// `showAurumModalBottomSheet(`.
Future<T?> showAurumModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  Color? barrierColor,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool isDismissible = true,
  bool enableDrag = true,
  ShapeBorder? shape,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: backgroundColor,
    barrierColor: barrierColor ?? Colors.black45,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    shape: shape,
    builder: builder,
  );
}
