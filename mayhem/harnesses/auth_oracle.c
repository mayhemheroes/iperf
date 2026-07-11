/*
 * auth_oracle.c — behavioral test oracle for Base64Decode (src/iperf_auth.c).
 *
 * Decodes a known base64 string ("aGVsbG8=" == "hello") and prints the result.
 * test.sh greps for "hello"; a no-op / exit(0) program produces no output and
 * the grep fails (anti-reward-hacking, §6.3).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Declaration from iperf_auth.c (not static; not in a public header). */
int Base64Decode(const char *b64message, unsigned char **buffer, size_t *length);

int main(void) {
    const char *b64 = "aGVsbG8=";   /* "hello" */
    unsigned char *buf = NULL;
    size_t len = 0;

    int rc = Base64Decode(b64, &buf, &len);
    if (rc != 0 || buf == NULL || len == 0) {
        fprintf(stderr, "auth_oracle: Base64Decode failed (rc=%d)\n", rc);
        free(buf);
        return 1;
    }
    if (len != 5 || memcmp(buf, "hello", 5) != 0) {
        fprintf(stderr, "auth_oracle: expected 'hello' (5 bytes), got '%.*s' (%zu bytes)\n",
                (int)len, buf, len);
        free(buf);
        return 1;
    }

    printf("auth_oracle: Base64Decode(aGVsbG8=)=hello len=%zu OK\n", len);
    free(buf);
    return 0;
}
