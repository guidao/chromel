// Test-only probe: detect NSApp.run invoked from a CEF pump call.
// Loaded into disposable GUI tests only, never into production Emacs.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <emacs-module.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <cstring>

extern "C" { int plugin_is_GPL_compatible; }
namespace {
IMP originalRun;
bool armed = false;
int nestedRuns = 0;
void observedRun(id self, SEL cmd) {
  if (armed) {
    // Emacs may process pending signals between the native return and the
    // Lisp advice's cleanup.  Count only a real native pump on the stack,
    // not normal ns_read_socket_1 calls in that gap.
    void* frames[128];
    const int count = backtrace(frames, 128);
    for (int i = 0; i < count; ++i) {
      Dl_info info{};
      if (dladdr(frames[i], &info) && info.dli_sname &&
          std::strcmp(info.dli_sname, "_ZN7chromel4pumpEv") == 0) {
        ++nestedRuns;
        break;
      }
    }
  }
  reinterpret_cast<void (*)(id, SEL)>(originalRun)(self, cmd);
}
emacs_value probe(emacs_env* env, ptrdiff_t, emacs_value* args, void*) noexcept {
  armed = env->is_not_nil(env, args[0]);
  return env->make_integer(env, nestedRuns);
}
}
extern "C" int emacs_module_init(emacs_runtime* runtime) noexcept {
  Class appClass = object_getClass(NSApp);
  Method method = class_getInstanceMethod(appClass, @selector(run));
  originalRun = method_getImplementation(method);
  if (!class_addMethod(appClass, @selector(run), (IMP)observedRun, method_getTypeEncoding(method)))
    method_setImplementation(method, (IMP)observedRun);
  emacs_env* env = runtime->get_environment(runtime);
  emacs_value args[] = {env->intern(env, "chromel-test-pump-probe"),
    env->make_function(env, 1, 1, probe,
      "Arm with non-nil; disarm with nil. Return cumulative NSApp.run count while armed.", nullptr)};
  env->funcall(env, env->intern(env, "fset"), 2, args);
  return 0;
}
