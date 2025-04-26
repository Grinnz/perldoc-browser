document.addEventListener('keydown', function (event) {
  if ((event.key === 's' || event.key === 'S')
      && !event.ctrlKey && !event.altKey && !event.metaKey
      && document.activeElement.tagName.toLowerCase() !== 'input') {
    document.getElementById('search-input').focus();
    event.preventDefault();
  }
});
