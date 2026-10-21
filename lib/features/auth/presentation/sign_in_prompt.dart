import 'package:flutter/material.dart';

/// Tells a guest that [action] needs an account, with a way to sign in.
void askToSignIn(
  BuildContext context, {
  required String action,
  VoidCallback? onSignIn,
}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      persist: false,
      duration: const Duration(seconds: 4),
      content: Text('برای $action وارد حسابت شو.'),
      action: onSignIn == null
          ? null
          : SnackBarAction(label: 'ورود', onPressed: onSignIn),
    ));
}
