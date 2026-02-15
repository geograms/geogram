/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Geogram Garmin Watch App — main entry point.
 * Connects to a geogram station to download nearby alerts and places.
 */

import Toybox.Application;
import Toybox.Background;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

(:background)
class GeogramApp extends Application.AppBase {

    private var _alertsView as AlertsView?;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
        // Schedule background proximity check when app closes
        registerBackgroundEvent();
    }

    //! Return the initial view
    function getInitialView() as [Views] or [Views, InputDelegates] {
        _alertsView = new AlertsView();
        return [_alertsView, new AlertsDelegate(_alertsView)];
    }

    //! Return background service delegate for proximity checks
    function getServiceDelegate() as [ServiceDelegate] {
        return [new ProximityChecker()];
    }

    //! Handle data from background service
    function onBackgroundData(data as PersistableType) as Void {
        // Background proximity checker found a nearby alert
        if (_alertsView != null) {
            _alertsView.refreshData();
        }
    }

    //! Register a temporal background event (every 5 minutes)
    function registerBackgroundEvent() as Void {
        var lastTime = Background.getTemporalEventRegisteredTime();
        if (lastTime == null) {
            // Register for 5-minute intervals
            Background.registerForTemporalEvent(new Time.Duration(300));
        }
    }
}
