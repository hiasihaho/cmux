#pragma once
// GTK first so this module carries the full GTK/GObject API for the
// Ghostty-bound Swift file (cross-module GTK types don't unify; each
// C-importing file sticks to one module's view, like CVte/CWebKit).
#include <gtk/gtk.h>
#include <ghostty_gtk_embed.h>
