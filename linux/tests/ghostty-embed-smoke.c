// Smoke test for the Ghostty GTK embedding shim (ghostty branch
// linux-gtk-embed): host a live Ghostty terminal surface inside a plain
// foreign GtkApplication — the same situation cmux-adw is in.
//
// Build + run:
//   cd ghostty && zig build lib-gtk -Dapp-runtime=gtk -Dversion-string=1.3.0-dev
//   gcc -o /tmp/ghostty-embed-smoke linux/tests/ghostty-embed-smoke.c \
//       $(pkg-config --cflags --libs gtk4) \
//       -Ighostty/zig-out/include -Lghostty/zig-out/lib \
//       -lghostty-gtk -Wl,-rpath,$PWD/ghostty/zig-out/lib
//   /tmp/ghostty-embed-smoke
//
// Exit criteria (increment 1): window shows a shell prompt, typing works,
// title property updates (printed to stdout), closing the window exits
// cleanly.

#include <gtk/gtk.h>
#include <ghostty_gtk_embed.h>

static void on_title_changed(GObject *obj, GParamSpec *pspec, gpointer data) {
    char *title = NULL;
    g_object_get(obj, "title", &title, NULL);
    g_print("smoke: title changed: %s\n", title ? title : "(null)");
    g_free(title);
}

static void activate(GtkApplication *app, gpointer user_data) {
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "ghostty embed smoke");
    gtk_window_set_default_size(GTK_WINDOW(window), 900, 600);

    if (ghostty_embed_init() != 0) {
        g_printerr("smoke: ghostty_embed_init failed\n");
        gtk_window_present(GTK_WINDOW(window));
        return;
    }
    g_print("smoke: ghostty_embed_init ok\n");

    // Exercise per-surface overrides: cwd lands in the shell prompt/title
    // (verifiable from the notify::title print), env var checkable by hand.
    const char *env_keys[] = {"SMOKE_TEST_VAR"};
    const char *env_values[] = {"it-works"};
    GtkWidget *surface = ghostty_embed_surface_new("/tmp", env_keys, env_values, 1);
    if (surface == NULL) {
        g_printerr("smoke: ghostty_embed_surface_new failed\n");
        gtk_window_present(GTK_WINDOW(window));
        return;
    }
    g_print("smoke: surface widget created: %s\n", G_OBJECT_TYPE_NAME(surface));

    g_signal_connect(surface, "notify::title", G_CALLBACK(on_title_changed), NULL);

    gtk_window_set_child(GTK_WINDOW(window), surface);
    gtk_window_present(GTK_WINDOW(window));
    gtk_widget_grab_focus(surface);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new(
        "com.manaflow.cmux.ghostty-smoke", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
