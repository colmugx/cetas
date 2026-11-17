/* Test-only full terminal-state snapshot; never reads terminal input. */
#include <moonbit.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
MOONBIT_FFI_EXPORT
moonbit_bytes_t cetas_auth_test_snapshot(HANDLE fd) {
  DWORD state;
  if (!GetConsoleMode(fd, &state)) return moonbit_make_bytes(0, 0);
#else
#include <termios.h>
MOONBIT_FFI_EXPORT
moonbit_bytes_t cetas_auth_test_snapshot(int fd) {
  struct termios state;
  memset(&state, 0, sizeof(state));
  if (tcgetattr(fd, &state) < 0) return moonbit_make_bytes(0, 0);
#endif
  moonbit_bytes_t result = moonbit_make_bytes(sizeof(state), 0);
  memcpy(result, &state, sizeof(state));
  return result;
}
