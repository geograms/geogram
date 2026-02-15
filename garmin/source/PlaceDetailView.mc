/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Detail view for a single place.
 * Shows name, type, distance + bearing, description, coordinates.
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class PlaceDetailView extends WatchUi.View {

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

        // Name
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var title = _item["title"] as String;
        y = DrawUtils.drawWrappedText(dc, w / 2, y, Graphics.FONT_SMALL, title, w - 20);

        y += 4;

        // Place type badge
        var placeType = _item["type"] as String;
        if (!placeType.equals("")) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, y, Graphics.FONT_XTINY, placeType.toUpper(), Graphics.TEXT_JUSTIFY_CENTER);
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
            y = DrawUtils.drawWrappedText(dc, 12, y, Graphics.FONT_XTINY, desc, w - 24);
            y += 4;
        }

        // Address
        if (data["address"] instanceof String) {
            var address = data["address"] as String;
            if (!address.equals("")) {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                y = DrawUtils.drawWrappedText(dc, 12, y, Graphics.FONT_XTINY, address, w - 24);
                y += 4;
            }
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
}

//! Input delegate for place detail view
class PlaceDetailDelegate extends WatchUi.BehaviorDelegate {

    private var _view as PlaceDetailView;

    function initialize(view as PlaceDetailView) {
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
