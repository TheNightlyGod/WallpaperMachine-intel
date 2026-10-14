// The inspector's Compatibility card for an installed wallpaper: what native could establish
// about it before it plays (files, resources, lock screen, native video admission, scene
// support where the parsed scene says so), and which backend is drawing it now, if any. Every
// line comes from the snapshot's `wallpaperCompatibility`; the page adds no verdict of its own,
// and an unknown stays unknown until the wallpaper runs.
import { t } from './i18n.js';

// Status glyphs and their colours live in the stylesheet; the words are for the screen reader.
const statuses = {
  ok: ['circleCheck', 'OK'],
  warning: ['triangleAlert', 'Warning'],
  unavailable: ['circleX', 'Unavailable'],
  unknown: ['circleHelp', 'Unknown'],
};

// The checks about the installed copy itself (its manifest and its entry file).
const repairable = new Set(['project', 'entry']);

export function createCompatibility({ escapeHTML, icon, button, keyAttr, busy, canReinstall }) {
  let state = null;
  const sync = (snapshot) => { state = snapshot; };
  const report = () => state?.wallpaperCompatibility;
  const shown = (item) => Boolean(report() && report().wallpaperID === item.id);

  function summary(checks, checking) {
    if (checking) return t('Checking…');
    const counts = { warning: 0, unavailable: 0, unknown: 0 };
    for (const check of checks) if (check.status in counts) counts[check.status] += 1;
    const parts = [];
    if (counts.unavailable) parts.push(t(counts.unavailable === 1 ? '1 unavailable' : '{count} unavailable', { count: counts.unavailable }));
    if (counts.warning) parts.push(t(counts.warning === 1 ? '1 warning' : '{count} warnings', { count: counts.warning }));
    if (counts.unknown) parts.push(t(counts.unknown === 1 ? '1 unknown' : '{count} unknown', { count: counts.unknown }));
    if (parts.length) return parts.join(' · ');
    return checks.length ? t('No problems found') : '';
  }

  function section(item, target) {
    if (!shown(item)) return '';
    const data = report();
    const checks = (Array.isArray(data.checks) ? data.checks : []).filter(check => check && typeof check === 'object');
    const checking = Boolean(data.checking);
    const targetOK = Boolean(target?.enabled) && target.mode !== 'mirror' && target.id === data.displayID;
    const rows = checks.map((check, index) => {
      const [glyph, word] = statuses[check.status] || statuses.unknown;
      const status = statuses[check.status] ? check.status : 'unknown';
      return `<li class="compat-check ${status}" ${keyAttr(`check-${check.id || index}`)}><span class="compat-glyph" role="img" aria-label="${escapeHTML(t(word))}">${icon(glyph, 15)}</span><div class="compat-body"><span class="compat-title">${escapeHTML(check.title || '')}</span>${check.detail ? `<span class="compat-detail">${escapeHTML(check.detail)}</span>` : ''}</div></li>`;
    }).join('');
    const backend = data.backend
      ? `<p class="compat-backend"><small>${escapeHTML(data.reason ? t('Drawn now by {backend} (fallback: {reason})', { backend: data.backend, reason: data.reason }) : t('Drawn now by {backend}', { backend: data.backend }))}</small></p>`
      : `<p class="compat-backend muted"><small>${escapeHTML(t('Which backend draws it is known once it plays on this display.'))}</small></p>`;
    const words = summary(checks, checking);
    const empty = !checks.length && !checking ? `<p class="muted"><small>${escapeHTML(t('Not checked yet on this display.'))}</small></p>` : '';
    const check = button(checks.length ? t('Check again') : t('Check compatibility'), 'compatibilityCheck', { id: item.id, displayID: data.displayID }, { className: 'link', icon: 'refresh', disabled: checking || !targetOK || busy('compatibilityCheck', { id: item.id, displayID: data.displayID }), title: targetOK ? t('Reads the wallpaper’s files again and re-runs the checks') : t('Choose an enabled, independent target display to check this wallpaper') });
    // Only the installed files are what a fresh copy from the Workshop repairs: the lock screen, the target
    // display, native video admission and the shared scene resources are unavailable for reasons it leaves as they are.
    const repairs = checks.some(entry => entry.status === 'unavailable' && repairable.has(entry.id));
    const reinstall = repairs && item.kind !== 'Unknown' && canReinstall(item)
      ? button(t('Reinstall from Workshop…'), 'workshopReinstall', { id: item.id }, { className: 'link', icon: 'refresh' }) : '';
    return `<section class="inspector-section"><details open ${keyAttr(`compatibility-${item.id}`)}><summary><span class="compat-heading">${escapeHTML(t('Compatibility check'))}${words ? `<span class="compat-summary${checking ? ' checking' : ''}" role="status">${checking ? icon('loader', 12) : ''}${escapeHTML(words)}</span>` : ''}</span>${icon('chevronRight', 14)}</summary><div class="section-content compat">`
      + (rows ? `<ul class="compat-list" aria-busy="${checking}">${rows}</ul>` : checking ? `<p class="muted" role="status"><small>${escapeHTML(t('Reading the wallpaper’s files…'))}</small></p>` : empty)
      + backend
      + (data.error ? `<p class="notice error" role="alert">${escapeHTML(data.error)}</p>` : '')
      + `<div class="actions">${check}${reinstall}</div></div></details></section>`;
  }

  return { sync, section };
}
