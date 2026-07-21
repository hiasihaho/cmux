/* Sends WM_DELETE_WINDOW to a window — the polite close a WM ✕ performs.
   xdotool windowclose calls XDestroyWindow, which bypasses GTK's
   close-request entirely; this goes through it. */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: wmdelete <window-id>\n"); return 2; }
    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "no display\n"); return 2; }
    Window w = (Window)strtoul(argv[1], NULL, 0);
    XEvent e = {0};
    e.xclient.type = ClientMessage;
    e.xclient.window = w;
    e.xclient.message_type = XInternAtom(d, "WM_PROTOCOLS", True);
    e.xclient.format = 32;
    e.xclient.data.l[0] = XInternAtom(d, "WM_DELETE_WINDOW", True);
    e.xclient.data.l[1] = CurrentTime;
    XSendEvent(d, w, False, NoEventMask, &e);
    XFlush(d);
    XCloseDisplay(d);
    return 0;
}
