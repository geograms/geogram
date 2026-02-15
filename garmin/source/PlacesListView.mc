/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Places list view — shows nearby places sorted by distance.
 * Extends BaseListView for shared list rendering.
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class PlacesListView extends BaseListView {

    private var _items as Array = [];
    private var _client as StationClient;

    function initialize() {
        BaseListView.initialize();
        _client = new StationClient();
    }

    function getHeaderTitle() as String {
        return "Places";
    }

    function getItems() as Array {
        return _items;
    }

    function onLayout(dc as Dc) as Void {
        loadCachedData();
        refreshData();
    }

    function loadCachedData() as Void {
        var places = DataStore.getPlaces();
        _items = [];

        if (places != null) {
            for (var i = 0; i < places.size(); i++) {
                var p = places[i];
                if (p instanceof Dictionary) {
                    _items.add(buildPlaceItem(p));
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
        _client.fetchPlaces(lat, lon, radius, method(:onPlacesResult));
    }

    function onPlacesResult(places as Array?) as Void {
        _items = [];
        if (places == null) {
            if (_items.size() == 0) {
                _state = :error;
                _errorMsg = "No connection";
            }
            WatchUi.requestUpdate();
            return;
        }
        DataStore.setPlaces(places);
        for (var i = 0; i < places.size(); i++) {
            var p = places[i];
            if (p instanceof Dictionary) {
                _items.add(buildPlaceItem(p));
            }
        }
        sortByDistance();
        _selectedIndex = 0;
        _scrollOffset = 0;
        _state = :ready;
        WatchUi.requestUpdate();
    }

    function buildPlaceItem(data as Dictionary) as Dictionary {
        var name = (data["name"] != null) ? data["name"].toString() : "Place";
        var lat = parseDouble(data["latitude"]);
        var lon = parseDouble(data["longitude"]);
        var placeType = "";
        if (data["type"] instanceof String) {
            placeType = data["type"] as String;
        }
        return {
            "title" => name,
            "lat" => lat,
            "lon" => lon,
            "type" => placeType,
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

    function drawRow(dc as Dc, item, y as Number, w as Number, isSelected as Boolean) as Void {
        var dict = item as Dictionary;

        // Green dot for places
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(16, y + ROW_HEIGHT / 2, DOT_RADIUS);

        // Name
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var title = dict["title"] as String;
        if (title.length() > 16) {
            title = title.substring(0, 15) + "..";
        }
        dc.drawText(28, y + 2, Graphics.FONT_TINY, title, Graphics.TEXT_JUSTIFY_LEFT);

        // Distance
        var dist = dict["distance"] as Double;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w - 8, y + 2, Graphics.FONT_XTINY, GeoUtils.formatDistance(dist), Graphics.TEXT_JUSTIFY_RIGHT);
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
            var detailView = new PlaceDetailView(item, lat, lon);
            WatchUi.pushView(detailView, new PlaceDetailDelegate(detailView), WatchUi.SLIDE_LEFT);
        }
    }
}
