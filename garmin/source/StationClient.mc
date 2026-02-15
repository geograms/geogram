/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * HTTP client for the geogram station API.
 * Fetches alerts and places via WiFi using makeWebRequest().
 */

import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

class StationClient {

    private var _alertsCallback as Method?;
    private var _placesCallback as Method?;

    function initialize() {
    }

    //! Fetch alerts from the station API
    //! @param lat Current latitude
    //! @param lon Current longitude
    //! @param radiusKm Search radius in km
    //! @param callback Method to call with (alerts as Array?) — null on error
    function fetchAlerts(lat as Double, lon as Double, radiusKm as Number, callback as Method) as Void {
        _alertsCallback = callback;
        var url = DataStore.getStationUrl() + "/api/alerts";
        var params = {
            "lat" => lat,
            "lon" => lon,
            "radius" => radiusKm,
            "status" => "open"
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :headers => {
                "Accept" => "application/json"
            }
        };
        Communications.makeWebRequest(url, params, options, method(:onAlertsResponse));
    }

    //! Handle alerts API response
    function onAlertsResponse(responseCode as Number, data as Dictionary or Null) as Void {
        var cb = _alertsCallback;
        _alertsCallback = null;
        if (cb == null) {
            return;
        }
        if (responseCode == 200 && data != null && data["alerts"] instanceof Array) {
            cb.invoke(data["alerts"] as Array);
        } else {
            System.println("Alerts fetch failed: " + responseCode);
            cb.invoke(null);
        }
    }

    //! Fetch places from the station API
    //! @param lat Current latitude
    //! @param lon Current longitude
    //! @param radiusKm Search radius in km
    //! @param callback Method to call with (places as Array?) — null on error
    function fetchPlaces(lat as Double, lon as Double, radiusKm as Number, callback as Method) as Void {
        _placesCallback = callback;
        var url = DataStore.getStationUrl() + "/api/places";
        var params = {
            "lat" => lat,
            "lon" => lon,
            "radius" => radiusKm
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :headers => {
                "Accept" => "application/json"
            }
        };
        Communications.makeWebRequest(url, params, options, method(:onPlacesResponse));
    }

    //! Handle places API response
    function onPlacesResponse(responseCode as Number, data as Dictionary or Null) as Void {
        var cb = _placesCallback;
        _placesCallback = null;
        if (cb == null) {
            return;
        }
        if (responseCode == 200 && data != null && data["places"] instanceof Array) {
            cb.invoke(data["places"] as Array);
        } else {
            System.println("Places fetch failed: " + responseCode);
            cb.invoke(null);
        }
    }
}
