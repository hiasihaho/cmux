// Probe: how does WebKitGTK's WebKitWebView::create actually behave?
// Written before implementing popup routing, because the Web Inspector
// increment taught that an API's shape is not what its docs read like.
//
//   gcc linux/tests/popup-probe.c -o /tmp/popup-probe \
//       $(pkg-config --cflags --libs gtk4 webkitgtk-6.0) && /tmp/popup-probe
//
// Questions it answers:
//   1. Does `create` fire for window.open() without a user gesture?
//   2. Does it fire for a target="_blank" link click?
//   3. Is the navigation action's URI available in the handler?
//   4. Does WebKit load the URL into the view we return, or must we?
//   5. Does `ready-to-show` fire, and when?
//   6. What does returning NULL do?
#include <gtk/gtk.h>
#include <webkit/webkit.h>

static int created = 0;
static int block_next = 0;   // second half of the run returns NULL

static const char *PAGE =
    "<!doctype html><title>opener</title><body>"
    "<a id='lnk' href='https://example.com/from-link' target='_blank'>link</a>"
    "<script>"
    "  window.addEventListener('load', function () {"
    "    setTimeout(function () {"
    "      var w = window.open('https://example.com/from-script', '_blank');"
    "      console.log('window.open returned: ' + (w ? 'a window' : 'null'));"
    "      setTimeout(function () { document.getElementById('lnk').click(); }, 900);"
    "    }, 400);"
    "  });"
    "</script></body>";

static void on_ready_to_show(WebKitWebView *v, gpointer d) {
    const char *uri = webkit_web_view_get_uri(v);
    g_print("  [ready-to-show] view=%p uri=%s\n", (void *)v, uri ? uri : "(null)");
}

static void on_close(WebKitWebView *v, gpointer d) {
    g_print("  [close] view=%p\n", (void *)v);
}

static GtkWidget *on_create(WebKitWebView *parent,
                            WebKitNavigationAction *action,
                            gpointer user_data) {
    created++;
    WebKitURIRequest *req = webkit_navigation_action_get_request(action);
    g_print("[create #%d] uri=%s  is_user_gesture=%d  nav_type=%d\n",
            created,
            req ? webkit_uri_request_get_uri(req) : "(no request)",
            webkit_navigation_action_is_user_gesture(action),
            webkit_navigation_action_get_navigation_type(action));

    if (block_next) {
        g_print("  -> returning NULL (blocking)\n");
        return NULL;
    }

    // WebKitGTK 6.0 dropped webkit_web_view_new_with_related_view(); the
    // relationship is a CONSTRUCT-ONLY "related-view" property, so it can
    // only be set through g_object_new. Sharing the web process is what
    // keeps window.opener working.
    GtkWidget *v = GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                           "related-view", parent, NULL));
    g_print("  -> returned related view %p (uri now: %s)\n",
            (void *)v, webkit_web_view_get_uri(WEBKIT_WEB_VIEW(v))
                       ? webkit_web_view_get_uri(WEBKIT_WEB_VIEW(v)) : "(null)");
    g_signal_connect(v, "ready-to-show", G_CALLBACK(on_ready_to_show), NULL);
    g_signal_connect(v, "close", G_CALLBACK(on_close), NULL);
    // Deliberately do NOT load anything: question 4 is whether WebKit does.
    return v;
}

static gboolean phase2(gpointer data) {
    g_print("\n--- phase 2: same page, handler now returns NULL ---\n");
    block_next = 1;
    webkit_web_view_load_html(WEBKIT_WEB_VIEW(data), PAGE, "https://example.com/");
    return G_SOURCE_REMOVE;
}

static gboolean finish(gpointer data) {
    g_print("\ntotal create signals: %d\n", created);
    exit(0);
}

static void activate(GtkApplication *app, gpointer d) {
    GtkWidget *win = gtk_application_window_new(app);
    GtkWidget *wv = webkit_web_view_new();
    gtk_window_set_child(GTK_WINDOW(win), wv);
    gtk_window_set_default_size(GTK_WINDOW(win), 900, 600);
    WebKitSettings *st = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(wv));
    // Both default to FALSE. The first gates scripted window.open entirely
    // (no `create` signal at all, silently); the second just lets us see
    // what the page logged.
    g_print("defaults: js_can_open_windows=%d\n",
            webkit_settings_get_javascript_can_open_windows_automatically(st));
    webkit_settings_set_javascript_can_open_windows_automatically(st, TRUE);
    webkit_settings_set_enable_write_console_messages_to_stdout(st, TRUE);
    g_signal_connect(wv, "create", G_CALLBACK(on_create), NULL);
    gtk_widget_set_visible(win, TRUE);
    webkit_web_view_load_html(WEBKIT_WEB_VIEW(wv), PAGE, "https://example.com/");
    g_timeout_add(4000, phase2, wv);
    g_timeout_add(8000, finish, NULL);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("com.manaflow.cmux.popupprobe",
                                              G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    return g_application_run(G_APPLICATION(app), argc, argv);
}
