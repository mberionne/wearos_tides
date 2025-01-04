import 'package:logging/logging.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class PositionHelper {
  static Logger log = Logger("Tides");

  static Future<Position> getPosition() async {
    // Hardcode location for testing on web. Return it with a small
    // delay to facilitate UI testing.
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.delayed(
          const Duration(seconds: 2),
          () => Position(
              // Somewhere in Canada
              // latitude: 44.96786648111967,
              // longitude: -61.92402808706994,
              // Somewhere in the US
              latitude: 32.93693693693694,
              longitude: -117.21905287360934,
              accuracy: 1.0,
              altitude: 0,
              altitudeAccuracy: 1.0,
              speed: 0,
              speedAccuracy: 1.0,
              heading: 0,
              headingAccuracy: 1.0,
              timestamp: DateTime.now()));
    }

    // Test if location services are enabled.
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Location services are not enabled don't continue
      // accessing the position and request users of the
      // App to enable the location services.
      return Future.error("Location is disabled.");
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        // Permissions are denied, next time you could try
        // requesting permissions again (this is also where
        // Android's shouldShowRequestPermissionRationale
        // returned true. According to Android guidelines
        // your App should show an explanatory UI now.
        return Future.error("Location is denied");
      }
    }
    if (permission == LocationPermission.deniedForever) {
      // Permissions are denied forever, handle appropriately.
      return Future.error("Location is permanently denied");
    }
    // When we reach here, permissions are granted and we can
    // continue accessing the position of the device.

    // Check if there is a last known location.
    Position? position = await Geolocator.getLastKnownPosition();
    if (position != null) {
      log.info("Last known location is returned");
      return position;
    }

    // This application can work with low accuracy (lowest does not guarantee
    // a location),  and we also want to specify a timeout to avoid an infinite wait.
    return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 8));
  }
}
