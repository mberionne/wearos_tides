import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:equations/equations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' as intl;
import 'package:logging_to_logcat/logging_to_logcat.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sunrise_sunset_calc/sunrise_sunset_calc.dart';

enum AppState {
  init,
  gettingLocation,
  gettingData,
  parsingData,
  ready,
  // Error states
  errorGeneric,
  errorNoLocation,
  errorHttpTimeout,
  errorHttpError,
  errorParsing,
}

class TideData {
  TideData(
      {required this.station, required this.heights, required this.extremes});
  final String station;
  final SplayTreeMap<double, double> heights;
  final Map<double, double> extremes;

  @override
  String toString() {
    return "heights: $heights, extremes: $extremes";
  }

  factory TideData.fromJson(Map<String, dynamic> data) {
    // This function does not perform any operation, but simply
    // extracts the values of interest from the JSON.
    var station = data['station']; // dynamic
    SplayTreeMap<double, double> heights = SplayTreeMap();
    for (final height in data['heights']) {
      heights[height['dt'].toDouble()] = height['height'].toDouble();
    }
    Map<double, double> extremes = {};
    for (final extreme in data['extremes']) {
      extremes[extreme['dt'].toDouble()] = extreme['height'].toDouble();
    }
    return TideData(
        station: station ?? "", heights: heights, extremes: extremes);
  }
}

class CoordinateConv {
  CoordinateConv(
      {required this.minValue,
      required this.maxValue,
      required this.width,
      required this.height});
  final double minValue;
  final double maxValue;
  final double height;
  final double width;

  Offset convert(double hour, double value) {
    assert(hour >= 0 && hour <= 24);
    assert(value >= minValue && value <= maxValue);
    return Offset(width / 24 * hour,
        -(height / (maxValue - minValue) * (value - minValue)));
  }
}

void main() {
  // Activate logging
  Logger.root.activateLogcat();
  Logger.root.level = Level.ALL;

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tides',
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.black),
        useMaterial3: true,
      ),
      home: const MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  final String title = "";

  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {
  AppState _appState = AppState.init;
  bool _isRunning = false;
  bool _needsRefresh = false;
  TideData? _tideData;
  DateTime? _sunrise;
  DateTime? _sunset;
  double _animationProgress = 1.0;
  DateTime _lastSuccessTimestamp = DateTime.fromMillisecondsSinceEpoch(0);
  Logger log = Logger("Tides");

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mainFlow(force: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _needsRefresh = true;
        _animationProgress = 0;
        break;
      case AppLifecycleState.resumed:
        if (_needsRefresh) {
          _needsRefresh = false;
          _mainFlow(force: false);
        }
        break;
    }
  }

  void _mainFlow({bool force = false}) async {
    if (_isRunning) {
      log.info("Main flow already running");
      return;
    }
    _isRunning = true;
    await _mainFlowImpl(force);
    _isRunning = false;
  }

  Future _mainFlowImpl(bool force) async {
    log.info("Start main flow");

    final now = DateTime.now();
    if (!force && now.difference(_lastSuccessTimestamp).inMinutes.abs() < 15) {
      // We ran the algorithm recently and we are not requested to force it
      // so we can directly return. This happens only when the app goes to
      // background and then becomes visible again.
      log.info("Recently displayed - skipping refresh and perform animation");
      await _playAnimation();
      return;
    }

    // Retrive position. At this point, it's ok to fail.
    _moveTo(AppState.gettingLocation, null);
    Position? position;
    try {
      position = await _determinePosition();
      log.info("Location: ${position.latitude}, ${position.longitude}");
    } catch (err) {
      log.severe("Location error: $err");
    }

    // Retrieve data, either from the cache or from the server
    String body = "";
    bool isFromServer = false;
    _moveTo(AppState.gettingData);
    SharedPreferences prefs = await SharedPreferences.getInstance();
    try {
      // Retrieve the cache
      body = _getCacheIfValid(prefs, now, position);
      // If the cache is not available and a position is available, perform query
      // from the server. Otherwise move to error state.
      if (body.isEmpty) {
        if (position != null) {
          log.info("Cache is empty - retrieving from server");
          body =
              await _fetchDataFromServer(position.latitude, position.longitude);
          // Don't cache the body yet, as we want to make sure that it can be parsed.
          // Simply mark it as from server, so we can cache it later.
          isFromServer = true;
        } else {
          log.severe("Cache is empty and location unavailable");
          _moveTo(AppState.errorNoLocation);
          return;
        }
      }
    } on TimeoutException catch (_) {
      log.severe("Http timeout exception");
      _moveTo(AppState.errorHttpTimeout);
      return;
    } catch (err) {
      log.severe("Http error: $err");
      _moveTo(AppState.errorHttpError);
      return;
    }

    // Parse data (this stage includes the calculation of sunrise and sunset)
    _moveTo(AppState.parsingData);
    DateTime? sunrise, sunset;
    if (position != null) {
      (sunrise, sunset) =
          _calculateSunriseSunset(now, position.latitude, position.longitude);
    }
    try {
      TideData tideData = _parseBody(body);
      if (isFromServer) {
        // Position must be known if we retrieve content from server.
        _setCache(prefs, body, now, position!);
      }
      log.info("Body with tides parsed successfully");
      log.fine("Tide data: $tideData");
      _moveTo(AppState.ready, tideData, sunrise, sunset);
      await _playAnimation();
      _lastSuccessTimestamp = now;
    } catch (err) {
      log.severe("Error parsing the body: $err");
      log.severe("Body: $body");
      _moveTo(AppState.errorParsing);
    }
  }

  _moveTo(AppState newState,
      [TideData? tideData, DateTime? sunrise, DateTime? sunset]) {
    setState(() {
      _appState = newState;
      _tideData = tideData;
      _sunrise = sunrise;
      _sunset = sunset;
      _animationProgress = 0.0;
    });
  }

  Future _playAnimation() async {
    double stepSize = 1 / 20;
    for (double i = 0; i <= 1; i += stepSize) {
      // To complete
      setState(() {
        _animationProgress = i;
      });
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }

  double _metersToFeet(double m) {
    return m * 3.28084;
  }

  double _epochToHour(double ms) {
    return ms / 3600;
  }

  String _getCacheIfValid(
      SharedPreferences prefs, DateTime now, Position? position) {
    // Check date
    String cachedDate = prefs.getString('date') ?? '';
    if (cachedDate.isEmpty ||
        cachedDate != intl.DateFormat('yyyy-MM-dd').format(now)) {
      // If the cache is for a different day, return immediately.
      log.info("Discarding cache from a different day: $cachedDate");
      return '';
    }
    // Check location
    if (position != null) {
      double? cachedLatitude = prefs.getDouble('lat');
      double? cachedLongitude = prefs.getDouble('lon');
      if (cachedLatitude == null || cachedLongitude == null) {
        return '';
      }
      double distanceMeters = Geolocator.distanceBetween(position.latitude,
          position.longitude, cachedLatitude, cachedLongitude);
      if (distanceMeters > 50000) {
        // If the cache is for a point that is too far, return immediately.
        log.info("Discarding cache due to distance: $distanceMeters meters");
        return '';
      }
    }
    // Retrieve cached value
    String cachedValue = prefs.getString('value') ?? '';
    log.info("Body retrieved from cache (${cachedValue.length} bytes)");
    return cachedValue;
  }

  void _setCache(
      SharedPreferences prefs, String value, DateTime now, Position position) {
    prefs.setString('date', intl.DateFormat('yyyy-MM-dd').format(now));
    prefs.setString('value', value);
    prefs.setDouble('lat', position.latitude);
    prefs.setDouble('lon', position.longitude);
  }

  TideData _parseBody(String body) {
    // Parse the JSON and verify the correctness.
    Map<String, dynamic> map = jsonDecode(body);
    int result = map['status'];
    if (result != 200) {
      log.severe("Invalid result: $result");
      throw Exception("Invalid result received ($result)");
    }
    TideData tideData = TideData.fromJson(map);
    // Reduce the length of station name (to be displayed easily)
    String station = "";
    if (tideData.station.isNotEmpty) {
      station = tideData.station.split(',')[0];
    }
    // Normalize the timestamp in hours and the values in feet.
    double minTimestamp = tideData.heights.keys.reduce(min);
    SplayTreeMap<double, double> h = SplayTreeMap<double, double>.fromIterable(
        tideData.heights.entries,
        key: (e) => _epochToHour(e.key - minTimestamp),
        value: (e) => _metersToFeet(e.value));
    h.removeWhere((key, value) => key > 24);
    // Create interpolation points using Spline algorithm
    final spline = SplineInterpolation(
        nodes: h.entries
            .map((e) => InterpolationNode(x: e.key, y: e.value))
            .toList());
    SplayTreeMap<double, double> interpolation = SplayTreeMap();
    for (final e in h.entries) {
      final nextKey = h.firstKeyAfter(e.key);
      if (nextKey != null) {
        final newKey = (e.key + nextKey) / 2;
        interpolation.putIfAbsent(newKey, () => spline.compute(newKey));
      }
    }
    h.addAll(interpolation);
    // Normalize the timestamp in hours and the values in feet for the extremes.
    Map<double, double> e = tideData.extremes.map((key, value) =>
        MapEntry(_epochToHour(key - minTimestamp), _metersToFeet(value)));

    return TideData(station: station, heights: h, extremes: e);
  }

  Uri _composeUri(double latitude, double longitude) {
    return Uri.parse("https://www.worldtides.info/api/v3?"
        "heights&days=1&date=today&datum=CD&"
        "extremes&"
        "lat=$latitude&lon=$longitude&"
        "step=3600&"
        "key=8280c866-8a82-44e8-8943-c542836f15af");
  }

  Future<String> _fetchDataFromServer(double latitude, double longitude) async {
    final uri = _composeUri(latitude, longitude);

    String debugUri = uri.toString();
    debugUri = debugUri.substring(0, debugUri.indexOf("key="));
    log.info("URI for request (without key): $debugUri");

    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) {
      return response.body;
    } else {
      log.severe("Error response from server - code: ${response.statusCode}");
      log.severe("Error response from server - body: ${response.body}");
      throw Exception('Error response from server');
    }
  }

  Future<Position> _determinePosition() async {
    // Hardcode location for testing on web. Return it with a small
    // delay to facilitate UI testing.
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.delayed(
          const Duration(seconds: 2),
          () => Position(
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
      return Future.error('Location is disabled.');
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
        return Future.error('Location is denied');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      // Permissions are denied forever, handle appropriately.
      return Future.error('Location is permanently denied');
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

  (DateTime, DateTime) _calculateSunriseSunset(
      DateTime now, double latitude, double longitude) {
    var sunriseSunset =
        getSunriseSunset(latitude, longitude, now.timeZoneOffset, now);
    log.info("Sunrise: ${sunriseSunset.sunrise}, Sunset: ${sunriseSunset.sunset}");
    return (sunriseSunset.sunrise, sunriseSunset.sunset);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: showState(),
        ),
      ),
    );
  }

  String stateToString(AppState state) {
    switch (state) {
      case AppState.gettingLocation:
        return "Retrieving location";
      case AppState.gettingData:
        return "Retrieving data";
      case AppState.parsingData:
        return "Parsing data";
      case AppState.errorGeneric:
        return "Generic error";
      case AppState.errorNoLocation:
        return "Location is not available";
      case AppState.errorHttpTimeout:
        return "Data connection timeout";
      case AppState.errorHttpError:
        return "Data connection error";
      case AppState.errorParsing:
        return "Invalid data";
      default:
        // Other states don't have a valid string to be displayed.
        return "";
    }
  }

  List<Widget> showState() {
    var widgets = <Widget>[];
    switch (_appState) {
      case AppState.init:
      case AppState.gettingLocation:
      case AppState.gettingData:
      case AppState.parsingData:
        widgets = <Widget>[
          const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(),
          ),
          Text(
            stateToString(_appState),
            style: const TextStyle(fontSize: 20, color: Colors.white),
          )
        ];
        break;
      case AppState.errorGeneric:
      case AppState.errorNoLocation:
      case AppState.errorHttpTimeout:
      case AppState.errorHttpError:
      case AppState.errorParsing:
        widgets = <Widget>[
          Text(
            stateToString(_appState),
            style: const TextStyle(fontSize: 20, color: Colors.white),
          ),
          ElevatedButton(
            child: const Text('Retry'),
            onPressed: () => _mainFlow(force: true),
          ),
        ];
        break;
      case AppState.ready:
        // Write the station name only if it's available.
        bool stationNamePresent = (_tideData?.station ?? "").isNotEmpty;
        widgets = <Widget>[
          // Wrap the Text in SizedBox, so that we can truncate the text
          // if it's too long.
          SizedBox(
              width: MediaQuery.of(context).size.width * 0.6,
              child: Center(
                  child: Text(
                stationNamePresent ? _tideData!.station : "Unknown station",
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white,
                    fontStyle: stationNamePresent
                        ? FontStyle.normal
                        : FontStyle.italic),
              ))),
          SizedBox(
              width: MediaQuery.of(context).size.width * 0.8,
              height: MediaQuery.of(context).size.height * 0.7,
              child: GestureDetector(
                  onDoubleTap: () {
                    if (_appState == AppState.ready) {
                      _mainFlow(force: true);
                    }
                  },
                  child: ClipRect(
                      // At this point we know for sure that TideData is available.
                      child: CustomPaint(
                          painter: TidePainter(_tideData!, _sunrise, _sunset,
                              DateTime.now(), _animationProgress))))),
        ];
        break;
    }
    return widgets;
  }
}

class TidePainter extends CustomPainter {
  final TideData tideData;
  final DateTime? sunrise, sunset;
  final DateTime now;
  final double animationProgress;

  TidePainter(this.tideData, this.sunrise, this.sunset, this.now,
      this.animationProgress);

  @override
  void paint(Canvas canvas, Size size) {
    double minValue = tideData.heights.values.reduce(min);
    double maxValue = tideData.heights.values.reduce(max);
    minValue -= (maxValue - minValue) * 0.08;
    maxValue += (maxValue - minValue) * 0.08;

    final paintAxes = Paint()..color = Colors.white24;
    final paintTides = Paint()..color = Colors.lightBlue.shade900;
    final paintExtremes = Paint()..color = Colors.lightBlue.shade100;
    final paintBackgroundNight = Paint()..color = Colors.grey.shade900;
    final paintBackgroundDay = Paint()..color = Colors.grey.shade800;
    final paintCurrentTime = Paint()
      ..color = Colors.yellow.shade200
      ..strokeWidth = 2;

    // Values for the chart
    const double rightMargin = 10;
    const double leftMargin = 15;
    const double topMargin = 20;
    const double bottomMargin = 10;
    const double tickLen = 2;
    final zero = Offset(leftMargin, size.height - bottomMargin);
    CoordinateConv conv = CoordinateConv(
        minValue: minValue,
        maxValue: maxValue,
        width: size.width - (leftMargin + rightMargin),
        height: size.height - (topMargin + bottomMargin));

    // Draw background of the chart
    canvas.drawRect(Rect.fromPoints(zero, zero + conv.convert(24, maxValue)),
        paintBackgroundNight);
    if (sunrise != null && sunset != null) {
      canvas.drawRect(
          Rect.fromPoints(
              zero + conv.convert(_dateTimeToDouble(sunrise!), minValue),
              zero + conv.convert(_dateTimeToDouble(sunset!), maxValue)),
          paintBackgroundDay);
    }

    // Draw polygon with tides
    var points = <Offset>[];
    points.add(zero + conv.convert(0, minValue).scale(1, animationProgress));
    for (var entry in tideData.heights.entries) {
      points.add(zero +
          conv.convert(entry.key, entry.value).scale(1, animationProgress));
    }
    points.add(zero + conv.convert(24, minValue).scale(1, animationProgress));
    Path path = Path();
    path.addPolygon(points, true);
    canvas.drawPath(path, paintTides);

    // Draw X axis
    canvas.drawLine(zero, zero + conv.convert(24, minValue), paintAxes);
    for (int hour = 0; hour <= 24; hour++) {
      Offset offset = conv.convert(hour.toDouble(), minValue);
      canvas.drawLine(
          zero + offset, zero + offset + const Offset(0, tickLen), paintAxes);
      if (hour > 0 && hour.toInt() % 3 == 0) {
        final tp = _prepareText(hour.toInt().toString(), fontSize: 8);
        tp.paint(canvas, zero + offset + Offset(-tp.width / 2, tickLen));
      }
    }
    // Draw Y axis
    canvas.drawLine(zero, zero + conv.convert(0, maxValue), paintAxes);
    for (int i = minValue.ceil(); i <= maxValue; i++) {
      Offset offset = conv.convert(0, i.toDouble());
      canvas.drawLine(
          zero + offset, zero + offset + const Offset(-tickLen, 0), paintAxes);
      final tp = _prepareText(i.toString(), fontSize: 8);
      tp.paint(
          canvas,
          zero +
              offset +
              Offset(-leftMargin / 2 - tp.width / 2, -tp.height / 2));
    }

    // Draw line of current time
    double currentHour = _dateTimeToDouble(now);
    canvas.drawLine(zero + conv.convert(currentHour, minValue),
        zero + conv.convert(currentHour, maxValue), paintCurrentTime);

    // Write min and max values and associated dots
    Rect previousTextRect = const Rect.fromLTWH(0, 0, 0, 0);
    for (var e in tideData.extremes.entries) {
      canvas.drawCircle(
          zero + conv.convert(e.key, e.value).scale(1, animationProgress),
          2,
          paintExtremes);
      String hour = e.key.truncate().toString();
      String minute = ((e.key - e.key.truncate()) * 60)
          .truncate()
          .toString()
          .padLeft(2, "0");
      final tp = _prepareText("$hour:$minute", fontSize: 10);
      Offset textOffset = conv.convert(e.key, e.value);
      // Scale the offset based on the animation progress.
      textOffset = textOffset.scale(1, animationProgress);
      // Move the text up to avoid writing over the dot.
      textOffset += Offset(0, -10 - tp.height / 2);
      // If the text is too much left (out of chart), move it to the right.
      textOffset += Offset(-min(tp.width / 2, textOffset.dx), 0);
      // If the text is too much right (out of chart), move it to the left.
      textOffset += Offset(
          -max(textOffset.dx + tp.width - conv.convert(24, minValue).dx, 0.0),
          0);
      // Calculate the Rect containing the text. If there is any intersection
      // with the previous one, then we need to move the text up.
      Rect textRect =
          Rect.fromPoints(textOffset, textOffset + Offset(tp.width, tp.height));
      if (textRect.contains(previousTextRect.bottomRight) ||
          textRect.contains(previousTextRect.topRight)) {
        final shift =
            Offset(0, -tp.height - (textRect.top - previousTextRect.top));
        textOffset += shift;
        textRect.shift(shift);
      }
      tp.paint(canvas, zero + textOffset);
      previousTextRect = textRect;
    }
  }

  double _dateTimeToDouble(DateTime dateTime) {
    return dateTime.hour + (dateTime.minute / 60);
  }

  TextPainter _prepareText(String text, {double fontSize = 8}) {
    TextSpan span = TextSpan(
        style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.bold),
        text: text);
    TextPainter tp = TextPainter(
        text: span,
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center);
    tp.layout();
    return tp;
  }

  @override
  bool shouldRepaint(TidePainter oldDelegate) {
    return oldDelegate.now != now;
  }
}
