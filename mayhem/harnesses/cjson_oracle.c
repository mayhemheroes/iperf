/*
 * cjson_oracle.c — behavioral test oracle for cJSON_Parse.
 *
 * Parses a hard-coded JSON object and prints the value of "duration" and
 * "num_streams". test.sh greps for those values; a no-op / exit(0) program
 * produces no output and the grep fails (anti-reward-hacking, §6.3).
 */
#include <stdio.h>
#include <stdlib.h>
#include "cjson.h"

int main(void) {
    const char *json = "{\"num_streams\":1,\"omit\":0,\"duration\":10,\"reverse\":false}";
    cJSON *root = cJSON_Parse(json);
    if (!root) {
        fprintf(stderr, "cjson_oracle: cJSON_Parse returned NULL\n");
        return 1;
    }

    cJSON *dur = cJSON_GetObjectItem(root, "duration");
    cJSON *ns  = cJSON_GetObjectItem(root, "num_streams");
    if (!dur || !ns) {
        fprintf(stderr, "cjson_oracle: missing expected fields\n");
        cJSON_Delete(root);
        return 1;
    }
    if (!cJSON_IsNumber(dur) || (int)dur->valuedouble != 10) {
        fprintf(stderr, "cjson_oracle: duration expected 10, got %g\n", dur->valuedouble);
        cJSON_Delete(root);
        return 1;
    }
    if (!cJSON_IsNumber(ns) || (int)ns->valuedouble != 1) {
        fprintf(stderr, "cjson_oracle: num_streams expected 1, got %g\n", ns->valuedouble);
        cJSON_Delete(root);
        return 1;
    }

    printf("cjson_oracle: duration=%d num_streams=%d OK\n",
           (int)dur->valuedouble, (int)ns->valuedouble);
    cJSON_Delete(root);
    return 0;
}
