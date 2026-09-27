#include <emscripten.h>
int main(void) {
    EM_ASM({ document.body.dataset.emccMain = 'yes'; });
    return 0;
}
