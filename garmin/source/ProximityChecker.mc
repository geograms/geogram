/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Background service delegate that checks proximity to alerts.
 * Runs every 5 minutes. If user is within alertRadiusKm of an alert,
 * fires a notification (vibration + tone).
 */

import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Background;
import Toybox.Lang;
import Toybox.Position;
import Toybox.System;

(:background)
class ProximityChecker extends System.ServiceDelegate {

    function initialize() {
        ServiceDelegate.initialize();
    }

    //! Called by the system when our temporal event fires
    function onTemporalEvent() as Void {
        // Get last known position
        var latVal = Storage.getValue("lastLat");
        var lonVal = Storage.getValue("lastLon");

        if (latVal == null || lonVal == null) {
            Background.exit(null);
            return;
        }

        var lat = 0.0d;
        var lon = 0.0d;
        if (latVal instanceof Double) {
            lat = latVal;
        } else if (latVal instanceof Float) {
            lat = latVal.toDouble();
        }
        if (lonVal instanceof Double) {
            lon = lonVal;
        } else if (lonVal instanceof Float) {
            lon = lonVal.toDouble();
        }

        if (lat == 0.0d && lon == 0.0d) {
            Background.exit(null);
            return;
        }

        // Get alert radius threshold
        var alertRadiusVal = Storage.getValue("alertRadiusKm");
        var alertRadius = 10;
        if (alertRadiusVal instanceof Number) {
            alertRadius = alertRadiusVal;
        }

        // Get cached alerts
        var alertsVal = Storage.getValue("alerts");
        if (!(alertsVal instanceof Array)) {
            Background.exit(null);
            return;
        }
        var alerts = alertsVal as Array;

        // Get already-notified IDs
        var notifiedVal = Storage.getValue("notifiedIds");
        var notifiedIds = [] as Array;
        if (notifiedVal instanceof Array) {
            notifiedIds = notifiedVal;
        }

        // Check each alert for proximity
        var foundNearby = false;
        for (var i = 0; i < alerts.size(); i++) {
            var alert = alerts[i];
            if (!(alert instanceof Dictionary)) {
                continue;
            }
            var aDict = alert as Dictionary;

            // Get alert ID for dedup
            var alertId = "";
            if (aDict["id"] instanceof String) {
                alertId = aDict["id"] as String;
            } else if (aDict["title"] instanceof String) {
                alertId = aDict["title"] as String;
            }

            // Skip if already notified
            var alreadyNotified = false;
            for (var j = 0; j < notifiedIds.size(); j++) {
                if (notifiedIds[j].equals(alertId)) {
                    alreadyNotified = true;
                    break;
                }
            }
            if (alreadyNotified) {
                continue;
            }

            // Get alert coordinates
            var aLat = 0.0d;
            var aLon = 0.0d;
            if (aDict["latitude"] instanceof Double) {
                aLat = aDict["latitude"] as Double;
            } else if (aDict["latitude"] instanceof Float) {
                aLat = (aDict["latitude"] as Float).toDouble();
            } else if (aDict["latitude"] instanceof Number) {
                aLat = (aDict["latitude"] as Number).toDouble();
            }
            if (aDict["longitude"] instanceof Double) {
                aLon = aDict["longitude"] as Double;
            } else if (aDict["longitude"] instanceof Float) {
                aLon = (aDict["longitude"] as Float).toDouble();
            } else if (aDict["longitude"] instanceof Number) {
                aLon = (aDict["longitude"] as Number).toDouble();
            }

            if (aLat == 0.0d && aLon == 0.0d) {
                continue;
            }

            // Calculate distance using inline haversine (GeoUtils module not available in background)
            var dist = haversineKm(lat, lon, aLat, aLon);

            if (dist <= alertRadius) {
                foundNearby = true;
                // Record as notified
                notifiedIds.add(alertId);
                // Keep only last 100
                if (notifiedIds.size() > 100) {
                    notifiedIds = notifiedIds.slice(notifiedIds.size() - 100, null);
                }
                Storage.setValue("notifiedIds", notifiedIds);

                // Wake the app with a notification
                if (Application has :loadResource) {
                    Background.requestApplicationWake(Application.loadResource($.Rez.Strings.ProximityAlert) as String);
                } else {
                    Background.requestApplicationWake("Alert nearby!");
                }
                break;
            }
        }

        Background.exit(foundNearby);
    }

    //! Inline haversine calculation for background context
    //! (Cannot use GeoUtils module in background due to memory constraints)
    function haversineKm(lat1 as Double, lon1 as Double, lat2 as Double, lon2 as Double) as Double {
        var R = 6371.0d;
        var dLat = toRad(lat2 - lat1);
        var dLon = toRad(lon2 - lon1);
        var rLat1 = toRad(lat1);
        var rLat2 = toRad(lat2);

        var a = Math.sin(dLat / 2.0d) * Math.sin(dLat / 2.0d) +
                Math.cos(rLat1) * Math.cos(rLat2) *
                Math.sin(dLon / 2.0d) * Math.sin(dLon / 2.0d);
        var c = 2.0d * Math.atan2(Math.sqrt(a), Math.sqrt(1.0d - a));
        return R * c;
    }

    function toRad(deg as Double) as Double {
        return deg * 3.14159265358979d / 180.0d;
    }
}
