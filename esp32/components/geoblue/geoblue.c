#include "geoblue.h"

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cJSON.h"

static char *geoblue_json_to_string(cJSON *json)
{
    if (!json) {
        return NULL;
    }

    char *out = cJSON_PrintUnformatted(json);
    if (!out) {
        return NULL;
    }

    return out;
}

static void geoblue_add_caps(cJSON *payload, const char **capabilities, size_t capability_count)
{
    if (!payload) {
        return;
    }

    cJSON *caps = cJSON_CreateArray();
    if (!caps) {
        return;
    }

    for (size_t i = 0; i < capability_count; i++) {
        const char *cap = capabilities ? capabilities[i] : NULL;
        if (cap && cap[0] != '\0') {
            cJSON_AddItemToArray(caps, cJSON_CreateString(cap));
        }
    }

    if (cJSON_GetArraySize(caps) == 0) {
        cJSON_AddItemToArray(caps, cJSON_CreateString("hello"));
        cJSON_AddItemToArray(caps, cJSON_CreateString("data"));
        cJSON_AddItemToArray(caps, cJSON_CreateString("broadcast"));
    }

    cJSON_AddItemToObject(payload, "capabilities", caps);
}

static cJSON *geoblue_build_event(const char *callsign,
                                  const char *npub,
                                  const char *board)
{
    cJSON *event = cJSON_CreateObject();
    cJSON *tags = cJSON_CreateArray();
    if (!event || !tags) {
        cJSON_Delete(event);
        cJSON_Delete(tags);
        return NULL;
    }

    const char *safe_callsign = (callsign && callsign[0] != '\0') ? callsign : "NOCALL";
    const char *safe_npub = (npub && npub[0] != '\0') ? npub : "";
    const char *safe_board = (board && board[0] != '\0') ? board : "esp32";

    cJSON_AddNumberToObject(event, "kind", 0);
    cJSON_AddNumberToObject(event, "created_at", (double)time(NULL));
    cJSON_AddStringToObject(event, "pubkey", safe_npub);
    cJSON_AddStringToObject(event, "content", "");

    cJSON *tag_callsign = cJSON_CreateArray();
    cJSON *tag_nickname = cJSON_CreateArray();
    cJSON *tag_board = cJSON_CreateArray();

    if (!tag_callsign || !tag_nickname || !tag_board) {
        cJSON_Delete(event);
        cJSON_Delete(tags);
        cJSON_Delete(tag_callsign);
        cJSON_Delete(tag_nickname);
        cJSON_Delete(tag_board);
        return NULL;
    }

    cJSON_AddItemToArray(tag_callsign, cJSON_CreateString("callsign"));
    cJSON_AddItemToArray(tag_callsign, cJSON_CreateString(safe_callsign));

    cJSON_AddItemToArray(tag_nickname, cJSON_CreateString("nickname"));
    cJSON_AddItemToArray(tag_nickname, cJSON_CreateString(safe_callsign));

    cJSON_AddItemToArray(tag_board, cJSON_CreateString("board"));
    cJSON_AddItemToArray(tag_board, cJSON_CreateString(safe_board));

    cJSON_AddItemToArray(tags, tag_callsign);
    cJSON_AddItemToArray(tags, tag_nickname);
    cJSON_AddItemToArray(tags, tag_board);
    cJSON_AddItemToObject(event, "tags", tags);

    return event;
}

static cJSON *geoblue_build_profile(const char *callsign,
                                    const char *npub,
                                    const char *board)
{
    cJSON *profile = cJSON_CreateObject();
    if (!profile) {
        return NULL;
    }

    cJSON_AddStringToObject(profile,
                            "callsign",
                            (callsign && callsign[0] != '\0') ? callsign : "NOCALL");
    if (npub && npub[0] != '\0') {
        cJSON_AddStringToObject(profile, "npub", npub);
    }
    if (board && board[0] != '\0') {
        cJSON_AddStringToObject(profile, "board", board);
    }
    cJSON_AddStringToObject(profile, "platform", "esp32");

    return profile;
}

static char *geoblue_build_profile_frame(const char *id,
                                         const char *type,
                                         const char *callsign,
                                         const char *npub,
                                         const char *board,
                                         const char **capabilities,
                                         size_t capability_count,
                                         bool include_success,
                                         bool success,
                                         const char *message)
{
    cJSON *payload = cJSON_CreateObject();
    cJSON *envelope = cJSON_CreateObject();
    cJSON *event = geoblue_build_event(callsign, npub, board);
    cJSON *profile = geoblue_build_profile(callsign, npub, board);
    if (!payload || !envelope || !event || !profile) {
        cJSON_Delete(payload);
        cJSON_Delete(envelope);
        cJSON_Delete(event);
        cJSON_Delete(profile);
        return NULL;
    }

    cJSON_AddItemToObject(payload, "event", event);
    cJSON_AddItemToObject(payload, "profile", profile);
    geoblue_add_caps(payload, capabilities, capability_count);
    cJSON_AddNumberToObject(payload, "timestamp", (double)time(NULL));

    if (include_success) {
        cJSON_AddBoolToObject(payload, "success", success);
        if (message && message[0] != '\0') {
            cJSON_AddStringToObject(payload, "message", message);
        }
    }

    cJSON_AddNumberToObject(envelope, "v", 1);
    cJSON_AddStringToObject(envelope, "id", (id && id[0] != '\0') ? id : "unknown");
    cJSON_AddStringToObject(envelope, "type", type ? type : "hello");
    cJSON_AddNumberToObject(envelope, "seq", 0);
    cJSON_AddNumberToObject(envelope, "total", 1);
    cJSON_AddItemToObject(envelope, "payload", payload);

    char *out = geoblue_json_to_string(envelope);
    cJSON_Delete(envelope);
    return out;
}

const char *geoblue_frame_type_name(geoblue_frame_type_t type)
{
    switch (type) {
        case GEOBLUE_FRAME_HELLO:
            return "hello";
        case GEOBLUE_FRAME_HELLO_ACK:
            return "hello_ack";
        case GEOBLUE_FRAME_DATA:
            return "data";
        case GEOBLUE_FRAME_BROADCAST:
            return "broadcast";
        case GEOBLUE_FRAME_ERROR:
            return "error";
        default:
            return "unknown";
    }
}

geoblue_frame_type_t geoblue_frame_type_from_name(const char *name)
{
    if (!name || name[0] == '\0') {
        return GEOBLUE_FRAME_UNKNOWN;
    }

    if (strcmp(name, "hello") == 0) {
        return GEOBLUE_FRAME_HELLO;
    }
    if (strcmp(name, "hello_ack") == 0) {
        return GEOBLUE_FRAME_HELLO_ACK;
    }
    if (strcmp(name, "data") == 0) {
        return GEOBLUE_FRAME_DATA;
    }
    if (strcmp(name, "broadcast") == 0) {
        return GEOBLUE_FRAME_BROADCAST;
    }
    if (strcmp(name, "error") == 0) {
        return GEOBLUE_FRAME_ERROR;
    }

    return GEOBLUE_FRAME_UNKNOWN;
}

char *geoblue_build_hello_frame(const char *id,
                                const char *callsign,
                                const char *npub,
                                const char *board,
                                const char **capabilities,
                                size_t capability_count)
{
    return geoblue_build_profile_frame(id,
                                       "hello",
                                       callsign,
                                       npub,
                                       board,
                                       capabilities,
                                       capability_count,
                                       false,
                                       true,
                                       NULL);
}

char *geoblue_build_hello_ack_frame(const char *id,
                                    bool success,
                                    const char *callsign,
                                    const char *npub,
                                    const char *board,
                                    const char **capabilities,
                                    size_t capability_count,
                                    const char *message)
{
    return geoblue_build_profile_frame(id,
                                       "hello_ack",
                                       callsign,
                                       npub,
                                       board,
                                       capabilities,
                                       capability_count,
                                       true,
                                       success,
                                       message);
}

char *geoblue_build_data_frame(const char *id,
                               const char *from,
                               const char *to,
                               const char *channel,
                               const char *content,
                               int64_t timestamp)
{
    cJSON *payload = cJSON_CreateObject();
    cJSON *envelope = cJSON_CreateObject();
    if (!payload || !envelope) {
        cJSON_Delete(payload);
        cJSON_Delete(envelope);
        return NULL;
    }

    cJSON_AddStringToObject(payload, "from", (from && from[0] != '\0') ? from : "NOCALL");
    cJSON_AddStringToObject(payload, "channel", (channel && channel[0] != '\0') ? channel : "main");
    cJSON_AddStringToObject(payload, "content", content ? content : "");
    if (to && to[0] != '\0') {
        cJSON_AddStringToObject(payload, "to", to);
    }
    cJSON_AddNumberToObject(payload, "timestamp", (double)(timestamp > 0 ? timestamp : (int64_t)time(NULL)));

    cJSON_AddNumberToObject(envelope, "v", 1);
    cJSON_AddStringToObject(envelope, "id", (id && id[0] != '\0') ? id : "unknown");
    cJSON_AddStringToObject(envelope, "type", "data");
    cJSON_AddNumberToObject(envelope, "seq", 0);
    cJSON_AddNumberToObject(envelope, "total", 1);
    cJSON_AddItemToObject(envelope, "payload", payload);

    char *out = geoblue_json_to_string(envelope);
    cJSON_Delete(envelope);
    return out;
}

char *geoblue_build_broadcast_frame(const char *id,
                                    const char *from,
                                    const char *topic,
                                    const char *content,
                                    int64_t timestamp)
{
    cJSON *payload = cJSON_CreateObject();
    cJSON *envelope = cJSON_CreateObject();
    if (!payload || !envelope) {
        cJSON_Delete(payload);
        cJSON_Delete(envelope);
        return NULL;
    }

    cJSON_AddStringToObject(payload, "from", (from && from[0] != '\0') ? from : "NOCALL");
    cJSON_AddStringToObject(payload, "topic", (topic && topic[0] != '\0') ? topic : "general");
    cJSON_AddStringToObject(payload, "content", content ? content : "");
    cJSON_AddNumberToObject(payload, "timestamp", (double)(timestamp > 0 ? timestamp : (int64_t)time(NULL)));

    cJSON_AddNumberToObject(envelope, "v", 1);
    cJSON_AddStringToObject(envelope, "id", (id && id[0] != '\0') ? id : "unknown");
    cJSON_AddStringToObject(envelope, "type", "broadcast");
    cJSON_AddNumberToObject(envelope, "seq", 0);
    cJSON_AddNumberToObject(envelope, "total", 1);
    cJSON_AddItemToObject(envelope, "payload", payload);

    char *out = geoblue_json_to_string(envelope);
    cJSON_Delete(envelope);
    return out;
}

bool geoblue_find_json_object_bounds(const uint8_t *buffer,
                                     size_t len,
                                     size_t *json_start,
                                     size_t *json_end,
                                     size_t *discard_prefix,
                                     bool *incomplete)
{
    if (!buffer || len == 0 || !json_start || !json_end || !discard_prefix || !incomplete) {
        return false;
    }

    *discard_prefix = 0;
    *incomplete = false;

    size_t start = SIZE_MAX;
    for (size_t i = 0; i < len; i++) {
        if (buffer[i] == '{') {
            start = i;
            break;
        }
    }

    if (start == SIZE_MAX) {
        *discard_prefix = len;
        return false;
    }

    int depth = 0;
    bool in_string = false;
    bool escaped = false;

    for (size_t i = start; i < len; i++) {
        char c = (char)buffer[i];

        if (escaped) {
            escaped = false;
            continue;
        }

        if (in_string && c == '\\') {
            escaped = true;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            continue;
        }

        if (in_string) {
            continue;
        }

        if (c == '{') {
            depth++;
        } else if (c == '}') {
            depth--;
            if (depth == 0) {
                *json_start = start;
                *json_end = i;
                *discard_prefix = start;
                return true;
            }
        }
    }

    *discard_prefix = start;
    *incomplete = true;
    return false;
}
