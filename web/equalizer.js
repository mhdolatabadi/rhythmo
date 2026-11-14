'use strict';

// The web equalizer (#224). just_audio plays through audio elements it
// never puts in the page, so the elements are picked up as they start
// playing. Until the listener turns the equalizer on, nothing is touched
// and the browser plays the file as it is. Once on, each audio element of
// this origin is routed through Web Audio: one shelf or peaking filter per
// band and a gain that leaves headroom for boosted bands. Media from
// another origin is never routed, as the browser would play it silent.
(function () {
  var Context = window.AudioContext || window.webkitAudioContext;
  if (!Context || !window.HTMLMediaElement || !window.MediaElementAudioSourceNode) return;

  var context = null;
  var filters = [];
  var output = null;
  var wanted = null;
  var known = [];
  var routed = typeof WeakSet === 'function' ? new WeakSet() : null;

  function sameOrigin(element) {
    var src = element.currentSrc || element.src;
    if (!src) return false;
    if (src.indexOf('blob:') === 0) return true;
    try {
      return new URL(src, location.href).origin === location.origin;
    } catch (_) {
      return false;
    }
  }

  function ensureGraph(frequencies) {
    if (context && filters.length === frequencies.length) return;
    context = context || new Context();
    output = output || context.createGain();
    output.connect(context.destination);
    filters = frequencies.map(function (frequency, index) {
      var filter = context.createBiquadFilter();
      filter.type = index === 0 ? 'lowshelf'
        : index === frequencies.length - 1 ? 'highshelf' : 'peaking';
      filter.frequency.value = frequency;
      filter.Q.value = 1;
      return filter;
    });
    for (var i = 0; i < filters.length - 1; i++) filters[i].connect(filters[i + 1]);
    filters[filters.length - 1].connect(output);
  }

  function route(element) {
    if (!wanted || !routed || routed.has(element) || !sameOrigin(element)) return;
    try {
      context.createMediaElementSource(element).connect(filters[0]);
      routed.add(element);
    } catch (error) {
      console.warn('Equalizer could not take this audio:', error);
    }
  }

  var play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    if (this instanceof HTMLAudioElement) {
      if (known.indexOf(this) < 0) known.push(this);
      if (wanted) {
        route(this);
        if (context.state === 'suspended') context.resume();
      }
    }
    return play.apply(this, arguments);
  };

  window.rhythmoEqualizer = {
    // gains in dB at frequencies in Hz; headroom in dB turned down overall.
    set: function (frequencies, gains, headroomDb) {
      ensureGraph(frequencies);
      wanted = true;
      for (var i = 0; i < filters.length; i++) filters[i].gain.value = gains[i] || 0;
      output.gain.value = Math.pow(10, -(headroomDb || 0) / 20);
      for (var j = 0; j < known.length; j++) route(known[j]);
      if (context.state === 'suspended') context.resume();
    },
    // Flat again. Elements already routed stay routed, at unity gain.
    off: function () {
      wanted = null;
      for (var i = 0; i < filters.length; i++) filters[i].gain.value = 0;
      if (output) output.gain.value = 1;
    },
  };
})();
