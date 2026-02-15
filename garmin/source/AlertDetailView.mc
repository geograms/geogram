/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Detail view for a single alert or place.
 * Shows title, severity/type, distance + bearing, description, coordinates.
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class AlertDetailView extends WatchUi.View {

    private var _item as Dictionary;
    private var _userLat as Double;
    private var _userLon as Double;
    private var _scrollY as Number = 0;

    function initialize(item as Dictionary, userLat as Double, userLon as Double) {
        View.initialize();
        _item = item;
        _userLat = userLat;
        _userLon = userLon;
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var y = 8 - _scrollY;
        var data = _item["data"] as Dictionary;
        var isAlert = (_item["type"] == :alert);

        // Title
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var title = _item["title"] as String;
        y = drawWrappedText(dc, w / 2, y, Graphics.FONT_SMALL, title, w - 20);

        y += 4;

        // Severity badge (alerts) or type badge (places)
        if (isAlert) {
            var severity = _item["severity"] as String;
            if (!severity.equals("")) {
                var badgeColor = getSeverityColor(severity);
                dc.setColor(badgeColor, Graphics.COLOR_TRANSPARENT);
                dc.drawText(w / 2, y, Graphics.FONT_XTINY, severity.toUpper(), Graphics.TEXT_JUSTIFY_CENTER);
                y += 18;
            }
            // Alert type
            if (data["type"] instanceof String) {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(w / 2, y, Graphics.FONT_XTINY, data["type"] as String, Graphics.TEXT_JUSTIFY_CENTER);
                y += 18;
            }
        } else {
            // Place type
            if (data["type"] instanceof String) {
                dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
                dc.drawText(w / 2, y, Graphics.FONT_XTINY, (data["type"] as String).toUpper(), Graphics.TEXT_JUSTIFY_CENTER);
                y += 18;
            }
        }

        y += 4;

        // Distance + bearing
        var itemLat = _item["lat"] as Double;
        var itemLon = _item["lon"] as Double;
        var dist = GeoUtils.calculateDistance(_userLat, _userLon, itemLat, itemLon);
        var bearing = GeoUtils.calculateBearing(_userLat, _userLon, itemLat, itemLon);
        var cardinal = GeoUtils.bearingToCardinal(bearing);
        var distStr = GeoUtils.formatDistance(dist) + " " + cardinal;

        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, y, Graphics.FONT_SMALL, distStr, Graphics.TEXT_JUSTIFY_CENTER);
        y += 24;

        // Separator
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(20, y, w - 20, y);
        y += 6;

        // Description
        var desc = "";
        if (data["description"] instanceof String) {
            desc = data["description"] as String;
        }
        if (!desc.equals("")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            y = drawWrappedText(dc, 12, y, Graphics.FONT_XTINY, desc, w - 24);
            y += 4;
        }

        // Coordinates
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        var coordStr = formatCoord(itemLat, "N", "S") + " " + formatCoord(itemLon, "E", "W");
        dc.drawText(w / 2, y, Graphics.FONT_XTINY, coordStr, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Format a coordinate value as degrees with direction
    function formatCoord(value as Double, positive as String, negative as String) as String {
        var dir = positive;
        var v = value;
        if (v < 0.0d) {
            dir = negative;
            v = -v;
        }
        var deg = v.toNumber();
        var min = ((v - deg) * 60.0d).toNumber();
        return deg.toString() + "'" + min.toString() + dir;
    }

    //! Draw text with word wrapping, return Y position after last line
    function drawWrappedText(dc as Dc, x as Number, y as Number, font as Graphics.FontDefinition, text as String, maxWidth as Number) as Number {
        var charWidth = dc.getTextWidthInPixels("M", font);
        var charsPerLine = maxWidth / charWidth;
        if (charsPerLine < 5) {
            charsPerLine = 5;
        }
        var lineHeight = dc.getFontHeight(font) + 2;

        var pos = 0;
        while (pos < text.length()) {
            var end = pos + charsPerLine;
            if (end >= text.length()) {
                end = text.length();
            } else {
                // Try to break at a space
                var spacePos = end;
                while (spacePos > pos) {
                    var ch = text.substring(spacePos - 1, spacePos);
                    if (ch.equals(" ")) {
                        break;
                    }
                    spacePos--;
                }
                if (spacePos > pos) {
                    end = spacePos;
                }
            }
            var line = text.substring(pos, end);
            dc.drawText(x, y, font, line, Graphics.TEXT_JUSTIFY_LEFT);
            y += lineHeight;
            pos = end;
            // Skip leading space on next line
            if (pos < text.length()) {
                var nextCh = text.substring(pos, pos + 1);
                if (nextCh.equals(" ")) {
                    pos++;
                }
            }
        }
        return y;
    }

    function getSeverityColor(severity as String) as Number {
        if (severity.equals("emergency")) {
            return Graphics.COLOR_RED;
        } else if (severity.equals("urgent")) {
            return Graphics.COLOR_ORANGE;
        } else if (severity.equals("attention")) {
            return Graphics.COLOR_YELLOW;
        }
        return Graphics.COLOR_BLUE;
    }

    //! Scroll content up
    function scrollUp() as Void {
        if (_scrollY > 0) {
            _scrollY -= 30;
            if (_scrollY < 0) {
                _scrollY = 0;
            }
            WatchUi.requestUpdate();
        }
    }

    //! Scroll content down
    function scrollDown() as Void {
        _scrollY += 30;
        WatchUi.requestUpdate();
    }

    function getItem() as Dictionary {
        return _item;
    }
}

//! Input delegate for alert detail view
class AlertDetailDelegate extends WatchUi.BehaviorDelegate {

    private var _view as AlertDetailView;

    function initialize(view as AlertDetailView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onNextPage() as Boolean {
        _view.scrollDown();
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.scrollUp();
        return true;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
