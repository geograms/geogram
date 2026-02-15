/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Geogram Garmin Watch App — main entry point.
 * Connects to a geogram station to download nearby alerts, places, and chat.
 */

import Toybox.Application;
import Toybox.Background;
import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.WatchUi;

(:background)
class GeogramApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        // Centralized GPS — all views read from DataStore
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
    }

    //! GPS position callback — stores in DataStore, triggers UI refresh
    function onPosition(info as Position.Info) as Void {
        if (info.position != null) {
            var coords = info.position.toDegrees();
            var lat = coords[0].toDouble();
            var lon = coords[1].toDouble();
            DataStore.setLastPosition(lat, lon);
            WatchUi.requestUpdate();
        }
    }

    function onStop(state as Dictionary?) as Void {
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        registerBackgroundEvent();
    }

    //! Return the initial view — main menu
    function getInitialView() as [Views] or [Views, InputDelegates] {
        var menu = new MainMenuView();
        return [menu, new MainMenuDelegate(menu)];
    }

    //! Return background service delegate for proximity checks
    function getServiceDelegate() as [ServiceDelegate] {
        return [new ProximityChecker()];
    }

    //! Handle data from background service
    function onBackgroundData(data as PersistableType) as Void {
        // Background proximity checker found a nearby alert — refresh UI
        WatchUi.requestUpdate();
    }

    //! Register a temporal background event (every 5 minutes)
    function registerBackgroundEvent() as Void {
        var lastTime = Background.getTemporalEventRegisteredTime();
        if (lastTime == null) {
            Background.registerForTemporalEvent(new Time.Duration(300));
        }
    }
}
