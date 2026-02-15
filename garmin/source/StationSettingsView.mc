/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Station settings view — cycle URL, search radius, alert radius.
 * Custom-drawn with 3 selectable fields.
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class StationSettingsView extends WatchUi.View {

    private var _selectedField as Number = 0;
    private const FIELD_COUNT = 3;
    private const FIELD_URL = 0;
    private const FIELD_RADIUS = 1;
    private const FIELD_ALERT_RADIUS = 2;

    function initialize() {
        View.initialize();
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // Header
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 8, Graphics.FONT_SMALL, "Station", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(10, 36, w - 10, 36);

        var rowH = 44;
        var startY = 44;

        // URL field
        drawField(dc, startY, w, rowH, "URL", getDisplayUrl(), _selectedField == FIELD_URL);

        // Search radius
        var radiusStr = DataStore.getRadiusKm().toString() + " km";
        drawField(dc, startY + rowH, w, rowH, "Search Radius", radiusStr, _selectedField == FIELD_RADIUS);

        // Alert radius
        var alertRadiusStr = DataStore.getAlertRadiusKm().toString() + " km";
        drawField(dc, startY + rowH * 2, w, rowH, "Alert Radius", alertRadiusStr, _selectedField == FIELD_ALERT_RADIUS);

        // Hint at bottom
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h - 28, Graphics.FONT_XTINY, "SELECT to cycle", Graphics.TEXT_JUSTIFY_CENTER);
    }

    function drawField(dc as Dc, y as Number, w as Number, h as Number, label as String, value as String, selected as Boolean) as Void {
        if (selected) {
            dc.setColor(Graphics.COLOR_DK_BLUE, Graphics.COLOR_DK_BLUE);
            dc.fillRectangle(0, y, w, h);
        }

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(14, y + 2, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_LEFT);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var displayVal = value;
        if (displayVal.length() > 22) {
            displayVal = displayVal.substring(0, 21) + "..";
        }
        dc.drawText(14, y + 20, Graphics.FONT_TINY, displayVal, Graphics.TEXT_JUSTIFY_LEFT);
    }

    function getDisplayUrl() as String {
        var url = DataStore.getStationUrl();
        // Strip protocol for display
        if (url.length() > 8 && url.substring(0, 8).equals("https://")) {
            return url.substring(8, url.length());
        }
        if (url.length() > 7 && url.substring(0, 7).equals("http://")) {
            return url.substring(7, url.length());
        }
        return url;
    }

    function selectPrevious() as Void {
        if (_selectedField > 0) {
            _selectedField--;
            WatchUi.requestUpdate();
        }
    }

    function selectNext() as Void {
        if (_selectedField < FIELD_COUNT - 1) {
            _selectedField++;
            WatchUi.requestUpdate();
        }
    }

    function cycleSelectedField() as Void {
        if (_selectedField == FIELD_URL) {
            cycleUrl();
        } else if (_selectedField == FIELD_RADIUS) {
            cycleRadius();
        } else if (_selectedField == FIELD_ALERT_RADIUS) {
            cycleAlertRadius();
        }
        WatchUi.requestUpdate();
    }

    function cycleUrl() as Void {
        var urls = DataStore.getStationUrls();
        var current = DataStore.getStationUrl();
        var nextIdx = 0;
        for (var i = 0; i < urls.size(); i++) {
            if (urls[i].equals(current) && i < urls.size() - 1) {
                nextIdx = i + 1;
                break;
            }
        }
        DataStore.setStationUrl(urls[nextIdx]);
    }

    function cycleRadius() as Void {
        var current = DataStore.getRadiusKm();
        var values = [10, 25, 50, 100, 200] as Array<Number>;
        var next = values[0];
        for (var i = 0; i < values.size() - 1; i++) {
            if (values[i] == current) {
                next = values[i + 1];
                break;
            }
        }
        DataStore.setRadiusKm(next);
    }

    function cycleAlertRadius() as Void {
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
    }
}

//! Input delegate for station settings
class StationSettingsDelegate extends WatchUi.BehaviorDelegate {

    private var _view as StationSettingsView;

    function initialize(view as StationSettingsView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.cycleSelectedField();
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

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
