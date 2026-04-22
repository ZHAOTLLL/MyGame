/**
 * Cyberpunk upper-body character busts (8 SVG variants).
 */
(function () {
  const NS = "http://www.w3.org/2000/svg";

  const BUSTS = [
    `<svg viewBox="0 0 88 108" xmlns="${NS}" class="cyber-svg"><defs><linearGradient id="a0" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#00d8ff"/><stop offset="1" stop-color="#ff9f2d"/></linearGradient><filter id="g0"><feGaussianBlur stdDeviation="0.8" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs><path d="M44 4 L72 38 L68 104 L20 104 L16 38 Z" fill="#0f1520" stroke="url(#a0)" stroke-width="1.4"/><ellipse cx="44" cy="36" rx="22" ry="16" fill="#091018" stroke="#00d8ff" stroke-width="1"/><rect x="24" y="32" width="40" height="4" rx="1" fill="#00d8ff" filter="url(#g0)" opacity=".95"/><path d="M22 58 Q44 72 66 58 L64 98 L24 98 Z" fill="#121d28" stroke="#ff9f2d" stroke-width="0.8" opacity=".9"/><path d="M30 78 L44 88 L58 78" fill="none" stroke="#00d8ff" stroke-width="0.6" opacity=".5"/></svg>`,
    `<svg viewBox="0 0 88 108" xmlns="${NS}" class="cyber-svg"><defs><linearGradient id="a1" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff6a2a"/><stop offset="1" stop-color="#ffb347"/></linearGradient></defs><path d="M44 6 L38 22 L50 22 Z" fill="#ff6a2a"/><path d="M32 18 L44 8 L56 18 L52 28 L36 28 Z" fill="#17110d" stroke="url(#a1)" stroke-width="1.2"/><rect x="38" y="26" width="12" height="14" rx="2" fill="#0f0d0a" stroke="#ff6a2a" stroke-width="1"/><circle cx="48" cy="33" r="4" fill="#ff6a2a" opacity=".9"/><path d="M24 48 L64 48 L70 104 L18 104 Z" fill="#17120d" stroke="#ffb347" stroke-width="1.2"/><line x1="32" y1="62" x2="56" y2="62" stroke="#ff6a2a" stroke-width="0.5" opacity=".4"/></svg>`,
    `<svg viewBox="0 0 88 108" xmlns="${NS}" class="cyber-svg"><defs><linearGradient id="a2" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#06ffa5"/><stop offset="1" stop-color="#00bbf9"/></linearGradient></defs><path d="M8 42 L80 42 L76 106 L12 106 Z" fill="#0a1218" stroke="url(#a2)" stroke-width="1.5"/><path d="M44 8 L62 40 L26 40 Z" fill="#0d1820" stroke="#06ffa5" stroke-width="1"/><rect x="34" y="18" width="20" height="14" rx="2" fill="#050a0e" stroke="#00bbf9" stroke-width="0.8"/><line x1="38" y1="24" x2="38" y2="32" stroke="#06ffa5" stroke-width="2"/><line x1="50" y1="24" x2="50" y2="32" stroke="#06ffa5" stroke-width="2"/><rect x="28" y="48" width="32" height="4" fill="#06ffa5" opacity=".25"/><path d="M20 70 L68 70" stroke="#00bbf9" stroke-width="0.5" opacity=".4"/></svg>`,
    `<svg viewBox="0 0 88 108" xmlns="${NS}" class="cyber-svg"><defs><linearGradient id="a3" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffbe0b"/><stop offset="1" stop-color="#fb5607"/></linearGradient></defs><path d="M28 12 Q44 4 60 12 L64 48 Q44 38 24 48 Z" fill="#1a1208" stroke="#ffbe0b" stroke-width="1"/><ellipse cx="44" cy="34" rx="18" ry="20" fill="#120a0a" stroke="url(#a3)" stroke-width="1.2"/><path d="M30 28 L58 28 M30 34 L58 34 M30 40 L58 40" stroke="#fb5607" stroke-width="0.6" opacity=".7"/><path d="M18 52 L70 52 L66 106 L22 106 Z" fill="#160e12" stroke="#ffbe0b" stroke-width="1"/><circle cx="36" cy="72" r="3" fill="#ffbe0b" opacity=".4"/><circle cx="52" cy="72" r="3" fill="#fb5607" opacity=".4"/></svg>`,
    `<svg viewBox="0 0 88 108" xmlns="${NS}" class="cyber-svg"><defs><linearGradient id="a4" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#00c2ff"/><stop offset="1" stop-color="#5ae3ff"/></linearGradient></defs><circle cx="44" cy="36" r="22" fill="#0d1720" stroke="url(#a4)" stroke-width="1.4"/><circle cx="44" cy="36" r="14" fill="#091018" stroke="#5ae3ff" stroke-width="0.8"/><circle cx="44" cy="36" r="6" fill="#083147" stroke="#d6fbff" stroke-width="0.6"/><path d="M12 36 L4 36 L4 52 L12 52" fill="none" stroke="#00c2ff" stroke-width="1.5"/><path d="M76 36 L84 36 L84 52 L76 52" fill="none" stroke="#00c2ff" stroke-width="1.5"/><path d="M24 70 L64 70 L60 104 L28 104 Z" fill="#0c1820" stroke="#1e88ff" stroke-width="1"/><line x1="44" y1="58" x2="44" y2="70" stroke="#5ae3ff" stroke-width="1"/></svg>`,
    `<svg viewBox="0 0 88 108" xmlns="${NS}" class="cyber-svg"><defs><linearGradient id="a5" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#00f5ff" stop-opacity="0.2"/><stop offset="0.5" stop-color="#00f5ff" stop-opacity="0.9"/><stop offset="1" stop-color="#00f5ff" stop-opacity="0.2"/></linearGradient></defs><path d="M44 6 L70 34 L66 104 L22 104 L18 34 Z" fill="#080c14" stroke="#00f5ff" stroke-width="1.2"/><path d="M22 30 L66 30 L62 40 L26 40 Z" fill="url(#a5)" stroke="#00f5ff" stroke-width="0.6"/><ellipse cx="44" cy="52" rx="16" ry="10" fill="#0a1018" stroke="#00f5ff" stroke-width="0.5" opacity=".6"/><path d="M26 68 L62 68 L58 100 L30 100 Z" fill="#0a0e16" stroke="#3a86ff" stroke-width="0.9"/><path d="M34 76 L44 86 L54 76" fill="none" stroke="#00f5ff" stroke-width="0.8" opacity=".5"/></svg>`,
    `<svg viewBox="0 0 88 108" xmlns="${NS}" class="cyber-svg"><defs><linearGradient id="a6" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#ef233c"/><stop offset="1" stop-color="#ff4d6d"/></linearGradient></defs><rect x="14" y="28" width="10" height="20" rx="2" fill="#1a080c" stroke="#ef233c" stroke-width="0.8"/><rect x="64" y="28" width="10" height="20" rx="2" fill="#1a080c" stroke="#ef233c" stroke-width="0.8"/><path d="M44 10 L58 32 L58 48 L30 48 L30 32 Z" fill="#14080a" stroke="url(#a6)" stroke-width="1.3"/><path d="M36 36 L44 44 L52 36" fill="none" stroke="#ff4d6d" stroke-width="1"/><path d="M20 54 L68 54 L64 106 L24 106 Z" fill="#120608" stroke="#ef233c" stroke-width="1.1"/><line x1="44" y1="60" x2="44" y2="88" stroke="#ff4d6d" stroke-width="0.4" opacity=".5"/></svg>`,
    `<svg viewBox="0 0 88 108" xmlns="${NS}" class="cyber-svg"><defs><linearGradient id="a7" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffd60a"/><stop offset="1" stop-color="#ff9e00"/></linearGradient></defs><path d="M4 40 L44 8 L84 40 L78 108 L10 108 Z" fill="#0f0a06" stroke="url(#a7)" stroke-width="1.2"/><ellipse cx="44" cy="38" rx="20" ry="22" fill="#120a08" stroke="#ffd60a" stroke-width="1"/><ellipse cx="44" cy="38" rx="10" ry="4" fill="#ffd60a" opacity=".85"/><path d="M24 58 L64 58 L60 100 L28 100 Z" fill="#1a1208" stroke="#ff9e00" stroke-width="0.8"/><rect x="40" y="64" width="8" height="28" rx="1" fill="#ff9e00" opacity=".15"/></svg>`,
  ];

  const PALETTES = [
    "cyan",
    "amber",
    "mint",
    "amber",
    "steel",
    "azure",
    "crimson",
    "gold",
  ];

  function cyberCharacterBust(avatarIndex) {
    const idx = Math.max(0, Math.min(7, (Number(avatarIndex) || 1) - 1));
    const palette = PALETTES[idx] || PALETTES[0];
    return `
      <div class="avatar-shell avatar-shell--${palette}">
        <div class="avatar-3d-scene">
          <div class="avatar-platform" aria-hidden="true">
            <span class="avatar-platform-ring ring-a"></span>
            <span class="avatar-platform-ring ring-b"></span>
            <span class="avatar-platform-core"></span>
          </div>
          <div class="avatar-model">
            <div class="avatar-model-shadow" aria-hidden="true"></div>
            <div class="avatar-torso" aria-hidden="true">
              <span class="avatar-panel panel-left"></span>
              <span class="avatar-panel panel-right"></span>
            </div>
            <div class="avatar-neck" aria-hidden="true"></div>
            <div class="avatar-head">
              <div class="avatar-head-face front">${BUSTS[idx] || BUSTS[0]}</div>
              <div class="avatar-head-face back"></div>
              <div class="avatar-head-face left"></div>
              <div class="avatar-head-face right"></div>
              <div class="avatar-head-face top"></div>
              <div class="avatar-head-face bottom"></div>
            </div>
            <div class="avatar-orbit" aria-hidden="true"></div>
          </div>
        </div>
      </div>
    `;
  }

  window.cyberCharacterBust = cyberCharacterBust;
})();
