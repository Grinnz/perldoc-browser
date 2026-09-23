function set_expand (expand) {
  var perldocdiv = document.getElementById('perldocdiv');
  var expanded = perldocdiv.classList.contains('wide') ? true : false;
  if (expand === null) {
    expand = !expanded;
  }
  if ((expand && !expanded) || (!expand && expanded)) {
    var div_classlist = perldocdiv.classList;
    var button_classlist = document.getElementById('content-expand-button').classList;
    if (expand) {
      div_classlist.add('wide');
      button_classlist.add('btn-secondary');
      button_classlist.remove('btn-dark');
    } else {
      div_classlist.remove('wide');
      button_classlist.add('btn-dark');
      button_classlist.remove('btn-secondary');
    }
  }
  return expand;
}

function toggle_expand () {
  var expand = set_expand(null);
  document.cookie = 'perldoc_expand=' + (expand ? 1 : 0) + '; path=/; max-age=31536000; samesite=Lax';
}

function read_expand () {
  return document.cookie.split(';').some(function (item) { return item.indexOf('perldoc_expand=1') >= 0 });
}

// must be done in JS as pages are cached independently of user preference
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', function () {
    if (read_expand()) {
      set_expand(true);
    }
    document.getElementById('content-expand-button').addEventListener('click', toggle_expand);
  });
} else {
  if (read_expand()) {
    set_expand(true);
  }
  document.getElementById('content-expand-button').addEventListener('click', toggle_expand);
}
