import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  final ValueNotifier<bool> isConnected = ValueNotifier<bool>(true);
  late StreamSubscription<List<ConnectivityResult>> _subscription;

  void initialize() {
    _subscription = Connectivity().onConnectivityChanged.listen(
      (List<ConnectivityResult> results) {
        isConnected.value = !results.contains(ConnectivityResult.none);
      },
    );
  }

  void dispose() {
    _subscription.cancel();
  }
}