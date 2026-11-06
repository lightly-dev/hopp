(function () {
  'use strict';

  function store(key, value) {
    try { localStorage.setItem(key, value); } catch (e) {}
  }

  // Theme toggle
  var root = document.documentElement;
  var toggle = document.getElementById('theme-toggle');
  function labelTheme() {
    var label = root.dataset.theme === 'light' ? toggle.dataset.labelDark : toggle.dataset.labelLight;
    toggle.setAttribute('aria-label', label);
    toggle.title = label;
  }
  labelTheme();
  toggle.addEventListener('click', function () {
    root.dataset.theme = root.dataset.theme === 'light' ? 'dark' : 'light';
    store('hopp-theme', root.dataset.theme);
    labelTheme();
  });

  // Language menu: remember the choice and close when clicking elsewhere
  var menu = document.querySelector('.lang-menu');
  menu.querySelectorAll('a[data-lang]').forEach(function (link) {
    link.addEventListener('click', function () { store('hopp-lang', link.dataset.lang); });
  });
  document.addEventListener('click', function (event) {
    if (menu.open && !menu.contains(event.target)) menu.open = false;
  });
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && menu.open) {
      menu.open = false;
      menu.querySelector('summary').focus();
    }
  });

  // Demo videos: play only while on screen
  var videos = Array.prototype.slice.call(document.querySelectorAll('video[data-demo]'));
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    videos.forEach(function (video) { video.pause(); video.controls = true; });
    return;
  }
  if (!('IntersectionObserver' in window)) return;
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        var playing = entry.target.play();
        if (playing && playing.catch) playing.catch(function () {});
      } else {
        entry.target.pause();
      }
    });
  }, { threshold: 0.25 });
  videos.forEach(function (video) { observer.observe(video); });
})();
