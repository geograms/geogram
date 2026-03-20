/**
 * @file lv_conf.h
 * Configuration file for LVGL v8.x for Geogram e-paper display
 */

#ifndef LV_CONF_H
#define LV_CONF_H

#include <stdint.h>

/*====================
   COLOR SETTINGS
 *====================*/

/* Color depth: 1 (1 byte per pixel) for monochrome e-paper */
#define LV_COLOR_DEPTH 16

/* Swap the 2 bytes of RGB565 color for e-paper */
#define LV_COLOR_16_SWAP 0

/* Enable more complex drawing routines */
#define LV_COLOR_SCREEN_TRANSP 0

/*=========================
   MEMORY SETTINGS
 *=========================*/

/* Size of the memory used by `lv_mem_alloc` in bytes (>= 2kB) */
#define LV_MEM_CUSTOM 0
#define LV_MEM_SIZE (32U * 1024U)

/* Use the standard `memcpy` and `memset` instead of LVGL's own functions */
#define LV_MEMCPY_MEMSET_STD 1

/*====================
   HAL SETTINGS
 *====================*/

/* Default display refresh period in milliseconds */
#define LV_DISP_DEF_REFR_PERIOD 100

/* Input device read period in milliseconds */
#define LV_INDEV_DEF_READ_PERIOD 30

/* Use a custom tick source for LVGL */
#define LV_TICK_CUSTOM 1
#define LV_TICK_CUSTOM_INCLUDE "esp_timer.h"
#define LV_TICK_CUSTOM_SYS_TIME_EXPR ((esp_timer_get_time() / 1000))

/*====================
   FEATURE CONFIGURATION
 *====================*/

/*-------------
 * Drawing
 *-----------*/

/* Enable complex draw engine (required for anti-aliasing, gradients, etc.) */
#define LV_DRAW_COMPLEX 1

/* Enable shadow drawing */
#define LV_SHADOW_CACHE_SIZE 0

/* Set the maximum length of the circle cache */
#define LV_CIRCLE_CACHE_SIZE 4

/* Garbage collector settings */
#define LV_GC_INCLUDE "gc_builtin.h"
#define LV_ENABLE_GC 0

/*-------------
 * Logging
 *-----------*/

/* Enable log module */
#define LV_USE_LOG 1

#if LV_USE_LOG
/* How important log should be added:
 * LV_LOG_LEVEL_TRACE
 * LV_LOG_LEVEL_INFO
 * LV_LOG_LEVEL_WARN
 * LV_LOG_LEVEL_ERROR
 * LV_LOG_LEVEL_USER
 * LV_LOG_LEVEL_NONE
 */
#define LV_LOG_LEVEL LV_LOG_LEVEL_WARN

/* 1: Print the log with 'printf'; 0: user need to register a callback */
#define LV_LOG_PRINTF 1

/* Enable/disable LV_LOG_TRACE in modules */
#define LV_LOG_TRACE_MEM 0
#define LV_LOG_TRACE_TIMER 0
#define LV_LOG_TRACE_INDEV 0
#define LV_LOG_TRACE_DISP_REFR 0
#define LV_LOG_TRACE_EVENT 0
#define LV_LOG_TRACE_OBJ_CREATE 0
#define LV_LOG_TRACE_LAYOUT 0
#define LV_LOG_TRACE_ANIM 0

#endif /* LV_USE_LOG */

/*-------------
 * Asserts
 *-----------*/

#define LV_USE_ASSERT_NULL 1
#define LV_USE_ASSERT_MALLOC 1
#define LV_USE_ASSERT_STYLE 0
#define LV_USE_ASSERT_MEM_INTEGRITY 0
#define LV_USE_ASSERT_OBJ 0

/*-------------
 * Others
 *-----------*/

/* Show CPU and FPS count in bottom right corner */
#define LV_USE_PERF_MONITOR 0

/* Show memory usage in bottom left corner */
#define LV_USE_MEM_MONITOR 0

/* Draw random colored rectangles over the redrawn areas */
#define LV_USE_REFR_DEBUG 0

/* Define a custom attribute for large constant arrays to place them in special memory */
#define LV_ATTRIBUTE_LARGE_CONST

/* Export integer constant to binding, e.g. lv_obj_class.h */
#define LV_EXPORT_CONST_INT(int_value) struct _silence_gcc_warning

/* Prefix for API function names */
#define LV_ATTRIBUTE_MEM_ALIGN_SIZE 1
#define LV_ATTRIBUTE_MEM_ALIGN

/*=====================
 *  FONT USAGE
 *====================*/

/* Montserrat fonts with bpp = 4 */
#define LV_FONT_MONTSERRAT_8 0
#define LV_FONT_MONTSERRAT_10 1
#define LV_FONT_MONTSERRAT_12 1
#define LV_FONT_MONTSERRAT_14 1
#define LV_FONT_MONTSERRAT_16 1
#define LV_FONT_MONTSERRAT_18 0
#define LV_FONT_MONTSERRAT_20 0
#define LV_FONT_MONTSERRAT_22 0
#define LV_FONT_MONTSERRAT_24 1
#define LV_FONT_MONTSERRAT_26 0
#define LV_FONT_MONTSERRAT_28 0
#define LV_FONT_MONTSERRAT_30 0
#define LV_FONT_MONTSERRAT_32 0
#define LV_FONT_MONTSERRAT_34 0
#define LV_FONT_MONTSERRAT_36 0
#define LV_FONT_MONTSERRAT_38 0
#define LV_FONT_MONTSERRAT_40 0
#define LV_FONT_MONTSERRAT_42 0
#define LV_FONT_MONTSERRAT_44 0
#define LV_FONT_MONTSERRAT_46 0
#define LV_FONT_MONTSERRAT_48 0

/* Unscii monospace font */
#define LV_FONT_UNSCII_8 0
#define LV_FONT_UNSCII_16 0

/* Symbols for icon fonts */
#define LV_FONT_MONTSERRAT_12_SUBPX 0
#define LV_FONT_MONTSERRAT_28_COMPRESSED 0
#define LV_FONT_DEJAVU_16_PERSIAN_HEBREW 0
#define LV_FONT_SIMSUN_16_CJK 0

/* Default font */
#define LV_FONT_DEFAULT &lv_font_montserrat_14

/* Enable handling large font and/or large textures */
#define LV_FONT_FMT_TXT_LARGE 0

/* Enable subpixel rendering */
#define LV_USE_FONT_SUBPX 0

/* Enable drawing placeholders when glyph is missing */
#define LV_USE_FONT_PLACEHOLDER 1

/*=================
 *  TEXT SETTINGS
 *================*/

/* String character encoding. More info at https://github.com/lvgl/lvgl/issues/1824 */
#define LV_TXT_ENC LV_TXT_ENC_UTF8

/* Allow break on these characters for line breaking */
#define LV_TXT_BREAK_CHARS " ,.;:-_"

/* If a word is at least this long, break a line wherever possible */
#define LV_TXT_LINE_BREAK_LONG_LEN 0

/* Pre-break long line if length below */
#define LV_TXT_LINE_BREAK_LONG_PRE_MIN_LEN 3

/* Post-break long line if length below */
#define LV_TXT_LINE_BREAK_LONG_POST_MIN_LEN 3

/* Enable bidirectional string support */
#define LV_USE_BIDI 0

/* Enable Arabic/Persian processing */
#define LV_USE_ARABIC_PERSIAN_CHARS 0

/*==================
 *  WIDGET USAGE
 *==================*/

#define LV_USE_ARC 0
#define LV_USE_BAR 1
#define LV_USE_BTN 1
#define LV_USE_BTNMATRIX 0
#define LV_USE_CANVAS 0
#define LV_USE_CHECKBOX 0
#define LV_USE_DROPDOWN 0
#define LV_USE_IMG 1
#define LV_USE_LABEL 1
#define LV_USE_LINE 1
#define LV_USE_ROLLER 0
#define LV_USE_SLIDER 0
#define LV_USE_SWITCH 0
#define LV_USE_TEXTAREA 0
#define LV_USE_TABLE 0

/*==================
 * EXTRA COMPONENTS
 *==================*/

/* WIDGETS */
#define LV_USE_ANIMIMG 0
#define LV_USE_CALENDAR 0
#define LV_USE_CHART 0
#define LV_USE_COLORWHEEL 0
#define LV_USE_IMGBTN 0
#define LV_USE_KEYBOARD 0
#define LV_USE_LED 0
#define LV_USE_LIST 0
#define LV_USE_MENU 0
#define LV_USE_METER 0
#define LV_USE_MSGBOX 0
#define LV_USE_SPAN 0
#define LV_USE_SPINBOX 0
#define LV_USE_SPINNER 0
#define LV_USE_TABVIEW 0
#define LV_USE_TILEVIEW 0
#define LV_USE_WIN 0

/* THEMES */
#define LV_USE_THEME_DEFAULT 1
#define LV_USE_THEME_MONO 1

/* LAYOUTS */
#define LV_USE_FLEX 1
#define LV_USE_GRID 0

/* OTHERS */
#define LV_USE_SNAPSHOT 0
#define LV_USE_FRAGMENT 0
#define LV_USE_GRIDNAV 0
#define LV_USE_MSG 0
#define LV_USE_IME_PINYIN 0

/*===================
 *  3RD PARTY LIBRARIES
 *==================*/

/* File system interfaces for common APIs */
#define LV_USE_FS_STDIO 0
#define LV_USE_FS_POSIX 0
#define LV_USE_FS_WIN32 0
#define LV_USE_FS_FATFS 0

/* PNG decoder */
#define LV_USE_PNG 0

/* BMP decoder */
#define LV_USE_BMP 0

/* JPG and SJPG decoder */
#define LV_USE_SJPG 0

/* GIF decoder */
#define LV_USE_GIF 0

/* QR code */
#define LV_USE_QRCODE 0

/* FreeType */
#define LV_USE_FREETYPE 0

/* Tiny TTF */
#define LV_USE_TINY_TTF 0

/* Rlottie */
#define LV_USE_RLOTTIE 0

/* FFmpeg */
#define LV_USE_FFMPEG 0

/*==================
 *  EXAMPLES / DEMOS
 *==================*/

/* Enable/disable examples */
#define LV_BUILD_EXAMPLES 0

#endif /* LV_CONF_H */
