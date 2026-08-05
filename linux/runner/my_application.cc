#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <unistd.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

namespace {

const gchar kStatusNotifierXml[] =
    "<node>"
    "<interface name='org.kde.StatusNotifierItem'>"
    "<property name='Category' type='s' access='read'/>"
    "<property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='WindowId' type='u' access='read'/>"
    "<property name='IconName' type='s' access='read'/>"
    "<property name='IconPixmap' type='a(iiay)' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/>"
    "<property name='Menu' type='o' access='read'/>"
    "<method name='Activate'><arg name='x' type='i' direction='in'/>"
    "<arg name='y' type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg name='x' type='i' direction='in'/>"
    "<arg name='y' type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg name='x' type='i' direction='in'/>"
    "<arg name='y' type='i' direction='in'/></method>"
    "<signal name='NewIcon'/><signal name='NewTitle'/><signal name='NewToolTip'/>"
    "</interface>"
    "</node>";

struct TrayIndicator {
  GtkWindow* window = nullptr;
  GdkPixbuf* icon = nullptr;
  GDBusConnection* connection = nullptr;
  gchar* service_name = nullptr;
  guint object_registration_id = 0;
  guint name_owner_id = 0;
};

GVariant* empty_icon_pixmaps() {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a(iiay)"));
  return g_variant_builder_end(&builder);
}

GVariant* tray_icon_pixmaps(GdkPixbuf* pixbuf) {
  if (pixbuf == nullptr) return empty_icon_pixmaps();

  const gint width = gdk_pixbuf_get_width(pixbuf);
  const gint height = gdk_pixbuf_get_height(pixbuf);
  const gint rowstride = gdk_pixbuf_get_rowstride(pixbuf);
  const gint channels = gdk_pixbuf_get_n_channels(pixbuf);
  const gboolean has_alpha = gdk_pixbuf_get_has_alpha(pixbuf);
  const guchar* source = gdk_pixbuf_get_pixels(pixbuf);
  g_autofree guchar* pixels =
      static_cast<guchar*>(g_malloc(static_cast<gsize>(width) * height * 4));

  gsize offset = 0;
  for (gint row = 0; row < height; ++row) {
    const guchar* cursor = source + row * rowstride;
    for (gint column = 0; column < width; ++column) {
      pixels[offset++] = has_alpha ? cursor[3] : 255;
      pixels[offset++] = cursor[0];
      pixels[offset++] = cursor[1];
      pixels[offset++] = cursor[2];
      cursor += channels;
    }
  }

  GVariantBuilder array;
  g_variant_builder_init(&array, G_VARIANT_TYPE("a(iiay)"));
  GVariantBuilder entry;
  g_variant_builder_init(&entry, G_VARIANT_TYPE("(iiay)"));
  g_variant_builder_add(&entry, "i", width);
  g_variant_builder_add(&entry, "i", height);
  g_variant_builder_add_value(
      &entry,
      g_variant_new_fixed_array(
          G_VARIANT_TYPE_BYTE, pixels, static_cast<gsize>(width) * height * 4, sizeof(guchar)));
  g_variant_builder_add_value(&array, g_variant_builder_end(&entry));
  return g_variant_builder_end(&array);
}

void show_tray_window(TrayIndicator* tray) {
  if (tray == nullptr || tray->window == nullptr) return;
  gtk_window_deiconify(tray->window);
  gtk_widget_show(GTK_WIDGET(tray->window));
  gtk_window_present(tray->window);
}

void on_tray_method_call(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                         const gchar* method_name, GVariant*,
                         GDBusMethodInvocation* invocation, gpointer user_data) {
  auto* tray = static_cast<TrayIndicator*>(user_data);
  if (g_strcmp0(method_name, "Activate") == 0 ||
      g_strcmp0(method_name, "SecondaryActivate") == 0) {
    show_tray_window(tray);
  }
  g_dbus_method_invocation_return_value(invocation, nullptr);
}

GVariant* on_tray_property_get(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                               const gchar* property_name, GError** error,
                               gpointer user_data) {
  auto* tray = static_cast<TrayIndicator*>(user_data);
  if (g_strcmp0(property_name, "Category") == 0) {
    return g_variant_new_string("ApplicationStatus");
  }
  if (g_strcmp0(property_name, "Id") == 0) {
    return g_variant_new_string("trading-challenge");
  }
  if (g_strcmp0(property_name, "Title") == 0) {
    return g_variant_new_string("Trading Challenge");
  }
  if (g_strcmp0(property_name, "Status") == 0) {
    return g_variant_new_string("Active");
  }
  if (g_strcmp0(property_name, "WindowId") == 0) {
    return g_variant_new_uint32(0);
  }
  if (g_strcmp0(property_name, "IconName") == 0) {
    return g_variant_new_string("");
  }
  if (g_strcmp0(property_name, "IconPixmap") == 0) {
    return tray_icon_pixmaps(tray == nullptr ? nullptr : tray->icon);
  }
  if (g_strcmp0(property_name, "ToolTip") == 0) {
    return g_variant_new("(s@a(iiay)ss)", "", empty_icon_pixmaps(),
                         "Trading Challenge", "Telegram WEEX copy-trader");
  }
  if (g_strcmp0(property_name, "ItemIsMenu") == 0) {
    return g_variant_new_boolean(FALSE);
  }
  if (g_strcmp0(property_name, "Menu") == 0) {
    return g_variant_new_object_path("/");
  }

  *error = g_error_new(G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
                       "Unknown property: %s", property_name);
  return nullptr;
}

void register_tray_with_watcher(GDBusConnection* connection, const gchar* service_name) {
  constexpr const gchar* watchers[] = {
      "org.kde.StatusNotifierWatcher",
      "com.canonical.StatusNotifierWatcher",
      nullptr,
  };
  for (const gchar* const* watcher = watchers; *watcher != nullptr; ++watcher) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
        connection, *watcher, "/StatusNotifierWatcher", *watcher,
        "RegisterStatusNotifierItem", g_variant_new("(s)", service_name), nullptr,
        G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
    if (reply != nullptr) return;
  }
  g_warning("No StatusNotifier watcher is available; the tray icon may be hidden.");
}

void on_tray_name_acquired(GDBusConnection* connection, const gchar* name, gpointer) {
  register_tray_with_watcher(connection, name);
}

TrayIndicator* create_tray_indicator(GtkWindow* window) {
  g_autoptr(GError) error = nullptr;
  GDBusConnection* connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (connection == nullptr) {
    g_warning("Could not create a system tray connection: %s",
              error == nullptr ? "unknown error" : error->message);
    return nullptr;
  }

  g_autoptr(GDBusNodeInfo) node_info =
      g_dbus_node_info_new_for_xml(kStatusNotifierXml, &error);
  if (node_info == nullptr) {
    g_warning("Could not create the system tray interface: %s",
              error == nullptr ? "unknown error" : error->message);
    g_object_unref(connection);
    return nullptr;
  }

  auto* tray = new TrayIndicator();
  tray->window = window;
  tray->connection = connection;
  tray->service_name = g_strdup_printf(
      "org.kde.StatusNotifierItem-%d-tradingchallenge", static_cast<gint>(getpid()));

  g_autofree gchar* executable_path = g_file_read_link("/proc/self/exe", nullptr);
  if (executable_path != nullptr) {
    g_autofree gchar* bundle_dir = g_path_get_dirname(executable_path);
    g_autofree gchar* icon_path = g_build_filename(
        bundle_dir, "data", "flutter_assets", "assets", "app-logo.jpg", nullptr);
    tray->icon = gdk_pixbuf_new_from_file(icon_path, nullptr);
  }

  static const GDBusInterfaceVTable vtable = {
      &on_tray_method_call,
      &on_tray_property_get,
      nullptr,
  };
  GDBusInterfaceInfo* interface = g_dbus_node_info_lookup_interface(
      node_info, "org.kde.StatusNotifierItem");
  tray->object_registration_id = g_dbus_connection_register_object(
      connection, "/StatusNotifierItem", interface, &vtable, tray, nullptr, &error);
  if (tray->object_registration_id == 0) {
    g_warning("Could not register the system tray icon: %s",
              error == nullptr ? "unknown error" : error->message);
    if (tray->icon != nullptr) g_object_unref(tray->icon);
    g_free(tray->service_name);
    g_object_unref(connection);
    delete tray;
    return nullptr;
  }

  tray->name_owner_id = g_bus_own_name_on_connection(
      connection, tray->service_name, G_BUS_NAME_OWNER_FLAGS_NONE,
      &on_tray_name_acquired, nullptr, tray, nullptr);
  return tray;
}

void destroy_tray_indicator(TrayIndicator* tray) {
  if (tray == nullptr) return;
  if (tray->name_owner_id != 0) g_bus_unown_name(tray->name_owner_id);
  if (tray->connection != nullptr && tray->object_registration_id != 0) {
    g_dbus_connection_unregister_object(tray->connection, tray->object_registration_id);
  }
  if (tray->icon != nullptr) g_object_unref(tray->icon);
  if (tray->connection != nullptr) g_object_unref(tray->connection);
  g_free(tray->service_name);
  delete tray;
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  TrayIndicator* tray_indicator;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    gtk_window_deiconify(self->window);
    gtk_widget_show(GTK_WIDGET(self->window));
    gtk_window_present(self->window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "trading_challenge");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "trading_challenge");
  }

  gtk_window_set_default_size(window, 1280, 720);

  // Taskbar/dock icon setup like operator-control
  gtk_window_set_icon_name(window, "com.atomicvoid.tradingchallenge");
  {
    g_autofree gchar* self_path = g_file_read_link("/proc/self/exe", nullptr);
    if (self_path != nullptr) {
      g_autofree gchar* bundle_dir = g_path_get_dirname(self_path);
      g_autofree gchar* icon_path = g_build_filename(
          bundle_dir, "data", "flutter_assets", "assets", "app-logo.jpg", nullptr);
      if (g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
        gtk_window_set_icon_from_file(window, icon_path, nullptr);
      }
    }
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
  self->tray_indicator = create_tray_indicator(window);
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  destroy_tray_indicator(self->tray_indicator);
  self->tray_indicator = nullptr;
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->window = nullptr;
  self->tray_indicator = nullptr;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_DEFAULT_FLAGS, nullptr));
}
