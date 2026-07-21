#pragma once
#include <webkit/webkit.h>

// WebKitGTK 6.0 exports the automation entry points and documents them in
// its introspection data (WebKit-6.0.gir: set_automation_allowed,
// is_automation_allowed, WebKitWebContext::automation-started), but
// Fedora's installed C headers omit these two functions. Declare them so
// the WebDriver opt-in links against the real, already-exported symbols.
WEBKIT_API void webkit_web_context_set_automation_allowed(WebKitWebContext *context,
                                                          gboolean allowed);
WEBKIT_API gboolean webkit_web_context_is_automation_allowed(WebKitWebContext *context);
