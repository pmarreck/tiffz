/* tiffz CLI — dogfoods the C FFI per project convention.
 *
 * M2: --version, --about, --help. The decode/validate subcommands
 * land alongside their M3+ implementations.
 */

#include <stdio.h>
#include <string.h>

#include "tiffz.h"

#if defined(__aarch64__) || defined(_M_ARM64)
#define TIFFZ_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#define TIFFZ_ARCH "x86_64"
#else
#define TIFFZ_ARCH "unknown"
#endif

#if defined(__APPLE__)
#define TIFFZ_OS "macos"
#elif defined(__linux__)
#define TIFFZ_OS "linux"
#elif defined(_WIN32)
#define TIFFZ_OS "windows"
#else
#define TIFFZ_OS "unknown"
#endif

static int print_about(void) {
    printf("tiffz %s — pure-Zig spec-complete TIFF reader (%s/%s)\n",
           tiffz_version(), TIFFZ_OS, TIFFZ_ARCH);
    return 0;
}

static int print_version(void) {
    printf("%s\n", tiffz_version());
    return 0;
}

static int print_help(void) {
    printf(
        "tiffz %s — pure-Zig TIFF reader\n"
        "\n"
        "USAGE:\n"
        "    tiffz [OPTIONS]\n"
        "\n"
        "OPTIONS:\n"
        "    --version, -v    Print version and exit\n"
        "    --about          Print one-line app description and exit\n"
        "    --help, -h       Print this help and exit\n"
        "\n"
        "STATUS: M2 scaffold. Decode subcommands land in M3+.\n",
        tiffz_version());
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        return print_help();
    }
    const char *arg = argv[1];
    if (strcmp(arg, "--version") == 0 || strcmp(arg, "-v") == 0) {
        return print_version();
    }
    if (strcmp(arg, "--about") == 0) {
        return print_about();
    }
    if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
        return print_help();
    }
    fprintf(stderr, "tiffz: unknown argument '%s' (try --help)\n", arg);
    return 1;
}
