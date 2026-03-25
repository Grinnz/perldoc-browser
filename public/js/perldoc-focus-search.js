document.addEventListener('keydown', function (event) {
  if ((event.key === 's' || event.key === 'S')
      && !event.ctrlKey && !event.altKey && !event.metaKey
      && document.activeElement.tagName.toLowerCase() !== 'input') {
    var searchinput = document.getElementById('search-input');
    searchinput.focus();
    searchinput.select();
    event.preventDefault();
  }
});
