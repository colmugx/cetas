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

typedef struct {
  auth_fd fd;
  int valid;
  int active;
#ifdef _WIN32
  DWORD saved;
#else
  struct termios saved;
#endif
} memoh_auth_mode;

static int memoh_restore_mode(memoh_auth_mode *guard) {
  if (!guard->active) return 1;
#ifdef _WIN32
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

static void memoh_close_mode(void *ptr) {
  memoh_auth_mode *guard = ptr;
  if (!guard->valid) return;
  memoh_restore_mode(guard);
#ifdef _WIN32
  CloseHandle(guard->fd);
#else
  close(guard->fd);
#endif
  guard->valid = 0;
}

MOONBIT_FFI_EXPORT
memoh_auth_mode *cetas_memoh_auth_mode_new(auth_fd fd) {
  memoh_auth_mode *guard =
    moonbit_make_external_object(memoh_close_mode, sizeof(memoh_auth_mode));
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
int32_t cetas_memoh_auth_mode_enter(memoh_auth_mode *guard) {
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
int32_t cetas_memoh_auth_mode_restore(memoh_auth_mode *guard) {
  return memoh_restore_mode(guard);
}

MOONBIT_FFI_EXPORT
void cetas_memoh_auth_mode_close(memoh_auth_mode *guard) {
  memoh_close_mode(guard);
}
