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
    private var _chatRoomsCallback as Method?;
    private var _chatMessagesCallback as Method?;

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

    //! Fetch chat rooms from the station API
    //! @param callback Method to call with (rooms as Array?) — null on error
    function fetchChatRooms(callback as Method) as Void {
        _chatRoomsCallback = callback;
        var url = DataStore.getStationUrl() + "/api/chat/rooms";
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :headers => {
                "Accept" => "application/json"
            }
        };
        Communications.makeWebRequest(url, {}, options, method(:onChatRoomsResponse));
    }

    //! Handle chat rooms API response
    function onChatRoomsResponse(responseCode as Number, data as Dictionary or Null) as Void {
        var cb = _chatRoomsCallback;
        _chatRoomsCallback = null;
        if (cb == null) {
            return;
        }
        if (responseCode == 200 && data != null && data["rooms"] instanceof Array) {
            cb.invoke(data["rooms"] as Array);
        } else {
            System.println("Chat rooms fetch failed: " + responseCode);
            cb.invoke(null);
        }
    }

    //! Fetch messages for a specific chat room
    //! @param roomId The room ID
    //! @param limit Maximum number of messages
    //! @param callback Method to call with (messages as Array?) — null on error
    function fetchChatMessages(roomId as String, limit as Number, callback as Method) as Void {
        _chatMessagesCallback = callback;
        var url = DataStore.getStationUrl() + "/api/chat/" + roomId + "/messages";
        var params = {
            "limit" => limit
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :headers => {
                "Accept" => "application/json"
            }
        };
        Communications.makeWebRequest(url, params, options, method(:onChatMessagesResponse));
    }

    //! Handle chat messages API response
    function onChatMessagesResponse(responseCode as Number, data as Dictionary or Null) as Void {
        var cb = _chatMessagesCallback;
        _chatMessagesCallback = null;
        if (cb == null) {
            return;
        }
        if (responseCode == 200 && data != null && data["messages"] instanceof Array) {
            cb.invoke(data["messages"] as Array);
        } else {
            System.println("Chat messages fetch failed: " + responseCode);
            cb.invoke(null);
        }
    }
}
