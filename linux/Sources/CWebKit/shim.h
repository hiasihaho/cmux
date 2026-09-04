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

// GUnixFDList lives in gio-unix's gunixfdlist.h, which plain gio.h does
// not include — but the TYPE is forward-declared by giotypes.h and the
// symbols live in the libgio every GTK app already links. Declared here
// (same treatment as the WebKit symbols above) for the Secret-portal
// key backend: RetrieveSecret passes a pipe fd over D-Bus, and the call
// must ride the APP'S OWN bus connection — the portal ties the request
// lifetime to the caller's connection, so a subprocess `gdbus call`
// that exits after the method reply gets its request closed before the
// secret is ever written (measured 2026-09-04, flatpak round).
GUnixFDList *g_unix_fd_list_new(void);
gint g_unix_fd_list_append(GUnixFDList *list, gint fd, GError **error);
