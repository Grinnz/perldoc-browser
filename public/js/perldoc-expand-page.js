function set_expand (expand) {
  var doc_classlist = document.documentElement.classList;
  var expanded = doc_classlist.contains('perldoc-wide') ? true : false;
  if (expand === null) {
    expand = !expanded;
  }
  if ((expand && !expanded) || (!expand && expanded)) {
    if (expand) {
      doc_classlist.add('perldoc-wide');
    } else {
      doc_classlist.remove('perldoc-wide');
    }
  }
  return expand;
}

function set_expand_button(expand) {
  var button_classlist = document.getElementById('content-expand-button').classList;
  if (expand === null) {
    expand = document.documentElement.classList.contains('perldoc-wide') ? true : false;
  }
  if (expand && button_classlist.contains('btn-dark')) {
    button_classlist.add('btn-secondary');
    button_classlist.remove('btn-dark');
  } else if (!expand && button_classlist.contains('btn-secondary')) {
    button_classlist.add('btn-dark');
    button_classlist.remove('btn-secondary');
  }
}

function toggle_expand () {
  var expand = set_expand(null);
  set_expand_button(expand);
  document.cookie = 'perldoc_expand=' + (expand ? 1 : 0) + '; path=/; max-age=31536000; samesite=Lax';
}

function setup_expand_button () {
  set_expand_button(null);
  document.getElementById('content-expand-button').addEventListener('click', toggle_expand);
}

function read_expand () {
  return document.cookie.split(';').some(function (item) { return item.indexOf('perldoc_expand=1') >= 0 });
}

// must be done in JS as pages are cached independently of user preference
// set immediately to reflect preference from cookie
// this runs in <head> after main document attribute
// button behavior must be set after document is loaded
if (read_expand()) {
  set_expand(true);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', function () {
    setup_expand_button();
  });
} else {
  setup_expand_button();
}
