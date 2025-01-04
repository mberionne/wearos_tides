import 'package:logging/logging.dart';
import 'package:sunrise_sunset_calc/sunrise_sunset_calc.dart';

class SunTime {
  static Logger log = Logger("Tides");

  SunTime({required this.sunrise, required this.sunset});

  final DateTime sunrise;
  final DateTime sunset;

  static SunTime? calculateSunriseSunset(
      DateTime now, double latitude, double longitude) {
    try {
      var value =
          getSunriseSunset(latitude, longitude, now.timeZoneOffset, now);
      log.info("Sunrise: ${value.sunrise}, Sunset: ${value.sunset}");
      // The values returned by getSunriseSunset are in UTC, so use UTC time
      // to validate them.
      final dayStart = DateTime.utc(now.year, now.month, now.day);
      final dayEnd = dayStart.add(const Duration(hours: 24));
      if (value.sunrise.isBefore(dayStart) ||
          value.sunset.isAfter(dayEnd) ||
          value.sunrise.isAfter(value.sunset)) {
        log.severe("Unable to validate sunrise and sunset");
        return null;
      }
      return SunTime(sunrise: value.sunrise, sunset: value.sunset);
    } catch (err) {
      log.severe("Exception on sunrise and sunset: $err");
      return null;
    }
  }
}
