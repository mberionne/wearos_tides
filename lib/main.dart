import 'dart:async';
import 'dart:convert';
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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
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
  String _errorMessage = "";
  Location location = Location();

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
      List<double> heights = _parseBody(body);
      _moveTo(AppState.ready);
    } on TimeoutException catch (_) {
      _moveTo(AppState.errorHttpTimeout);
    } catch (err) {
      _errorMessage = "$err";
      switch(_appState) {
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

  _moveTo(AppState newState) {
    setState(() {
      _appState = newState;
    });
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

  List<double> _parseBody(String body) {
    Map<String, dynamic> map = jsonDecode(body);
    int result = map['status'];
    if (result != 200) {
      throw Exception("Invalid result received");
    }

    final heights = <double>[];
    final points = map['heights'];
    for(final point in points){
      heights.add(point['height']);
    }
    return heights;
  }

  Uri _composeUri(LocationData locationData) {
    return Uri.parse(
       "https://www.worldtides.info/api/v3?"
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
          children: <Widget>[
            showState()
          ],
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

  Widget showState() {
    switch (_appState) {
      case AppState.init:
      case AppState.gettingLocation:
      case AppState.gettingData:
      case AppState.parsingData:
        return Column(
          children: <Widget>[
            const SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(),
            ),
            Text(
              _appState.name,
              style: const TextStyle(fontSize: 20, color: Colors.black),
            )
          ],
        );
      case AppState.errorGeneric:
      case AppState.errorNoLocation:
      case AppState.errorHttpTimeout:
      case AppState.errorHttpError:
      case AppState.errorParsing:
      case AppState.ready:
        return Text(
          _errorMessage.isEmpty ?
          _appState.name : _errorMessage,
          style: const TextStyle(fontSize: 20, color: Colors.black),
        );
    }
  }
}
