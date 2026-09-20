function get_perldoc_theme() {
  var theme = document.documentElement.getAttribute('data-bs-theme');
  if (theme === null) {
    return 'light';
  } else {
    return theme;
  }
}

function set_perldoc_theme(mode) {
  if (mode == 'dark') {
    document.documentElement.setAttribute('data-bs-theme', 'dark');
    document.getElementById('stylesheet-perldoc').setAttribute('href', '/css/perldoc-dark.css');
    document.getElementById('stylesheet-highlight').setAttribute('href', '/css/stackoverflow-dark.min.css');
  } else {
    document.documentElement.setAttribute('data-bs-theme', 'light');
    document.getElementById('stylesheet-perldoc').setAttribute('href', '/css/perldoc-light.css');
    document.getElementById('stylesheet-highlight').setAttribute('href', '/css/stackoverflow-light.min.css');
  }
}

function set_perldoc_theme_button() {
  document.getElementById('perldoc-theme-button').textContent = get_perldoc_theme() == 'dark' ? 'Light' : 'Dark';
}

function set_perldoc_theme_cookie() {
  document.cookie = 'perldoc_theme=' + get_perldoc_theme() + '; path=/; max-age=31536000; samesite=Lax';
}

function prefers_dark_mode() {
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function toggle_dark_mode() {
  var new_theme = get_perldoc_theme() == 'dark' ? 'light' : 'dark';
  set_perldoc_theme(new_theme);
  set_perldoc_theme_button();
  set_perldoc_theme_cookie();
}

function read_preferred_theme() {
  if (document.cookie.split(';').some(function (item) { return item.indexOf('perldoc_theme=dark') >= 0 })) {
    return 'dark';
  } else if (document.cookie.split(';').some(function (item) { return item.indexOf('perldoc_theme=light') >= 0 })) {
    return 'light';
  } else {
    return prefers_dark_mode() ? 'dark' : 'light';
  }
}

set_perldoc_theme(read_preferred_theme());

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', function () {
    set_perldoc_theme_button();
    document.getElementById('perldoc-theme-button').addEventListener('click', toggle_dark_mode);
  });
} else {
  set_perldoc_theme_button();
  document.getElementById('perldoc-theme-button').addEventListener('click', toggle_dark_mode);
}
