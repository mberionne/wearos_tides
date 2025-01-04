part of 'main_page_screen.dart';

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

abstract class _MainPageController extends State<MainPage> with WidgetsBindingObserver {
  AppState _appState = AppState.init;
  bool _isRunning = false;
  bool _needsRefresh = false;
  TideData? _tideData;
  SunTime? _sunTime;
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

  /// Triggers the main flow, if one is not already running.
  void _mainFlow({bool force = false}) async {
    if (_isRunning) {
      log.info("Main flow already running");
      return;
    }
    _isRunning = true;
    await _mainFlowImpl(force);
    _isRunning = false;
  }

  /// Implementation of the main flow with the logic.
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
      position = await PositionHelper.getPosition();
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
    SunTime? sunTime;
    Unit unit = Unit.feet;
    if (position != null) {
      sunTime =
          SunTime.calculateSunriseSunset(now, position.latitude, position.longitude);
      unit = UnitHelper.calculateUnit(position.latitude, position.longitude);
      log.info("Selected unit: ${UnitHelper.name(unit)}");
    }
    try {
      TideData tideData = _parseBody(body, unit);
      if (isFromServer) {
        // Position must be known if we retrieve content from server.
        _setCache(prefs, body, now, position!);
      }
      log.info("Body with tides parsed successfully");
      log.fine("Tide data: $tideData");
      _moveTo(AppState.ready, tideData, sunTime);
      await _playAnimation();
      _lastSuccessTimestamp = now;
    } catch (err) {
      log.severe("Error parsing the body: $err");
      log.severe("Body: $body");
      _moveTo(AppState.errorParsing);
    }
  }

  /// Update the state.
  _moveTo(AppState newState,
      [TideData? tideData, SunTime? sunTime]) {
    setState(() {
      _appState = newState;
      _tideData = tideData;
      _sunTime = sunTime;
      _animationProgress = 0.0;
    });
  }

  /// Async method to play the animation of the tides
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

  /// Convert epoch time (ms) to hour
  double _epochToHour(double ms) {
    return ms / 3600;
  }

  /// Calculate a unique ID for each day.
  int _dateId(DateTime date) {
    final fixedDate = DateTime(2024, 3, 18); // Arbitrary start
    final onlyDate = DateTime(date.year, date.month, date.day);
    // We can safely ignore the case of short days due to DST.
    return onlyDate.difference(fixedDate).inDays;
  }

  /// Retrieves the content of the cache if valid (not stale, not distant)
  String _getCacheIfValid(
      SharedPreferences prefs, DateTime now, Position? position) {
    // Check date
    int cachedDateId = prefs.getInt("dateid") ?? 0;
    if (cachedDateId == 0 || cachedDateId != _dateId(now)) {
      // If the cache is for a different day, return immediately.
      log.info("Discarding cache from a different day: $cachedDateId");
      return "";
    }
    // Check location
    if (position != null) {
      double? cachedLatitude = prefs.getDouble("lat");
      double? cachedLongitude = prefs.getDouble("lon");
      if (cachedLatitude == null || cachedLongitude == null) {
        return "";
      }
      double distanceMeters = Geolocator.distanceBetween(position.latitude,
          position.longitude, cachedLatitude, cachedLongitude);
      if (distanceMeters > 50000) {
        // If the cache is for a point that is too far, return immediately.
        log.info("Discarding cache due to distance: $distanceMeters meters");
        return "";
      }
    }
    // Retrieve cached value
    String cachedValue = prefs.getString("value") ?? "";
    log.info("Body retrieved from cache (${cachedValue.length} bytes)");
    return cachedValue;
  }

  /// Store the values into the cache. We store the body of the tide data received from
  /// the server as it is.
  void _setCache(
      SharedPreferences prefs, String value, DateTime now, Position position) {
    prefs.setInt("dateid", _dateId(now));
    prefs.setString("value", value);
    prefs.setDouble("lat", position.latitude);
    prefs.setDouble("lon", position.longitude);
  }

  /// Parse the body received from the server into TideData. As part of
  /// this operation, it performs interpolation and unit convertion.
  TideData _parseBody(String body, Unit unit) {
    // Parse the JSON and verify the correctness.
    Map<String, dynamic> map = jsonDecode(body);
    int result = map["status"];
    if (result != 200) {
      log.severe("Invalid result: $result");
      throw Exception("Invalid result received ($result)");
    }
    TideData tideData = TideData.fromJson(map);
    // Reduce the length of station name (to be displayed easily)
    String station = "";
    if (tideData.station.isNotEmpty) {
      station = tideData.station.split(",")[0];
    }
    // Normalize the timestamp in hours and converts the values in feet (if needed).
    double minTimestamp = tideData.heights.keys.reduce(min);
    SplayTreeMap<double, double> h = SplayTreeMap<double, double>.fromIterable(
        tideData.heights.entries,
        key: (e) => _epochToHour(e.key - minTimestamp),
        value: (e) => unit == Unit.feet ? UnitHelper.metersToFeet(e.value) : e.value);
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
        MapEntry(_epochToHour(key - minTimestamp), UnitHelper.metersToFeet(value)));

    return TideData(station: station, heights: h, extremes: e, unit: unit);
  }

  /// Compose the URI to request the tide data from the server.
  Uri _composeUri(double latitude, double longitude) {
    String key = dotenv.env["API_KEY"] ?? "";
    String uriStringNoKey = "https://www.worldtides.info/api/v3?"
        "heights&days=1&date=today&datum=CD&"
        "extremes&"
        "lat=$latitude&lon=$longitude&"
        "step=3600";
    log.info("URI for request (without key): $uriStringNoKey");
    return Uri.parse("$uriStringNoKey&key=$key");
  }

  /// Retrieve the tide data from the server.
  Future<String> _fetchDataFromServer(double latitude, double longitude) async {
    final uri = _composeUri(latitude, longitude);
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) {
      return response.body;
    } else {
      log.severe("Error response from server - code: ${response.statusCode}");
      log.severe("Error response from server - body: ${response.body}");
      throw Exception("Error response from server");
    }
  }
}