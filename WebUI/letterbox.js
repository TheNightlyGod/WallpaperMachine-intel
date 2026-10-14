// The inspector's Black bars card for an installed video: an explicit check that samples a few
// frames of the file for bars baked into the picture, and what Fill with a scale factor would do
// about them on the target display. Everything shown comes from the snapshot's `videoLetterbox`
// (a state, a reason code, the measured bars, a suggestion native computed for this display and
// whether it can be staged); the page chooses the words and decides nothing about the video.
// Staging sends only which wallpaper and display: native recomputes the factor itself.
import { t } from './i18n.js';

// A status glyph per outcome, drawn in the compatibility card's colours.
const outcomes = {
  none: ['circleCheck', 'ok'],
  found: ['info', ''],
  unclear: ['circleHelp', 'unknown'],
  failed: ['triangleAlert', 'warning'],
};

export function createLetterbox({ escapeHTML, icon, button, keyAttr, busy }) {
  let state = null;
  const sync = (snapshot) => { state = snapshot; };
  const report = () => state?.videoLetterbox;
  const shown = (item) => Boolean(report() && report().wallpaperID === item.id);

  const percent = (value) => Math.max(1, Math.round(Number(value) * 100));
  const factor = (value) => String(Number(Number(value).toFixed(2)));
  const modes = () => ({ none: t('Original size'), stretch: t('Stretch'), match: t('Fit'), fill: t('Fill') });

  // What was found, in words, from the measured bars.
  function finding(bars) {
    const vertical = Number(bars?.top) > 0 && Number(bars?.bottom) > 0;
    const horizontal = Number(bars?.left) > 0 && Number(bars?.right) > 0;
    if (vertical && horizontal) return t('Black bars found on all four sides, up to {percent}% of the picture.', { percent: percent(Math.max(bars.top, bars.bottom, bars.left, bars.right)) });
    if (horizontal) return t('Black bars found at the left and right, about {percent}% of the picture on each side.', { percent: percent(Math.max(bars.left, bars.right)) });
    return t('Black bars found at the top and bottom, about {percent}% of the picture on each side.', { percent: percent(Math.max(Number(bars?.top) || 0, Number(bars?.bottom) || 0)) });
  }

  // What Fill and a scale factor would do about found bars on this display.
  function advice(data) {
    const suggestion = data.suggestion;
    if (suggestion?.kind === 'factor' && Number.isFinite(Number(suggestion.factor))) return t('With Fill on this display, a scale factor of ×{factor} hides them.', { factor: factor(suggestion.factor) });
    if (suggestion?.kind === 'hidden') return t('Fill on this display already crops them out.');
    if (suggestion?.kind === 'implausible') return t('The bars look too large to be reliable, so nothing is suggested.');
    const mode = data.current?.scalingMode;
    if (mode && mode !== 'fill' && modes()[mode]) return t('This display uses {mode} scaling. Black bars can be hidden with Fill and a scale factor.', { mode: modes()[mode] });
    return '';
  }

  function unclear(reason) {
    if (reason === 'dark') return t('The sampled frames are too dark to tell.');
    if (reason === 'disagree') return t('The sampled frames do not agree on where the bars are.');
    if (reason === 'fewFrames') return t('Too few different frames could be sampled to tell.');
    return t('The bars look too large to be reliable, so nothing is suggested.');
  }

  function failed(reason) {
    if (reason === 'timedOut') return t('Reading the video took too long.');
    if (reason === 'changed') return t('The video changed while it was being checked. Look again.');
    return t('This video cannot be read here, so it cannot be checked.');
  }

  // [outcome, headline, detail] for a finished check, or null before one.
  function result(data) {
    switch (data.state) {
      case 'none': return ['none', t('No black bars found.'), ''];
      case 'bars': return ['found', finding(data.bars), advice(data)];
      case 'uneven': return ['found', t('The bars are uneven, so a scale factor could not hide them without cutting into the picture.'), ''];
      case 'unclear': return ['unclear', unclear(data.reason), ''];
      case 'failed': return ['failed', failed(data.reason), ''];
      default: return null;
    }
  }

  function section(item, target) {
    if (!shown(item)) return '';
    const data = report();
    const checking = data.state === 'checking';
    const targetOK = Boolean(data.eligible) && Boolean(target?.enabled) && target.mode !== 'mirror' && target.id === data.displayID;
    const args = { id: item.id, displayID: data.displayID };
    const found = result(data);
    let body = '';
    if (checking) {
      body = `<p class="muted" role="status"><span class="compat-summary checking">${icon('loader', 12)}<small>${escapeHTML(t('Looking for black bars…'))}</small></span></p>`;
    } else if (found) {
      const [outcome, headline, detail] = found;
      const [glyph, status] = outcomes[outcome];
      body = `<ul class="compat-list"><li class="compat-check ${status}" ${keyAttr(`letterbox-result-${item.id}`)}><span class="compat-glyph" aria-hidden="true">${icon(glyph, 15)}</span><div class="compat-body"><span class="compat-title">${escapeHTML(headline)}</span>${detail ? `<span class="compat-detail">${escapeHTML(detail)}</span>` : ''}</div></li></ul>`;
    }
    const label = data.state === 'idle' || checking ? t('Look for black bars') : t('Look again');
    const check = button(label, 'videoLetterboxCheck', args, { className: 'link', icon: 'refresh', disabled: checking || !targetOK || busy('videoLetterboxCheck', args), title: targetOK ? '' : t('Choose an enabled, independent target display to check this wallpaper') });
    const [stageButton, stageNote] = staging(item, data, args, targetOK);
    return `<section class="inspector-section"><details open ${keyAttr(`letterbox-${item.id}`)}><summary><span class="compat-heading">${escapeHTML(t('Black bars'))}</span>${icon('chevronRight', 14)}</summary><div class="section-content compat">`
      + `<p class="muted"><small>${escapeHTML(t('Some videos have black bars baked into the picture. Looking samples a few frames of the file; nothing is changed.'))}</small></p>`
      + body
      + `<div class="actions">${stageButton}${check}</div>${stageNote}</div></details></section>`;
  }

  // The button that fills in the display's Scale factor with the suggested one, and the line under
  // it: what it does, or that the factor is now in the draft. The factor named on
  // the button and in the line comes from the snapshot, never from what the page last did.
  function staging(item, data, args, targetOK) {
    const stage = data.state === 'bars' && data.suggestion?.kind === 'factor' ? data.stage : null;
    if (!stage) return ['', ''];
    const note = (text, key, live = false) => `<p class="muted"${live ? ' role="status"' : ''} ${keyAttr(`${key}-${item.id}`)}><small>${escapeHTML(text)}</small></p>`;
    if (stage.applied) {
      if (!stage.pending) return ['', ''];
      return ['', note(t('Scale factor is set to ×{factor}. Choose Apply changes to keep it, or Revert to undo.', { factor: factor(data.current?.scalingFactor) }), 'letterbox-staged', true)];
    }
    const suggested = factor(data.suggestion.factor);
    const stageButton = button(t('Set scale factor to ×{factor}', { factor: suggested }), 'videoLetterboxStage', args, { className: 'link', icon: 'slidersVertical', disabled: !targetOK || !stage.available || busy('videoLetterboxStage', args) });
    return [stageButton, note(t('Fills in this display’s Scale factor. Nothing is saved until you choose Apply changes.'), 'letterbox-stage-note')];
  }

  return { sync, section };
}
