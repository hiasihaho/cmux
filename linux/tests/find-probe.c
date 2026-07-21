// Probe: WebKitFindController behaviour, before wiring find-in-page.
//
//   gcc linux/tests/find-probe.c -o /tmp/find-probe \
//       $(pkg-config --cflags --libs gtk4 webkitgtk-6.0) && /tmp/find-probe
//
// Questions:
//   1. Does search() highlight all matches or only the current one?
//   2. Does found-text carry a count, or is count_matches() separate?
//   3. Does counted-matches fire without an explicit count_matches() call?
//   4. Does search_next() past the end wrap only with WRAP_AROUND?
//   5. What does search_finish() do to the highlight?
//   6. Can search() be called on a view that is not in a window?
#include <gtk/gtk.h>
#include <webkit/webkit.h>

static WebKitFindController *fc;
static int step = 0;

static void on_found(WebKitFindController *c, guint count, gpointer d) {
    g_print("  [found-text] match_count_arg=%u  search_text=%s\n",
            count, webkit_find_controller_get_search_text(c));
}
static void on_failed(WebKitFindController *c, gpointer d) {
    g_print("  [failed-to-find-text] search_text=%s\n",
            webkit_find_controller_get_search_text(c));
}
static void on_counted(WebKitFindController *c, guint count, gpointer d) {
    g_print("  [counted-matches] count=%u\n", count);
}

static gboolean drive(gpointer data) {
    step++;
    switch (step) {
    case 1:
        g_print("1) search('needle') with WRAP_AROUND|CASE_INSENSITIVE\n");
        webkit_find_controller_search(fc, "needle",
            WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE | WEBKIT_FIND_OPTIONS_WRAP_AROUND, 100);
        break;
    case 2:
        g_print("2) count_matches('needle') — is it needed for a count?\n");
        webkit_find_controller_count_matches(fc, "needle",
            WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE, 100);
        break;
    case 3:
        g_print("3) search_next() x3 (only 3 needles exist — does it wrap?)\n");
        webkit_find_controller_search_next(fc);
        webkit_find_controller_search_next(fc);
        webkit_find_controller_search_next(fc);
        break;
    case 4:
        g_print("4) search('nomatch')\n");
        webkit_find_controller_search(fc, "nomatch",
            WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE, 100);
        break;
    case 5:
        g_print("5) search_finish()\n");
        webkit_find_controller_search_finish(fc);
        break;
    default:
        g_print("done\n");
        exit(0);
    }
    return G_SOURCE_CONTINUE;
}

static void activate(GtkApplication *app, gpointer d) {
    GtkWidget *win = gtk_application_window_new(app);
    GtkWidget *wv = webkit_web_view_new();
    gtk_window_set_child(GTK_WINDOW(win), wv);
    gtk_window_set_default_size(GTK_WINDOW(win), 800, 600);

    fc = webkit_web_view_get_find_controller(WEBKIT_WEB_VIEW(wv));
    g_signal_connect(fc, "found-text", G_CALLBACK(on_found), NULL);
    g_signal_connect(fc, "failed-to-find-text", G_CALLBACK(on_failed), NULL);
    g_signal_connect(fc, "counted-matches", G_CALLBACK(on_counted), NULL);

    webkit_web_view_load_html(WEBKIT_WEB_VIEW(wv),
        "<!doctype html><body>"
        "<p>first needle here</p><p>second NEEDLE here</p><p>third needle here</p>"
        "<p>nothing to see</p></body>", "https://example.com/");
    gtk_widget_set_visible(win, TRUE);
    g_timeout_add(1200, drive, NULL);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("com.manaflow.cmux.findprobe",
                                              G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    return g_application_run(G_APPLICATION(app), argc, argv);
}
