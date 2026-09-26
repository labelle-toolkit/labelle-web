// Drives the real EM_JS entry points from wasm, under Node (no IndexedDB).
// A JS exception crossing EM_JS aborts the module, so a regression shows up as
// a non-zero exit rather than a failed assertion.
#include <stdint.h>
#include <stdio.h>

uint32_t labelle_blob_begin(const char *ns, uint32_t ns_len, uint32_t kind, const char *name, uint32_t name_len, const uint8_t *data, uint32_t data_len, uint32_t limit);
int32_t labelle_blob_status(uint32_t id);
uint32_t labelle_blob_length(uint32_t id);
int32_t labelle_blob_copy(uint32_t id, uint8_t *out, uint32_t len);
void labelle_blob_release(uint32_t id);

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static void unknown_handle(uint32_t id) {
    uint8_t buf[4] = {0};
    CHECK(labelle_blob_status(id) == -3);
    CHECK(labelle_blob_length(id) == 0);
    CHECK(labelle_blob_copy(id, buf, sizeof buf) == 0);
    CHECK(labelle_blob_copy(id, buf, 0) == 1);
    labelle_blob_release(id);
}

int main(void) {
    // Before the first begin the JS service does not exist yet.
    unknown_handle(0);
    unknown_handle(7);

    const uint8_t payload[] = "data";
    uint32_t id = labelle_blob_begin("boundary", 8, 1, "a.json", 6, payload, 4, 0);
    CHECK(id != 0);
    CHECK(labelle_blob_length(id) == 0); // pending: no bytes yet
    labelle_blob_release(id);
    unknown_handle(id);    // released
    unknown_handle(0);     // failed-begin handle
    unknown_handle(12345); // never issued

    if (failures) return 1;
    printf("wasm boundary: all checks passed\n");
    return 0;
}
