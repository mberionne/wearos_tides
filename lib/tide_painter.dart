import 'package:flutter/material.dart';
import 'dart:math';
import 'sun_time.dart';
import 'tide_data.dart';
import 'unit.dart';

// Helper class to convert coordindate
class _CoordinateConv {
  _CoordinateConv(
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

// Custom painter for the tides
class TidePainter extends CustomPainter {
  final TideData tideData;
  final SunTime? sunTime;
  final DateTime now;
  final double animationProgress;

  TidePainter(this.tideData, this.sunTime, this.now,
      this.animationProgress);

  @override
  void paint(Canvas canvas, Size size) {
    double minValue = tideData.heights.values.reduce(min);
    double maxValue = tideData.heights.values.reduce(max);
    minValue -= (maxValue - minValue) * 0.08;
    maxValue += (maxValue - minValue) * 0.08;

    final paintAxes = Paint()..color = Colors.white24;
    final paintTicks = Paint()..color = Colors.white;
    final paintTides = Paint()
      ..color = Colors.lightBlue.shade800.withAlpha(210);
    final paintExtremes = Paint()..color = Colors.lightBlue.shade100;
    final paintBackgroundNight = Paint()..color = Colors.grey.shade900;
    final paintBackgroundDay = Paint()..color = Colors.grey.shade600;
    final paintCurrentTime = Paint()
      ..color = Colors.yellow.shade200
      ..strokeWidth = 2;

    // Values for the chart
    final double rightMargin = (size.width * 0.1) + 10;
    final double leftMargin = (size.width * 0.1) + 15;
    const double topMargin = 20;
    const double bottomMargin = 10;
    const double tickLen = 2;
    final zero = Offset(leftMargin, size.height - bottomMargin);
    _CoordinateConv conv = _CoordinateConv(
        minValue: minValue,
        maxValue: maxValue,
        width: size.width - (leftMargin + rightMargin),
        height: size.height - (topMargin + bottomMargin));

    // Draw background of the chart
    canvas.drawRect(Rect.fromPoints(zero, zero + conv.convert(24, maxValue)),
        paintBackgroundNight);
    if (sunTime != null) {
      canvas.drawRect(
          Rect.fromPoints(
              zero + conv.convert(_dateTimeToDouble(sunTime!.sunrise), minValue),
              zero + conv.convert(_dateTimeToDouble(sunTime!.sunset), maxValue)),
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
          zero + offset, zero + offset + const Offset(0, tickLen), paintTicks);
      if (hour > 0 && hour.toInt() % 3 == 0) {
        final tp = _prepareText(hour.toInt().toString(), fontSize: 8);
        tp.paint(canvas, zero + offset + Offset(-tp.width / 2, tickLen));
      }
    }
    // Draw Y axis
    canvas.drawLine(zero, zero + conv.convert(0, maxValue), paintAxes);
    double yRange = (maxValue - minValue);
    double yStep = 1;
    double yStart = minValue.ceil().toDouble();
    if (yRange < 0.5) {
      yStep = 0.1;
      yStart = (minValue * 10).ceil().toDouble() / 10.0;
    } else if (yRange < 1.5) {
      yStep = 0.2;
      yStart = (minValue * 5).ceil().toDouble() / 5.0;
    } else if (yRange < 4) {
      yStep = 0.5;
      yStart = (minValue * 2).ceil().toDouble() / 2.0;
    } else if (yRange < 8) {
      yStep = 1;
    } else if (yRange < 16) {
      yStep = 2;
    } else if (yRange < 24) {
      yStep = 3;
    } else {
      yStep = 4;
    }
    for (double i = yStart; i <= maxValue; i += yStep) {
      Offset offset = conv.convert(0, i);
      canvas.drawLine(
          zero + offset, zero + offset + const Offset(-tickLen, 0), paintTicks);
      final tp = _prepareText(_doubleToString(i, 1), fontSize: 8);
      tp.paint(canvas,
          zero + offset + Offset(-tp.width - tickLen - 1, -tp.height / 2));
    }
    final unitTp =
        _prepareText(tideData.unit == Unit.feet ? "ft" : "m", fontSize: 8);
    unitTp.paint(
        canvas,
        zero +
            conv.convert(0, maxValue) +
            Offset(-unitTp.width - tickLen, -unitTp.height));

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
      final tp = _prepareText(_timeToString(e.key), fontSize: 10);
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

  String _timeToString(double time) {
    String hour = time.truncate().toString();
    String minute =
        ((time - time.truncate()) * 60).truncate().toString().padLeft(2, "0");
    return "$hour:$minute";
  }

  String _doubleToString(double value, int maxDecimalDigits) {
    String s = value.toStringAsFixed(maxDecimalDigits);
    if (s.indexOf(".") > 0) {
      s = s.replaceAll(RegExp(r"\.0*$"), "");
    }
    if (s == "-0") {
      s = "0";
    }
    return s;
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
