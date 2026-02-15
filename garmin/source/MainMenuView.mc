/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Main menu view — 4-item menu: Alerts, Places, Chat, Station.
 * Shows GPS indicator, colored icons, cached counts, station URL.
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class MainMenuView extends WatchUi.View {

    private var _selectedIndex as Number = 0;
    private const MENU_ITEMS = 4;
    private const ROW_HEIGHT = 40;

    function initialize() {
        View.initialize();
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // GPS indicator at top
        var pos = DataStore.getLastPosition();
        var gpsColor = (pos != null) ? Graphics.COLOR_GREEN : Graphics.COLOR_RED;
        dc.setColor(gpsColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(w / 2, 14, 4);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2 + 10, 6, Graphics.FONT_XTINY, "GPS", Graphics.TEXT_JUSTIFY_LEFT);

        // Menu items start below GPS indicator
        var startY = 30;

        // Alerts
        drawMenuItem(dc, startY, w, "Alerts", Graphics.COLOR_RED,
            DataStore.getAlertCount(), _selectedIndex == 0);

        // Places
        drawMenuItem(dc, startY + ROW_HEIGHT, w, "Places", Graphics.COLOR_GREEN,
            DataStore.getPlaceCount(), _selectedIndex == 1);

        // Chat
        drawMenuItem(dc, startY + ROW_HEIGHT * 2, w, "Chat", Graphics.COLOR_BLUE,
            DataStore.getChatRoomCount(), _selectedIndex == 2);

        // Station
        drawMenuItem(dc, startY + ROW_HEIGHT * 3, w, "Station", Graphics.COLOR_DK_GRAY,
            -1, _selectedIndex == 3);

        // Station URL at bottom
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        var url = DataStore.getStationUrl();
        // Strip protocol for display
        if (url.length() > 8 && url.substring(0, 8).equals("https://")) {
            url = url.substring(8, url.length());
        } else if (url.length() > 7 && url.substring(0, 7).equals("http://")) {
            url = url.substring(7, url.length());
        }
        if (url.length() > 24) {
            url = url.substring(0, 23) + "..";
        }
        dc.drawText(w / 2, h - 24, Graphics.FONT_XTINY, url, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Draw a single menu item row
    function drawMenuItem(dc as Dc, y as Number, w as Number, label as String, iconColor as Number, count as Number, selected as Boolean) as Void {
        // Selection highlight
        if (selected) {
            dc.setColor(Graphics.COLOR_DK_BLUE, Graphics.COLOR_DK_BLUE);
            dc.fillRectangle(0, y, w, ROW_HEIGHT);
        }

        // Colored icon dot
        dc.setColor(iconColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(24, y + ROW_HEIGHT / 2, 7);

        // Label
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(40, y + 6, Graphics.FONT_SMALL, label, Graphics.TEXT_JUSTIFY_LEFT);

        // Count badge (skip for negative values like Station)
        if (count >= 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w - 16, y + 8, Graphics.FONT_TINY, "(" + count.toString() + ")", Graphics.TEXT_JUSTIFY_RIGHT);
        }
    }

    function selectPrevious() as Void {
        if (_selectedIndex > 0) {
            _selectedIndex--;
            WatchUi.requestUpdate();
        }
    }

    function selectNext() as Void {
        if (_selectedIndex < MENU_ITEMS - 1) {
            _selectedIndex++;
            WatchUi.requestUpdate();
        }
    }

    function getSelectedIndex() as Number {
        return _selectedIndex;
    }
}

//! Input delegate for the main menu
class MainMenuDelegate extends WatchUi.BehaviorDelegate {

    private var _view as MainMenuView;

    function initialize(view as MainMenuView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        var idx = _view.getSelectedIndex();
        if (idx == 0) {
            // Alerts
            var view = new AlertsListView();
            WatchUi.pushView(view, new BaseListDelegate(view), WatchUi.SLIDE_LEFT);
        } else if (idx == 1) {
            // Places
            var view = new PlacesListView();
            WatchUi.pushView(view, new BaseListDelegate(view), WatchUi.SLIDE_LEFT);
        } else if (idx == 2) {
            // Chat
            var view = new ChatRoomsView();
            WatchUi.pushView(view, new BaseListDelegate(view), WatchUi.SLIDE_LEFT);
        } else if (idx == 3) {
            // Station Settings
            var view = new StationSettingsView();
            WatchUi.pushView(view, new StationSettingsDelegate(view), WatchUi.SLIDE_LEFT);
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

    function onBack() as Boolean {
        return false; // Let system handle (exit app)
    }
}
