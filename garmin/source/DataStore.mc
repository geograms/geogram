/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Persistent data storage wrapper using Application.Storage.
 * Stores settings, cached alerts/places, and last GPS position.
 */

import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Lang;

module DataStore {

    const KEY_STATION_URL = "stationUrl";
    const KEY_RADIUS_KM = "radiusKm";
    const KEY_ALERT_RADIUS_KM = "alertRadiusKm";
    const KEY_ALERTS = "alerts";
    const KEY_PLACES = "places";
    const KEY_LAST_LAT = "lastLat";
    const KEY_LAST_LON = "lastLon";
    const KEY_NOTIFIED_IDS = "notifiedIds";
    const KEY_CHAT_ROOMS = "chatRooms";
    const KEY_STATION_URLS = "stationUrls";
    const KEY_ALERT_COUNT = "alertCount";
    const KEY_PLACE_COUNT = "placeCount";
    const KEY_CHAT_ROOM_COUNT = "chatRoomCount";

    const DEFAULT_STATION_URL = "https://p2p.radio";
    const DEFAULT_RADIUS_KM = 50;
    const DEFAULT_ALERT_RADIUS_KM = 10;

    // -- Settings --

    function getStationUrl() as String {
        var url = Storage.getValue(KEY_STATION_URL);
        if (url instanceof String) {
            return url;
        }
        return DEFAULT_STATION_URL;
    }

    function setStationUrl(url as String) as Void {
        Storage.setValue(KEY_STATION_URL, url);
    }

    function getRadiusKm() as Number {
        var r = Storage.getValue(KEY_RADIUS_KM);
        if (r instanceof Number) {
            return r;
        }
        return DEFAULT_RADIUS_KM;
    }

    function setRadiusKm(radius as Number) as Void {
        Storage.setValue(KEY_RADIUS_KM, radius);
    }

    function getAlertRadiusKm() as Number {
        var r = Storage.getValue(KEY_ALERT_RADIUS_KM);
        if (r instanceof Number) {
            return r;
        }
        return DEFAULT_ALERT_RADIUS_KM;
    }

    function setAlertRadiusKm(radius as Number) as Void {
        Storage.setValue(KEY_ALERT_RADIUS_KM, radius);
    }

    // -- Cached Data --

    function getAlerts() as Array? {
        var data = Storage.getValue(KEY_ALERTS);
        if (data instanceof Array) {
            return data;
        }
        return null;
    }

    function setAlerts(alerts as Array) as Void {
        Storage.setValue(KEY_ALERTS, alerts);
        Storage.setValue(KEY_ALERT_COUNT, alerts.size());
    }

    function getPlaces() as Array? {
        var data = Storage.getValue(KEY_PLACES);
        if (data instanceof Array) {
            return data;
        }
        return null;
    }

    function setPlaces(places as Array) as Void {
        Storage.setValue(KEY_PLACES, places);
        Storage.setValue(KEY_PLACE_COUNT, places.size());
    }

    // -- GPS Position --

    function getLastPosition() as Array<Double>? {
        var lat = Storage.getValue(KEY_LAST_LAT);
        var lon = Storage.getValue(KEY_LAST_LON);
        if (lat instanceof Double && lon instanceof Double) {
            return [lat, lon] as Array<Double>;
        }
        if (lat instanceof Float && lon instanceof Float) {
            return [lat.toDouble(), lon.toDouble()] as Array<Double>;
        }
        return null;
    }

    function setLastPosition(lat as Double, lon as Double) as Void {
        Storage.setValue(KEY_LAST_LAT, lat);
        Storage.setValue(KEY_LAST_LON, lon);
    }

    // -- Notified Alert IDs (avoid repeat proximity alerts) --

    function getNotifiedIds() as Array<String> {
        var data = Storage.getValue(KEY_NOTIFIED_IDS);
        if (data instanceof Array) {
            return data as Array<String>;
        }
        return [] as Array<String>;
    }

    function addNotifiedId(id as String) as Void {
        var ids = getNotifiedIds();
        ids.add(id);
        // Keep only last 100 to avoid unbounded growth
        if (ids.size() > 100) {
            ids = ids.slice(ids.size() - 100, null) as Array<String>;
        }
        Storage.setValue(KEY_NOTIFIED_IDS, ids);
    }

    function clearNotifiedIds() as Void {
        Storage.deleteValue(KEY_NOTIFIED_IDS);
    }

    // -- Chat Rooms --

    function getChatRooms() as Array? {
        var data = Storage.getValue(KEY_CHAT_ROOMS);
        if (data instanceof Array) {
            return data;
        }
        return null;
    }

    function setChatRooms(rooms as Array) as Void {
        Storage.setValue(KEY_CHAT_ROOMS, rooms);
        Storage.setValue(KEY_CHAT_ROOM_COUNT, rooms.size());
    }

    // -- Station URLs (cycle list) --

    function getStationUrls() as Array<String> {
        var data = Storage.getValue(KEY_STATION_URLS);
        if (data instanceof Array && data.size() > 0) {
            return data as Array<String>;
        }
        return [DEFAULT_STATION_URL] as Array<String>;
    }

    function setStationUrls(urls as Array<String>) as Void {
        Storage.setValue(KEY_STATION_URLS, urls);
    }

    // -- Cached counts --

    function getAlertCount() as Number {
        var c = Storage.getValue(KEY_ALERT_COUNT);
        if (c instanceof Number) {
            return c;
        }
        return 0;
    }

    function setAlertCount(count as Number) as Void {
        Storage.setValue(KEY_ALERT_COUNT, count);
    }

    function getPlaceCount() as Number {
        var c = Storage.getValue(KEY_PLACE_COUNT);
        if (c instanceof Number) {
            return c;
        }
        return 0;
    }

    function setPlaceCount(count as Number) as Void {
        Storage.setValue(KEY_PLACE_COUNT, count);
    }

    function getChatRoomCount() as Number {
        var c = Storage.getValue(KEY_CHAT_ROOM_COUNT);
        if (c instanceof Number) {
            return c;
        }
        return 0;
    }
}
