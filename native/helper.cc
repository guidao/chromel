// SPDX-License-Identifier: GPL-3.0-or-later
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/cef_process_message.h"
#include "include/cef_v8.h"
#include "include/cef_dom.h"
#include "web_scripts.h"

namespace {
// Only the browser process can request evaluation.  No native API is exposed
// to page JavaScript, and replies are data, never Lisp code.
class RendererApp final : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                        CefRefPtr<CefV8Context> context) override {
    if (!context->Enter()) return;
    CefRefPtr<CefV8Value> result;
    CefRefPtr<CefV8Exception> exception;
    context->Eval(kWebScrollBootstrap, "", 1, result, exception);
    context->Exit();
  }
  void OnFocusedNodeChanged(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefDOMNode> node) override {
    if (!frame) return;
    const auto tag = node && node->IsElement() ? node->GetElementTagName().ToString() : "";
    auto message = CefProcessMessage::Create("web.input-focus");
    message->GetArgumentList()->SetBool(0, node &&
      (node->IsEditable() || tag == "SELECT" || tag == "INPUT" || tag == "TEXTAREA" ||
       tag == "EMBED" || tag == "OBJECT"));
    frame->SendProcessMessage(PID_BROWSER, message);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    if (source != PID_BROWSER || message->GetName() != "web.eval" || !frame->IsMain())
      return false;
    auto input = message->GetArgumentList();
    auto reply = CefProcessMessage::Create("web.eval.result");
    auto output = reply->GetArgumentList();
    output->SetString(0, input->GetString(0));
    output->SetBool(1, false);
    output->SetString(2, "Page JavaScript context is not ready");
    auto context = frame->GetV8Context();
    if (context && context->Enter()) {
      CefRefPtr<CefV8Value> value;
      CefRefPtr<CefV8Exception> exception;
      const bool ok = context->Eval(input->GetString(1), "", 1, value, exception);
      if (ok && value && value->IsString()) {
        output->SetBool(1, true);
        output->SetString(2, value->GetStringValue());
      } else {
        output->SetString(2, exception ? exception->GetMessage() : CefString("Expected a JSON string result"));
      }
      context->Exit();
    }
    frame->SendProcessMessage(PID_BROWSER, reply);
    return true;
  }
 private:
  IMPLEMENT_REFCOUNTING(RendererApp);
};
}

int main(int argc, char** argv) {
  // The sandbox must be initialized before the Chromium framework is loaded.
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 2;
  return CefExecuteProcess(CefMainArgs(argc, argv), new RendererApp, nullptr);
}
