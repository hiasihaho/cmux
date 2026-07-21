// Probe: what is webkit_web_inspector_get_web_view() actually, and when
// does it become available? Determines whether the cmux surface factory
// can treat an adopted inspector view as a WebKitWebView.
#include <gtk/gtk.h>
#include <webkit/webkit.h>

static WebKitWebInspector *inspector;
static int ticks = 0;

static void report(const char *when) {
    WebKitWebViewBase *v = webkit_web_inspector_get_web_view(inspector);
    g_print("[%s] get_web_view=%p", when, (void *)v);
    if (v) {
        g_print("  type=%s  IS_WEB_VIEW=%d  IS_WIDGET=%d  parent=%p",
                G_OBJECT_TYPE_NAME(v),
                WEBKIT_IS_WEB_VIEW(v),
                GTK_IS_WIDGET(v),
                (void *)gtk_widget_get_parent(GTK_WIDGET(v)));
    }
    g_print("  attached=%d can_attach=%d\n",
            webkit_web_inspector_is_attached(inspector),
            webkit_web_inspector_get_can_attach(inspector));
}

static gboolean on_attach(WebKitWebInspector *i, gpointer d) {
    report("attach signal");
    return TRUE;   // claim we handle placement ourselves
}

static gboolean on_open_window(WebKitWebInspector *i, gpointer d) {
    report("open-window signal");
    return TRUE;   // suppress the separate window
}

static gboolean tick(gpointer data) {
    ticks++;
    report(ticks == 1 ? "after show()" : "later");
    if (ticks >= 3) { g_print("done\n"); exit(0); }
    return G_SOURCE_CONTINUE;
}

static void activate(GtkApplication *app, gpointer d) {
    GtkWidget *win = gtk_application_window_new(app);
    GtkWidget *wv = webkit_web_view_new();
    gtk_window_set_child(GTK_WINDOW(win), wv);
    gtk_window_set_default_size(GTK_WINDOW(win), 800, 600);

    WebKitSettings *s = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(wv));
    webkit_settings_set_enable_developer_extras(s, TRUE);
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(wv), "about:blank");

    inspector = webkit_web_view_get_inspector(WEBKIT_WEB_VIEW(wv));
    g_print("inspector=%p\n", (void *)inspector);
    g_signal_connect(inspector, "attach", G_CALLBACK(on_attach), NULL);
    g_signal_connect(inspector, "open-window", G_CALLBACK(on_open_window), NULL);

    report("before show()");
    gtk_widget_set_visible(win, TRUE);
    webkit_web_inspector_show(inspector);
    g_timeout_add(700, tick, NULL);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("com.manaflow.cmux.inspprobe", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    return g_application_run(G_APPLICATION(app), argc, argv);
}
