/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Main list view showing nearby alerts and places sorted by distance.
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.WatchUi;

class AlertsView extends WatchUi.View {

    private var _items as Array = [];
    private var _selectedIndex as Number = 0;
    private var _scrollOffset as Number = 0;
    private var _state as Symbol = :loading; // :loading, :ready, :error
    private var _errorMsg as String = "";
    private var _client as StationClient;
    private var _pendingRequests as Number = 0;
    private var _tempAlerts as Array?;
    private var _tempPlaces as Array?;
    private var _currentLat as Double = 0.0d;
    private var _currentLon as Double = 0.0d;

    // Layout constants
    private const ROW_HEIGHT = 36;
    private const HEADER_HEIGHT = 40;
    private const DOT_RADIUS = 6;

    function initialize() {
        View.initialize();
        _client = new StationClient();
    }

    function onLayout(dc as Dc) as Void {
        // Start GPS listening
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        // Load cached data first
        loadCachedData();
        // Trigger a fresh fetch
        refreshData();
    }

    //! GPS position callback
    function onPosition(info as Position.Info) as Void {
        if (info.position != null) {
            var coords = info.position.toDegrees();
            _currentLat = coords[0].toDouble();
            _currentLon = coords[1].toDouble();
            DataStore.setLastPosition(_currentLat, _currentLon);
            // Re-sort items by distance
            sortItemsByDistance();
            WatchUi.requestUpdate();
        }
    }

    //! Load previously cached alerts and places
    function loadCachedData() as Void {
        var alerts = DataStore.getAlerts();
        var places = DataStore.getPlaces();
        var pos = DataStore.getLastPosition();

        if (pos != null) {
            _currentLat = pos[0];
            _currentLon = pos[1];
        }

        _items = [];
        if (alerts != null) {
            for (var i = 0; i < alerts.size(); i++) {
                var a = alerts[i];
                if (a instanceof Dictionary) {
                    _items.add(buildItem(a, :alert));
                }
            }
        }
        if (places != null) {
            for (var i = 0; i < places.size(); i++) {
                var p = places[i];
                if (p instanceof Dictionary) {
                    _items.add(buildItem(p, :place));
                }
            }
        }
        sortItemsByDistance();
        if (_items.size() > 0) {
            _state = :ready;
        }
    }

    //! Build a display item from an alert or place dictionary
    function buildItem(data as Dictionary, itemType as Symbol) as Dictionary {
        var title = "";
        if (itemType == :alert) {
            title = (data["title"] != null) ? data["title"].toString() : "Alert";
        } else {
            title = (data["name"] != null) ? data["name"].toString() : "Place";
        }

        var lat = 0.0d;
        var lon = 0.0d;
        if (data["latitude"] instanceof Double) {
            lat = data["latitude"] as Double;
        } else if (data["latitude"] instanceof Float) {
            lat = (data["latitude"] as Float).toDouble();
        } else if (data["latitude"] instanceof Number) {
            lat = (data["latitude"] as Number).toDouble();
        }
        if (data["longitude"] instanceof Double) {
            lon = data["longitude"] as Double;
        } else if (data["longitude"] instanceof Float) {
            lon = (data["longitude"] as Float).toDouble();
        } else if (data["longitude"] instanceof Number) {
            lon = (data["longitude"] as Number).toDouble();
        }

        var severity = "";
        if (data["severity"] instanceof String) {
            severity = data["severity"] as String;
        }

        return {
            "title" => title,
            "lat" => lat,
            "lon" => lon,
            "type" => itemType,
            "severity" => severity,
            "data" => data,
            "distance" => 0.0d
        };
    }

    //! Sort all items by distance from current position
    function sortItemsByDistance() as Void {
        // Calculate distances
        for (var i = 0; i < _items.size(); i++) {
            var item = _items[i] as Dictionary;
            var lat = item["lat"] as Double;
            var lon = item["lon"] as Double;
            if (_currentLat != 0.0d || _currentLon != 0.0d) {
                item["distance"] = GeoUtils.calculateDistance(_currentLat, _currentLon, lat, lon);
            }
        }
        // Simple insertion sort (small list, low memory)
        for (var i = 1; i < _items.size(); i++) {
            var key = _items[i] as Dictionary;
            var keyDist = key["distance"] as Double;
            var j = i - 1;
            while (j >= 0) {
                var jItem = _items[j] as Dictionary;
                if ((jItem["distance"] as Double) > keyDist) {
                    _items[j + 1] = _items[j];
                    j--;
                } else {
                    break;
                }
            }
            _items[j + 1] = key;
        }
    }

    //! Fetch fresh data from station
    function refreshData() as Void {
        _pendingRequests = 2;
        _tempAlerts = null;
        _tempPlaces = null;

        var lat = _currentLat;
        var lon = _currentLon;
        var radius = DataStore.getRadiusKm();

        if (lat == 0.0d && lon == 0.0d) {
            // No GPS yet, try cached position
            var pos = DataStore.getLastPosition();
            if (pos != null) {
                lat = pos[0];
                lon = pos[1];
            }
        }

        _state = :loading;
        WatchUi.requestUpdate();

        _client.fetchAlerts(lat, lon, radius, method(:onAlertsResult));
        _client.fetchPlaces(lat, lon, radius, method(:onPlacesResult));
    }

    //! Callback when alerts are fetched
    function onAlertsResult(alerts as Array?) as Void {
        _tempAlerts = alerts;
        if (alerts != null) {
            DataStore.setAlerts(alerts);
        }
        _pendingRequests--;
        if (_pendingRequests <= 0) {
            onAllDataReceived();
        }
    }

    //! Callback when places are fetched
    function onPlacesResult(places as Array?) as Void {
        _tempPlaces = places;
        if (places != null) {
            DataStore.setPlaces(places);
        }
        _pendingRequests--;
        if (_pendingRequests <= 0) {
            onAllDataReceived();
        }
    }

    //! Process data after both requests complete
    function onAllDataReceived() as Void {
        _items = [];

        if (_tempAlerts == null && _tempPlaces == null) {
            _state = :error;
            _errorMsg = "No connection";
            WatchUi.requestUpdate();
            return;
        }

        if (_tempAlerts != null) {
            var alerts = _tempAlerts as Array;
            for (var i = 0; i < alerts.size(); i++) {
                var a = alerts[i];
                if (a instanceof Dictionary) {
                    _items.add(buildItem(a, :alert));
                }
            }
        }

        if (_tempPlaces != null) {
            var places = _tempPlaces as Array;
            for (var i = 0; i < places.size(); i++) {
                var p = places[i];
                if (p instanceof Dictionary) {
                    _items.add(buildItem(p, :place));
                }
            }
        }

        sortItemsByDistance();
        _selectedIndex = 0;
        _scrollOffset = 0;
        _state = :ready;
        WatchUi.requestUpdate();
    }

    //! Draw the view
    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();

        // Clear background
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (_state == :loading) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 - 10, Graphics.FONT_MEDIUM, "Loading...", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (_state == :error) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 - 10, Graphics.FONT_SMALL, _errorMsg, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (_items.size() == 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 - 10, Graphics.FONT_SMALL, "No items nearby", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Draw header
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 6, Graphics.FONT_SMALL, "Geogram (" + _items.size() + ")", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(10, HEADER_HEIGHT - 2, w - 10, HEADER_HEIGHT - 2);

        // Calculate visible rows
        var visibleRows = (h - HEADER_HEIGHT) / ROW_HEIGHT;

        // Adjust scroll offset to keep selected item visible
        if (_selectedIndex < _scrollOffset) {
            _scrollOffset = _selectedIndex;
        }
        if (_selectedIndex >= _scrollOffset + visibleRows) {
            _scrollOffset = _selectedIndex - visibleRows + 1;
        }

        // Draw list items
        for (var i = 0; i < visibleRows && (i + _scrollOffset) < _items.size(); i++) {
            var idx = i + _scrollOffset;
            var item = _items[idx] as Dictionary;
            var y = HEADER_HEIGHT + (i * ROW_HEIGHT);

            // Highlight selected row
            if (idx == _selectedIndex) {
                dc.setColor(Graphics.COLOR_DK_BLUE, Graphics.COLOR_DK_BLUE);
                dc.fillRectangle(0, y, w, ROW_HEIGHT);
            }

            // Severity/type color dot
            var dotColor = getSeverityColor(item);
            dc.setColor(dotColor, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(16, y + ROW_HEIGHT / 2, DOT_RADIUS);

            // Title (truncated to fit)
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var title = item["title"] as String;
            if (title.length() > 16) {
                title = title.substring(0, 15) + "..";
            }
            dc.drawText(28, y + 2, Graphics.FONT_TINY, title, Graphics.TEXT_JUSTIFY_LEFT);

            // Distance
            var dist = item["distance"] as Double;
            var distStr = GeoUtils.formatDistance(dist);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w - 8, y + 2, Graphics.FONT_XTINY, distStr, Graphics.TEXT_JUSTIFY_RIGHT);
        }

        // Scroll indicator
        if (_items.size() > visibleRows) {
            var barH = h - HEADER_HEIGHT;
            var thumbH = (barH * visibleRows) / _items.size();
            if (thumbH < 10) { thumbH = 10; }
            var thumbY = HEADER_HEIGHT + (barH * _scrollOffset) / _items.size();
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(w - 3, thumbY, 3, thumbH);
        }
    }

    //! Get color for severity level or place type
    function getSeverityColor(item as Dictionary) as Number {
        if (item["type"] == :place) {
            return Graphics.COLOR_GREEN;
        }
        var severity = item["severity"] as String;
        if (severity.equals("emergency")) {
            return Graphics.COLOR_RED;
        } else if (severity.equals("urgent")) {
            return Graphics.COLOR_ORANGE;
        } else if (severity.equals("attention")) {
            return Graphics.COLOR_YELLOW;
        }
        return Graphics.COLOR_BLUE;
    }

    //! Get the currently selected item
    function getSelectedItem() as Dictionary? {
        if (_selectedIndex >= 0 && _selectedIndex < _items.size()) {
            return _items[_selectedIndex] as Dictionary;
        }
        return null;
    }

    //! Move selection up
    function selectPrevious() as Void {
        if (_selectedIndex > 0) {
            _selectedIndex--;
            WatchUi.requestUpdate();
        }
    }

    //! Move selection down
    function selectNext() as Void {
        if (_selectedIndex < _items.size() - 1) {
            _selectedIndex++;
            WatchUi.requestUpdate();
        }
    }

    function getItemCount() as Number {
        return _items.size();
    }

    function getCurrentLat() as Double {
        return _currentLat;
    }

    function getCurrentLon() as Double {
        return _currentLon;
    }
}

//! Input delegate for the alerts list
class AlertsDelegate extends WatchUi.BehaviorDelegate {

    private var _view as AlertsView;

    function initialize(view as AlertsView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        var item = _view.getSelectedItem();
        if (item != null) {
            var detailView = new AlertDetailView(item, _view.getCurrentLat(), _view.getCurrentLon());
            WatchUi.pushView(detailView, new AlertDetailDelegate(detailView), WatchUi.SLIDE_LEFT);
        } else {
            // No items — trigger refresh
            _view.refreshData();
        }
        return true;
    }

    function onNextPage() as Boolean {
        _view.selectNext();
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.selectPrevious();
        return true;
    }

    function onMenu() as Boolean {
        WatchUi.pushView(
            new WatchUi.Menu2({:title => "Settings"}),
            new SettingsDelegate(),
            WatchUi.SLIDE_UP
        );
        return true;
    }

    function onBack() as Boolean {
        return false; // Let system handle (exit app)
    }
}

//! Settings menu delegate
class SettingsDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        // For now, settings are edited via Garmin Connect Mobile
        // This shows current values
        var id = item.getId();
        if (id.equals("radius")) {
            var current = DataStore.getRadiusKm();
            // Cycle through common values: 10, 25, 50, 100, 200
            var values = [10, 25, 50, 100, 200] as Array<Number>;
            var next = values[0];
            for (var i = 0; i < values.size() - 1; i++) {
                if (values[i] == current) {
                    next = values[i + 1];
                    break;
                }
            }
            DataStore.setRadiusKm(next);
            item.setSubLabel(next.toString() + " km");
        } else if (id.equals("alertRadius")) {
            var current = DataStore.getAlertRadiusKm();
            var values = [5, 10, 20, 50] as Array<Number>;
            var next = values[0];
            for (var i = 0; i < values.size() - 1; i++) {
                if (values[i] == current) {
                    next = values[i + 1];
                    break;
                }
            }
            DataStore.setAlertRadiusKm(next);
            item.setSubLabel(next.toString() + " km");
        }
    }
}
