/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared base list view and drawing utilities.
 * Subclasses implement drawRow(), getItems(), onItemSelect().
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Shared drawing utilities used by multiple views
module DrawUtils {

    //! Draw text with word wrapping, return Y position after last line
    function drawWrappedText(dc as Dc, x as Number, y as Number, font as Graphics.FontDefinition, text as String, maxWidth as Number) as Number {
        var charWidth = dc.getTextWidthInPixels("M", font);
        var charsPerLine = maxWidth / charWidth;
        if (charsPerLine < 5) {
            charsPerLine = 5;
        }
        var lineHeight = dc.getFontHeight(font) + 2;

        var pos = 0;
        while (pos < text.length()) {
            var end = pos + charsPerLine;
            if (end >= text.length()) {
                end = text.length();
            } else {
                // Try to break at a space
                var spacePos = end;
                while (spacePos > pos) {
                    var ch = text.substring(spacePos - 1, spacePos);
                    if (ch.equals(" ")) {
                        break;
                    }
                    spacePos--;
                }
                if (spacePos > pos) {
                    end = spacePos;
                }
            }
            var line = text.substring(pos, end);
            dc.drawText(x, y, font, line, Graphics.TEXT_JUSTIFY_LEFT);
            y += lineHeight;
            pos = end;
            // Skip leading space on next line
            if (pos < text.length()) {
                var nextCh = text.substring(pos, pos + 1);
                if (nextCh.equals(" ")) {
                    pos++;
                }
            }
        }
        return y;
    }

    //! Get color for severity level
    function getSeverityColor(severity as String) as Number {
        if (severity.equals("emergency")) {
            return Graphics.COLOR_RED;
        } else if (severity.equals("urgent")) {
            return Graphics.COLOR_ORANGE;
        } else if (severity.equals("attention")) {
            return Graphics.COLOR_YELLOW;
        }
        return Graphics.COLOR_BLUE;
    }
}

//! Abstract base list view with header, scrollable rows, and state management.
//! Subclasses must override: getHeaderTitle(), getItems(), drawRow(), onItemSelect().
class BaseListView extends WatchUi.View {

    protected var _selectedIndex as Number = 0;
    protected var _scrollOffset as Number = 0;
    protected var _state as Symbol = :loading;
    protected var _errorMsg as String = "";

    // Layout constants
    const ROW_HEIGHT = 36;
    const HEADER_HEIGHT = 40;
    const DOT_RADIUS = 6;

    function initialize() {
        View.initialize();
    }

    //! Override: return the header title string (e.g. "Alerts")
    function getHeaderTitle() as String {
        return "";
    }

    //! Override: return the array of items to display
    function getItems() as Array {
        return [];
    }

    //! Override: draw a single row
    function drawRow(dc as Dc, item, y as Number, w as Number, isSelected as Boolean) as Void {
    }

    //! Override: handle item selection
    function onItemSelect(index as Number) as Void {
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var items = getItems();

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

        if (items.size() == 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 - 10, Graphics.FONT_SMALL, "No items", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Draw header
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 6, Graphics.FONT_SMALL, getHeaderTitle() + " (" + items.size() + ")", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(10, HEADER_HEIGHT - 2, w - 10, HEADER_HEIGHT - 2);

        // Calculate visible rows
        var visibleRows = (h - HEADER_HEIGHT) / ROW_HEIGHT;

        // Adjust scroll offset to keep selected item visible
        if (_selectedIndex < _scrollOffset) {
            _scrollOffset = _selectedIndex;
        }
        if (_selectedIndex >= _scrollOffset + visibleRows) {
            _scrollOffset = _selectedIndex - visibleRows + 1;
        }

        // Draw list items
        for (var i = 0; i < visibleRows && (i + _scrollOffset) < items.size(); i++) {
            var idx = i + _scrollOffset;
            var item = items[idx];
            var y = HEADER_HEIGHT + (i * ROW_HEIGHT);
            var isSelected = (idx == _selectedIndex);

            if (isSelected) {
                dc.setColor(Graphics.COLOR_DK_BLUE, Graphics.COLOR_DK_BLUE);
                dc.fillRectangle(0, y, w, ROW_HEIGHT);
            }

            drawRow(dc, item, y, w, isSelected);
        }

        // Scroll indicator
        if (items.size() > visibleRows) {
            var barH = h - HEADER_HEIGHT;
            var thumbH = (barH * visibleRows) / items.size();
            if (thumbH < 10) { thumbH = 10; }
            var thumbY = HEADER_HEIGHT + (barH * _scrollOffset) / items.size();
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(w - 3, thumbY, 3, thumbH);
        }
    }

    function selectPrevious() as Void {
        if (_selectedIndex > 0) {
            _selectedIndex--;
            WatchUi.requestUpdate();
        }
    }

    function selectNext() as Void {
        var items = getItems();
        if (_selectedIndex < items.size() - 1) {
            _selectedIndex++;
            WatchUi.requestUpdate();
        }
    }

    function getSelectedIndex() as Number {
        return _selectedIndex;
    }
}

//! Shared input delegate for BaseListView subclasses
class BaseListDelegate extends WatchUi.BehaviorDelegate {

    private var _view as BaseListView;

    function initialize(view as BaseListView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        var items = _view.getItems();
        if (items.size() > 0) {
            _view.onItemSelect(_view.getSelectedIndex());
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
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
