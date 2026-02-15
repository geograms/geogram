/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared base list view and drawing utilities.
 * Designed for round watch displays (e.g. Fenix 7 Pro, 260x260).
 * Subclasses implement drawRow(), getItems(), onItemSelect().
 */

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

//! Shared drawing utilities used by multiple views
module DrawUtils {

    //! Calculate horizontal inset for a Y position on a round screen.
    //! Returns the left margin needed so content stays inside the circle.
    //! @param yMid The vertical center of the element
    //! @param screenSize The screen diameter (width == height on round)
    //! @return Pixel inset from left (and right) edge
    function circleInset(yMid as Number, screenSize as Number) as Number {
        var r = screenSize / 2;
        var dy = yMid - r;
        if (dy < 0) { dy = -dy; }
        if (dy >= r) { return r; }
        var s = Math.sqrt((r * r - dy * dy).toFloat()).toNumber();
        var inset = r - s + 6;
        if (inset < 6) { inset = 6; }
        return inset;
    }

    //! Draw text with word wrapping, return Y position after last line.
    //! Uses circle insets when screenSize > 0 (round display).
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

    //! Draw circle-aware wrapped text — adjusts width per line for round display
    function drawWrappedTextRound(dc as Dc, y as Number, font as Graphics.FontDefinition, text as String, screenSize as Number) as Number {
        var charWidth = dc.getTextWidthInPixels("M", font);
        var lineHeight = dc.getFontHeight(font) + 2;

        var pos = 0;
        while (pos < text.length()) {
            var inset = circleInset(y + lineHeight / 2, screenSize);
            var availWidth = screenSize - inset * 2;
            if (availWidth < charWidth * 5) { availWidth = charWidth * 5; }
            var charsPerLine = availWidth / charWidth;
            if (charsPerLine < 5) { charsPerLine = 5; }

            var end = pos + charsPerLine;
            if (end >= text.length()) {
                end = text.length();
            } else {
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
            dc.drawText(inset + 4, y, font, line, Graphics.TEXT_JUSTIFY_LEFT);
            y += lineHeight;
            pos = end;
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
//! Round-display aware: uses circle insets for positioning.
//! Subclasses must override: getHeaderTitle(), getItems(), drawRow(), onItemSelect().
class BaseListView extends WatchUi.View {

    protected var _selectedIndex as Number = 0;
    protected var _scrollOffset as Number = 0;
    protected var _state as Symbol = :loading;
    protected var _errorMsg as String = "";

    // Layout constants
    const ROW_HEIGHT = 36;
    const HEADER_HEIGHT = 48;
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

    //! Override: draw a single row. inset = left margin for this row's Y.
    function drawRow(dc as Dc, item, y as Number, w as Number, isSelected as Boolean, inset as Number) as Void {
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

        // Draw header — pushed down for round display
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 18, Graphics.FONT_SMALL, getHeaderTitle() + " (" + items.size() + ")", Graphics.TEXT_JUSTIFY_CENTER);
        var lineInset = DrawUtils.circleInset(HEADER_HEIGHT - 2, h);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(lineInset, HEADER_HEIGHT - 2, w - lineInset, HEADER_HEIGHT - 2);

        // Calculate visible rows (leave bottom margin for round display)
        var usableH = h - HEADER_HEIGHT - 20;
        var visibleRows = usableH / ROW_HEIGHT;

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
            var rowMid = y + ROW_HEIGHT / 2;
            var inset = DrawUtils.circleInset(rowMid, h);

            if (isSelected) {
                dc.setColor(Graphics.COLOR_DK_BLUE, Graphics.COLOR_DK_BLUE);
                dc.fillRectangle(inset, y, w - inset * 2, ROW_HEIGHT);
            }

            drawRow(dc, item, y, w, isSelected, inset);
        }

        // Scroll indicator — positioned inside the circle
        if (items.size() > visibleRows) {
            var barTop = HEADER_HEIGHT;
            var barH = usableH;
            var thumbH = (barH * visibleRows) / items.size();
            if (thumbH < 10) { thumbH = 10; }
            var thumbY = barTop + (barH * _scrollOffset) / items.size();
            var thumbMid = thumbY + thumbH / 2;
            var scrollInset = DrawUtils.circleInset(thumbMid, h);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(w - scrollInset + 2, thumbY, 3, thumbH);
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
