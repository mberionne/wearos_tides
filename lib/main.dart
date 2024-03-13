import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:location/location.dart';
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
  TideData({required this.station, required this.heights});
  final String station;
  final List<double> heights;

  factory TideData.fromJson(Map<String, dynamic> data) {
    final station = data['station']; // dynamic
    List<double> heights = []; // dynamic
    for (final height in data['heights']) {
      heights.add(height['height']);
    }
    return TideData(station: station ?? "", heights: heights);
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
        -(height / (maxValue - minValue) * (minValue + value)));
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

class _MainPageState extends State<MainPage> {
  AppState _appState = AppState.init;
  String _debugMessage = "";
  Location location = Location();
  TideData? _tideData;

  void _mainFlow() async {
    try {
      // TO DO: Fetch the location only if the cache is invalid.
      _moveTo(AppState.gettingLocation);
      LocationData locationData = await _getLocation();
      SharedPreferences prefs = await SharedPreferences.getInstance();
      String body = _getCacheIfValid(prefs);
      if (body.isEmpty) {
        _moveTo(AppState.gettingData);
        body = await _fetchDataFromServer(locationData);
        _setCache(prefs, body);
      }
      _moveTo(AppState.parsingData);
      TideData tideData = _parseBody(body);
      _debugMessage = "Heights: ${tideData.heights}";
      _moveTo(AppState.ready, tideData);
    } on TimeoutException catch (_) {
      _moveTo(AppState.errorHttpTimeout);
    } catch (err) {
      _debugMessage = "$err";
      switch (_appState) {
        case AppState.gettingLocation:
          _moveTo(AppState.errorNoLocation);
          break;
        case AppState.gettingData:
          _moveTo(AppState.errorHttpError);
          break;
        case AppState.parsingData:
          _moveTo(AppState.errorParsing);
          break;
        default:
          _moveTo(AppState.errorGeneric);
          break;
      }
    }
  }

  _moveTo(AppState newState, [TideData? tideData]) {
    setState(() {
      _appState = newState;
      _tideData = tideData;
    });
  }

  double metersToFeet(double m) {
    return m * 3.28084;
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    return "${now.year}-${now.month}-${now.day}";
  }

  String _getCacheIfValid(SharedPreferences prefs) {
    String cachedDate = prefs.getString('date') ?? '';
    if (cachedDate.isEmpty || cachedDate != _getCurrentDate()) {
      return '';
    }
    String cachedValue = prefs.getString('value') ?? '';
    return cachedValue;
  }

  void _setCache(SharedPreferences prefs, String value) {
    prefs.setString('date', _getCurrentDate());
    prefs.setString('value', value);
  }

  TideData _parseBody(String body) {
    Map<String, dynamic> map = jsonDecode(body);
    int result = map['status'];
    if (result != 200) {
      throw Exception("Invalid result received ($result)");
    }
    TideData tideData = TideData.fromJson(map);
    return TideData(
        station: tideData.station,
        heights: tideData.heights.map((val) => metersToFeet(val)).toList());
  }

  Uri _composeUri(LocationData locationData) {
    return Uri.parse("https://www.worldtides.info/api/v3?"
        "heights&days=1&date=today&datum=CD&"
        "lat={$locationData.latitude}&lon={$locationData.longitude}&"
        "step=3600&"
        "key=8280c866-8a82-44e8-8943-c542836f15af");
  }

  Future<String> _fetchDataFromServer(LocationData locationData) async {
    final uri = _composeUri(locationData);
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) {
      return response.body;
    } else {
      throw Exception('Error response from server');
    }
  }

  Future<LocationData> _getLocation() async {
    // Hardcode location for testing on web.
    if (defaultTargetPlatform != TargetPlatform.android) {
      return LocationData.fromMap(<String, double>{
        'latitude': 32.7157,
        'longitude': -117.1611,
      });
    }

    bool serviceEnabled = await location.serviceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await location.requestService();
      if (!serviceEnabled) {
        throw Exception('Service not enabled');
      }
    }
    PermissionStatus permissionGranted = await location.hasPermission();
    if (permissionGranted == PermissionStatus.denied) {
      permissionGranted = await location.requestPermission();
      if (permissionGranted != PermissionStatus.granted) {
        throw Exception('Permissions not granted');
      }
    }

    LocationData currentPosition = await location.getLocation();
    return currentPosition;
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
      // TO DO: to be removed - Only used for testing
      floatingActionButton: FloatingActionButton(
        onPressed: _mainFlow,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
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
            _appState.name,
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
            _appState.name,
            style: const TextStyle(fontSize: 20, color: Colors.white),
          ),
          ElevatedButton(
            child: const Text('Retry'),
            onPressed: () => _mainFlow(),
          ),
        ];
        break;
      case AppState.ready:
        widgets = <Widget>[
          const Text(
            "Ready",
            style: TextStyle(fontSize: 20, color: Colors.white),
          ),
          SizedBox(
              width: MediaQuery.of(context).size.width * 0.8,
              height: MediaQuery.of(context).size.height * 0.8,
              child: ClipRect(
                  // At this point we know for sure that TideData is available.
                  child: CustomPaint(painter: TidePainter(_tideData!)))),
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

  TidePainter(this.tideData);

  @override
  void paint(Canvas canvas, Size size) {
    double maxValue = tideData.heights.reduce(max).ceil().toDouble();
    double minValue = tideData.heights.reduce(min).floor().toDouble();

    // Draw main rectangle
    canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(size.width / 2, size.height / 2),
              width: size.width,
              height: size.height),
          const Radius.circular(5),
        ),
        Paint()..color = Colors.grey.shade100);

    // Values for the chart
    const double margin = 10;
    Offset zero = Offset(margin, size.height - margin);
    CoordinateConv conv = CoordinateConv(
        minValue: minValue,
        maxValue: maxValue,
        width: size.width - (2 * margin),
        height: size.height - (2 * margin));

    var paintAxes = Paint()..color = Colors.black;
    // Draw X axis
    canvas.drawLine(zero, zero + conv.convert(24, 0), paintAxes);
    for (double i = 0; i < 24; i++) {
      Offset t = conv.convert(i, 0);
      canvas.drawLine(zero + t, zero + t + const Offset(0, 2), paintAxes);
      if (i > 0 && i % 2 == 0) {
        writeText(canvas, i.toString(), zero + t + const Offset(-2, 2));
      }
    }
    // Draw Y axis
    canvas.drawLine(zero, zero + conv.convert(0, maxValue), paintAxes);
    for (double i = minValue; i <= maxValue; i++) {
      Offset t = conv.convert(0, i);
      canvas.drawLine(zero + t, zero + t + const Offset(-2, 0), paintAxes);
      writeText(canvas, i.toString(), zero + t + const Offset(-margin, -4));
    }

    // Draw polygon with tides
    var points = <Offset>[];
    int minHour = 0;
    int maxHour = 0;
    points.add(zero + conv.convert(0, minValue));
    for (int i = 0; i <= 24 && i < tideData.heights.length; i++) {
      points.add(zero + conv.convert(i.toDouble(), tideData.heights[i]));
      if (tideData.heights[i] < tideData.heights[minHour]) {
        minHour = i;
      } else if (tideData.heights[i] > tideData.heights[maxHour]) {
        maxHour = i;
      }
    }
    points.add(zero + conv.convert(24, minValue));
    Path path = Path();
    path.addPolygon(points, true);
    var paintTides = Paint()..color = Colors.blue.shade400;
    canvas.drawPath(path, paintTides);

    // Write min and max values
    double v = tideData.heights[maxHour];
    writeText(canvas, v.toString(),
        zero + conv.convert(maxHour.toDouble(), v) + const Offset(0, -10));
  }

  void writeText(Canvas canvas, String text, Offset offset) {
    TextSpan span = TextSpan(
        style: const TextStyle(color: Colors.black, fontSize: 8.0), text: text);
    TextPainter tp = TextPainter(text: span, textDirection: TextDirection.ltr);
    tp.layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    // Not really needed because we don't expect that
    // the data can change.
    return false;
  }
}
