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
import 'package:shared_preferences/shared_preferences.dart';

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
  bool _needsRefresh = false;
  String _debugMessage = "";
  TideData? _tideData;
  DateTime _lastSuccessTimestamp = DateTime.fromMillisecondsSinceEpoch(0);

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
    _debugMessage = "";
    final now = DateTime.now();
    if (!force && now.difference(_lastSuccessTimestamp).inMinutes.abs() < 15) {
      // We ran the algorithm recently and we are not requested to force it
      // so we can directly return.
    }

    // Retrive position. At this point, it's ok to fail.
    _moveTo(AppState.gettingLocation, null);
    Position? position;
    String positionErr = "";
    try {
      position = await _determinePosition();
    } catch (err) {
      positionErr = "$err";
    }

    // Retrieve data, either from the cache or from the server
    String body = "";
    _moveTo(AppState.gettingData);
    try {
      // Retrieve the cache
      SharedPreferences prefs = await SharedPreferences.getInstance();
      body = _getCacheIfValid(prefs, now, position);
      // If the cache is not available and a position is available, perform query
      // from the server. Otherwise move to error state.
      if (body.isEmpty) {
        if (position != null) {
          body =
              await _fetchDataFromServer(position.latitude, position.longitude);
          _setCache(prefs, body, now, position);
        } else {
          _debugMessage = positionErr;
          _moveTo(AppState.errorNoLocation);
          return;
        }
      }
    } on TimeoutException catch (_) {
      _moveTo(AppState.errorHttpTimeout);
      return;
    } catch (err) {
      _debugMessage = "$err";
      _moveTo(AppState.errorHttpError);
      return;
    }

    // Parse data
    _moveTo(AppState.parsingData);
    try {
      TideData tideData = _parseBody(body);
      _moveTo(AppState.ready, tideData);
      _lastSuccessTimestamp = now;
    } catch (err) {
      _debugMessage = "$err ($body)";
      _moveTo(AppState.errorParsing);
    }
  }

  _moveTo(AppState newState, [TideData? tideData]) {
    setState(() {
      _appState = newState;
      _tideData = tideData;
    });
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
      if (distanceMeters > 100000) {
        // If the cache is for a point that is too far, return immediately.
        return '';
      }
    }
    // Retrieve cached value
    String cachedValue = prefs.getString('value') ?? '';
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
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) {
      return response.body;
    } else {
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
              latitude: 33.768321,
              longitude: -118.195617,
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
      return position;
    }

    // This application can work with low accuracy (lowest does not guarantee
    // a location),  and we also want to specify a timeout to avoid an infinite wait.
    return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 8));
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
        widgets = <Widget>[
          // Wrap the Text in SizedBox, so that we can truncate the text
          // if it's too long.
          SizedBox(
              width: MediaQuery.of(context).size.width * 0.8,
              child: Center(
                  child: Text(
                _tideData?.station ?? "",
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white),
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
                          painter: TidePainter(_tideData!, DateTime.now()))))),
        ];
        break;
    }
    if (_debugMessage.isNotEmpty) {
      widgets.add(Text(
        _debugMessage,
        style: const TextStyle(fontSize: 8, color: Colors.white),
      ));
    }
    return widgets;
  }
}

class TidePainter extends CustomPainter {
  final TideData tideData;
  final DateTime now;

  TidePainter(this.tideData, this.now);

  @override
  void paint(Canvas canvas, Size size) {
    final maxValue = tideData.heights.values.reduce(max).ceil().toDouble();
    final minValue = tideData.heights.values.reduce(min).floor().toDouble();

    final paintAxes = Paint()..color = Colors.white24;
    final paintTides = Paint()..color = Colors.lightBlue.shade900;
    final paintExtremes = Paint()..color = Colors.lightBlue.shade100;
    final paintBackground = Paint()..color = Colors.grey.shade800;
    final paintCurrentTime = Paint()
      ..color = Colors.yellow.shade200
      ..strokeWidth = 2;

    // Values for the chart
    const double rightMargin = 10;
    const double leftMargin = 15;
    const double topMargin = 20;
    const double bottomMargin = 10;
    final zero = Offset(leftMargin, size.height - bottomMargin);
    CoordinateConv conv = CoordinateConv(
        minValue: minValue,
        maxValue: maxValue,
        width: size.width - (leftMargin + rightMargin),
        height: size.height - (topMargin + bottomMargin));

    // Draw background of the chart
    canvas.drawRect(Rect.fromPoints(zero, zero + conv.convert(24, maxValue)),
        paintBackground);

    // Draw polygon with tides
    var points = <Offset>[];
    points.add(zero + conv.convert(0, minValue));
    for (var entry in tideData.heights.entries) {
      points.add(zero + conv.convert(entry.key, entry.value));
    }
    points.add(zero + conv.convert(24, minValue));
    Path path = Path();
    path.addPolygon(points, true);
    canvas.drawPath(path, paintTides);

    // Draw X axis
    canvas.drawLine(zero, zero + conv.convert(24, minValue), paintAxes);
    for (double hour in tideData.heights.keys) {
      // Skip entries that are not round
      if (hour != hour.toInt()) {
        continue;
      }
      Offset t = conv.convert(hour, minValue);
      canvas.drawLine(zero + t, zero + t + const Offset(0, 2), paintAxes);
      if (hour > 0 && hour.toInt() % 3 == 0) {
        _writeText(canvas, hour.toInt().toString(),
            zero + t + const Offset(0, bottomMargin / 2));
      }
    }
    // Draw Y axis
    canvas.drawLine(zero, zero + conv.convert(0, maxValue), paintAxes);
    for (double i = minValue; i <= maxValue; i++) {
      Offset t = conv.convert(0, i);
      canvas.drawLine(zero + t, zero + t + const Offset(-2, 0), paintAxes);
      _writeText(canvas, i.toInt().toString(),
          zero + t + const Offset(-leftMargin / 2, 0));
    }

    // Write min and max values and associated dot
    for (var e in tideData.extremes.entries) {
      canvas.drawCircle(zero + conv.convert(e.key, e.value), 2, paintExtremes);
      String hour = e.key.truncate().toString();
      String minute = ((e.key - e.key.truncate()) * 60)
          .truncate()
          .toString()
          .padLeft(2, "0");
      _writeText(canvas, "$hour:$minute",
          zero + conv.convert(e.key, e.value) + const Offset(0, -10),
          size: 10);
    }

    // Draw line of current time
    double currentHour = now.hour + (now.minute / 60);
    canvas.drawLine(zero + conv.convert(currentHour, minValue),
        zero + conv.convert(currentHour, maxValue), paintCurrentTime);
  }

  void _writeText(Canvas canvas, String text, Offset offset,
      {double size = 8.0}) {
    TextSpan span = TextSpan(
        style: TextStyle(
            color: Colors.white, fontSize: size, fontWeight: FontWeight.bold),
        text: text);
    TextPainter tp = TextPainter(
        text: span,
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center);
    tp.layout();
    tp.paint(canvas, offset + Offset(-tp.width / 2, -tp.height / 2));
  }

  @override
  bool shouldRepaint(TidePainter oldDelegate) {
    return oldDelegate.now != now;
  }
}
