import 'package:point_in_polygon/point_in_polygon.dart';

enum Unit {
  meters,
  feet,
}

class UnitHelper {
  // Convert unit to String for logging
  static String name(Unit unit) {
    return switch (unit) {
      Unit.meters => "meters",
      Unit.feet => "feet"
    };
  }

  // Convert value from meters to feet
  static double metersToFeet(double m) {
    return m * 3.28084;
  }

  // Returns the unit of measure to be used based on the location.
  // This function uses a rough approximation of the US as it is
  // OK to use the wrong unit right next to the border.
  static Unit calculateUnit(double latitude, double longitude) {
    final List<Point> polygonContinentalUs = <Point>[
      Point(x: -126.1248252, y: 49.0397314),
      Point(x: -124.6306846, y: 32.4380122),
      Point(x: -106.6131064, y: 31.6932006),
      Point(x: -97.3845908, y: 25.9210829),
      Point(x: -80.0701377, y: 24.6496008),
      Point(x: -66.7986533, y: 44.1842425),
      Point(x: -68.6443564, y: 47.7264568),
      Point(x: -71.1406083, y: 45.3783095),
      Point(x: -74.0056846, y: 45.0600094),
      Point(x: -82.0916221, y: 41.8061971),
      Point(x: -83.629708, y: 46.409524),
      Point(x: -94.8357627, y: 48.9820826),
    ];
    final List<Point> polygonAlaska = <Point>[
      Point(x: -140.9883337, y: 72.1624613),
      Point(x: -167.6191931, y: 72.3765883),
      Point(x: -169.7552027, y: 58.9312314),
      Point(x: -179.6602087, y: 49.8539187),
      Point(x: -141.3398962, y: 49.1691306),
    ];
    final List<Point> polygonHawaii = <Point>[
      Point(x: -162.8950747, y: 23.159566),
      Point(x: -162.9829653, y: 17.5592124),
      Point(x: -152.6118716, y: 17.4334757),
      Point(x: -152.6118716, y: 23.119156),
    ];
    final Point currentLocation = Point(x: longitude, y: latitude);
    if (Poly.isPointInPolygon(currentLocation, polygonContinentalUs) ||
        Poly.isPointInPolygon(currentLocation, polygonAlaska) ||
        Poly.isPointInPolygon(currentLocation, polygonHawaii)) {
      return Unit.feet;
    }
    return Unit.meters;
  }
}
