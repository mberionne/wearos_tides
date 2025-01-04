import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:equations/equations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'position_helper.dart';
import 'tide_data.dart';
import 'sun_time.dart';
import 'tide_painter.dart';
import 'unit.dart';

part 'main_page_controller.dart';

class MainPage extends StatefulWidget {
  final String title = "";

  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends _MainPageController {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: _showState(),
        ),
      ),
    );
  }

  String _stateToString(AppState state) {
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

  List<Widget> _showState() {
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
            _stateToString(_appState),
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
            _stateToString(_appState),
            style: const TextStyle(fontSize: 20, color: Colors.white),
          ),
          ElevatedButton(
            child: const Text("Retry"),
            onPressed: () => _mainFlow(force: true),
          ),
        ];
        break;
      case AppState.ready:
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
              // We reducde the height so that it is centered correctly.
              // Pass the entire width and handle margins in the painter.
              width: MediaQuery.of(context).size.width,
              height: MediaQuery.of(context).size.height * 0.7,
              child: GestureDetector(
                  onDoubleTap: () {
                    // This is displayed only for ready state, so no need to
                    // check it explicitly.
                    _mainFlow(force: true);
                  },
                  child: ClipRect(
                      // At this point we know for sure that TideData is available.
                      child: CustomPaint(
                          painter: TidePainter(_tideData!, _sunTime,
                              DateTime.now(), _animationProgress))))),
        ];
        break;
    }
    return widgets;
  }
}
