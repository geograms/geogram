/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Alerts list view — shows nearby alerts sorted by distance.
 * Extends BaseListView for shared list rendering.
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class AlertsListView extends BaseListView {

    private var _items as Array = [];
    private var _client as StationClient;

    function initialize() {
        BaseListView.initialize();
        _client = new StationClient();
    }

    function getHeaderTitle() as String {
        return "Alerts";
    }

    function getItems() as Array {
        return _items;
    }

    function onLayout(dc as Dc) as Void {
        loadCachedData();
        if (!MockData.DEBUG_MOCK) {
            refreshData();
        }
    }

    function loadCachedData() as Void {
        var alerts = DataStore.getAlerts();
        _items = [];

        if (alerts != null) {
            for (var i = 0; i < alerts.size(); i++) {
                var a = alerts[i];
                if (a instanceof Dictionary) {
                    _items.add(buildAlertItem(a));
                }
            }
        }
        sortByDistance();
        if (_items.size() > 0) {
            _state = :ready;
        }
    }

    function refreshData() as Void {
        var pos = DataStore.getLastPosition();
        var lat = 0.0d;
        var lon = 0.0d;
        if (pos != null) {
            lat = pos[0];
            lon = pos[1];
        }
        var radius = DataStore.getRadiusKm();
        _state = :loading;
        WatchUi.requestUpdate();
        _client.fetchAlerts(lat, lon, radius, method(:onAlertsResult));
    }

    function onAlertsResult(alerts as Array?) as Void {
        _items = [];
        if (alerts == null) {
            if (_items.size() == 0) {
                _state = :error;
                _errorMsg = "No connection";
            }
            WatchUi.requestUpdate();
            return;
        }
        DataStore.setAlerts(alerts);
        for (var i = 0; i < alerts.size(); i++) {
            var a = alerts[i];
            if (a instanceof Dictionary) {
                _items.add(buildAlertItem(a));
            }
        }
        sortByDistance();
        _selectedIndex = 0;
        _scrollOffset = 0;
        _state = :ready;
        WatchUi.requestUpdate();
    }

    function buildAlertItem(data as Dictionary) as Dictionary {
        var title = (data["title"] != null) ? data["title"].toString() : "Alert";
        var lat = parseDouble(data["latitude"]);
        var lon = parseDouble(data["longitude"]);
        var severity = "";
        if (data["severity"] instanceof String) {
            severity = data["severity"] as String;
        }
        return {
            "title" => title,
            "lat" => lat,
            "lon" => lon,
            "severity" => severity,
            "data" => data,
            "distance" => 0.0d
        };
    }

    function parseDouble(val) as Double {
        if (val instanceof Double) { return val as Double; }
        if (val instanceof Float) { return (val as Float).toDouble(); }
        if (val instanceof Number) { return (val as Number).toDouble(); }
        return 0.0d;
    }

    function sortByDistance() as Void {
        var pos = DataStore.getLastPosition();
        if (pos == null) { return; }
        var curLat = pos[0];
        var curLon = pos[1];
        for (var i = 0; i < _items.size(); i++) {
            var item = _items[i] as Dictionary;
            item["distance"] = GeoUtils.calculateDistance(curLat, curLon, item["lat"] as Double, item["lon"] as Double);
        }
        // Insertion sort
        for (var i = 1; i < _items.size(); i++) {
            var key = _items[i] as Dictionary;
            var keyDist = key["distance"] as Double;
            var j = i - 1;
            while (j >= 0 && (_items[j] as Dictionary)["distance"] as Double > keyDist) {
                _items[j + 1] = _items[j];
                j--;
            }
            _items[j + 1] = key;
        }
    }

    function drawRow(dc as Dc, item, y as Number, w as Number, isSelected as Boolean, inset as Number) as Void {
        var dict = item as Dictionary;
        // Severity color dot
        var severity = dict["severity"] as String;
        var dotColor = severity.equals("") ? Graphics.COLOR_BLUE : DrawUtils.getSeverityColor(severity);
        dc.setColor(dotColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(inset + 10, y + ROW_HEIGHT / 2, DOT_RADIUS);

        // Title
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var title = dict["title"] as String;
        var maxChars = (w - inset * 2 - 70) / 8;
        if (maxChars < 6) { maxChars = 6; }
        if (title.length() > maxChars) {
            title = title.substring(0, maxChars - 1) + "..";
        }
        dc.drawText(inset + 22, y + 2, Graphics.FONT_TINY, title, Graphics.TEXT_JUSTIFY_LEFT);

        // Distance
        var dist = dict["distance"] as Double;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w - inset - 4, y + 2, Graphics.FONT_XTINY, GeoUtils.formatDistance(dist), Graphics.TEXT_JUSTIFY_RIGHT);
    }

    function onItemSelect(index as Number) as Void {
        if (index >= 0 && index < _items.size()) {
            var item = _items[index] as Dictionary;
            var pos = DataStore.getLastPosition();
            var lat = 0.0d;
            var lon = 0.0d;
            if (pos != null) {
                lat = pos[0];
                lon = pos[1];
            }
            var detailView = new AlertDetailView(item, lat, lon);
            WatchUi.pushView(detailView, new AlertDetailDelegate(detailView), WatchUi.SLIDE_LEFT);
        }
    }
}
