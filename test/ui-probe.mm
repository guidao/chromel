// Test-only Cocoa accessibility probe, loaded only by disposable GUI tests.
// Operates inside this process; does not automate the user's other applications.
#import <Cocoa/Cocoa.h>
#include <emacs-module.h>
#include <functional>
#include <cstdlib>
#include <cstring>
#include <vector>
extern "C" { int plugin_is_GPL_compatible; }
namespace {
emacs_value probe(emacs_env* env, ptrdiff_t, emacs_value* args, void*) noexcept {
  @autoreleasepool {
    ptrdiff_t size = 0;
    env->copy_string_contents(env, args[0], nullptr, &size);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) return env->intern(env, "nil");
    std::vector<char> label(size);
    env->copy_string_contents(env, args[0], label.data(), &size);
    NSString* target = [NSString stringWithUTF8String:label.data()];
    NSMutableArray* nodes = [NSMutableArray array];
    int visited = 0;
    bool pressed = false;
    std::function<void(id, int)> visit = [&](id element, int depth) {
      if (!element || depth > 20 || ++visited > 2000 || pressed) return;
      NSString* role = [element respondsToSelector:@selector(accessibilityRole)] ? [element accessibilityRole] : @"";
      NSString* name = [element respondsToSelector:@selector(accessibilityLabel)] ? [element accessibilityLabel] : @"";
      NSString* title = [element respondsToSelector:@selector(accessibilityTitle)] ? [element accessibilityTitle] : @"";
      if (name.length || title.length)
        [nodes addObject:@{@"role": role ?: @"", @"label": name ?: @"", @"title": title ?: @""}];
      if (target.length && [role isEqualToString:NSAccessibilityButtonRole] &&
          ([name isEqualToString:target] || [title isEqualToString:target])) {
        pressed = [element accessibilityPerformPress];
        return;
      }
      if ([element respondsToSelector:@selector(accessibilityChildren)])
        for (id child in [element accessibilityChildren]) visit(child, depth + 1);
    };
    for (NSWindow* window in NSApp.windows) visit(window, 0);
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"pressed": @(pressed), @"nodes": nodes} options:0 error:nil];
    return env->make_string(env, static_cast<const char*>(data.bytes), data.length);
  }
}
}
extern "C" int emacs_module_init(emacs_runtime* runtime) noexcept {
  const char* mode = getenv("CHROMEL_CEF_TEST_MODE");
  if (!mode || std::strcmp(mode, "1")) return 1;
  emacs_env* env = runtime->get_environment(runtime);
  emacs_value args[] = {env->intern(env, "chromel-test-ui-probe"),
    env->make_function(env, 1, 1, probe, "Inspect own process UI; press the named button, or inspect with empty string.", nullptr)};
  env->funcall(env, env->intern(env, "fset"), 2, args);
  return 0;
}
