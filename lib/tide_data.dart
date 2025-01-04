import 'dart:collection';
import 'unit.dart';

// Contains the information about the tide
class TideData {
  TideData(
      {required this.station,
      required this.heights,
      required this.extremes,
      required this.unit});
  final String station;
  final SplayTreeMap<double, double> heights;
  final Map<double, double> extremes;
  final Unit unit;

  @override
  String toString() {
    return "heights: $heights, extremes: $extremes";
  }

  factory TideData.fromJson(Map<String, dynamic> data) {
    // This function does not perform any operation, but simply
    // extracts the values of interest from the JSON.
    var station = data["station"]; // dynamic
    SplayTreeMap<double, double> heights = SplayTreeMap();
    for (final height in data["heights"]) {
      heights[height["dt"].toDouble()] = height["height"].toDouble();
    }
    Map<double, double> extremes = {};
    for (final extreme in data["extremes"]) {
      extremes[extreme["dt"].toDouble()] = extreme["height"].toDouble();
    }
    // The data received in the JSON is always in meters.
    return TideData(
        station: station ?? "",
        heights: heights,
        extremes: extremes,
        unit: Unit.meters);
  }
}
