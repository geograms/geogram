/**
 * @file tdongle_ui.c
 * @brief LVGL-based UI for the LILYGO T-Dongle-S3 (ST7735, 160x80).
 *
 * Layout (landscape, 160 wide x 80 tall):
 *   ┌──────────────────────────────────────┐
 *   │  orange top bar  (uptime)        20px│
 *   ├──────────────────────────────────────┤
 *   │  black chat area  (messages)     46px│
 *   ├──────────────────────────────────────┤
 *   │  grey bottom bar  (IP + count)   14px│
 *   └──────────────────────────────────────┘
 */

#include "tdongle_ui.h"
#include <string.h>
#include <stdio.h>
#include "lvgl.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"

static const char *TAG = "tdongle_ui";

/* ---- constants ---------------------------------------------------------- */

#define SCREEN_W  ST7735_WIDTH    /* 160 */
#define SCREEN_H  ST7735_HEIGHT   /*  80 */
#define TOP_H     20
#define BOTTOM_H  14
#define CENTER_H  (SCREEN_H - TOP_H - BOTTOM_H)

#define MSG_MAX   4               /* keep last N messages */
#define MSG_CAP   128             /* per-message char cap */

/* ---- state -------------------------------------------------------------- */

static st7735_handle_t      s_lcd;
static lv_disp_draw_buf_t   s_draw_buf;
static lv_disp_drv_t        s_disp_drv;
static lv_disp_t           *s_disp;

/* LVGL widgets */
static lv_obj_t *s_status_label;
static lv_obj_t *s_msg_label;
static lv_obj_t *s_count_label;
static lv_obj_t *s_ip_label;

/* Message ring */
static char     s_msgs[MSG_MAX][MSG_CAP];
static uint8_t  s_msg_cnt;
static volatile bool s_msgs_dirty;

/* Device count / IP (written from any task, applied in LVGL task) */
static int      s_dev_count;
static bool     s_dev_dirty;
static char     s_ip_str[24];
static bool     s_ip_dirty;

/* ---- LVGL flush callback ------------------------------------------------ */

static void lcd_flush_cb(lv_disp_drv_t *drv, const lv_area_t *area, lv_color_t *color_p)
{
    uint32_t size = (area->x2 - area->x1 + 1) * (area->y2 - area->y1 + 1);
    uint16_t *px = (uint16_t *)color_p;

    /* LVGL stores RGB565 in CPU-native (little-endian) order.
     * ST7735 SPI expects big-endian — swap bytes. */
    for (uint32_t i = 0; i < size; i++) {
        px[i] = (px[i] >> 8) | (px[i] << 8);
    }

    st7735_flush(s_lcd,
                 area->x1, area->y1,
                 area->x2, area->y2,
                 px);
    lv_disp_flush_ready(drv);
}

/* ---- update (called from main loop, same pattern as old Arduino code) --- */

static uint32_t s_uptime_last = 0;
static uint64_t s_last_tick_us = 0;

void tdongle_ui_update(void)
{
    /* Advance LVGL tick (the managed LVGL component doesn't see our lv_conf.h,
     * so LV_TICK_CUSTOM is not active — we must call lv_tick_inc manually) */
    uint64_t now_us = esp_timer_get_time();
    uint32_t elapsed_ms = (uint32_t)((now_us - s_last_tick_us) / 1000);
    if (elapsed_ms > 0) {
        lv_tick_inc(elapsed_ms);
        s_last_tick_us = now_us;
    }

    /* Pump LVGL — flushes dirty regions from previous iteration */
    lv_timer_handler();

    /* Uptime label (once per second) */
    uint32_t total_sec = (uint32_t)(esp_timer_get_time() / 1000000);
    if (total_sec != s_uptime_last && s_status_label) {
        s_uptime_last = total_sec;

        static char buf[64];
        uint32_t days    = total_sec / 86400;
        uint32_t hours   = (total_sec / 3600) % 24;
        uint32_t minutes = (total_sec / 60) % 60;
        uint32_t seconds = total_sec % 60;

        if (days == 0) {
            snprintf(buf, sizeof(buf), "geogram uptime: %02lu:%02lu:%02lu",
                     (unsigned long)hours, (unsigned long)minutes, (unsigned long)seconds);
        } else {
            snprintf(buf, sizeof(buf), "geogram uptime: %lu day%s %02lu h",
                     (unsigned long)days, (days == 1 ? "" : "s"), (unsigned long)hours);
        }
        lv_label_set_text(s_status_label, buf);
    }

    /* Apply chat messages */
    if (s_msgs_dirty) {
        s_msgs_dirty = false;

        if (s_msg_label) {
            static char combined[MSG_MAX * MSG_CAP + 8];
            combined[0] = '\0';

            for (uint8_t i = 0; i < s_msg_cnt; i++) {
                strncat(combined, s_msgs[i], sizeof(combined) - 1 - strlen(combined));
                if (i + 1 < s_msg_cnt) {
                    strncat(combined, "\n", sizeof(combined) - 1 - strlen(combined));
                }
            }

            lv_label_set_text(s_msg_label, (s_msg_cnt == 0) ? "--" : combined);

            lv_obj_t *parent = lv_obj_get_parent(s_msg_label);
            lv_obj_update_layout(parent);
            lv_obj_scroll_to_y(parent, LV_COORD_MAX, LV_ANIM_OFF);
        }
    }

    /* Device count */
    if (s_dev_dirty) {
        s_dev_dirty = false;
        if (s_count_label) {
            char buf[16];
            if (s_dev_count > 0)
                snprintf(buf, sizeof(buf), LV_SYMBOL_BLUETOOTH "%d", s_dev_count);
            else
                buf[0] = '\0';
            lv_label_set_text(s_count_label, buf);
        }
    }

    /* IP label */
    if (s_ip_dirty) {
        s_ip_dirty = false;
        if (s_ip_label) {
            lv_label_set_text(s_ip_label, s_ip_str);
        }
    }
}

/* ---- UI construction ---------------------------------------------------- */

static void build_ui(void)
{
    /* Screen background */
    lv_obj_t *scr = lv_scr_act();
    lv_obj_remove_style_all(scr);
    lv_obj_set_style_bg_color(scr, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    /* ---- Top bar (orange, rounded corners) ---- */
    lv_obj_t *top = lv_obj_create(scr);
    lv_obj_set_size(top, SCREEN_W, TOP_H);
    lv_obj_set_style_bg_color(top, lv_color_make(255, 140, 0), 0);
    lv_obj_set_style_border_width(top, 0, 0);
    lv_obj_set_style_pad_all(top, 0, 0);
    lv_obj_clear_flag(top, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_align(top, LV_ALIGN_TOP_MID, 0, 0);

    s_status_label = lv_label_create(top);
    lv_label_set_text(s_status_label, "geogram  00:00:00");
    lv_obj_set_style_text_font(s_status_label, &lv_font_montserrat_10, 0);
    lv_obj_set_style_text_color(s_status_label, lv_color_black(), 0);
    lv_obj_align(s_status_label, LV_ALIGN_LEFT_MID, 4, 0);

    /* ---- Center chat area (black) ---- */
    lv_obj_t *center = lv_obj_create(scr);
    lv_obj_remove_style_all(center);
    lv_obj_set_size(center, SCREEN_W, CENTER_H);
    lv_obj_align(center, LV_ALIGN_TOP_LEFT, 0, TOP_H);
    lv_obj_set_style_bg_color(center, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(center, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(center, 0, 0);
    lv_obj_set_style_pad_all(center, 4, 0);
    lv_obj_set_scrollbar_mode(center, LV_SCROLLBAR_MODE_OFF);

    s_msg_label = lv_label_create(center);
    lv_label_set_text(s_msg_label, "--");
    lv_obj_set_style_text_font(s_msg_label, &lv_font_montserrat_10, 0);
    lv_obj_set_style_text_color(s_msg_label, lv_color_white(), 0);
    lv_label_set_long_mode(s_msg_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(s_msg_label, LV_PCT(100));
    lv_obj_align(s_msg_label, LV_ALIGN_TOP_LEFT, 0, 0);

    /* ---- Bottom bar (grey, rounded corners) ---- */
    lv_obj_t *bot = lv_obj_create(scr);
    lv_obj_set_size(bot, SCREEN_W, BOTTOM_H);
    lv_obj_set_style_bg_color(bot, lv_color_make(128, 128, 128), 0);
    lv_obj_set_style_border_width(bot, 0, 0);
    lv_obj_set_style_pad_all(bot, 0, 0);
    lv_obj_clear_flag(bot, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_align(bot, LV_ALIGN_BOTTOM_MID, 0, 0);

    s_ip_label = lv_label_create(bot);
    lv_label_set_text(s_ip_label, "");
    lv_obj_set_style_text_font(s_ip_label, &lv_font_montserrat_10, 0);
    lv_obj_set_style_text_color(s_ip_label, lv_color_black(), 0);
    lv_obj_align(s_ip_label, LV_ALIGN_LEFT_MID, 4, 0);

    s_count_label = lv_label_create(bot);
    lv_label_set_text(s_count_label, "");
    lv_obj_set_style_text_font(s_count_label, &lv_font_montserrat_10, 0);
    lv_obj_set_style_text_color(s_count_label, lv_color_black(), 0);
    lv_obj_align(s_count_label, LV_ALIGN_RIGHT_MID, -4, 0);
}

/* ---- public API --------------------------------------------------------- */

esp_err_t tdongle_ui_init(st7735_handle_t lcd)
{
    if (!lcd) return ESP_ERR_INVALID_ARG;
    s_lcd = lcd;

    /* LVGL init */
    lv_init();

    /* Draw buffer — one full screen (160*80*2 = 25.6 KB) */
    static lv_color_t *buf1;
    buf1 = heap_caps_malloc(SCREEN_W * SCREEN_H * sizeof(lv_color_t), MALLOC_CAP_DMA);
    if (!buf1) {
        buf1 = malloc(SCREEN_W * SCREEN_H * sizeof(lv_color_t));
    }
    if (!buf1) return ESP_ERR_NO_MEM;

    lv_disp_draw_buf_init(&s_draw_buf, buf1, NULL, SCREEN_W * SCREEN_H);

    /* Display driver */
    lv_disp_drv_init(&s_disp_drv);
    s_disp_drv.hor_res  = SCREEN_W;
    s_disp_drv.ver_res  = SCREEN_H;
    s_disp_drv.flush_cb = lcd_flush_cb;
    s_disp_drv.draw_buf = &s_draw_buf;
    s_disp = lv_disp_drv_register(&s_disp_drv);

    /* Dark theme (tick is handled by LV_TICK_CUSTOM in lv_conf.h) */
    lv_theme_t *th = lv_theme_default_init(s_disp,
                                           lv_palette_main(LV_PALETTE_BLUE),
                                           lv_palette_main(LV_PALETTE_GREY),
                                           true,
                                           &lv_font_montserrat_10);
    lv_disp_set_theme(s_disp, th);

    /* Build widgets */
    build_ui();

    /* Init message ring */
    memset(s_msgs, 0, sizeof(s_msgs));
    s_msg_cnt = 0;
    s_msgs_dirty = false;
    s_dev_count = 0;
    s_dev_dirty = false;
    s_ip_str[0] = '\0';
    s_ip_dirty = false;

    ESP_LOGI(TAG, "T-Dongle UI initialised (%dx%d) — call tdongle_ui_update() from main loop", SCREEN_W, SCREEN_H);
    return ESP_OK;
}

void tdongle_ui_push_message(const char *from, const char *text)
{
    if (!from || !text) return;

    char line[MSG_CAP];
    snprintf(line, sizeof(line), "%s: %s", from, text);

    /* Shift up if full */
    if (s_msg_cnt >= MSG_MAX) {
        for (uint8_t i = 1; i < MSG_MAX; i++) {
            memcpy(s_msgs[i - 1], s_msgs[i], MSG_CAP);
        }
        strncpy(s_msgs[MSG_MAX - 1], line, MSG_CAP - 1);
        s_msgs[MSG_MAX - 1][MSG_CAP - 1] = '\0';
    } else {
        strncpy(s_msgs[s_msg_cnt], line, MSG_CAP - 1);
        s_msgs[s_msg_cnt][MSG_CAP - 1] = '\0';
        s_msg_cnt++;
    }

    s_msgs_dirty = true;
}

void tdongle_ui_set_device_count(int count)
{
    s_dev_count = count;
    s_dev_dirty = true;
}

void tdongle_ui_set_ip(const char *ip)
{
    if (!ip) return;
    snprintf(s_ip_str, sizeof(s_ip_str), "IP: %s", ip);
    s_ip_dirty = true;
}
