// One player for the public song lists (#377). The page works without it:
// every row keeps its own <audio> for crawlers and visitors without
// scripts. With it, the native controls are hidden, a single bar at the
// bottom plays the list in order, and only one song plays at a time.
(function () {
  "use strict";
  var rows = Array.prototype.slice.call(document.querySelectorAll("[data-track]"));
  if (!rows.length) return;
  var tracks = rows.map(function (row) {
    var audio = row.querySelector("audio");
    return {
      row: row,
      src: audio ? audio.getAttribute("src") : "",
      title: row.getAttribute("data-title") || "",
      artist: row.getAttribute("data-artist") || "",
      art: row.getAttribute("data-art") || ""
    };
  }).filter(function (t) { return t.src; });
  if (!tracks.length) return;
  document.documentElement.classList.add("js-player");

  var digits = "۰۱۲۳۴۵۶۷۸۹";
  function fa(n) { return String(n).replace(/[0-9]/g, function (d) { return digits[d]; }); }
  function clock(s) {
    if (!isFinite(s) || s < 0) s = 0;
    s = Math.floor(s);
    var m = Math.floor(s / 60), r = s % 60;
    return fa(m + ":" + (r < 10 ? "0" : "") + r);
  }
  function icon(path) {
    return '<svg class="icon" viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="' + path + '"/></svg>';
  }
  var PLAY = "M240,128a15.74,15.74,0,0,1-7.6,13.51L88.32,229.65a16,16,0,0,1-16.2.3A15.86,15.86,0,0,1,64,216.13V39.87a15.86,15.86,0,0,1,8.12-13.82,16,16,0,0,1,16.2.3L232.4,114.49A15.74,15.74,0,0,1,240,128Z";
  var PAUSE = "M216,48V208a16,16,0,0,1-16,16H160a16,16,0,0,1-16-16V48a16,16,0,0,1,16-16h40A16,16,0,0,1,216,48ZM96,32H56A16,16,0,0,0,40,48V208a16,16,0,0,0,16,16H96a16,16,0,0,0,16-16V48A16,16,0,0,0,96,32Z";
  // The page is right to left: "next" sits on the left and points left.
  var PREV = "M32,71.84V184.16c0,12.59,13.89,20.66,24.94,14.25L152,145.83V184a8,8,0,0,0,16,0V72a8,8,0,0,0-16,0v38.17L56.94,57.59C45.89,51.18,32,59.25,32,71.84Z";
  var NEXT = "M224,71.84V184.16c0,12.59-13.89,20.66-24.94,14.25L104,145.83V184a8,8,0,0,1-16,0V72a8,8,0,0,1,16,0v38.17l95.06-52.58C210.11,51.18,224,59.25,224,71.84Z";

  // Covers load lazily; a song without one keeps its placeholder.
  tracks.forEach(function (t) {
    if (!t.art) return;
    var box = t.row.querySelector(".art");
    if (!box) return;
    var img = new Image();
    img.alt = "";
    img.loading = "lazy";
    img.decoding = "async";
    img.addEventListener("load", function () { box.textContent = ""; box.appendChild(img); box.classList.add("has-cover"); });
    img.src = t.art;
  });

  var audio = new Audio();
  audio.preload = "none";
  var current = -1;

  var bar = document.createElement("div");
  bar.className = "bar";
  bar.setAttribute("role", "region");
  bar.setAttribute("aria-label", "پخش‌کننده");
  bar.hidden = true;
  bar.innerHTML =
    '<div class="wrap bar-inner">' +
    '<span class="grow"><span class="title" dir="auto"></span><span class="sub"><bdi></bdi></span></span>' +
    '<button type="button" class="icon-button" data-act="prev" aria-label="آهنگ قبلی">' + icon(PREV) + "</button>" +
    '<button type="button" class="icon-button play" data-act="toggle" aria-label="پخش">' + icon(PLAY) + "</button>" +
    '<button type="button" class="icon-button" data-act="next" aria-label="آهنگ بعدی">' + icon(NEXT) + "</button>" +
    '<span class="seek" dir="ltr"><span class="time" data-time="now">' + clock(0) + '</span>' +
    '<input type="range" min="0" max="1000" value="0" step="1" aria-label="جای پخش">' +
    '<span class="time" data-time="total">' + clock(0) + "</span></span>" +
    "</div>";
  document.body.appendChild(bar);
  var titleEl = bar.querySelector(".title");
  var artistEl = bar.querySelector(".sub bdi");
  var toggle = bar.querySelector('[data-act="toggle"]');
  var range = bar.querySelector("input");
  var nowEl = bar.querySelector('[data-time="now"]');
  var totalEl = bar.querySelector('[data-time="total"]');
  var seeking = false;

  function setPlaying(playing) {
    toggle.innerHTML = icon(playing ? PAUSE : PLAY);
    toggle.setAttribute("aria-label", playing ? "توقف" : "پخش");
    tracks.forEach(function (t, i) {
      var button = t.row.querySelector(".row-play");
      var on = i === current && playing;
      t.row.classList.toggle("playing", i === current);
      if (button) {
        button.innerHTML = icon(on ? PAUSE : PLAY);
        button.setAttribute("aria-label", (on ? "توقف " : "پخش ") + t.title);
      }
    });
    if ("mediaSession" in navigator) navigator.mediaSession.playbackState = playing ? "playing" : "paused";
  }

  function play(i) {
    if (i < 0 || i >= tracks.length) return;
    var t = tracks[i];
    if (i !== current) {
      current = i;
      audio.src = t.src;
      titleEl.textContent = t.title;
      artistEl.textContent = t.artist;
      range.value = 0;
      nowEl.textContent = clock(0);
      totalEl.textContent = clock(0);
      if ("mediaSession" in navigator && window.MediaMetadata) {
        var meta = { title: t.title, artist: t.artist, album: document.title };
        if (t.art) meta.artwork = [{ src: t.art }];
        navigator.mediaSession.metadata = new MediaMetadata(meta);
      }
    }
    bar.hidden = false;
    document.body.classList.add("has-bar");
    var started = audio.play();
    if (started && started.catch) started.catch(function () { setPlaying(false); });
  }

  function toggleAt(i) {
    if (i === current && !audio.paused) audio.pause();
    else play(i);
  }

  tracks.forEach(function (t, i) {
    var native = t.row.querySelector("audio");
    if (native) { native.removeAttribute("controls"); native.hidden = true; }
    var button = document.createElement("button");
    button.type = "button";
    button.className = "icon-button row-play";
    button.setAttribute("aria-label", "پخش " + t.title);
    button.innerHTML = icon(PLAY);
    button.addEventListener("click", function () { toggleAt(i); });
    t.row.appendChild(button);
  });

  Array.prototype.forEach.call(document.querySelectorAll("[data-play-all]"), function (b) {
    b.hidden = false;
    b.addEventListener("click", function () { current >= 0 ? toggleAt(current) : play(0); });
  });

  bar.addEventListener("click", function (e) {
    var b = e.target.closest ? e.target.closest("[data-act]") : null;
    if (!b) return;
    var act = b.getAttribute("data-act");
    if (act === "toggle") toggleAt(Math.max(current, 0));
    else if (act === "next") play(current + 1);
    else if (act === "prev") audio.currentTime > 3 ? (audio.currentTime = 0) : play(Math.max(current - 1, 0));
  });

  range.addEventListener("input", function () {
    seeking = true;
    if (isFinite(audio.duration)) nowEl.textContent = clock(audio.duration * range.value / 1000);
  });
  range.addEventListener("change", function () {
    if (isFinite(audio.duration)) audio.currentTime = audio.duration * range.value / 1000;
    seeking = false;
  });

  audio.addEventListener("play", function () { setPlaying(true); });
  audio.addEventListener("pause", function () { setPlaying(false); });
  audio.addEventListener("loadedmetadata", function () { totalEl.textContent = clock(audio.duration); });
  audio.addEventListener("timeupdate", function () {
    if (seeking || !isFinite(audio.duration) || !audio.duration) return;
    range.value = Math.round(audio.currentTime / audio.duration * 1000);
    nowEl.textContent = clock(audio.currentTime);
  });
  audio.addEventListener("ended", function () {
    if (current + 1 < tracks.length) play(current + 1);
    else setPlaying(false);
  });

  if ("mediaSession" in navigator) {
    var handlers = {
      play: function () { play(Math.max(current, 0)); },
      pause: function () { audio.pause(); },
      nexttrack: function () { play(current + 1); },
      previoustrack: function () { play(Math.max(current - 1, 0)); }
    };
    Object.keys(handlers).forEach(function (k) {
      try { navigator.mediaSession.setActionHandler(k, handlers[k]); } catch (e) { /* not supported */ }
    });
  }
})();
