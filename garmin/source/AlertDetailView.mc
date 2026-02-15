/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Detail view for a single alert.
 * Designed for round watch display.
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
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var y = 24 - _scrollY;
        var data = _item["data"] as Dictionary;

        // Title — center-justified works well on round
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var title = _item["title"] as String;
        y = DrawUtils.drawWrappedTextRound(dc, y, Graphics.FONT_SMALL, title, w);

        y += 4;

        // Severity badge
        var severity = _item["severity"] as String;
        if (!severity.equals("")) {
            var badgeColor = DrawUtils.getSeverityColor(severity);
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

        // Separator — circle-aware
        var sepInset = DrawUtils.circleInset(y, h);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(sepInset, y, w - sepInset, y);
        y += 6;

        // Description — circle-aware wrapping
        var desc = "";
        if (data["description"] instanceof String) {
            desc = data["description"] as String;
        }
        if (!desc.equals("")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            y = DrawUtils.drawWrappedTextRound(dc, y, Graphics.FONT_XTINY, desc, w);
            y += 4;
        }

        // Coordinates
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        var coordStr = GeoUtils.formatCoord(itemLat, "N", "S") + " " + GeoUtils.formatCoord(itemLon, "E", "W");
        dc.drawText(w / 2, y, Graphics.FONT_XTINY, coordStr, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function scrollUp() as Void {
        if (_scrollY > 0) {
            _scrollY -= 30;
            if (_scrollY < 0) {
                _scrollY = 0;
            }
            WatchUi.requestUpdate();
        }
    }

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
