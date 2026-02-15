/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat views — read-only chat rooms list and messages display.
 * ChatRoomsView extends BaseListView. ChatMessagesView is a scrollable view.
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! List of chat rooms from the station
class ChatRoomsView extends BaseListView {

    private var _rooms as Array = [];
    private var _client as StationClient;

    function initialize() {
        BaseListView.initialize();
        _client = new StationClient();
    }

    function getHeaderTitle() as String {
        return "Chat";
    }

    function getItems() as Array {
        return _rooms;
    }

    function onLayout(dc as Dc) as Void {
        loadCachedData();
        if (!MockData.DEBUG_MOCK) {
            refreshData();
        }
    }

    function loadCachedData() as Void {
        var rooms = DataStore.getChatRooms();
        _rooms = [];
        if (rooms != null) {
            _rooms = rooms;
        }
        if (_rooms.size() > 0) {
            _state = :ready;
        }
    }

    function refreshData() as Void {
        _state = :loading;
        WatchUi.requestUpdate();
        _client.fetchChatRooms(method(:onRoomsResult));
    }

    function onRoomsResult(rooms as Array?) as Void {
        if (rooms == null) {
            if (_rooms.size() == 0) {
                _state = :error;
                _errorMsg = "No connection";
            }
            WatchUi.requestUpdate();
            return;
        }
        DataStore.setChatRooms(rooms);
        _rooms = rooms;
        _selectedIndex = 0;
        _scrollOffset = 0;
        _state = :ready;
        WatchUi.requestUpdate();
    }

    function drawRow(dc as Dc, item, y as Number, w as Number, isSelected as Boolean) as Void {
        var dict = item as Dictionary;

        // Blue dot for chat
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(16, y + ROW_HEIGHT / 2, DOT_RADIUS);

        // Room name
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var name = "";
        if (dict["name"] instanceof String) {
            name = dict["name"] as String;
        }
        if (name.length() > 18) {
            name = name.substring(0, 17) + "..";
        }
        dc.drawText(28, y + 2, Graphics.FONT_TINY, name, Graphics.TEXT_JUSTIFY_LEFT);

        // Message count
        if (dict["messageCount"] instanceof Number) {
            var count = dict["messageCount"] as Number;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w - 8, y + 2, Graphics.FONT_XTINY, count.toString(), Graphics.TEXT_JUSTIFY_RIGHT);
        }
    }

    function onItemSelect(index as Number) as Void {
        if (index >= 0 && index < _rooms.size()) {
            var room = _rooms[index] as Dictionary;
            var roomId = "";
            if (room["id"] instanceof String) {
                roomId = room["id"] as String;
            } else if (room["id"] instanceof Number) {
                roomId = (room["id"] as Number).toString();
            }
            var roomName = "";
            if (room["name"] instanceof String) {
                roomName = room["name"] as String;
            }
            var messagesView = new ChatMessagesView(roomId, roomName);
            WatchUi.pushView(messagesView, new ChatMessagesDelegate(messagesView), WatchUi.SLIDE_LEFT);
        }
    }
}

//! Read-only chat messages display for a single room
class ChatMessagesView extends WatchUi.View {

    private var _roomId as String;
    private var _roomName as String;
    private var _messages as Array = [];
    private var _state as Symbol = :loading;
    private var _errorMsg as String = "";
    private var _scrollY as Number = 0;
    private var _client as StationClient;

    private const MSG_LIMIT = 20;

    function initialize(roomId as String, roomName as String) {
        View.initialize();
        _roomId = roomId;
        _roomName = roomName;
        _client = new StationClient();
    }

    function onLayout(dc as Dc) as Void {
        if (MockData.DEBUG_MOCK) {
            _messages = MockData.getChatMessages(_roomId);
            _state = :ready;
        } else {
            _client.fetchChatMessages(_roomId, MSG_LIMIT, method(:onMessagesResult));
        }
    }

    function onMessagesResult(messages as Array?) as Void {
        if (messages == null) {
            _state = :error;
            _errorMsg = "No connection";
            WatchUi.requestUpdate();
            return;
        }
        _messages = messages;
        _state = :ready;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (_state == :loading) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 - 10, Graphics.FONT_MEDIUM, "Loading...", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (_state == :error) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 - 10, Graphics.FONT_SMALL, _errorMsg, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (_messages.size() == 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 - 10, Graphics.FONT_SMALL, "No messages", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Header
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var headerText = _roomName;
        if (headerText.length() > 20) {
            headerText = headerText.substring(0, 19) + "..";
        }
        dc.drawText(w / 2, 6, Graphics.FONT_SMALL, headerText, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(10, 38, w - 10, 38);

        // Messages
        var y = 42 - _scrollY;
        var lineHeight = dc.getFontHeight(Graphics.FONT_XTINY) + 2;

        for (var i = 0; i < _messages.size(); i++) {
            var msg = _messages[i];
            if (!(msg instanceof Dictionary)) {
                continue;
            }
            var dict = msg as Dictionary;

            var author = "";
            if (dict["author"] instanceof String) {
                author = dict["author"] as String;
            }
            var content = "";
            if (dict["content"] instanceof String) {
                content = dict["content"] as String;
            }

            // Author in blue
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(8, y, Graphics.FONT_XTINY, author + ":", Graphics.TEXT_JUSTIFY_LEFT);
            y += lineHeight;

            // Content wrapped
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            y = DrawUtils.drawWrappedText(dc, 12, y, Graphics.FONT_XTINY, content, w - 24);
            y += 4;

            // Separator
            dc.setColor(0x333333, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(12, y, w - 12, y);
            y += 4;
        }
    }

    function scrollUp() as Void {
        if (_scrollY > 0) {
            _scrollY -= 30;
            if (_scrollY < 0) {
                _scrollY = 0;
            }
            WatchUi.requestUpdate();
        }
    }

    function scrollDown() as Void {
        _scrollY += 30;
        WatchUi.requestUpdate();
    }
}

//! Input delegate for chat messages view
class ChatMessagesDelegate extends WatchUi.BehaviorDelegate {

    private var _view as ChatMessagesView;

    function initialize(view as ChatMessagesView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onNextPage() as Boolean {
        _view.scrollDown();
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.scrollUp();
        return true;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
