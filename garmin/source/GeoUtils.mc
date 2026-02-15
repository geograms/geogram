/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Geographic utility functions: haversine distance, bearing calculation.
 */

import Toybox.Lang;
import Toybox.Math;

module GeoUtils {

    const EARTH_RADIUS_KM = 6371.0d;

    //! Calculate distance between two coordinates using the haversine formula
    //! @param lat1 Latitude of point 1 in degrees
    //! @param lon1 Longitude of point 1 in degrees
    //! @param lat2 Latitude of point 2 in degrees
    //! @param lon2 Longitude of point 2 in degrees
    //! @return Distance in kilometers
    function calculateDistance(lat1 as Double, lon1 as Double, lat2 as Double, lon2 as Double) as Double {
        var dLat = Math.toRadians(lat2 - lat1);
        var dLon = Math.toRadians(lon2 - lon1);
        var rLat1 = Math.toRadians(lat1);
        var rLat2 = Math.toRadians(lat2);

        var a = Math.sin(dLat / 2.0d) * Math.sin(dLat / 2.0d) +
                Math.cos(rLat1) * Math.cos(rLat2) *
                Math.sin(dLon / 2.0d) * Math.sin(dLon / 2.0d);
        var c = 2.0d * Math.atan2(Math.sqrt(a), Math.sqrt(1.0d - a));
        return EARTH_RADIUS_KM * c;
    }

    //! Calculate bearing from point 1 to point 2
    //! @param lat1 Latitude of point 1 in degrees
    //! @param lon1 Longitude of point 1 in degrees
    //! @param lat2 Latitude of point 2 in degrees
    //! @param lon2 Longitude of point 2 in degrees
    //! @return Bearing in degrees (0-360)
    function calculateBearing(lat1 as Double, lon1 as Double, lat2 as Double, lon2 as Double) as Double {
        var rLat1 = Math.toRadians(lat1);
        var rLat2 = Math.toRadians(lat2);
        var dLon = Math.toRadians(lon2 - lon1);

        var y = Math.sin(dLon) * Math.cos(rLat2);
        var x = Math.cos(rLat1) * Math.sin(rLat2) -
                Math.sin(rLat1) * Math.cos(rLat2) * Math.cos(dLon);
        var bearing = Math.toDegrees(Math.atan2(y, x));
        var result = bearing + 360.0d;
        result = result - (Math.floor(result / 360.0d) * 360.0d);
        return result.toDouble();
    }

    //! Convert bearing in degrees to cardinal direction string
    //! @param bearing Bearing in degrees (0-360)
    //! @return Cardinal direction string (N, NE, E, SE, S, SW, W, NW)
    function bearingToCardinal(bearing as Double) as String {
        var dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"] as Array<String>;
        var adjusted = bearing + 22.5d;
        adjusted = adjusted - (Math.floor(adjusted / 360.0d) * 360.0d);
        var index = (adjusted / 45.0d).toNumber();
        if (index < 0 || index >= dirs.size()) {
            index = 0;
        }
        return dirs[index];
    }

    //! Format distance for display
    //! @param distKm Distance in kilometers
    //! @return Formatted string like "2.3 km" or "450 m"
    function formatDistance(distKm as Double) as String {
        if (distKm < 1.0d) {
            var meters = (distKm * 1000.0d).toNumber();
            return meters.toString() + " m";
        }
        // Show one decimal place
        var whole = distKm.toNumber();
        var frac = ((distKm - whole) * 10.0d).toNumber();
        return whole.toString() + "." + frac.toString() + " km";
    }
}
