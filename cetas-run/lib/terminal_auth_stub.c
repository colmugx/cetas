#include <moonbit.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef HANDLE auth_fd;
#else
#include <errno.h>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
typedef int auth_fd;
#endif

/* Own a duplicate, so restoration never targets a closed/reused async fd. */
typedef struct {
  auth_fd fd;
  int valid;
  int active;
#ifdef _WIN32
  DWORD saved;
#else
  struct termios saved;
#endif
} auth_mode;

static int restore_mode(auth_mode *guard) {
  if (!guard->active) return 1;
#ifdef _WIN32
  /* Discard partial secrets before echo can be enabled again. */
  BOOL flushed = FlushConsoleInputBuffer(guard->fd);
  if (!SetConsoleMode(guard->fd, guard->saved)) return 0;
#else
  int result;
  do { result = tcsetattr(guard->fd, TCSAFLUSH, &guard->saved); }
  while (result < 0 && errno == EINTR);
  if (result < 0) return 0;
#endif
  guard->active = 0;
#ifdef _WIN32
  return flushed != 0;
#else
  return 1;
#endif
}

static void close_mode(void *ptr) {
  auth_mode *guard = ptr;
  if (!guard->valid) return;
  restore_mode(guard);
#ifdef _WIN32
  CloseHandle(guard->fd);
#else
  close(guard->fd);
#endif
  guard->valid = 0;
}

static const char *cetas_auth_terminal_path(void) {
#ifdef _WIN32
  return "CONIN$";
#else
  return "/dev/tty";
#endif
}

MOONBIT_FFI_EXPORT
auth_mode *cetas_auth_mode_new(auth_fd fd) {
  auth_mode *guard = moonbit_make_external_object(close_mode, sizeof(auth_mode));
  memset(guard, 0, sizeof(*guard));
#ifdef _WIN32
  guard->valid = DuplicateHandle(GetCurrentProcess(), fd, GetCurrentProcess(),
                                &guard->fd, 0, FALSE, DUPLICATE_SAME_ACCESS);
#else
  guard->fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  guard->valid = guard->fd >= 0;
#endif
  return guard;
}

MOONBIT_FFI_EXPORT
int32_t cetas_auth_mode_enter(auth_mode *guard) {
  if (!guard->valid || guard->active) return 0;
#ifdef _WIN32
  if (!GetConsoleMode(guard->fd, &guard->saved)) return 0;
  if (!FlushConsoleInputBuffer(guard->fd)) return 0;
  DWORD mode = (guard->saved | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT)
               & ~ENABLE_ECHO_INPUT;
  guard->active = 1;
  if (!SetConsoleMode(guard->fd, mode)) return 0;
  DWORD actual;
  return GetConsoleMode(guard->fd, &actual) && !(actual & ENABLE_ECHO_INPUT);
#else
  if (tcgetattr(guard->fd, &guard->saved) < 0) return 0;
  struct termios mode = guard->saved;
  tcflag_t echo = ECHO | ECHONL | ECHOE | ECHOK;
#ifdef ECHOCTL
  echo |= ECHOCTL;
#endif
#ifdef ECHOPRT
  echo |= ECHOPRT;
#endif
#ifdef ECHOKE
  echo |= ECHOKE;
#endif
  mode.c_lflag = (mode.c_lflag | ICANON | ISIG) & ~echo;
  guard->active = 1;
  int result;
  do { result = tcsetattr(guard->fd, TCSAFLUSH, &mode); }
  while (result < 0 && errno == EINTR);
  if (result < 0) return 0;
  struct termios actual;
  return tcgetattr(guard->fd, &actual) == 0 && !(actual.c_lflag & echo);
#endif
}

MOONBIT_FFI_EXPORT
int32_t cetas_auth_mode_restore(auth_mode *guard) {
  return restore_mode(guard);
}

MOONBIT_FFI_EXPORT
void cetas_auth_mode_close(auth_mode *guard) {
  close_mode(guard);
}

/* Windows input and output consoles are separate devices. */
MOONBIT_FFI_EXPORT
moonbit_string_t cetas_auth_input_path(void) {
  const char *path = cetas_auth_terminal_path();
  int len = (int)strlen(path);
  moonbit_string_t result = moonbit_make_string(len, 0);
  for (int i = 0; i < len; i++) result[i] = (unsigned char)path[i];
  return result;
}

#include "terminal_auth_test_fixture.h"
