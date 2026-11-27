#include "oxcairo.h"
#include <stdio.h>
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/memory.h>

static int report(char *error, size_t size, const char *message) {
  if (error && size) snprintf(error, size, "%s", message);
  return *message != '\0';
}

int oxcairo_replay_v1(const char *input, const char *layout, const char *trace,
                      const char *memory, const char *output, char *error, size_t size) {
  if (!input || !*input) return report(error, size, "missing input PIE path");
  static const value *callback;
  if (!callback) {
    static char name[] = "oxcairo";
    static char *argv[] = {name, NULL};
    caml_startup(argv);
    callback = caml_named_value("oxcairo.replay.v1");
    if (!callback) return report(error, size, "missing OCaml replay callback");
  }

  CAMLparam0();
  CAMLlocalN(args, 5);
  CAMLlocal1(result);
  args[0] = caml_copy_string(input);
  args[1] = caml_copy_string(layout ? layout : "all_cairo");
  args[2] = caml_copy_string(trace ? trace : "");
  args[3] = caml_copy_string(memory ? memory : "");
  args[4] = caml_copy_string(output ? output : "");
  result = caml_callbackN_exn(*callback, 5, args);
  int status = report(error, size, Is_exception_result(result)
                                  ? "OCaml replay callback failed" : String_val(result));
  CAMLreturnT(int, status);
}
