// Read-only theme inputs for widgets shared by desktop and browser.
export 'workbench_colors.dart';
export 'render_theme_native.dart'
    if (dart.library.js_interop) 'render_theme_web.dart'
    show
        themeColors,
        renderThemeRevision,
        renderPebrelTheme,
        renderUsesWindowsFonts,
        renderWindowBlurEnabled;
